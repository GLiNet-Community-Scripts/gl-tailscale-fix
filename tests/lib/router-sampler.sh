#!/bin/sh
#
# gl-tailscale-fix test suite — router-side two-layer kill-switch state sampler
#
# Runs ON the GL router. READ-ONLY: it only queries UCI, policy rules, routes, netfilter and
# tailscale state — it never changes anything, so it is safe to run on the router that is also the
# laptop's gateway. It is fed over ssh as `sh -s` on stdin, so it is self-contained, and no command
# in it may read stdin (every one reads a pipe, a file or /dev/null). Time-boxed: every INTERVAL
# seconds for DURATION seconds it records both kill-switch layers, raw, plus the context needed to
# interpret a leak.
#
# PROTECTION MEANS EITHER LAYER, judged per family and per source zone (lan, guest, iot):
#   rule layer  our `iif br-<zone> priority 5279 lookup 100` rule present (whole-token match, so
#               GL's `lookup 1002` never counts; `[detached]` counts) AND table 100's `unreachable
#               default` present AND no rule ahead of 5279 sending that bridge's traffic to main
#               (sh_* = 0). GL adds exactly such a rule — `from <net> lookup main`, priority 0 — for
#               guest and iot whenever a Custom Exit Node is set; while it stands the rule layer does
#               not protect that bridge, and the engine swaps it for `to <net> lookup main`.
#   zone layer  FORWARD policy DROP AND zone_<zone>_forward present AND no ACCEPT path from it into
#               a watched zone (netfilter, fw3) AND no recorded pair of that zone re-enabled in UCI.
# Each layer survives the other's eraser: a firewall restart flushes netfilter to policy ACCEPT
# (zone layer gone) but leaves policy rules; netifd's start wipes every policy rule but not UCI. A
# sample where BOTH fail for a zone is protection lost — fm2-wan-bounce.sh analyze reports exactly
# that, per zone and family.
#
# COLUMNS — addressable by name (fm2 decodes by header, never by position):
#   ts_epoch uci_ks            sample time; ts-fix.settings.kill_switch (the armed intent)
#   ks_severed_n sev_open_n    pairs recorded in ts-fix.settings.ks_severed; how many of them are NOT
#                              severed in UCI right now (enabled != '0', or no forwarding matches the
#                              pair — record and config disagreeing is not protection)
#   sev_open_lan/guest/iot     sev_open_n split by the pair's source zone (iot pairs count too)
#   lan2ts                     an enabled lan -> tailscale0 forwarding exists in UCI
#   r_<zone>4/6 t100_4/6       rule layer, raw
#   sh_<zone>4/6               rules ahead of 5279 that send the bridge's traffic to main. v4 uses the
#                              zone's network (ipcalc); v6 networks are not derived, so any v6 source
#                              rule counts against every bridge (fail-secure)
#   glfrom_guest4 glfrom_iot4  GL's `from <net> lookup main`; to_guest4 to_iot4 the `to` rule that
#                              replaces it; swapmark = the engine's /tmp/ts-fix-ks.srcswap exists
#   pol4/6 ch_<zone>4/6 j_<zone>4/6   zone layer in netfilter, from iptables-save (fw3). NA on fw4:
#                              nft is not read here, so on fw4 only the UCI half of the zone layer
#                              is sampled and a flush is invisible to this sampler
#   t52_4 t52_6 wan_def daemon backend exitnodeid uci_exit_ip   context
#   gl_ks4 gl_ks6 gl9920_4 gl9920_6   GL's OWN blackholes (5280 = 4.9's ts_killswitch, IPv4 + br-lan
#                              only; 9920 = its VPN-client leak block). Not ours: kept because a clean
#                              run with one of them up cannot be credited to our kill switch alone
#   watch nets4 zones          the watched zone set, the source-zone networks and which of
#                              lan/guest/iot exist as firewall zones — derived once at start
# NA = not sampled. ERR = sampled but the dump failed; ERR never counts as protected.
# Beside the CSV, <csv>.raw gets the raw rule, route and chain lines behind the columns whenever the
# columns change (first sample included), so an unexpected r, sh or j value can be triaged later.
# The suite's harvest fetches the CSV only: fetch the .raw by hand when a run needs triage.
#
# THE WATCHED SET is the dests of the pairs in ts-fix.settings.ks_severed UNION every zone the
# engine's own ks_zone_class classifies uplink or vpnclient — extracted from /usr/bin/ts-fix-ks
# between its "# ---8<--- ks-classify" markers, never re-implemented here. VPN server zones
# classify "other" and are not watched. Without the engine the set falls back, LOUDLY, to every
# zone but lan/guest/iot/tailscale0 (the watch column then starts "FALLBACK:").
#
# COST: per sample one `uci show firewall` + awk, one sectioned dump (ip -4/-6 rule, table-100
# routes, iptables-save/ip6tables-save) + one awk, plus the context probes. Heavy tailscale probes
# (BackendState + ExitNodeID) cost ~10MB RSS each; TS_PROBE=0 samples kernel/UCI only.
#
# Harvest the CSV afterwards:  scp -O root@<router>:/tmp/ts-fix-test/<file> .
#
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix

DURATION="${DURATION:-180}"
INTERVAL="${INTERVAL:-1}"
LABEL="${LABEL:-router}"
OUT="${OUT:-/tmp/ts-fix-test}"
TS_PROBE="${TS_PROBE:-1}"
KS_ENGINE="${KS_ENGINE:-/usr/bin/ts-fix-ks}"
IPCALC="${IPCALC:-/bin/ipcalc.sh}"
SWAP_MARK="${SWAP_MARK:-/tmp/ts-fix-ks.srcswap}"

# ---8<--- sampler-parse (unit-tested by tests/unit/test-sampler-parse.sh) ---8<---
# Every function in this block reads text (stdin or arguments) and runs no router command, so the
# unit test extracts the block and drives it with fixtures.

# zone_parse "<ks_severed value>" < `uci show firewall`
#   -> "<ks_severed_n>,<sev_open_n>,<sev_open_lan>,<sev_open_guest>,<sev_open_iot>,<lan2ts>"
#
# Sections are reached by ENUMERATION, never by name or index: GL ships both anonymous
# (firewall.@forwarding[7]) and named (firewall.lan_zerotier) forwardings in one config and rewrites
# the file wholesale, so an index is meaningless a firmware later. The awk keys off the option
# suffix, and only sections declared type "forwarding" are considered — rules carry src/dest too.
# `uci show` prints option values single-quoted and section lines unquoted; \047 strips the quotes
# without a quote character inside this single-quoted awk program.
zone_parse() {
  awk -v sev="$1" '
    {
      eq = index($0, "=")
      if (eq == 0) next
      key = substr($0, 1, eq - 1)
      val = substr($0, eq + 1)
      gsub(/\047/, "", val)
      n = length(key)
      if (n > 4 && substr(key, n - 3) == ".src")           SRC[substr(key, 1, n - 4)] = val
      else if (n > 5 && substr(key, n - 4) == ".dest")     DST[substr(key, 1, n - 5)] = val
      else if (n > 8 && substr(key, n - 7) == ".enabled")  EN[substr(key, 1, n - 8)] = val
      # Fallthrough, not a type test: any remaining line whose value is the word "forwarding"
      # registers as a section. A zone literally NAMED forwarding lands in FWD[] too and sits
      # there inert — with no src/dest of its own it keys as ":", which no real pair can be, and
      # it can never satisfy lan2ts. Verified against a decoy: counts are unchanged by it. Should
      # a corrupted sidecar ever name ":", the entry counts as OPEN rather than as severed, so
      # even that path fails secure.
      else if (val == "forwarding")                        FWD[key] = 1
    }
    END {
      nsev = split(sev, P, " ")
      open = 0; ol = 0; og = 0; oi = 0
      for (i = 1; i <= nsev; i++) {
        pair = P[i]
        if (pair == "") continue
        found = 0; openpair = 0
        for (s in FWD) {
          if (SRC[s] ":" DST[s] != pair) continue
          found = 1
          # Only the exact value "0" counts as severed. An absent option means
          # enabled in uci, and any other spelling is not provably inert.
          if (EN[s] != "0") openpair = 1
        }
        if (!found || openpair) {
          open++
          src = substr(pair, 1, index(pair, ":") - 1)
          if (src == "lan") ol++; else if (src == "guest") og++; else if (src == "iot") oi++
        }
      }
      l2t = 0
      for (s in FWD)
        if (SRC[s] == "lan" && DST[s] == "tailscale0" && EN[s] != "0") l2t = 1
      printf "%d,%d,%d,%d,%d,%d\n", nsev, open, ol, og, oi, l2t
    }'
}

# zone_list_parse < `uci show firewall` -> "name|networks" per zone section
zone_list_parse() {
  awk '
    {
      eq = index($0, "="); if (eq == 0) next
      key = substr($0, 1, eq - 1); val = substr($0, eq + 1)
      gsub(/\047/, "", val)
      n = split(key, k, ".")
      if (n == 2 && val == "zone") { sec[++ns] = k[2]; isz[k[2]] = 1; next }
      if (n == 3 && isz[k[2]] == 1) {
        if (k[3] == "name") name[k[2]] = val
        else if (k[3] == "network") nets[k[2]] = val
      }
    }
    END { for (i = 1; i <= ns; i++) if (name[sec[i]] != "") print name[sec[i]] "|" nets[sec[i]] }'
}

# net4_parse < ipcalc.sh output -> "NETWORK/PREFIX", or nothing
net4_parse() {
  awk -F= '$1 == "NETWORK" { n = $2 } $1 == "PREFIX" { p = $2 }
    END { if (n ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && p ~ /^[0-9]+$/ && p + 0 <= 32) print n "/" p }'
}

# addr4_first < `ip -4 -o addr show dev X` -> the first "a.b.c.d/p"
addr4_first() {
  awk '{ for (i = 1; i < NF; i++) if ($i == "inet") { print $(i + 1); exit } }'
}

# watch_derive "<uci show firewall>" "<ks_severed>" -> sets WATCH (needs ks_zone_class, or
# CLS_OK=0 for the fallback) and ZONES (which of lan/guest/iot exist as zones). Sidecar dests
# first, then the engine's uplink/vpnclient zones.
watch_derive() {
  WATCH=""; ZONES=""
  for _p in $2; do
    case "$_p" in *:*) case " $WATCH " in *" ${_p#*:} "*) ;; *) WATCH="${WATCH:+$WATCH }${_p#*:}" ;; esac ;; esac
  done
  _zl=$(printf '%s\n' "$1" | zone_list_parse)
  while IFS='|' read -r _zn _znets; do
    [ -n "$_zn" ] || continue
    case "$_zn" in lan|guest|iot) case " $ZONES " in *" $_zn "*) ;; *) ZONES="${ZONES:+$ZONES }$_zn" ;; esac ;; esac
    if [ "${CLS_OK:-0}" = 1 ]; then
      case "$(ks_zone_class "$_zn" "$_znets")" in uplink|vpnclient) ;; *) continue ;; esac
    else
      case "$_zn" in lan|guest|iot|tailscale0) continue ;; esac
    fi
    case " $WATCH " in *" $_zn "*) ;; *) WATCH="${WATCH:+$WATCH }$_zn" ;; esac
  done <<EOF
$_zl
EOF
}

# classifier_block < engine -> the engine's ks-classify block, ONLY when both marker lines are present,
# in order, EXACTLY as the engine writes them ("# ---8<--- ks-classify", "# ---8<--- end
# ks-classify"; trailing blanks ignored), rc 0; otherwise nothing and rc 1. A block whose end marker
# is missing or renamed (even to a longer name) is refused whole: printing from the start marker to
# EOF would hand everything after it, the engine's dispatcher included, to eval as root.
classifier_block() {
  awk '
    { l = $0; sub(/[ \t\r]+$/, "", l) }
    !on && l == "# ---8<--- ks-classify" { on = 1 }
    on { buf = buf $0 "\n" }
    on && l == "# ---8<--- end ks-classify" { printf "%s", buf; done = 1; exit }
    END { exit done ? 0 : 1 }'
}

# layers_parse < sectioned dump -> the rule-layer, shadow, swap, netfilter and GL-blackhole columns.
# Input: "@@R4"/"@@R6" + `ip -4|-6 rule`, "@@T4"/"@@T6" + `ip -4|-6 route show table 100`,
# "@@F4"/"@@F6" + `iptables-save|ip6tables-save -t filter`, each dump followed by "@@rc <status>".
# Env: WATCH (watched zones), NET_lan NET_guest NET_iot (a.b.c.d/p, "none" or "?"). Optional
# RAWLOG + STAMP: whenever the columns differ from the previous call's (kept in RAWLOG.sig), the raw
# lines behind them — every rule at or ahead of 5280 and at 9920, table 100, the FORWARD policy and
# the source-zone chains with all their -A lines — are appended to RAWLOG under "@@ <STAMP> <columns>".
# The matching rules are the ones of tests/results/instruments-*/ks-sample.awk (git-ignored
# instrument set); both are fixture-tested with the same cases.
# NET_* are assigned through eval at start, which shellcheck cannot see.
# shellcheck disable=SC2154
layers_parse() {
  awk -v watch="$WATCH" -v net_lan="$NET_lan" -v net_guest="$NET_guest" -v net_iot="$NET_iot" \
      -v rawlog="${RAWLOG:-}" -v stamp="${STAMP:-}" '
    function isnet(v) { return v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ }
    function ip2n(a,   p) { split(a, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
    function plen(v,   k) { k = index(v, "/"); return k ? substr(v, k + 1) + 0 : 32 }
    function addr(v,   k) { k = index(v, "/"); return k ? substr(v, 1, k - 1) : v }
    function norm4(v) { return index(v, "/") ? v : v "/32" }
    # powers of two by doubling: BusyBox awk without FEATURE_AWK_LIBM rejects the ^ operator
    function overlaps(a, b,   m, d, i) {
      m = plen(a); if (plen(b) < m) m = plen(b)
      if (m == 0) return 1
      d = 1; for (i = m; i < 32; i++) d = d * 2
      return int(ip2n(addr(a)) / d) == int(ip2n(addr(b)) / d)
    }
    function parse_rule(line,   n, t, i, tk) {
      R_ok = 0; R_prio = ""; R_from = ""; R_to = ""; R_iif = ""; R_act = ""; R_tab = ""; R_other = 0
      n = split(line, t, /[ \t]+/)
      if (n < 2 || t[1] !~ /^[0-9]+:$/) return
      R_prio = substr(t[1], 1, length(t[1]) - 1) + 0
      for (i = 2; i <= n; i++) {
        tk = t[i]
        if (tk == "") continue
        if (tk == "from") { R_from = t[++i]; continue }
        if (tk == "to") { R_to = t[++i]; continue }
        if (tk == "iif") { R_iif = t[++i]; continue }
        if (tk == "oif") { R_other = 1; i++; continue }
        if (tk == "[detached]") continue
        if (tk == "lookup" || tk == "table") { R_act = "lookup"; R_tab = t[++i]; continue }
        if (tk == "blackhole" || tk == "unreachable" || tk == "prohibit") { R_act = tk; continue }
        if (tk == "goto") { R_act = "goto"; R_tab = t[++i]; continue }
        if (tk == "nop") { R_act = "nop"; continue }
        if (tk == "proto" || tk == "protocol") { i++; continue }
        if (tk == "fwmark" || tk == "tos" || tk == "dsfield" || tk == "uidrange" || \
            tk == "ipproto" || tk == "sport" || tk == "dport" || tk == "realms" || \
            tk == "suppress_prefixlength" || tk == "suppress_ifgroup" || tk == "tun_id") {
          R_other = 1; i++; continue
        }
        R_other = 1
      }
      if (R_from == "") R_from = "all"
      R_ok = 1
    }
    function zone_net(z) { return z == "lan" ? net_lan : (z == "guest" ? net_guest : net_iot) }
    function covers4(from, z,   net) {
      if (from == "all") return 1
      net = zone_net(z)
      if (net == "none" || net == "") return 0
      if (net == "?" || !isnet(net) || !isnet(from)) return 1
      return overlaps(norm4(from), norm4(net))
    }
    function raw(tag, line) { RAWN++; RAWL[RAWN] = tag " " line }
    function rule_line(f, line,   z, br, k) {
      parse_rule(line)
      if (!R_ok) return
      if (R_prio <= 5280 || R_prio == 9920) raw("R" f, line)
      if (R_prio == 5280 && R_act == "blackhole") G5280[f]++
      if (R_prio == 9920 && R_act == "blackhole") G9920[f]++
      for (k = 1; k <= NZ; k++) {
        z = ZN[k]; br = "br-" z
        if (R_prio == 5279 && R_act == "lookup" && R_tab == "100" && R_iif == br && \
            R_from == "all" && R_to == "" && !R_other) RL[z, f]++
        if (R_prio < 5279 && R_act == "lookup" && (R_tab == "main" || R_tab == "254") && \
            R_to == "" && !R_other && (R_iif == "" || R_iif == br)) {
          if (f == 6) { if (R_from == "all" || index(R_from, ":")) SH[z, f]++ }
          else if (covers4(R_from, z)) SH[z, f]++
        }
        if (f == 4 && (z == "guest" || z == "iot") && R_prio < 5279 && R_act == "lookup" && \
            (R_tab == "main" || R_tab == "254") && !R_other && R_iif == "" && isnet(zone_net(z))) {
          if (R_to == "" && R_from != "all" && isnet(R_from) && norm4(R_from) == norm4(zone_net(z))) GF[z]++
          if (R_from == "all" && isnet(R_to) && norm4(R_to) == norm4(zone_net(z))) TO[z]++
        }
      }
    }
    function fw_line(f, line,   n, t, i, z, tgt, dest, dnat, k) {
      if (line ~ /^\*filter/) { SAWF[f] = 1; return }
      n = split(line, t, /[ \t]+/)
      if (t[1] == ":FORWARD") { POL[f] = t[2]; raw("F" f, line); return }
      for (k = 1; k <= NZ; k++) {
        z = ZN[k]
        if (t[1] == ":zone_" z "_forward") { CH[z, f] = 1; raw("F" f, line); return }
        if (t[1] == "-A" && t[2] == "zone_" z "_forward") {
          raw("F" f, line)
          tgt = ""; dnat = 0
          for (i = 3; i <= n; i++) {
            if (t[i] == "-j" && i < n) tgt = t[i + 1]
            if (t[i] == "--ctstate" && t[i + 1] == "DNAT") dnat = 1
          }
          if (tgt == "ACCEPT" && !dnat) { J[z, f]++; return }
          if (tgt ~ /^zone_.+_dest_ACCEPT$/) {
            dest = substr(tgt, 6, length(tgt) - 17)
            if (dest in W) J[z, f]++
          }
          return
        }
      }
    }
    function val(sampled, failed, v) { return !sampled ? "NA" : (failed ? "ERR" : v + 0) }
    function flag(sampled, failed, v) { return !sampled ? "NA" : (failed ? "ERR" : (v + 0 > 0 ? 1 : 0)) }
    BEGIN {
      NZ = split("lan guest iot", ZN, " ")
      nw = split(watch, WL, /[ \t]+/)
      for (i = 1; i <= nw; i++) if (WL[i] != "") W[WL[i]] = 1
      sec = ""
    }
    /^@@/ {
      if ($1 == "@@rc") { if (sec != "") RC[sec] = $2; sec = ""; next }
      sec = substr($1, 3); SEEN[sec] = 1; next
    }
    sec == "R4" { rule_line(4, $0); next }
    sec == "R6" { rule_line(6, $0); next }
    sec == "T4" || sec == "T6" { raw(sec, $0); if ($1 == "unreachable" && $2 == "default") T100[substr(sec, 2)] = 1; next }
    sec == "F4" { fw_line(4, $0); next }
    sec == "F6" { fw_line(6, $0); next }
    END {
      for (f = 4; f <= 6; f += 2) {
        s = "R" f; rsmp[f] = SEEN[s]; rfail[f] = SEEN[s] && (RC[s] == "" || RC[s] + 0 != 0)
        s = "F" f; fsmp[f] = SEEN[s]; ffail[f] = SEEN[s] && (RC[s] == "" || RC[s] + 0 != 0 || !SAWF[f])
      }
      row = ""
      for (f = 4; f <= 6; f += 2) {
        for (k = 1; k <= NZ; k++) { cell = val(rsmp[f], rfail[f], RL[ZN[k], f]); row = (row == "" ? cell : row "," cell) }
        row = row "," (!SEEN["T" f] ? "NA" : (rfail[f] ? "ERR" : T100[f] + 0))
      }
      for (f = 4; f <= 6; f += 2)
        for (k = 1; k <= NZ; k++) row = row "," val(rsmp[f], rfail[f], SH[ZN[k], f])
      row = row "," val(rsmp[4], rfail[4], GF["guest"]) "," val(rsmp[4], rfail[4], GF["iot"])
      row = row "," val(rsmp[4], rfail[4], TO["guest"]) "," val(rsmp[4], rfail[4], TO["iot"])
      for (f = 4; f <= 6; f += 2) {
        row = row "," (!fsmp[f] ? "NA" : (ffail[f] ? "ERR" : (POL[f] == "" ? "none" : POL[f])))
        for (k = 1; k <= NZ; k++) row = row "," val(fsmp[f], ffail[f], CH[ZN[k], f])
        for (k = 1; k <= NZ; k++) row = row "," val(fsmp[f], ffail[f], J[ZN[k], f])
      }
      row = row "," flag(rsmp[4], rfail[4], G5280[4]) "," flag(rsmp[6], rfail[6], G5280[6])
      row = row "," val(rsmp[4], rfail[4], G9920[4]) "," val(rsmp[6], rfail[6], G9920[6])
      print row
      if (rawlog != "") {
        sigf = rawlog ".sig"; prev = ""
        if ((getline prev < sigf) > 0) close(sigf)
        if (prev != row) {
          print "@@ " stamp " " row >> rawlog
          for (i = 1; i <= RAWN; i++) print RAWL[i] >> rawlog
          close(rawlog)
          print row > sigf
          close(sigf)
        }
      }
    }'
}
LAYERS_HDR="r_lan4,r_guest4,r_iot4,t100_4,r_lan6,r_guest6,r_iot6,t100_6,sh_lan4,sh_guest4,sh_iot4,sh_lan6,sh_guest6,sh_iot6,glfrom_guest4,glfrom_iot4,to_guest4,to_iot4,pol4,ch_lan4,ch_guest4,ch_iot4,j_lan4,j_guest4,j_iot4,pol6,ch_lan6,ch_guest6,ch_iot6,j_lan6,j_guest6,j_iot6,gl_ks4,gl_ks6,gl9920_4,gl9920_6"
# ---8<--- end sampler-parse ---8<---

# layers_dump — one sectioned dump for layers_parse. FW=fw4 skips netfilter (its columns read NA).
layers_dump() {
  echo @@R4; ip -4 rule 2>/dev/null; echo "@@rc $?"
  echo @@R6; ip -6 rule 2>/dev/null; echo "@@rc $?"
  echo @@T4; ip -4 route show table 100 2>/dev/null; echo "@@rc $?"
  echo @@T6; ip -6 route show table 100 2>/dev/null; echo "@@rc $?"
  if [ "$FW" != fw4 ]; then
    echo @@F4; iptables-save -t filter 2>/dev/null; echo "@@rc $?"
    echo @@F6; ip6tables-save -t filter 2>/dev/null; echo "@@rc $?"
  fi
}

t52_def() {
  if ip "$1" route show table 52 2>/dev/null | grep -q "default"; then echo 1; else echo 0; fi
}
wan_def() {
  # 1 if a v4 default route exists in main — netifd removes it when the uplink drops,
  # so this column records whether the WAN-bounce trigger actually took, router-side.
  if ip -4 route show default 2>/dev/null | grep -q "^default"; then echo 1; else echo 0; fi
}

set -f
mkdir -p "$OUT"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
csv="$OUT/${stamp}-${LABEL}.csv"
rawf="${csv%.csv}.raw"

# ---- start-time derivation (read once, recorded in the watch, nets4 and zones columns of every row)
if [ -x /sbin/fw4 ]; then FW=fw4; else FW=fw3; fi
CLS_OK=0; cls_why=""
if [ -r "$KS_ENGINE" ]; then
  # Read through a redirect, not as an argument, so no command line carries the engine path. Only a
  # COMPLETE block (both markers) is ever evaluated; the engine's dispatcher is also disarmed.
  _blk=$(classifier_block < "$KS_ENGINE") || _blk=""
  if [ -n "$_blk" ]; then
    # shellcheck disable=SC2034  # read by the evaluated engine text
    TS_FIX_KS_NO_MAIN=1
    eval "$_blk"
    if command -v ks_zone_class >/dev/null 2>&1; then CLS_OK=1; else cls_why="block defines no ks_zone_class"; fi
  else
    cls_why="no complete ks-classify block (start AND end marker) in $KS_ENGINE"
  fi
else
  cls_why="$KS_ENGINE not readable"
fi
watch_derive "$(uci show firewall 2>/dev/null)" "$(uci -q get ts-fix.settings.ks_severed 2>/dev/null)"
if [ "$CLS_OK" = 1 ]; then WATCH_COL="$WATCH"; else
  WATCH_COL="FALLBACK:$WATCH"
  echo "[router-sampler] WARNING: engine classifier unavailable ($cls_why) - watching EVERY zone but lan/guest/iot/tailscale0 (over-inclusive)" >&2
fi
for _z in lan guest iot; do
  _a=$(ip -4 -o addr show dev "br-$_z" 2>/dev/null | addr4_first)
  if [ -z "$_a" ]; then _n=none
  else _n=$("$IPCALC" "$_a" </dev/null 2>/dev/null | net4_parse); [ -n "$_n" ] || _n="?"; fi
  eval "NET_$_z=\$_n"
done
NETS_COL="lan=$NET_lan guest=$NET_guest iot=$NET_iot"
# A dump that yields no row at all still fills every column, so the CSV never shifts.
LAYERS_ERR=$(printf '%s\n' "$LAYERS_HDR" | sed 's/[^,][^,]*/ERR/g')
[ "$FW" = fw4 ] && echo "[router-sampler] NOTE: fw4 - the netfilter columns read NA; only the UCI half of the zone layer is sampled" >&2

printf 'ts_epoch,uci_ks,ks_severed_n,sev_open_n,sev_open_lan,sev_open_guest,sev_open_iot,lan2ts,%s,swapmark,t52_4,t52_6,daemon,backend,exitnodeid,uci_exit_ip,wan_def,watch,nets4,zones\n' \
  "$LAYERS_HDR" > "$csv"
echo "[router-sampler] start=$stamp duration=${DURATION}s interval=${INTERVAL}s ts_probe=$TS_PROBE fw=$FW watch=[$WATCH_COL] nets=[$NETS_COL] zones=[$ZONES] csv=$csv" >&2

end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  now="$(date +%s)"
  sev="$(uci -q get ts-fix.settings.ks_severed 2>/dev/null)"
  zs="$(uci show firewall 2>/dev/null | zone_parse "$sev")"
  ly="$(layers_dump | RAWLOG="$rawf" STAMP="$now" layers_parse)"
  if [ -f "$SWAP_MARK" ]; then sm=1; else sm=0; fi
  t524="$(t52_def -4)"; t526="$(t52_def -6)"
  if pgrep tailscaled >/dev/null 2>&1; then daemon=1; else daemon=0; fi
  backend=""; enid=""
  if [ "$daemon" = "1" ] && [ "$TS_PROBE" = "1" ]; then
    backend="$(/usr/sbin/tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null)"
    enid="$(/usr/sbin/tailscale debug prefs 2>/dev/null | jsonfilter -e '@.ExitNodeID' 2>/dev/null)"
  fi
  uci_exit="$(uci -q get tailscale.settings.exit_node_ip)"
  uci_ks="$(uci -q get ts-fix.settings.kill_switch)"
  wandef="$(wan_def)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$now" "${uci_ks:-}" "${zs:-ERR,ERR,ERR,ERR,ERR,ERR}" "${ly:-$LAYERS_ERR}" "$sm" "$t524" "$t526" \
    "$daemon" "${backend:-},${enid:-},${uci_exit:-},$wandef" "$WATCH_COL,$NETS_COL,$ZONES" >> "$csv"
  printf '[%s] ks=%s zone=%s %s backend=%s enid=%s wan=%s\n' "$now" "${uci_ks:-?}" "${zs:-ERR}" \
    "$(printf '%s\n' "$ly" | awk -F, '{ printf "rules4=%s/%s/%s t100=%s/%s pol=%s/%s", $1, $2, $3, $4, $8, $19, $26 }')" \
    "${backend:-?}" "${enid:-none}" "$wandef" >&2
  sleep "$INTERVAL"
done
echo "[router-sampler] done csv=$csv" >&2
