#!/bin/bash
#
# prerm-drain — certifies that a package REMOVAL is atomic against the plugin's own engine
# writers. The class (proven in the sibling gl-zerotier-fix as "finding 43", 2026-08-21) has
# two halves: in-flight writers orphaned by procd stop that finish AFTER teardown, and NEW
# writers born INSIDE the removal window by still-installed event-driven entry points. Under
# the two-layer kill switch the writer set is the two iface hotplug handlers (the spawn
# sources: 20-ts-fix spawns a reapply, 10-ts-fix-ks runs the engine's lock-free rules-ensure),
# an orphaned ts-fix-reapply, the watchdog (a rebirth source — its 5s poll spawns both a reapply
# and an engine check), and the kill-switch ENGINE itself: ts-fix-ks is spawned detached by the
# RPC and called by every reapply, so it outlives its caller and can re-sever, re-record or
# re-commit AFTER the teardown has swept. The fixed prerm neutralizes them in spawn-source
# order before its teardown: hotplug rm (both handlers) -> guard kill -> watchdog kill ->
# bounded 100s reapply drain -> bounded 30s engine drain -> uci revert -> teardown (which ends
# in `ts-fix-ks disarm`).
#
# "Armed" is scored here on BOTH layers. Zone layer: the engine severs every lan/guest/iot ->
# uplink-class firewall forwarding and records each as a src:dest pair in the
# ts-fix.settings.ks_severed sidecar, so every armed setup below is `uci set kill_switch=1` +
# commit + `ts-fix-ks arm`, and every zone assert is "sidecar non-empty AND every recorded pair's
# forwarding reads enabled='0'" (zone_armed). Rule layer: priority-5279 rules for
# br-lan/br-guest/br-iot with table 100 plus the table-100 unreachable route, in both families
# (rule_layer_present). Every leg that removes an armed package asserts both BEFORE the removal —
# without that, a post-removal residue count of zero could be earned by a router that never had
# the rules. These objects, and the engine's source-rule swap (its marker and its `to` rules), are
# CURRENT state on an armed router, not legacy artifacts; after a removal any piece still standing
# is residue: a kill switch left enforcing with no package behind it.
#
# Legs:
#   0  preflight — identity, INSTALLED prerm carries the fix (content probe, not version: the
#      fix ships inside the release), posture preconditions, as-found capture, dead-man
#   A  control — no stragglers: removal is FAST (drain must not wait on nothing), zero residue
#   B' armed removal restores zone state — arm, remove: every recorded pair must come back
#      enabled, the sidecar and ts_fix_lan2ts must be gone, and the config file must be gone
#      (prerm keeps it on a FAILED disarm, so its absence is the successful-restore signal)
#   C  hotplug-born — an EVENT-GATED `ifup wan6` landing inside the removal window + a window
#      sampler on the hotplug-unique writer (reapply, diffed against a pre-removal baseline):
#      zero born writers, zero residue, wan6 recovers from its own bounce
#   D  parked writer — a REAL reapply parked in its ~33s daemon wait at remove time (daemon
#      stopped): the drain must WAIT for it (wall-time window), no writer survives teardown
#
# The RPDB-era boot guard leg is RETIRED with the mechanism: the pivoted init.d spawns no
# `ip monitor rule` watcher (zone state is flash-persisted UCI that the firewall re-emits at
# S19, so there is no boot window to guard). prerm still KILLS that class — a leftovers-cover
# for a pre-pivot build being removed — and that kill line is deliberately left untested here;
# it has no live mechanism to exercise, and a synthetic monitor would certify the instrument
# rather than the product.
#
# Every post-removal residue count is DERIVED from an enumeration printed into the log — a red
# names its objects in the same observation that scores the number (sibling obs: a count is
# blind).
#
# PGREP BRACKET AUDIT (obs 112-116: an instrument that matches the mechanism it measures scores
# itself). Every pgrep here brackets one letter, so the literal text riding the ssh command line
# ("ts-fix-reappl[y]") does NOT contain the string that prerm's own ERE patterns match
# ("ts-fix-reapply"), and vice versa — neither can see the other. Patterns in this file, checked
# against the pivoted prerm's three patterns ('ip monitor rul[e]', 'ts-fix-reappl[y]',
# 'ts-fix-k[s]'):
#   reapply_n / residue / leg C sampler  'ts-fix-reappl[y]'      clear of prerm's reapply drain
#   residue                              'ts-fix-watchdo[g]'     prerm kills, does not pgrep-wait
#   residue                              'ip monitor rul[e]'     legacy/foreign monitor only
#   residue                              'ts-fix-k[s]'           clear of prerm's ENGINE drain
#   arm/cancel_deadman                   'tsfx-drain-deadma[n]'  no prerm pattern is near it
# The UNBRACKETABLE contacts are deliberate and enumerated: leg 0's marker probe, the dead-man
# writer, zone_arm, and the cleanup block all carry the literal text "ts-fix-ks" on their ssh
# command lines, which prerm's engine drain WOULD match. Every one of them is a short-lived rssh
# call that has returned before any removal starts, so none can be concurrent with a drain — and
# nothing long-lived (the leg C window sampler, the dead-man's own `sh /tmp/tsfx-drain-deadman.sh`
# process) carries that string. The residue probe is split in two for the same reason: see
# residue_enumerate.
#
# NEW INSTRUMENT (lint before the first scored run): the dead-man is written through a heredoc
# whose expansion is MIXED — the outer rssh argument is double-quoted, so $1/$RIPK/$AF_KS expand
# on the LAPTOP, while `\$fam`-style escapes and the quoted <<'DEOF' body stay literal and expand
# on the ROUTER at fire time. Two-state on-device lint required before this gate is scored: fire
# a shortened dead-man once with the package REMOVED and once with it INSTALLED, and confirm the
# router-side file contains the intended literals and that both paths restore. A wrong-side
# expansion here is silent — it produces a dead-man that runs and does nothing.
#
# Usage:
#   TARGET=<router-ip> IPK=build/out/gl-tailscale-fix_<ver>_all.ipk ./tests/prerm-drain.sh
#   Optional: ROUTER_JUMP=user@host:port (ssh -J), ALLOW_AXT1800=1 (refused otherwise — the
#   AXT carries krm's uplink; its legs are krm-driven by project protocol).
#
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix

set -u
cd "$(dirname "$0")/.." || exit 2
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RESULTS="tests/results/${STAMP}-prerm-drain.log"
mkdir -p tests/results
_PASS=0; _FAIL=0

log() { echo "$(date +%H:%M:%S) $*" | tee -a "$RESULTS"; }

rssh() {
    if [ -n "${ROUTER_JUMP:-}" ]; then
        ssh -J "$ROUTER_JUMP" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$TARGET" "$@"
    else
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$TARGET" "$@"
    fi
}

assert_eq() {  # desc got want
    if [ "$2" = "$3" ]; then
        _PASS=$((_PASS+1)); log "PASS: $1 [$2]"
    else
        _FAIL=$((_FAIL+1)); log "FAIL: $1 — expected [$3], got [${2:-empty}]"
    fi
}

assert_ge() {  # desc got floor
    if [ "${2:-0}" -ge "$3" ] 2>/dev/null; then
        _PASS=$((_PASS+1)); log "PASS: $1 [$2]"
    else
        _FAIL=$((_FAIL+1)); log "FAIL: $1 — expected >= $3, got [${2:-empty}]"
    fi
}

assert_eventually() {  # desc want fn... (poll 1s, ceiling AE_CEIL or 20)
    _ae_desc=$1; _ae_want=$2; shift 2
    _ae_ceil=${AE_CEIL:-20}; AE_CEIL=""
    _ae_t0=$(date +%s); _ae_n=0; _ae_got=""
    while :; do
        _ae_n=$((_ae_n + 1)); _ae_got=$("$@")
        [ "$_ae_got" = "$_ae_want" ] && break
        [ $(( $(date +%s) - _ae_t0 )) -ge "$_ae_ceil" ] && break
        sleep 1
    done
    _ae_el=$(( $(date +%s) - _ae_t0 ))
    if [ "$_ae_got" = "$_ae_want" ]; then
        _PASS=$((_PASS+1)); log "PASS: $_ae_desc [$_ae_got, converged in ${_ae_el}s over $_ae_n samples]"
    else
        _FAIL=$((_FAIL+1)); log "FAIL: $_ae_desc — expected [$_ae_want], last saw [${_ae_got:-empty}] after ${_ae_el}s ($_ae_n samples)"
    fi
}

require_control_alive() {  # $1 = tag — an unreachable DUT means ABORT, not a verdict
    if [ "$(rssh "echo ok" 2>/dev/null)" != "ok" ]; then
        log "ABORT($1): control path to $TARGET dead — refusing to score anything from here"
        finish; exit 2
    fi
}

finish() {
    log "== prerm-drain: $_PASS pass, $_FAIL fail =="
    log "results: $(pwd)/$RESULTS"
}

# --- helpers ---------------------------------------------------------------------------------

# ABSENT is not zero. A probe that never completed — an unreachable DUT, where every rssh fails
# "No route to host", or a remote shell that died half way — prints nothing or a truncated part,
# and a count or an emptiness test over that reads as clean: measured live (2026-09-30 07:21), a
# router that could not be reached scored "zero plugin residue [0]". So every probe whose empty
# result would PASS ends by printing PROBE-END, and its output is used only when that line arrived.
# probe_body <output> prints the output without that last line, or "probe-dead" when it never
# came; rssh_read <command> runs one command that way. A result that stays "probe-dead" matches no
# expected value, so the assert built on it FAILs. rule_layer_count's "probe-dead" is the same
# convention; readers that already FAIL on an empty answer (a count compared with "0" as a string,
# or "1" expected) are left as they are.
probe_body() {
    case "$1" in
        PROBE-END|*"
PROBE-END") printf '%s' "${1%PROBE-END}" ;;
        *) echo "probe-dead" ;;
    esac
}
rssh_read() { probe_body "$(rssh "$1; echo PROBE-END")"; }

ts_state()   { rssh "/usr/sbin/tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null"; }
wd_running() { rssh "ubus call service list '{\"name\":\"ts-fix\"}' 2>/dev/null | grep -c running"; }
wan6_up()    { rssh "ubus call network.interface.wan6 status 2>/dev/null | grep -c '\"up\": true'"; }
reapply_n()  { rssh "pgrep -f 'ts-fix-reappl[y]' 2>/dev/null | wc -l"; }
sev_list()   { rssh_read "uci -q get ts-fix.settings.ks_severed 2>/dev/null"; }

# zone_armed -> "1" when the zone kill switch is genuinely in force, else "0". The two halves are
# both required: a populated ks_severed sidecar (the record disarm restores from) AND every pair
# it names still reading enabled='0' in the live firewall config. Either half alone is a false
# read — a sidecar with re-enabled forwardings is a lost sever (open egress that reports armed),
# and disabled forwardings with no record are severed-with-no-way-back.
#
# A recorded pair that matches NO forwarding section scores 0 on purpose. It is not "protected by
# absence": it means the record and the config disagree, which is the state a red must see rather
# than be reassured about. Sections are reached by ENUMERATION (GL ships both anonymous and named
# forwardings, and rewrites the file wholesale), never by name or index. `set -f` because
# "firewall.@forwarding[0]=..." is a glob pattern in an unquoted word split.
zone_armed() {
    rssh 'set -f
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
      echo 1'
}

# The RAW observation that belongs next to any zone verdict: the sidecar plus every lan/guest/iot
# forwarding with its section, pair and enabled value. Logged at preflight and around leg B' so a
# surprising verdict is triageable from the artifact instead of from another run (obs: an
# instrument that prints only its verdict costs a whole re-run to explain itself).
zone_dump() {
    rssh 'set -f
      echo "sidecar=[$(uci -q get ts-fix.settings.ks_severed 2>/dev/null)]"
      echo "lan2ts=[$(uci -q get firewall.ts_fix_lan2ts 2>/dev/null)] lan2ts_created=[$(uci -q get ts-fix.settings.ks_lan2ts_created 2>/dev/null)]"
      for l in $(uci show firewall 2>/dev/null); do
        case "$l" in firewall.*=forwarding) ;; *) continue ;; esac
        sec=${l%=forwarding}
        src=$(uci -q get "$sec.src")
        case "$src" in lan|guest|iot) ;; *) continue ;; esac
        echo "fwd $sec $src:$(uci -q get "$sec.dest") enabled=[$(uci -q get "$sec.enabled")]"
      done'
}

# --- router-side probes, shared verbatim by the armed asserts and the residue enumeration ------
# Kept as text so ONE definition serves both directions: the rule-layer probe decides "the layer
# is complete" before a removal (rule_layer_present) and "this is residue" after one
# (residue_enumerate), so the two can never disagree about what counts as our rule. The marked
# block is extracted and linted locally from this exact text; keep the markers.
#
# RULE_LAYER_PROBE splits each `ip rule list` line into tokens (callers run it under `set -f`, so
# iproute2's "[detached]" token, printed between the iif name and "lookup" when the bridge does
# not exist, stays a word instead of a glob) and reports a line only when ALL of these hold as
# whole tokens: the priority is exactly "5279:" or "5280:", the word after "iif" is br-lan,
# br-guest or br-iot, and the word after "lookup" is exactly "100". A foreign "lookup 1002" rule
# at the same priority therefore never counts, and neither does GL's own 5280 blackhole rule,
# which carries no "lookup" at all. Every table-100 route is reported, tagged
# "unreachable-default" when the line begins with those two words (the v6 line carries more after
# them) and "other" when it does not. Output: parsed fields first, the RAW line after " | ":
#   RES rule-layer<fam> <prio> <iif> | <raw ip rule line>
#   RES rule-layer-table100<fam> <unreachable-default|other> | <raw ip route line>
#
# TO_RULE_PROBE reports priority-0 "to <net> lookup main" rules for the guest and iot networks:
# Route Guest and the engine's source-rule swap both add one, and after a removal neither may
# remain. The network is ipcalc.sh's NETWORK/PREFIX for the bridge's first IPv4 address, never the
# last octet zeroed (right only for a /24), and the rule is matched on whole tokens: priority
# exactly "0:", the word after "to" exactly that network, the word after "lookup" exactly "main".
# A bridge with no IPv4 address has nothing to check and prints a NOTE line, which is not counted.
# An address or an ipcalc answer it cannot read is an instrument failure and prints a
# "RES PROBE-ERROR" line, which IS counted, so it can never pass as clean; leg 0 aborts on one.
# ---8<--- probes ---8<---
RULE_LAYER_PROBE='for fam in -4 -6; do
        ip $fam rule list 2>/dev/null | while IFS= read -r l; do
          pri=""; iif=""; tbl=""; prev=""
          for t in $l; do
            [ -n "$pri" ] || pri=$t
            [ "$prev" = "iif" ] && iif=$t
            [ "$prev" = "lookup" ] && tbl=$t
            prev=$t
          done
          case "$pri" in 5279:|5280:) ;; *) continue ;; esac
          case "$iif" in br-lan|br-guest|br-iot) ;; *) continue ;; esac
          [ "$tbl" = "100" ] && echo "RES rule-layer$fam ${pri%:} $iif | $l"
        done
        ip $fam route show table 100 2>/dev/null | while IFS= read -r l; do
          case "$l" in "unreachable default"|"unreachable default "*) k=unreachable-default ;; *) k=other ;; esac
          echo "RES rule-layer-table100$fam $k | $l"
        done
      done'
TO_RULE_PROBE='for br in br-guest br-iot; do
        a=""; prev=""
        for t in $(ip -4 addr show $br 2>/dev/null); do
          [ "$prev" = "inet" ] && [ -z "$a" ] && a=$t
          prev=$t
        done
        if [ -z "$a" ]; then echo "NOTE to-main-rule $br: no IPv4 address, nothing to check"; continue; fi
        case "$a" in *[!0-9./]*|*/*/*) a="" ;; *.*.*.*/?*) ;; *) a="" ;; esac
        if [ -z "$a" ]; then echo "RES PROBE-ERROR to-main-rule $br: unparsable IPv4 address (instrument, not plugin residue)"; continue; fi
        n=""; p=""
        for kv in $(/bin/ipcalc.sh "$a" 2>/dev/null); do
          case "$kv" in NETWORK=*) n=${kv#NETWORK=} ;; PREFIX=*) p=${kv#PREFIX=} ;; esac
        done
        case "$n" in ""|*[!0-9.]*) n="" ;; esac
        case "$p" in ""|*[!0-9]*) n="" ;; esac
        if [ -z "$n" ]; then echo "RES PROBE-ERROR to-main-rule $br: ipcalc.sh gave no NETWORK/PREFIX for $a (instrument, not plugin residue)"; continue; fi
        net="$n/$p"
        ip -4 rule list 2>/dev/null | while IFS= read -r l; do
          pri=""; to=""; tbl=""; prev=""
          for t in $l; do
            [ -n "$pri" ] || pri=$t
            [ "$prev" = "to" ] && to=$t
            [ "$prev" = "lookup" ] && tbl=$t
            prev=$t
          done
          [ "$pri" = "0:" ] && [ "$to" = "$net" ] && [ "$tbl" = "main" ] && echo "RES to-main-rule $br $net | $l"
        done
      done'
# ---8<--- end probes ---8<---

# The trailing PROBE-END line proves the probe ran to completion on the DUT, so an empty result can
# be told apart from a dead control path (see rule_layer_count).
rule_layer_probe() {
    rssh "set -f
$RULE_LAYER_PROBE
echo PROBE-END"
}

# rule_layer_verdict (stdin: probe output) -> "1" when BOTH families show a priority-5279 table-100
# rule for each of br-lan, br-guest and br-iot (a [detached] one counts: br-iot does not exist on
# every router) AND a table-100 route beginning "unreachable default"; otherwise "0". It reads only
# the fields the probe parsed router-side, so it applies no matching of its own. Empty input — a
# dead control path — reads "0".
rule_layer_verdict() {
    awk '
        $1 == "RES" && ($2 == "rule-layer-4" || $2 == "rule-layer-6") && $3 == "5279" { seen[$2 " " $4] = 1 }
        $1 == "RES" && ($2 == "rule-layer-table100-4" || $2 == "rule-layer-table100-6") && $3 == "unreachable-default" { seen[$2] = 1 }
        END {
            ok = 1
            nf = split("-4 -6", fam, " ")
            nb = split("br-lan br-guest br-iot", br, " ")
            for (f = 1; f <= nf; f++) {
                if (!(("rule-layer-table100" fam[f]) in seen)) ok = 0
                for (b = 1; b <= nb; b++) if (!(("rule-layer" fam[f] " " br[b]) in seen)) ok = 0
            }
            print ok
        }'
}

rule_layer_present() { rule_layer_probe 2>/dev/null | rule_layer_verdict; }

# rule_layer_count -> how many rule-layer objects the probe sees at all (0 on a disarmed router),
# or "probe-dead" when the PROBE-END line never arrived: absent is not the same state as unread,
# and an "absent" assert must not pass on a probe that did not run.
rule_layer_count() {
    _rlc=$(rule_layer_probe 2>/dev/null)
    case "$_rlc" in
        *PROBE-END*) printf '%s\n' "$_rlc" | grep -c '^RES ' ;;
        *) echo "probe-dead" ;;
    esac
}

# The RAW probe lines next to a rule-layer verdict, as zone_dump is for the zone layer.
log_rule_layer() {  # $1 = tag
    rule_layer_probe 2>/dev/null | while IFS= read -r _l; do log "  $1 rules $_l"; done
}

# pairs_state "<src:dest> ..." -> one "pair|section|enabled" line per matching section, and
# "pair|<no-section>|<absent>" for a pair nothing matches. Used post-removal to enumerate the
# restore rather than count it.
#
# The pair list is INTERPOLATED into a remote command, so it is charset-gated first: pairs come
# from our own sidecar, but a gate that interpolates unvalidated router state into a root shell
# is a shell-injection surface regardless of where the state came from. The list travels as an
# environment assignment with the body arriving on stdin as a quoted heredoc, so nothing in the
# body expands on the laptop. The body ends with PROBE-END, and an enumeration that never finished
# reads "probe-dead" (probe_body) rather than an empty list.
pairs_state() {
    # Gate the WHOLE list before any word splitting — splitting it first would let a token
    # containing a glob character be expanded against the laptop's cwd before it is ever checked.
    case "$(printf '%s' "$1" | tr -d ' ')" in
        *[!a-zA-Z0-9_:.-]*)
            log "REFUSING to interpolate pair list with unexpected characters: [$1]"
            return 1 ;;
    esac
    _ps_out=$(rssh "TSFX_PAIRS='$1' sh -s" <<'PSEOF'
set -f
for pair in $TSFX_PAIRS; do
  hit=0
  for l in $(uci show firewall 2>/dev/null); do
    case "$l" in firewall.*=forwarding) ;; *) continue ;; esac
    sec=${l%=forwarding}
    [ "$(uci -q get "$sec.src"):$(uci -q get "$sec.dest")" = "$pair" ] || continue
    hit=1
    echo "$pair|$sec|$(uci -q get "$sec.enabled")"
  done
  [ "$hit" = "1" ] || echo "$pair|<no-section>|<absent>"
done
echo PROBE-END
PSEOF
)
    probe_body "$_ps_out"
}

# bp_bad <pairs_state output> -> how many enumerated pairs are not restored (enabled not exactly
# "1"), or "unread" when the output holds no pair line at all: a dead probe ("probe-dead"), a
# charset refusal (empty), or an enumeration that found nothing. None of those measured a restore,
# so none may score as "0 unrestored".
bp_bad() {
    if printf '%s\n' "$1" | grep -q '|'; then
        printf '%s\n' "$1" | grep '|' | grep -vc '|1$'
    else
        echo "unread"
    fi
}

# Arm the zone kill switch the way every caller does: commit the intent FIRST (the engine
# self-gates on it and is a logged no-op otherwise), then run the engine.
#
# The engine's rc is read from a PRINTED marker rather than inferred, and a non-zero rc ABORTS
# instead of scoring: rc 2 is the Router-mode gate refusing and rc 1 is an unreadable firewall
# config, both of which mean the DUT cannot be armed at all. Continuing would turn a
# misconfigured bench into a product FAIL — an unreachable/unarmable DUT is an abort, not a
# verdict, exactly as require_control_alive treats a dead control path.
zone_arm() {
    _za_out=$(rssh "uci set ts-fix.settings.kill_switch=1
                    uci commit ts-fix
                    /usr/bin/ts-fix-ks arm
                    echo \"__RC=\$?\"" 2>&1)
    log "zone_arm: $(printf '%s' "$_za_out" | tr '\n' ' ')"
    case "$_za_out" in
        *__RC=0*) ;;
        *)  log "ABORT: ts-fix-ks arm did not return 0 (mode gate refusal, or the firewall config"
            log "       could not be enumerated) — refusing to score an armed-removal leg"
            finish; exit 2 ;;
    esac
}

# Residue enumeration — one router round-trip; every surviving plugin object prints as an
# "RES " line, and the count the assert scores is derived from those lines (never a separate
# observation). Three families of object:
#
#   ZONE state: a lan/guest/iot forwarding left disabled (the engine's source zones), the
#   ks_severed sidecar, our ts_fix_lan2ts forwarding, the engine binary, and the engine's tmpfs
#   lock + commit-failure sentinel. A severed forwarding surviving a removal is the worst residue
#   this gate can find — it is a dark LAN with no package left to restore it.
#
#   RULE-LAYER state: priority-5279 rules (and 5280, the pre-v1.0.21 layout prerm still sweeps)
#   for br-lan/br-guest/br-iot whose table is exactly 100, table-100 routes, the priority-0
#   "to <guest/iot network> lookup main" rules of Route Guest and the engine's source-rule swap,
#   and the swap's marker /tmp/ts-fix-ks.srcswap. These are CURRENT on an armed router — arm
#   installs them, disarm removes them first — so they are residue only after a removal, where
#   a rule still standing with its unreachable route is a kill switch left enforcing with no
#   package behind it. Both rule probes are the shared texts above (RULE_LAYER_PROBE,
#   TO_RULE_PROBE), matched on whole tokens: GL's own table 1002 exists on real routers and its
#   rules are not ours.
#
#   LEGACY: an `ip monitor rule` watcher, the boot guard of the RPDB-era v1.0.22 dev builds.
#   Nothing in this package spawns one any more; prerm still kills that class, so one standing
#   afterwards is a real miss. An operator's own ad-hoc monitor would also show up here — name
#   it, don't guess.
#
# Also covered as before: plugin UCI firewall sections, plugin-owned masq6, files (the rule-layer
# hotplug handler and the pre-firewall init script included), rc.d links (the S18 preboot link
# included), and live writer processes.
#
# Disabled lan/guest/iot forwardings print as "RES fwd-disabled <sec>=<pair>" so
# post_removal_asserts can excuse the ones the DUT already had disabled BEFORE this gate ran (the
# engine never records or re-enables those, so they are not ours to answer for).
#
# TWO round trips, deliberately. The object probe has to name real paths — /usr/bin/ts-fix-ks,
# /tmp/ts-fix-ks.lock — and those literals sit in the remote shell's own cmdline, where
# `pgrep -f 'ts-fix-k[s]'` (an ERE matching "ts-fix-ks") would match the probe itself and report a
# live engine on every single call. Bracketing cannot help: the paths must be spelled correctly to
# be tested. So the process probe runs as a SEPARATE command whose text contains bracketed
# patterns only. Same class as the sampler audit in the header — an instrument must not appear in
# its own search space.
# `set -f` for the section walk below (an unquoted "firewall.@forwarding[0]=..." word is a glob)
# and for the shared probes; it is switched back OFF before the rc.d loop, which needs the
# S??ts-fix glob to expand.
#
# Every rc.d link is tested with -L as well as -e: after a removal whose disable did not run, a
# link is DANGLING (opkg has already deleted its target), which -e, -f and an `ls` of the glob
# all read as absent. That holds for the S18 preboot link and for the S??ts-fix service links.
#
# UNREAD IS NOT CLEAN. Both probes end with PROBE-END, and a probe whose output lacks it — an
# unreachable DUT, a remote shell that died half way — contributes one "RES PROBE-ERROR" line in
# place of whatever it printed, so every residue count built on this enumeration FAILs instead of
# reading zero, and leg 0 aborts on it. The PROBE-END lines themselves are not printed: the
# enumeration reads exactly as before on a DUT that answered.
residue_enumerate() {
    _re_procs=$(residue_procs)
    _re_objs=$(rssh 'set -f
      '"$RULE_LAYER_PROBE"'
      '"$TO_RULE_PROBE"'
      for l in $(uci show firewall 2>/dev/null); do
        case "$l" in firewall.*=forwarding) ;; *) continue ;; esac
        sec=${l%=forwarding}
        src=$(uci -q get "$sec.src")
        case "$src" in lan|guest|iot) ;; *) continue ;; esac
        [ "$(uci -q get "$sec.enabled")" = "0" ] && echo "RES fwd-disabled $sec=$src:$(uci -q get "$sec.dest")"
      done
      [ -n "$(uci -q get ts-fix.settings.ks_severed 2>/dev/null)" ] && echo "RES uci ts-fix.settings.ks_severed=[$(uci -q get ts-fix.settings.ks_severed)]"
      for s in ts_fix_guest2ts ts_fix_ts2guest ts_fix_lan2ts ts_ks_lan2wan ts_ks_guest2wan; do
        [ -n "$(uci -q get firewall.$s 2>/dev/null)" ] && echo "RES uci firewall.$s"
      done
      [ "$(uci -q get firewall.tailscale0.masq6 2>/dev/null)" = "1" ] && echo "RES uci firewall.tailscale0.masq6=1"
      [ -f /etc/config/ts-fix ] && echo "RES file /etc/config/ts-fix"
      [ -f /etc/hotplug.d/iface/20-ts-fix ] && echo "RES file /etc/hotplug.d/iface/20-ts-fix"
      [ -f /etc/hotplug.d/iface/10-ts-fix-ks ] && echo "RES file /etc/hotplug.d/iface/10-ts-fix-ks"
      [ -f /etc/init.d/ts-fix-preboot ] && echo "RES file /etc/init.d/ts-fix-preboot"
      [ -f /usr/bin/ts-fix-ks ] && echo "RES file /usr/bin/ts-fix-ks"
      [ -f /tmp/ts-fix-ks.lock ] && echo "RES file /tmp/ts-fix-ks.lock"
      [ -f /tmp/ts-fix-ks.commit-failed ] && echo "RES file /tmp/ts-fix-ks.commit-failed"
      [ -f /tmp/ts-fix-ks.scopewarn ] && echo "RES file /tmp/ts-fix-ks.scopewarn"
      [ -f /tmp/ts-fix-ks.defroutewarn ] && echo "RES file /tmp/ts-fix-ks.defroutewarn"
      [ -f /tmp/ts-fix-ks.srcswap ] && echo "RES file /tmp/ts-fix-ks.srcswap"
      [ -f /tmp/ts-fix-daemon-pending ] && echo "RES file /tmp/ts-fix-daemon-pending"
      [ -d /usr/share/ts-fix ] && echo "RES dir /usr/share/ts-fix"
      { [ -L /etc/rc.d/S18ts-fix-preboot ] || [ -e /etc/rc.d/S18ts-fix-preboot ]; } && echo "RES rc /etc/rc.d/S18ts-fix-preboot"
      set +f
      for l in /etc/rc.d/S??ts-fix; do { [ -L "$l" ] || [ -e "$l" ]; } && echo "RES rc $l"; done
      echo PROBE-END')
    for _re_p in procs objects; do
        if [ "$_re_p" = "procs" ]; then _re_out=$_re_procs; else _re_out=$_re_objs; fi
        _re_body=$(probe_body "$_re_out")
        if [ "$_re_body" = "probe-dead" ]; then
            echo "RES PROBE-ERROR residue $_re_p probe did not complete (no PROBE-END: unreachable DUT or dead probe) - unread, not zero"
        elif [ -n "$_re_body" ]; then
            printf '%s\n' "$_re_body"
        fi
    done
}

# Live-writer half of the enumeration. Nothing but bracketed pgrep patterns may appear in this
# command's text (see residue_enumerate) — no plugin path, no unbracketed process name.
residue_procs() {
    rssh '
      pgrep -f "ts-fix-reappl[y]" >/dev/null 2>&1 && echo "RES proc reapply-writer alive"
      pgrep -f "ts-fix-watchdo[g]" >/dev/null 2>&1 && echo "RES proc watchdog-daemon alive"
      pgrep -f "ts-fix-k[s]" >/dev/null 2>&1 && echo "RES proc ks-engine alive"
      pgrep -f "ip monitor rul[e]" >/dev/null 2>&1 && echo "RES proc legacy monitor alive"
      echo PROBE-END'
}

post_removal_asserts() {  # $1 = leg tag
    _res=$(residue_enumerate)
    # Baseline exclusion, matched on the PAIR (see the AF_PREDIS capture in leg 0 for why the
    # section index cannot be part of the key). A lan/guest/iot forwarding the DUT already had
    # disabled at leg 0 is not our residue: the engine deliberately never records or re-enables a
    # forwarding it did not sever (that is also the coexistence rule with the sibling plugin —
    # first-to-sever owns restore). Without this, a stock router carrying one disabled guest or iot
    # forwarding would fail every leg for a condition the package never touched — a vacuous red.
    #
    # One awk pass with exact string comparison rather than a grep loop: the pair is taken from
    # after the FIRST "=" and looked up whole, so no substring or regex accident can excuse a line
    # that is not an exact baseline match, and only "RES fwd-disabled" lines are ever candidates.
    _res=$(printf '%s\n' "$_res" | awk -v pairs=" ${AF_PREDIS:-} " '
        {
            if (index($0, "RES fwd-disabled ") == 1) {
                p = substr($0, index($0, "=") + 1)
                if (index(pairs, " " p " ") > 0) next
            }
            print
        }')
    _res_n=$(printf '%s\n' "$_res" | grep -c '^RES ')
    assert_eq "$1 zero plugin residue (enumerated)" "$_res_n" "0"
    [ "$_res_n" != "0" ] && printf '%s\n' "$_res" | while IFS= read -r _l; do log "  $1 $_l"; done
    assert_eq "$1 config gone" "$(rssh "ls /etc/config/ts-fix 2>/dev/null | wc -l")" "0"
    assert_eq "$1 nginx up after postrm de-injection restart" "$(rssh "pgrep nginx >/dev/null 2>&1 && echo 1 || echo 0")" "1"
}

remove_and_time() {  # -> RM_SECS, RM_OUT
    _t0=$(date +%s)
    RM_OUT=$(rssh "opkg remove gl-tailscale-fix 2>&1")
    RM_SECS=$(( $(date +%s) - _t0 ))
}

reinstall_and_verify() {  # $1 = leg tag, $2 = expected kill_switch after config restore
    rssh "opkg install $RIPK" >/dev/null 2>&1
    AE_CEIL=30 assert_eventually "$1 reinstalled: watchdog running" "1" wd_running
    assert_eq "$1 saved config restored (kill_switch=$2 preserved across remove/reinstall)" \
        "$(rssh "uci -q get ts-fix.settings.kill_switch")" "$2"
    if [ "$2" = "1" ]; then
        # postinst arms the engine directly when the restored intent is on; the watchdog's check
        # pass is the backstop, hence the 30s ceiling rather than a single sample.
        AE_CEIL=30 assert_eventually "$1 re-armed unaided (postinst -> ts-fix-ks arm)" "1" zone_armed
        AE_CEIL=30 assert_eventually "$1 re-armed unaided: rule layer complete" "1" rule_layer_present
    fi
    # Let postinst's background reapply finish before the next leg needs a clean writer
    # baseline. Ceiling 120s: with the daemon down it parks its full ~93s.
    _rw=$(date +%s)
    while [ $(( $(date +%s) - _rw )) -lt 120 ] && [ "$(reapply_n)" != "0" ]; do sleep 2; done
    log "$1 postinst reapply settled in $(( $(date +%s) - _rw ))s"
}

arm_deadman() {  # $1 = seconds — router-LOCAL revert; every mutation below is covered by it
    # Zone-model revert: restoring intent is not enough on its own. Zone state lives in flash, so
    # an abandoned run leaves the severed forwardings severed until something converges them —
    # hence the explicit engine call in the matching direction. The rule layer needs no separate
    # sweep here either: it is current kill-switch state that the engine owns in both directions
    # (arm installs it, disarm removes it first), and the dead-man's reinstall line runs FIRST, so
    # the engine is present again even when the run was abandoned mid-removal. The same holds for
    # the engine's source-rule swap. See the header note: the expansion here is mixed (laptop-side
    # for $1/$RIPK/$AF_KS, router-side for the escaped and quoted-heredoc parts) and gets a
    # two-state on-device lint before this gate is scored.
    rssh "kill \$(pgrep -f 'tsfx-drain-deadma[n].sh' 2>/dev/null) 2>/dev/null; true" >/dev/null 2>&1
    rssh "cat > /tmp/tsfx-drain-deadman.sh <<'DEOF'
sleep $1
[ -f /etc/config/ts-fix ] || opkg install $RIPK >/dev/null 2>&1
uci -q set ts-fix.settings.kill_switch=$AF_KS
uci commit ts-fix
if [ -x /usr/bin/ts-fix-ks ]; then
  if [ \"$AF_KS\" = \"1\" ]; then
    /usr/bin/ts-fix-ks arm >/dev/null 2>&1
  else
    /usr/bin/ts-fix-ks disarm >/dev/null 2>&1
  fi
fi
/etc/init.d/tailscale start >/dev/null 2>&1
[ -x /etc/init.d/ts-fix ] && /etc/init.d/ts-fix start >/dev/null 2>&1
[ -x /usr/bin/ts-fix-reapply ] && /usr/bin/ts-fix-reapply >/dev/null 2>&1
DEOF
( sh /tmp/tsfx-drain-deadman.sh ) </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1
    if [ "$(rssh "pgrep -f 'tsfx-drain-deadma[n].sh' 2>/dev/null | wc -l" 2>/dev/null)" -ge 1 ] 2>/dev/null; then
        _PASS=$((_PASS+1)); log "PASS: dead-man timer LIVE (pgrep readback)"
    else
        _FAIL=$((_FAIL+1)); log "FAIL: dead-man did not arm — refusing to run removal legs"; finish; exit 2
    fi
}

cancel_deadman() {
    rssh "kill \$(pgrep -f 'tsfx-drain-deadma[n].sh' 2>/dev/null) 2>/dev/null; true" >/dev/null 2>&1
    rssh "rm -f /tmp/tsfx-drain-deadman.sh; true" >/dev/null 2>&1
    assert_eq "cleanup: dead-man cancelled (pgrep readback empty)" \
        "$(rssh "pgrep -f 'tsfx-drain-deadma[n].sh' 2>/dev/null | wc -l")" "0"
}

# --- leg 0: preflight ------------------------------------------------------------------------

[ -z "${TARGET:-}" ] && { echo "TARGET=<router-ip> required" >&2; exit 2; }
[ -z "${IPK:-}" ] && { echo "IPK=<local path to FIXED build> required" >&2; exit 2; }
[ -f "$IPK" ] || { echo "IPK not found: $IPK" >&2; exit 2; }

log "== prerm-drain gate — target $TARGET, ipk $IPK =="
require_control_alive "leg0"

MODEL=$(rssh "cat /tmp/sysinfo/model 2>/dev/null")
GLVER=$(rssh "awk '{print \$1}' /etc/glversion 2>/dev/null")
FWGEN=$(rssh "[ -x /sbin/fw4 ] && echo fw4 || echo fw3")
log "leg0 identity: model=[$MODEL] glversion=[$GLVER] $FWGEN"
case "$MODEL" in
    *AXT1800*|*Slate\ AX*)
        if [ "${ALLOW_AXT1800:-0}" != "1" ]; then
            log "ABORT: target is an AXT1800 — krm-driven by project protocol (ALLOW_AXT1800=1 to override)"
            exit 2
        fi ;;
esac

# The INSTALLED prerm must carry the fix — probed by CONTENT (functional lines), not version:
# the fix ships inside a release, so a version gate cannot discriminate fixed from unfixed.
# Against an unfixed prerm this gate would measure a known bug and report it as a fresh red —
# refuse instead (the red direction lives in the committed red-proof evidence log).
#
# Five markers, covering both generations of the fix. The first three are the removal-window
# neutralization (hotplug rm, guard kill, reapply drain). The last two are the zone pivot: the
# ENGINE DRAIN pattern and the teardown's engine disarm — without them the installed prerm is a
# pre-pivot script that cannot restore severed forwardings, and leg B' would score its own
# staleness as a product defect. grep -F, so the bracketed drain pattern is matched literally.
_iprerm=/usr/lib/opkg/info/gl-tailscale-fix.prerm
for _marker in "rm -f /etc/hotplug.d/iface/20-ts-fix" "ip monitor rul" "ts-fix-reappl" \
               "ts-fix-k[s]" "ts-fix-ks disarm"; do
    if ! rssh "grep -qF \"$_marker\" $_iprerm 2>/dev/null && echo hit" | grep -q hit; then
        log "ABORT: installed prerm lacks fix marker [$_marker] — deploy the fixed build first"
        exit 2
    fi
done
log "leg0 installed prerm carries all five neutralization/zone-teardown markers"
_md5_local=$(md5sum pkg/prerm | awk '{print $1}')
_md5_dut=$(rssh "md5sum $_iprerm 2>/dev/null | awk '{print \$1}'")
assert_eq "leg0 installed prerm byte-identical to repo pkg/prerm" "$_md5_dut" "$_md5_local"

# Posture preconditions: the legs need Tailscale enabled + Running and a live wan6 to bounce.
assert_eq "leg0 tailscale enabled (GL UCI)" "$(rssh "uci -q get tailscale.settings.enabled")" "1"
AE_CEIL=60 assert_eventually "leg0 tailscaled Running" "Running" ts_state
assert_eq "leg0 wan6 up (leg C bounces it)" "$(wan6_up)" "1"
assert_eq "leg0 GL tailscale init present (leg D parks against its stop)" \
    "$(rssh "[ -x /etc/init.d/tailscale ] && echo 1 || echo 0")" "1"

# As-found capture (restored exactly by cleanup; dead-man restores kill_switch + service).
AF_KS=$(rssh "uci -q get ts-fix.settings.kill_switch"); AF_KS=${AF_KS:-0}
AF_RG=$(rssh "uci -q get ts-fix.settings.route_guest"); AF_RG=${AF_RG:-0}
AF_ADV=$(rssh "uci -q get ts-fix.settings.advertise_exit_node"); AF_ADV=${AF_ADV:-0}
AF_SSH=$(rssh "uci -q get ts-fix.settings.tailscale_ssh"); AF_SSH=${AF_SSH:-0}
AF_MASQ6=$(rssh "uci -q get firewall.tailscale0.masq6")
AF_RL_N=$(rule_layer_count)
log "leg0 as-found: ks=$AF_KS rg=$AF_RG adv=$AF_ADV ssh=$AF_SSH tailscale0.masq6=[${AF_MASQ6:-unset}] armed=$(zone_armed) rule-layer-objects=$AF_RL_N watchdog=$(wd_running)"
while IFS= read -r _l; do log "  leg0 zone $_l"; done <<ZDUMP
$(zone_dump)
ZDUMP
log_rule_layer "leg0"
if [ "$AF_KS" != "0" ]; then
    log "ABORT: as-found kill_switch=$AF_KS — this gate assumes a disarmed parked DUT (restore semantics are written for it)"
    exit 2
fi
if [ "$(zone_armed)" != "0" ]; then
    log "ABORT: as-found zone state reads ARMED with kill_switch=0 — stranded severed forwardings"
    log "       (run 'ts-fix-ks disarm' on the DUT and re-check before scoring anything here)"
    exit 2
fi
# The same stance for the rule layer: with kill_switch=0 the engine's disarmed check removes any
# rule-layer rule within a poll, so objects standing here are stranded — or the probe is dead
# ("probe-dead"), which is no better. Either way the restore semantics below would be wrong.
if [ "$AF_RL_N" != "0" ]; then
    log "ABORT: as-found rule layer reads [$AF_RL_N] with kill_switch=0 — stranded rules or an unreadable probe"
    log "       (run 'ts-fix-ks rules-clean' on the DUT, read the leg0 rules lines above, and re-check)"
    exit 2
fi

# Baseline of lan/guest/iot forwardings ALREADY disabled before the gate ran. post_removal_asserts
# excuses exactly these from the residue count: the engine records and restores only what IT
# severed, so a forwarding disabled by the user (or by a sibling plugin) is not residue, and
# counting it would red every leg for a condition we never touched.
#
# Keyed on the PAIR, not on "<sec>=<pair>". The section half is an anonymous index in the common
# case, and this same file documents those indexes as unstable — prerm deletes named sections
# (ts_fix_guest2ts, ts_fix_lan2ts, ...) during every leg, and GL rewrites /etc/config/firewall
# wholesale, either of which renumbers @forwarding[N] and would silently un-excuse a baseline
# entry mid-run. The pair is also the engine's own restore granularity, so the exclusion is keyed
# the same way the product reasons about it.
_r0=$(residue_enumerate)
AF_PREDIS=$(printf '%s\n' "$_r0" | sed -n 's/^RES fwd-disabled [^=]*=//p' | tr '\n' ' ')
log "leg0 pre-disabled lan/guest/iot forwardings (excused from residue): [${AF_PREDIS:-none}]"
# The residue probe must be able to read this DUT before anything is scored with it: a
# "RES PROBE-ERROR" line means TO_RULE_PROBE could not derive a network (ipcalc.sh missing or
# answering in a form it cannot parse), or that one of the two probes never finished (no
# PROBE-END; see residue_enumerate). NOTE lines say which checks had nothing to look at here.
printf '%s\n' "$_r0" | grep '^NOTE ' | while IFS= read -r _l; do log "  leg0 probe $_l"; done
if printf '%s\n' "$_r0" | grep -q '^RES PROBE-ERROR'; then
    printf '%s\n' "$_r0" | grep '^RES PROBE-ERROR' | while IFS= read -r _l; do log "  leg0 $_l"; done
    log "ABORT: the residue probe cannot read this DUT — fix the instrument before scoring anything"
    exit 2
fi

# Stage the exact build under test at a FIXED name — no glob selection anywhere in this gate
# (a glob-and-head selector silently downgraded a sibling DUT mid-certificate; obs 107/108).
RIPK=/tmp/gl-tailscale-fix-under-test.ipk
if [ -n "${ROUTER_JUMP:-}" ]; then
    scp -O -o ProxyJump="$ROUTER_JUMP" -o StrictHostKeyChecking=accept-new "$IPK" "root@$TARGET:$RIPK" >/dev/null 2>&1
else
    scp -O -o StrictHostKeyChecking=accept-new "$IPK" "root@$TARGET:$RIPK" >/dev/null 2>&1
fi
assert_eq "leg0 staged IPK md5 matches local build" \
    "$(rssh "md5sum $RIPK 2>/dev/null | awk '{print \$1}'")" "$(md5sum "$IPK" | awk '{print $1}')"

arm_deadman 900

# =============================================================================================
log "== LEG A: CONTROL — no stragglers, removal must be fast and total =="
require_control_alive "legA"
remove_and_time
log "A.1 control removal wall-time: ${RM_SECS}s"
log "A.1 opkg output: $(echo "$RM_OUT" | tr '\n' ' ')"
if [ "$RM_SECS" -le 25 ]; then
    _PASS=$((_PASS+1)); log "PASS: A.2 no-straggler removal is FAST (${RM_SECS}s <= 25s) — drain did not wait on nothing"
else
    _FAIL=$((_FAIL+1)); log "FAIL: A.2 no-straggler removal took ${RM_SECS}s — the drain waited with no writer alive"
fi
post_removal_asserts "A.3"
reinstall_and_verify "A.4" "$AF_KS"

# =============================================================================================
log "== LEG B': ARMED REMOVAL — the zone state the package severed must come back =="
require_control_alive "legBprime"
# The zone model moves the removal hazard from "a detached writer re-adds a policy rule" to
# "flash-persisted UCI outlives the package". Severed forwardings are not runtime state: they
# survive reboots and survive the package, so a removal that fails to restore them leaves a LAN
# with no egress, no plugin and no tooling — the most damaging outcome this gate can produce, and
# the reason prerm captures its disarm rc and KEEPS /etc/config/ts-fix when the restore fails.
#
# The retired leg-B boot-guard hazards do not apply: the pivoted init.d spawns no guard, so there
# is neither a re-assert writer nor an inherited service-lock queue to regress. Removal wall-time
# is therefore LOGGED here rather than scored — the thing worth scoring is the restored state.
zone_arm
AE_CEIL=30 assert_eventually "B'.0 armed: sidecar recorded and every recorded pair severed" "1" zone_armed
# Non-vacuity for the rule-layer half of every later residue count: the same probe that must read
# zero after the removal has to read the complete layer here, on this DUT, first.
AE_CEIL=30 assert_eventually "B'.0b armed: rule layer complete (5279 x br-lan/br-guest/br-iot + table-100 unreachable, both families)" "1" rule_layer_present
log_rule_layer "B'.0b"
BP_PAIRS=$(sev_list)
BP_N=$(printf '%s\n' "$BP_PAIRS" | tr ' ' '\n' | grep -c ':')
assert_ge "B'.1 non-vacuity: pairs actually recorded before removal" "$BP_N" "1"
log "B'.1 severed pairs: [$BP_PAIRS] (count $BP_N)"
while IFS= read -r _l; do log "  B'.1 zone $_l"; done <<ZDUMP
$(zone_dump)
ZDUMP
remove_and_time
log "B'.2 armed removal wall-time: ${RM_SECS}s (logged, not scored — no lock-queue mechanism left)"
log "B'.2 opkg output: $(echo "$RM_OUT" | tr '\n' ' ')"
# Restore is enumerated, not counted: every recorded pair prints with its section and its live
# enabled value, and the score is derived from that same enumeration. disarm sets enabled='1'
# explicitly (matching observed stock state), so anything that is not exactly "1" — still "0",
# absent, or a pair whose section vanished — is a failed restore and is named.
BP_STATE=$(pairs_state "$BP_PAIRS")
while IFS= read -r _l; do log "  B'.3 restore $_l"; done <<PSDUMP
$BP_STATE
PSDUMP
# The floor first: pairs_state returns EMPTY on a charset refusal and "probe-dead" on a dead
# control path, and neither may score as zero unrestored pairs — a pass earned by having measured
# nothing — so bp_bad reads both as "unread". Every recorded pair must appear at least once; more
# lines than pairs is legitimate (one pair can match several forwarding sections), fewer is the
# instrument failing silently.
BP_LINES=$(printf '%s\n' "$BP_STATE" | grep -c '|')
assert_ge "B'.3a non-vacuity: pairs_state enumerated every recorded pair" "$BP_LINES" "$BP_N"
BP_BAD=$(bp_bad "$BP_STATE")
assert_eq "B'.3 *** every severed pair re-enabled after removal (pairs NOT restored)" "$BP_BAD" "0"
# Both reads are PROBE-END-checked: an unreadable DUT answers "probe-dead", never "" (gone).
assert_eq "B'.4 sidecar gone" "$(sev_list)" ""
assert_eq "B'.5 ts_fix_lan2ts gone" "$(rssh_read "uci -q get firewall.ts_fix_lan2ts 2>/dev/null")" ""
# prerm deletes /etc/config/ts-fix ONLY when the disarm returned 0, so post_removal_asserts'
# "config gone" is simultaneously the successful-restore signal for this leg.
post_removal_asserts "B'.6"
reinstall_and_verify "B'.7" "1"

# =============================================================================================
log "== LEG C: HOTPLUG-BORN — an iface event fired INSIDE the removal window =="
require_control_alive "legC"
# Armed + daemon Running (worst case: a hotplug reapply completes fast and fully re-arms).
# The injection is EVENT-GATED, not sleep-timed: on this platform `ifup wan6` emits its
# ifdown hotplug event ~1-6s after the command, and the ifup event only at DHCPv6 COMPLETION
# (~6-8s later, variable — measured with a logger probe; a second `ifup` during negotiation
# RESTARTS it and pushes the event LATER, so never double-fire). ts-fix's handler acts only
# on ifup while Tailscale is enabled, so the removal launches at the ifdown sighting — the
# ifup event then lands mid-window — and C.1b verifies from the probe handler's log line
# that it really did: without that check, born=0 is vacuously green whenever the event
# missed the window (two sleep-timed shapes missed it before this gate existed). The probe
# handler is gate-owned, logger-only, and removed in cleanup; opkg does not touch it.
AE_CEIL=30 assert_eventually "C.0 still armed before injection (zone state)" "1" zone_armed
AE_CEIL=30 assert_eventually "C.0b still armed before injection (rule layer complete)" "1" rule_layer_present
rssh 'cat > /etc/hotplug.d/iface/99-tsfx-gate-probe <<PEOF
logger -t tsfxgate "ACTION=\$ACTION INTERFACE=\$INTERFACE up=\$(cut -d. -f1 /proc/uptime)"
PEOF
chmod 644 /etc/hotplug.d/iface/99-tsfx-gate-probe' >/dev/null 2>&1
_mark=$(rssh "logread 2>/dev/null | grep -c 'tsfxgate: ACTION=ifdown INTERFACE=wan6'")
rssh "ifup wan6" >/dev/null 2>&1
_ig=$(date +%s)
while [ $(( $(date +%s) - _ig )) -lt 15 ]; do
    _now=$(rssh "logread 2>/dev/null | grep -c 'tsfxgate: ACTION=ifdown INTERFACE=wan6'")
    [ "${_now:-0}" -gt "${_mark:-0}" ] 2>/dev/null && break
    sleep 1
done
# The bounce's ifdown-adjacent events (netifd also emits ifup for wan6's DHCPv6-PD
# sub-interfaces within ~1-2s of the ifdown) fire while the package is still fully
# installed — a writer they spawn is an ordinary IN-FLIGHT writer, the drain's jurisdiction,
# not this leg's question (the first scored run counted one such pid as "hotplug-born" while
# the drain visibly waited 18s and cleaned it). Settle past them, then take the baseline
# immediately before the removal.
sleep 3
_pre=$(rssh "pgrep -f 'ts-fix-reappl[y]' 2>/dev/null | sort" 2>/dev/null)
UP0=$(rssh "cut -d. -f1 /proc/uptime")
# Timestamped window sampler — each tick records uptime | handler-file state | live reapply
# pids. The pid column is DIAGNOSTIC ONLY: per-pid "born after" attribution by cmdline is
# structurally unreliable in this leg — an ash command substitution inside a live writer
# forks subshells that carry the parent's cmdline for their ~1s life (measured: a parked
# writer's Running-wait loop minted one 'new' pid per second), and a genuinely-born reapply
# that loses `flock -n` to that writer exits in milliseconds and can slip between ticks. The
# scored claims are structural instead: C.2 the handler file was removed EARLY in the window
# (H1->H0), C.2b the real ifup event landed AFTER that removal (netifd scans hotplug.d per
# event — verified live: this gate's own probe handler fired the instant it was created, no
# reload), and C.2c no writer survived teardown. The bracketed pattern cannot match the
# fixed prerm's own drain pgrep (in-file pattern equally bracketed), verified live.
#
# Cadence: `usleep` is a BusyBox applet, not a guarantee — applet sets differ per host and per
# firmware, and an unguarded call would abort each tick's sleep and burn all 24 samples in under
# a second (the window would close before the removal even started). The fallback halves the
# sampling DENSITY (1s ticks instead of 0.5s, so ~24s of coverage instead of ~12s), which the
# scored claims tolerate: C.2 asks whether the handler disappeared EARLY (a 5s allowance) and
# C.2b compares event uptime against handler-gone uptime, both at 1s resolution anyway.
#
# The backgrounded ssh gets its own </dev/null: a background ssh that shares the script's stdin
# competes for it with everything else, which is the measured ssh-hang trap in this project.
_WSF=$(mktemp)
rssh "for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
        echo \"\$(cut -d. -f1 /proc/uptime)|H\$([ -f /etc/hotplug.d/iface/20-ts-fix ] && echo 1 || echo 0)|\$(pgrep -f 'ts-fix-reappl[y]' 2>/dev/null | tr '\n' ',')\"
        usleep 500000 2>/dev/null || sleep 1
      done" </dev/null > "$_WSF" 2>/dev/null &
_WS_PID=$!
remove_and_time
UP1=$(rssh "cut -d. -f1 /proc/uptime")
log "C.1 injected removal wall-time: ${RM_SECS}s (uptime window $UP0..$UP1)"
log "C.1 opkg output: $(echo "$RM_OUT" | tr '\n' ' ')"
wait $_WS_PID 2>/dev/null
_evup=$(rssh "logread 2>/dev/null | grep 'tsfxgate: ACTION=ifup INTERFACE=wan6' | tail -1 | sed 's/.*up=//'")
if [ -n "$_evup" ] && [ "$_evup" -ge "$UP0" ] 2>/dev/null && [ "$_evup" -le "$UP1" ] 2>/dev/null; then
    _PASS=$((_PASS+1)); log "PASS: C.1b ifup EVENT landed INSIDE the removal window (up=$_evup in $UP0..$UP1) — C.2 is non-vacuous"
else
    _FAIL=$((_FAIL+1)); log "FAIL: C.1b ifup event up=[${_evup:-none}] outside removal window $UP0..$UP1 — C.2 would be vacuous; re-run the leg"
fi
_Hg=""
while IFS='|' read -r _u _h _pids; do
    [ "$_h" = "H0" ] && { _Hg=$_u; break; }
done < "$_WSF"
_born_after=""; _born_pre=""; _seen=" $(echo $_pre | tr '\n' ' ') "
while IFS='|' read -r _u _h _pids; do
    for _p in $(echo "$_pids" | tr ',' ' '); do
        [ -n "$_p" ] || continue
        case "$_seen" in *" $_p "*) continue ;; esac
        _seen="$_seen$_p "
        if [ -n "$_Hg" ] && [ "$_u" -ge "$_Hg" ] 2>/dev/null; then
            _born_after="$_born_after $_p@$_u"
        else
            _born_pre="$_born_pre $_p@$_u"
        fi
    done
done < "$_WSF"
log "C.1 window: handler-gone-at=[${_Hg:-never}] baseline=[$(echo $_pre)] first-seen-before-gone=[$(echo $_born_pre)] first-seen-after-gone (diagnostic, fork-lineage-ambiguous)=[$(echo $_born_after)]"
if [ -z "$_Hg" ]; then
    log "C.1 raw tick table (fail-time forensics):"
    while IFS= read -r _l; do log "  C.1 $_l"; done < "$_WSF"
fi
rm -f "$_WSF"
if [ -n "$_Hg" ] && [ $(( _Hg - UP0 )) -le 5 ] 2>/dev/null; then
    _PASS=$((_PASS+1)); log "PASS: C.2 *** handler file removed EARLY in the window (H1->H0 at up=$_Hg, +$(( _Hg - UP0 ))s from removal start)"
else
    _FAIL=$((_FAIL+1)); log "FAIL: C.2 handler removal not observed early — H1->H0 at [${_Hg:-never}], window start $UP0"
fi
if [ -n "$_Hg" ] && [ -n "$_evup" ] && [ "$_evup" -ge "$_Hg" ] 2>/dev/null; then
    _PASS=$((_PASS+1)); log "PASS: C.2b *** the ifup event (up=$_evup) met an ALREADY-DELETED handler (gone at $_Hg) — netifd had nothing left to run"
else
    _FAIL=$((_FAIL+1)); log "FAIL: C.2b event up=[${_evup:-none}] did not land after handler-gone [${_Hg:-never}]"
fi
assert_eq "C.2c no writer survived teardown (any pre-neutralization birth was drained)" "$(reapply_n)" "0"
post_removal_asserts "C.3"
AE_CEIL=60 assert_eventually "C.4 wan6 recovered from its own bounce" "1" wan6_up
reinstall_and_verify "C.5" "1"

# =============================================================================================
log "== LEG D: PARKED WRITER — an orphaned reapply in its daemon wait at remove time =="
require_control_alive "legD"
# Park substrate: with the daemon stopped (service stop — no procd respawn), a fresh reapply
# holds its own lock through sleep 3 + the 30s Running wait (~33s park), exactly the orphan procd
# cannot see. Spawned detached the same way the real orphan survives — with stdin redirected, so
# the backgrounded remote spawn cannot hold this ssh session open waiting on it.
rssh "/etc/init.d/tailscale stop" >/dev/null 2>&1
rssh "( /usr/bin/ts-fix-reapply ) </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1
sleep 2
assert_ge "D.0 straggler parked: reapply alive at remove time" "$(reapply_n)" "1"
# Single samples, not assert_eventually: the park window is finite, and both layers have been armed
# since C.5 (stopping the daemon changes neither — intent is UCI, and the rules are the engine's).
assert_eq "D.0a still armed at remove time (zone state)" "$(zone_armed)" "1"
assert_eq "D.0b still armed at remove time (rule layer complete)" "$(rule_layer_present)" "1"
remove_and_time
log "D.1 parked removal wall-time: ${RM_SECS}s"
log "D.1 opkg output: $(echo "$RM_OUT" | tr '\n' ' ')"
# The drain's signature: prerm waited for the park to end (~33s) — or capped at 100s + kill.
# Under 20s means the drain never saw the writer at all.
#
# Ceiling derivation, with the zone pivot's costs counted in (the window itself is unchanged):
#   ~33s  the reapply park this leg creates (sleep 3 + the 30s Running wait, daemon stopped)
#   0-30s the ENGINE drain that follows it. reapply calls ts-fix-ks in its kill-switch block,
#         which sits immediately after its flock and BEFORE the daemon waits, so by removal time
#         (2s after the spawn) the engine child has normally finished and this costs nothing —
#         the same "must not wait on nothing" property leg A scores.
#   +     TWO firewall reloads in the teardown: the one inside disarm's own _ks_commit, and
#         prerm's own reload after its section deletes.
#   ~11s  postrm's nginx restart (measured on this class of router).
# So a legitimate parked removal lands around 66-98s, and 115s is a ceiling with margin rather
# than a prediction. Above it the substrate has no way to spend the time, which is why the FAIL
# text names both possibilities instead of asserting the drain misbehaved.
if [ "$RM_SECS" -ge 20 ] && [ "$RM_SECS" -le 115 ]; then
    _PASS=$((_PASS+1)); log "PASS: D.2 *** drain WAITED for the parked writer (${RM_SECS}s in [20,115]; modelled 66-98s)"
elif [ "$RM_SECS" -lt 20 ]; then
    _FAIL=$((_FAIL+1)); log "FAIL: D.2 parked removal took ${RM_SECS}s (< 20s) — the drain never saw the parked writer"
else
    _FAIL=$((_FAIL+1)); log "FAIL: D.2 parked removal took ${RM_SECS}s (> 115s). Nothing in the modelled substrate"
    log "      (33s park + <=30s engine drain + 2 firewall reloads + ~11s nginx restart = 66-98s)"
    log "      can spend that long — either a drain failed to bound, or something outside the"
    log "      model stalled (an inherited lock, a hung reload). Read the opkg output above."
fi
assert_eq "D.3 no writer survived teardown" "$(reapply_n)" "0"
post_removal_asserts "D.4"
rssh "/etc/init.d/tailscale start" >/dev/null 2>&1
AE_CEIL=90 assert_eventually "D.5 tailscaled Running again" "Running" ts_state
reinstall_and_verify "D.6" "1"

# =============================================================================================
log "== cleanup: restore as-found =="
# The engine call is explicit rather than left to reapply: zone state is flash-persisted, so
# restoring the intent alone would leave the last leg's severed forwardings severed until some
# later convergence pass. reapply then re-applies the non-KS settings on top.
rssh "uci set ts-fix.settings.kill_switch=$AF_KS
      uci set ts-fix.settings.route_guest=$AF_RG
      uci set ts-fix.settings.advertise_exit_node=$AF_ADV
      uci set ts-fix.settings.tailscale_ssh=$AF_SSH
      uci commit ts-fix
      [ -x /usr/bin/ts-fix-ks ] && /usr/bin/ts-fix-ks disarm
      /usr/bin/ts-fix-reapply" >/dev/null 2>&1
if [ "$AF_KS" = "0" ]; then
    AE_CEIL=30 assert_eventually "cleanup: zone state disarmed (as-found)" "0" zone_armed
    AE_CEIL=30 assert_eventually "cleanup: rule layer gone (as-found: none, leg0 aborts otherwise)" "0" rule_layer_count
    assert_eq "cleanup: sidecar cleared" "$(sev_list)" ""
fi
while IFS= read -r _l; do log "  cleanup zone $_l"; done <<ZDUMP
$(zone_dump)
ZDUMP
assert_eq "cleanup: watchdog running" "$(wd_running)" "1"
AE_CEIL=90 assert_eventually "cleanup: tailscaled Running" "Running" ts_state
assert_eq "cleanup: kill_switch as-found" "$(rssh "uci -q get ts-fix.settings.kill_switch")" "$AF_KS"
cancel_deadman
rssh "rm -f $RIPK /etc/hotplug.d/iface/99-tsfx-gate-probe; true" >/dev/null 2>&1

finish
[ "$_FAIL" = "0" ] || exit 1
exit 0
