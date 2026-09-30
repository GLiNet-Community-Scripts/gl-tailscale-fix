#!/bin/bash
#
# FM2 — WAN interface change / multi-WAN autoswitch / temp disconnect-reconnect.
#
# This is the reset-window failure mode: an ifup (WAN reconnect, eth->repeater->
# tether autoswitch, or roam) makes GL run "gl_tailscale restart" -> "tailscale
# up --reset". During that window Tailscale's own KS is briefly down and GL
# rebuilds its routing rules; OUR kill switch must hold throughout.
#
# The kill switch has TWO layers, and "must hold" means at least one of them holds for
# every source zone (lan, guest, iot) in both families at every instant:
#   rule layer  iif br-lan/br-guest/br-iot priority 5279 -> table 100 `unreachable default`,
#               per family. netifd's start wipes every policy rule; a firewall restart
#               leaves them alone.
#   zone layer  every lan/guest/iot -> uplink-class forwarding disabled in flash-persisted
#               UCI, each recorded as a src:dest pair in ts-fix.settings.ks_severed, which
#               fw3 re-emits at every reload. A firewall restart flushes netfilter to policy
#               ACCEPT for a moment (0.2-1.6 s in Phase M, 2026-09-05); GL's gl_tailscale
#               restart runs one on 4.9+.
# This leg's reset window can hit either eraser. `start` refuses a router on which EITHER
# layer is not armed; `analyze` applies the combined predicate to every router sample.
# The laptop-side leak verdict remains the authority: any non-tunnel public IP is a LEAK.
#
# This script is a TEMPLATE for the other failure modes: a "start" phase that
# launches the monitors and prints the operator runbook, and an "analyze" phase
# that correlates the laptop egress artifact with the router state artifact.
#
# SAFETY: an armed kill switch cuts this laptop off with everything else behind
# the router. The egress monitor is time-boxed and fully detached, so it keeps
# recording right through the cut-off and self-stops. This script issues NO
# state-changing commands on the router — every probe it runs is read-only, and
# the operator triggers the WAN event and the recovery (disable the KS, or
# disable TS) by hand, per the printed timeline.
#
# Usage:
#   ./fm2-wan-bounce.sh start   --target <router-ip> [--duration 180] [--label fm2-<fw>]
#   ./fm2-wan-bounce.sh analyze --egress <base> --router <router.csv> \
#                               [--offset <sec>] [--trigger <epoch>] [--recover <epoch>]
#
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix

set -u
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

FM="fm2"
FM_DESC="WAN bounce / autoswitch / reconnect (the up --reset window)"

# Usage text is the file's HEADER block only — the contiguous comment run under the shebang, which
# ends at the first non-comment line. A whole-file `grep '^#'` used to be equivalent; it stopped
# being so once helper functions below grew comment blocks of their own, and it would now dump
# their internals at anyone who typed a bad argument.
usage() { awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 1; }

# The arming probe, exactly as it is sent to the router's `sh -s` (READ-ONLY, safe on the gateway).
# It prints "1" only when BOTH layers are armed, else "0":
#   zone layer  ts-fix.settings.ks_severed populated AND every pair it records matches a forwarding
#               whose enabled is exactly '0' — a sidecar with re-enabled forwardings is open egress
#               reporting armed, and disabled forwardings with no sidecar cannot be restored;
#   rule layer  per family, `ip rule list priority 5279` holds, for EACH of br-lan, br-guest and
#               br-iot, a rule matched on whole tokens: `from all`, iif equal to the bridge, the table
#               token after `lookup` exactly 100 (GL's `lookup 1002` never counts), no other selector;
#               `iif br-iot [detached]` counts, as the engine installs it where iot does not exist.
#               And table 100 holds `unreachable default`, per family.
# `_armed_probe` prints it, so the unit test runs this very text against fixtures.
fm2_armed_probe_script() {
  cat <<'PROBE'
set -f
sev=$(uci -q get ts-fix.settings.ks_severed 2>/dev/null)
[ -n "$sev" ] || { echo 0; exit 0; }
secs=""
for l in $(uci show firewall 2>/dev/null); do
  case "$l" in firewall.*=forwarding) secs="$secs ${l%=forwarding}" ;; esac
done
for pair in $sev; do
  hit=0
  for sec in $secs; do
    [ "$(uci -q get "$sec.src"):$(uci -q get "$sec.dest")" = "$pair" ] || continue
    hit=1
    [ "$(uci -q get "$sec.enabled")" = "0" ] || { echo 0; exit 0; }
  done
  [ "$hit" = "1" ] || { echo 0; exit 0; }
done
for fam in -4 -6; do
  ip $fam rule list priority 5279 2>/dev/null | awk '
    $1 == "5279:" {
      from = ""; iif = ""; tab = ""; other = 0
      for (i = 2; i <= NF; i++) {
        if ($i == "from") { from = $(++i); continue }
        if ($i == "iif") { iif = $(++i); continue }
        if ($i == "[detached]") continue
        if ($i == "lookup" || $i == "table") { tab = $(++i); continue }
        if ($i == "proto" || $i == "protocol") { i++; continue }
        other = 1
      }
      if (from == "") from = "all"
      if (from == "all" && tab == "100" && !other) ok[iif] = 1
    }
    END { exit !(ok["br-lan"] && ok["br-guest"] && ok["br-iot"]) }' || { echo 0; exit 0; }
  ip $fam route show table 100 2>/dev/null \
    | awk '$1 == "unreachable" && $2 == "default" { f = 1 } END { exit !f }' || { echo 0; exit 0; }
done
echo 1
PROBE
}

# Both-layer kill-switch presence on the router. "0" also on an unreachable router, which
# cmd_start treats as a hard stop.
#   $1 = target
fm2_ks_armed() {
  # shellcheck disable=SC2086  # SSH_OPTS is a word list of options (common.sh), split on purpose
  fm2_armed_probe_script | ssh $SSH_OPTS "root@$1" 'sh -s' 2>/dev/null
}

# The raw observation that belongs beside the verdict: the sidecar, every lan/guest/iot forwarding
# with its enabled value, the priority-5279 rules and table 100 of both families. Printed into the
# run's own log so a surprising verdict is triageable from the artifact rather than from another
# 3-minute window with an operator standing by.
#   $1 = target
fm2_ks_dump() {
  # shellcheck disable=SC2086  # SSH_OPTS is a word list of options (common.sh), split on purpose
  ssh $SSH_OPTS "root@$1" 'sh -s' 2>/dev/null <<'DUMP'
set -f
echo "sidecar=[$(uci -q get ts-fix.settings.ks_severed 2>/dev/null)]"
echo "kill_switch=[$(uci -q get ts-fix.settings.kill_switch 2>/dev/null)] ts_enabled=[$(uci -q get tailscale.settings.enabled 2>/dev/null)]"
for l in $(uci show firewall 2>/dev/null); do
  case "$l" in firewall.*=forwarding) ;; *) continue ;; esac
  sec=${l%=forwarding}
  src=$(uci -q get "$sec.src")
  case "$src" in lan|guest|iot) ;; *) continue ;; esac
  echo "fwd $sec $src:$(uci -q get "$sec.dest") enabled=[$(uci -q get "$sec.enabled")]"
done
for fam in -4 -6; do
  ip $fam rule list priority 5279 2>/dev/null | sed "s/^/rule$fam /"
  ip $fam route show table 100 2>/dev/null | sed "s/^/table100$fam /"
done
DUMP
}

# Column index of a named field in a CSV's header row, empty when the artifact does not carry it.
# Used instead of hardcoded positions so analyze survives a router-sampler schema change instead
# of silently decoding the wrong column.
#   $1 = csv ; $2 = column name
csv_col() { awk -F, -v want="$2" 'NR==1{for(i=1;i<=NF;i++) if($i==want){print i; exit}}' "$1"; }

# The two-layer protection predicate over every sample taken with armed intent (uci_ks=1), from a
# current router-sampler artifact. PROTECTION LOST = for some source zone the router has (the
# sampler's zones column) and some family, the zone layer is open AND the rule layer fails:
#   zone open    pol<f> != DROP, ch_<z><f> != 1 or j_<z><f> != 0 (netfilter), or sev_open_<z> != 0
#                (a recorded pair of that zone re-enabled in UCI, which the next reload would emit)
#   rule fails   r_<z><f> < 1, t100_<f> < 1, or sh_<z><f> != 0 (a rule ahead of 5279 — GL's guest/iot
#                `from <net> lookup main` — takes the bridge's traffic to main first)
# NA and ERR never count as holding. On fw4 the netfilter columns read NA (the sampler does not read
# nft), so the zone layer can never be confirmed there and every armed sample without the rule
# layer counts as lost: conservative, and said so in a NOTE.
#   $1 = router csv
fm2_protection_lost() {
  awk -F, '
    function isn(v) { return v ~ /^[0-9]+$/ }
    function col(n) { return (n in C) ? $(C[n]) : "NA" }
    NR == 1 { for (i = 1; i <= NF; i++) C[$i] = i; next }
    {
      if (nz == 0) {
        zones = col("zones")
        if (zones == "" || zones == "NA") { zones = "lan guest iot"; zguess = 1 }
        nz = split(zones, Z, " ")
      }
      if (col("uci_ks") != "1") { unarmed++; next }
      armed++
      for (f = 4; f <= 6; f += 2) for (k = 1; k <= nz; k++) {
        z = Z[k]; key = z f
        r = col("r_" z f); t = col("t100_" f); s = col("sh_" z f)
        rule_ok = isn(r) && r + 0 >= 1 && isn(t) && t + 0 >= 1 && isn(s) && s + 0 == 0
        p = col("pol" f); h = col("ch_" z f); j = col("j_" z f); uo = col("sev_open_" z)
        if (p == "NA") nfna = 1
        zone_ok = p == "DROP" && h == "1" && j == "0" && uo == "0"
        if (!rule_ok && !zone_ok) {
          L[key]++; tot++
          if (shown < 20) {
            shown++
            printf "  LOST %s @%s: rule[r=%s t100=%s sh=%s] zone[pol=%s ch=%s j=%s sev_open=%s]\n", \
              key, $1, r, t, s, p, h, j, uo
            print "        raw: " $0
          }
        }
      }
    }
    END {
      s = ""
      for (f = 4; f <= 6; f += 2) for (k = 1; k <= nz; k++) s = s " " Z[k] f "=" L[Z[k] f] + 0
      if (tot == 0) printf "  none: 0 lost in %d armed sample(s) (%s)\n", armed, substr(s, 2)
      else printf "  LOST in %d (zone, family, sample) instance(s) over %d armed sample(s):%s\n", tot, armed, s
      if (unarmed) printf "  (%d sample(s) without armed intent were not judged)\n", unarmed
      if (zguess) print "  NOTE: no zones column - evaluated lan, guest and iot"
      if (nfna) print "  NOTE: netfilter columns are NA (fw4): the zone layer cannot be confirmed from this artifact, so every armed sample without the rule layer counts as lost"
    }' "$1"
}

cmd_start() {
  local target="" duration=180
  LABEL="${LABEL:-fm2}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)   target="$2"; shift 2 ;;
      --duration) duration="$2"; shift 2 ;;
      --label)    LABEL="$2"; shift 2 ;;
      *) echo "unknown arg: $1" >&2; usage ;;
    esac
  done
  [ -z "$target" ] && { echo "ERROR: --target <router-ip> required" >&2; usage; }

  echo "=== FM2 START — $FM_DESC ==="
  echo "target router : $target"
  echo

  echo "[1/4] Capturing tunnel baseline (current laptop egress — should be the EXIT NODE IP)..."
  local b4 b6; b4="$(tsfx_curl_ip -4)"; b6="$(tsfx_curl_ip -6)"
  echo "      tunnel_v4 = ${b4:-<none>}"
  echo "      tunnel_v6 = ${b6:-<none>}"
  if [ -z "$b4" ] && [ -z "$b6" ]; then
    echo "      ABORT: no egress on either family, so there is no tunnel baseline to" >&2
    echo "      compare against. Without one the run cannot distinguish 'the kill switch" >&2
    echo "      blocked it' from 'this client never had egress', and an all-blocked" >&2
    echo "      window would be scored as a pass having exercised nothing. Confirm TS is" >&2
    echo "      enabled, the Custom Exit Node is set, and traffic is actually flowing" >&2
    echo "      through the tunnel, then re-run." >&2
    exit 1
  fi
  echo

  echo "[2/4] Measuring router<->laptop clock offset + reading kill-switch state, both layers (read-only)..."
  local offset; offset="$(tsfx_clock_offset "$target")"
  echo "      offset (router_epoch - laptop_epoch) = $offset s"
  local armed; armed="$(fm2_ks_armed "$target")"
  echo "      kill switch armed (zone AND rule layer) = ${armed:-0}"
  fm2_ks_dump "$target" | sed 's/^/      ks /'
  if [ "${armed:-0}" != "1" ]; then
    echo "      ABORT: the kill switch is not fully armed on $target, so this window would" >&2
    echo "      measure a HALF-PROTECTED (or unprotected) router and score whatever it saw." >&2
    echo "      Armed means BOTH layers: ts-fix.settings.ks_severed is populated and every pair" >&2
    echo "      it records reads enabled='0'; AND, in both families, iif br-lan, br-guest and" >&2
    echo "      br-iot each have 'priority 5279 lookup 100' with table 100 'unreachable default'." >&2
    echo "      Enable the Kill Switch (or run 'ts-fix-ks arm' with the intent committed)," >&2
    echo "      confirm the state above, then re-run." >&2
    exit 1
  fi
  echo

  echo "[3/4] Launching detached laptop egress monitor (${duration}s, v4+v6 concurrent)..."
  local base
  DURATION="$duration" INTERVAL=1 LABEL="$LABEL" TUNNEL_V4="$b4" TUNNEL_V6="$b6" base="$(tsfx_launch_egress)"
  sleep 3
  if [ -f "$base-egress.csv" ]; then
    echo "      OK  egress artifact: $base-egress.csv"
  else
    echo "      ERROR: monitor did not start; check $base-egress.log" >&2; exit 1
  fi
  # Stash run metadata for analyze.
  cat > "$base-meta.json" <<META
{ "fm": "$FM", "target": "$target", "duration_s": $duration, "label": "$LABEL",
  "tunnel_v4": "$b4", "tunnel_v6": "$b6", "clock_offset_s": "$offset",
  "ks_armed_at_start": ${armed:-0},
  "egress_base": "$base", "started_epoch": $(date +%s) }
META
  echo "      metadata: $base-meta.json"
  echo

  echo "[4/4] Start the router-side sampler in YOUR terminal now:"
  tsfx_router_cmd "$target" "$duration" "$LABEL"
  echo
  echo "=== OPERATOR RUNBOOK (relative to NOW) ==="
  echo "  T+0s        monitors running. Confirm both show baseline (v4/v6 = tunnel IP)."
  echo "  ~T+20s      TRIGGER the WAN event ONCE (pick the realistic one):"
  echo "                - unplug/replug the WAN cable, OR"
  echo "                - SSH: ifdown wan; sleep 3; ifup wan, OR"
  echo "                - switch the active uplink (eth -> repeater -> tether) in the GL UI"
  echo "              Note the wall-clock you triggered it (for --trigger)."
  echo "  watch       laptop monitor: 'blocked' = KS holding (good); any non-tunnel IP = LEAK."
  echo "  ~T+$((duration-20))s  RECOVER: disable the KS (or disable TS) so the laptop regains WAN."
  echo "  T+${duration}s     monitor self-stops and writes its JSON verdict."
  echo
  echo "When connectivity is back, harvest + analyze:"
  echo "  router_csv=\$(./fm2-wan-bounce.sh _harvest --target $target --label $LABEL)"
  echo "  ./fm2-wan-bounce.sh analyze --egress $base --router \"\$router_csv\" --offset $offset"
}

cmd_harvest() {
  local target="" label="fm2"
  while [ $# -gt 0 ]; do case "$1" in
    --target) target="$2"; shift 2 ;; --label) label="$2"; shift 2 ;; *) shift ;;
  esac; done
  tsfx_harvest_router "$target" "$label"
}

cmd_analyze() {
  local base="" router="" offset=0 trigger="" recover=""
  while [ $# -gt 0 ]; do case "$1" in
    --egress)  base="$2"; shift 2 ;;
    --router)  router="$2"; shift 2 ;;
    --offset)  offset="$2"; shift 2 ;;
    --trigger) trigger="$2"; shift 2 ;;
    --recover) recover="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac; done
  [ -z "$base" ] && { echo "ERROR: --egress <base> required" >&2; usage; }
  local egress_csv="$base-egress.csv" egress_json="$base-egress.json"
  [ -f "$egress_csv" ] || { echo "ERROR: $egress_csv not found" >&2; exit 1; }
  [ "$offset" = "NA" ] && offset=0

  echo "=== FM2 ANALYZE — $FM_DESC ==="
  echo "egress csv : $egress_csv"
  echo "router csv : ${router:-<none provided>}  (offset ${offset}s)"
  echo

  # Egress leaks (laptop truth).
  local leaks; leaks="$(awk -F, 'NR>1 && ($4=="LEAK" || $6=="LEAK")' "$egress_csv")"
  if [ -z "$leaks" ]; then
    echo "EGRESS: no LEAK samples. (v4/v6 were tunnel or blocked throughout.)  -> PASS candidate"
  else
    echo "EGRESS: LEAK samples detected:"
    echo "  ts_epoch            v4_ip            v4 / v6_ip                 v6"
    echo "$leaks" | awk -F, '{printf "  %s  %-15s %-4s %-25s %-4s\n",$1,$3,$4,$5,$6}'
  fi
  echo

  # Router-side state, aligned by clock offset.
  #
  # Decoded BY COLUMN NAME, never by position. Three sampler generations exist and this block must
  # assume none of them: the RPDB era (lan4/guest4/t100_* rule counts only), the zone era
  # (ks_severed_n/sev_open_n, no rule columns) and the current two-layer sampler
  # (tests/lib/router-sampler.sh: both layers, per zone and family). A named column the artifact
  # does not carry is simply absent from the output — it is never silently read off a neighbouring
  # column. The combined protection predicate (fm2_protection_lost) runs on two-layer artifacts only;
  # the older two get a NOTE saying what they cannot show.
  #
  # ONLY the per-leak-instant rows are gated on there being leaks. Everything below them is a
  # WHOLE-RUN scan and runs on a clean run too, deliberately:
  #   - the state-level fault (a recorded pair coming back enabled) can open and close inside the
  #     window without the 1s laptop probe cadence ever landing a sample in the gap, so a run with
  #     zero leaks and a non-zero sev_open_n is a real finding, not a contradiction;
  #   - the GL-5280 caveat exists FOR the clean run — its whole point is that a clean result with
  #     GL's own kill switch up cannot be credited to ours. Printing it only when we already leaked
  #     would be printing it exactly when it no longer matters.
  if [ -n "$router" ] && [ -f "$router" ]; then
    local hdr; hdr="$(head -1 "$router")"
    echo "ROUTER state (schema: $hdr)"
    local c_sev c_open c_ks c_gl4 c_gl6 c_lan4 c_r c_g94 c_g96 gen
    c_sev="$(csv_col "$router" ks_severed_n)"
    c_open="$(csv_col "$router" sev_open_n)"
    c_ks="$(csv_col "$router" uci_ks)"
    c_gl4="$(csv_col "$router" gl_ks4)"
    c_gl6="$(csv_col "$router" gl_ks6)"
    c_lan4="$(csv_col "$router" lan4)"
    c_r="$(csv_col "$router" r_lan4)"
    c_g94="$(csv_col "$router" gl9920_4)"
    c_g96="$(csv_col "$router" gl9920_6)"
    if [ -n "$c_r" ]; then
      gen=two-layer
    elif [ -n "$c_sev" ]; then
      gen=zone
      echo "  NOTE: this artifact predates the two-layer sampler. It carries the zone layer's UCI view"
      echo "        only (ks_severed_n / sev_open_n) — no rule-layer, shadow or netfilter column — so"
      echo "        the combined protection predicate cannot be evaluated and a firewall flush is"
      echo "        invisible in it. sev_open_n below keeps its zone-era meaning; treat the laptop"
      echo "        egress verdict as the authority and re-harvest with the current"
      echo "        tests/lib/router-sampler.sh for state-level correlation."
    else
      gen=rpdb
      echo "  NOTE: this artifact carries no zone column (ks_severed_n), so it predates the zone"
      echo "        sampler. It shows neither the zone layer nor any shadow, so the combined"
      echo "        protection predicate cannot be evaluated — treat the laptop egress verdict as"
      echo "        the authority and re-harvest with the current tests/lib/router-sampler.sh for"
      echo "        state-level correlation."
      [ -n "$c_lan4" ] && echo "        (lan4/guest4/t100_* there are the 5279 rule layer as THAT era's sampler counted it.)"
    fi
    if [ -n "$leaks" ]; then
      echo "Nearest router sample at each leak instant:"
      echo "$leaks" | awk -F, '{print $1}' | while read -r lt; do
        local rt=$(( lt + offset ))
        # printed raw so nothing is lost to a decoder
        awk -F, -v rt="$rt" 'NR>1 && $1>=rt {print "  @router " $0; exit}' "$router"
      done
      echo
    fi
    if [ "$gen" = two-layer ]; then
      echo "Protection lost (armed samples where a zone's zone layer was open AND its rule layer"
      echo "absent or shadowed, either family):"
      fm2_protection_lost "$router"
    fi
    # Two distinct ways the zone layer can be open in UCI, reported separately because they are
    # different faults: a recorded pair that came back enabled (the reset-window failure this leg
    # hunts), versus armed intent that severed nothing at all (the engine never ran, refused, or
    # could not write). In a zone-era artifact that WAS protection lost; under two layers it is lost
    # only where the rule layer failed too, which the section above decides.
    if [ -n "$c_open" ]; then
      if [ "$gen" = two-layer ]; then
        echo "Recorded pairs NOT severed in UCI during the run (sev_open_n > 0 = the zone layer is open):"
      else
        echo "Recorded pairs NOT severed during the run (sev_open_n > 0 = protection lost):"
      fi
      awk -F, -v c="$c_open" 'NR>1 && $c!="0" && $c!=""{print "  @"$1" sev_open_n="$c}' "$router" | head -20
    fi
    if [ -n "$c_sev" ] && [ -n "$c_ks" ]; then
      echo "Armed intent with nothing severed (uci_ks=1 while ks_severed_n=0):"
      awk -F, -v cs="$c_sev" -v ck="$c_ks" 'NR>1 && $ck=="1" && $cs=="0"{print "  @"$1" ks_severed_n=0"}' \
        "$router" | head -20
    fi
    if [ -n "$c_ks" ]; then
      echo "Intent values seen during the run (uci ts-fix.settings.kill_switch):"
      awk -F, -v c="$c_ks" 'NR>1{print $c}' "$router" | sort -u | sed 's/^/  /'
    fi
    # Attribution caveat, not a verdict: GL's own ts_killswitch can block traffic during the same
    # window, and a clean run with it armed does not by itself demonstrate that OUR kill switch
    # held. Empirical attribution needs the other factor held constant. The same holds for GL's
    # VPN-client blackhole at 9920 (live wherever a GL WireGuard/OpenVPN client is configured),
    # which the two-layer sampler records too.
    if [ -n "$c_gl4" ] && [ -n "$c_gl6" ]; then
      local gl_seen
      gl_seen="$(awk -F, -v a="$c_gl4" -v b="$c_gl6" 'NR>1 && ($a=="1" || $b=="1"){n++} END{print n+0}' "$router")"
      if [ "$gl_seen" != "0" ]; then
        echo "CAVEAT: GL's native ts_killswitch (blackhole at 5280) was present in $gl_seen sample(s)."
        echo "        It is IPv4 + br-lan only, and it is not ours — a blocked v4 sample in that"
        echo "        window cannot be attributed to our kill switch alone."
      fi
    fi
    if [ -n "$c_g94" ] && [ -n "$c_g96" ]; then
      local g99_seen
      g99_seen="$(awk -F, -v a="$c_g94" -v b="$c_g96" 'NR>1 && (($a+0)>0 || ($b+0)>0){n++} END{print n+0}' "$router")"
      if [ "$g99_seen" != "0" ]; then
        echo "CAVEAT: GL's VPN-client blackhole (priority 9920) was present in $g99_seen sample(s)."
        echo "        It is GL's, not ours — a blocked sample in that window cannot be attributed"
        echo "        to our kill switch alone."
      fi
    fi
  fi
  echo

  if [ -f "$egress_json" ]; then
    echo "MONITOR verdict:"
    grep -E '"(samples|leak_v4_count|leak_v6_count|first_leak_epoch|verdict)"' "$egress_json" | sed 's/^/  /'
  fi
}

case "${1:-}" in
  start)    shift; cmd_start "$@" ;;
  analyze)  shift; cmd_analyze "$@" ;;
  _harvest) shift; cmd_harvest "$@" ;;
  _armed_probe) fm2_armed_probe_script ;;
  *) usage ;;
esac
