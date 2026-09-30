#!/bin/sh
# Unit test for tests/prerm-drain.sh's probe helpers: a probe that never completes — an unreachable
# DUT, where every rssh fails — must read as unread (a "RES PROBE-ERROR" line, "probe-dead",
# "unread") and FAIL the assert built on it, never score as zero residue or an emptied sidecar.
# Laptop only, no router:
#   sh tests/unit/test-prerm-drain-probes.sh          (also runs under: busybox ash; needs bash)
#
# prerm-drain.sh is a bash script that runs its legs when executed, so its helpers are taken out by
# name — a one-line definition, or a definition line through the first line that is exactly "}" —
# together with its marked probes block, and run by bash, the gate's own interpreter, in a driver
# with a fake rssh. The fake records every command and has three modes: dead (no output, rc 255, as
# ssh with no route to the host), clean (a DUT with nothing left: each probe answers only its
# PROBE-END), and residue (the object probe also reports one leftover file). In the clean mode it
# also records any probe that asked for no PROBE-END: a helper that lost its sentinel shows there.

PD="$(dirname "$0")/../prerm-drain.sh"
fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
finish() {
    [ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
    echo "$fails FAILED ($oks ok)"; exit 1
}

command -v bash >/dev/null 2>&1 || { nok "bash present (prerm-drain.sh's interpreter)" "bash" "not found"; finish; }
T=$(mktemp -d) || { echo "FAIL: mktemp -d"; exit 1; }
trap 'rm -rf "$T"' EXIT

# fn <name> -> that function's definition from prerm-drain.sh. The one-liners align their braces
# with extra spaces ("sev_list()   {"), so any run of spaces may sit between "()" and "{".
fn() {
    command awk -v n="$1" '
        !on && index($0, n "()") == 1 && substr($0, length(n) + 3) ~ /^ *[{]/ {
            if ($0 ~ /}$/) { print; exit }
            on = 1
        }
        on { print; if ($0 == "}") exit }' "$PD"
}
FNS="log assert_eq probe_body rssh_read sev_list pairs_state bp_bad residue_procs residue_enumerate post_removal_asserts"
for f in $FNS; do fn "$f"; done > "$T/extracted.sh"
command awk '/^# ---8<--- probes ---8<---$/,/^# ---8<--- end probes ---8<---$/' "$PD" >> "$T/extracted.sh"
got=""
for f in $FNS; do
    [ "$(grep -c "^$f() " "$T/extracted.sh")" = "1" ] || got="$got $f"
done
is "every helper was extracted, once each (none renamed or lost)" "" "$got"
is "the shared probe texts came with them" "2" "$(grep -c -e '^RULE_LAYER_PROBE=' -e '^TO_RULE_PROBE=' "$T/extracted.sh")"
if bash -n "$T/extracted.sh" 2>"$T/err"; then ok "the extraction parses under bash"
else nok "the extraction parses under bash" "no syntax error" "$(cat "$T/err")"; fi

cat > "$T/driver.sh" <<'EOF'
set -u
RESULTS="$T/drain.log"; _PASS=0; _FAIL=0; AF_PREDIS=""
: > "$RESULTS"; : > "$T/rssh.calls"; : > "$T/unsentinelled"
. "$T/extracted.sh"
rssh() {
    printf '%s\n' "$*" >> "$T/rssh.calls"
    [ "$FAKE" = "dead" ] && return 255
    _c="$*"
    case "$_c" in *" sh -s") _c="$_c $(cat)" ;; esac
    case "$_c" in
        "ls /etc/config/ts-fix"*) echo 0; return 0 ;;
        "pgrep nginx"*) echo 1; return 0 ;;
    esac
    case "$_c" in *"echo PROBE-END"*) ;; *) printf '%s\n' "$_c" >> "$T/unsentinelled"; return 0 ;; esac
    if [ "$FAKE" = "residue" ]; then
        case "$_c" in *'echo "RES file /tmp/ts-fix-ks.lock"'*) echo "RES file /tmp/ts-fix-ks.lock" ;; esac
    fi
    case "$_c" in *"TSFX_PAIRS="*) echo "lan:wan|@forwarding[0]|1" ;; esac
    echo PROBE-END
}
say() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' '~')"; }
FAKE=dead
say lint-dead "$(rssh 'echo PROBE-END'; echo "rc=$?")"
say dead-residue "$(residue_enumerate)"
post_removal_asserts "X"
say dead-sev "$(sev_list)"
say dead-read "$(rssh_read "uci -q get firewall.ts_fix_lan2ts 2>/dev/null")"
say dead-pairs "$(pairs_state "lan:wan")"
say dead-bpbad "$(bp_bad "$(pairs_state "lan:wan")")"
say empty-bpbad "$(bp_bad "")"
assert_eq "B'.4 sidecar gone" "$(sev_list)" ""
say dead-log "$(cat "$RESULTS")"
say dead-counts "$_PASS $_FAIL"
: > "$RESULTS"; _PASS=0; _FAIL=0; : > "$T/unsentinelled"
FAKE=clean
say clean-residue "$(residue_enumerate)"
post_removal_asserts "Y"
say clean-sev "$(sev_list)"
say clean-pairs "$(pairs_state "lan:wan")"
say clean-bpbad "$(bp_bad "$(pairs_state "lan:wan")")"
say clean-log "$(cat "$RESULTS")"
say clean-counts "$_PASS $_FAIL"
say clean-unsentinelled "$(cat "$T/unsentinelled")"
: > "$RESULTS"; _PASS=0; _FAIL=0
FAKE=residue
say residue-residue "$(residue_enumerate)"
post_removal_asserts "Z"
say residue-log "$(cat "$RESULTS")"
say residue-counts "$_PASS $_FAIL"
EOF
out=$(T="$T" bash "$T/driver.sh" 2>"$T/driver.err"); rc=$?
is "the driver ran to its end (rc 0, nothing on stderr)" "0:" "$rc:$(cat "$T/driver.err")"
val() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | tr '~' '\n'; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) nok "$1" "text containing: $2" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) nok "$1" "text NOT containing: $2" "$3" ;; *) ok "$1" ;; esac; }

echo "== an unreachable DUT (every rssh fails, no output)"
is "instrument lint: the dead fake prints nothing and returns 255" "rc=255" "$(val lint-dead)"
is "the residue enumeration is two PROBE-ERROR lines, one per probe, and nothing else" \
"RES PROBE-ERROR residue procs probe did not complete (no PROBE-END: unreachable DUT or dead probe) - unread, not zero
RES PROBE-ERROR residue objects probe did not complete (no PROBE-END: unreachable DUT or dead probe) - unread, not zero" \
    "$(val dead-residue)"
has "post_removal_asserts FAILs the residue count (the measured 07:21 PASS [0])" \
    "FAIL: X zero plugin residue (enumerated) — expected [0], got [2]" "$(val dead-log)"
hasnt "... and never PASSes it" "PASS: X zero plugin residue" "$(val dead-log)"
has "... and logs what it could not read" "  X RES PROBE-ERROR residue objects probe did not complete" "$(val dead-log)"
is "sev_list reads probe-dead, not an empty sidecar" "probe-dead" "$(val dead-sev)"
is "rssh_read (B'.5's lan2ts read) reads probe-dead" "probe-dead" "$(val dead-read)"
is "pairs_state reads probe-dead, not an empty enumeration" "probe-dead" "$(val dead-pairs)"
is "bp_bad of it is unread, not 0 unrestored pairs (B'.3)" "unread" "$(val dead-bpbad)"
is "bp_bad of an empty enumeration (a charset refusal) is unread too" "unread" "$(val empty-bpbad)"
has "B'.4's assert FAILs on it" "FAIL: B'.4 sidecar gone — expected [], got [probe-dead]" "$(val dead-log)"
is "not one PASS in the whole dead run" "0" "$(val dead-counts | cut -d' ' -f1)"

echo "== a DUT that answers, with nothing left (the other direction)"
is "the residue enumeration is empty — the PROBE-END lines are not printed" "" "$(val clean-residue)"
has "post_removal_asserts PASSes the residue count" "PASS: Y zero plugin residue (enumerated) [0]" "$(val clean-log)"
is "... and its other two asserts pass too" "3 0" "$(val clean-counts)"
is "sev_list reads an empty sidecar" "" "$(val clean-sev)"
is "pairs_state returns the enumeration, sentinel removed" "lan:wan|@forwarding[0]|1" "$(val clean-pairs)"
is "bp_bad counts 0 unrestored pairs" "0" "$(val clean-bpbad)"
is "every probe the helpers sent asked for its PROBE-END" "" "$(val clean-unsentinelled)"

echo "== a DUT that answers, with one leftover file"
is "the enumeration output is the probe's own line, as before" "RES file /tmp/ts-fix-ks.lock" "$(val residue-residue)"
has "post_removal_asserts FAILs with a count of 1" \
    "FAIL: Z zero plugin residue (enumerated) — expected [0], got [1]" "$(val residue-log)"
has "... and names the object" "  Z RES file /tmp/ts-fix-ks.lock" "$(val residue-log)"
finish
