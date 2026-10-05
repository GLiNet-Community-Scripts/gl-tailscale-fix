#!/bin/sh
# Unit test for the side-switch accessory, accessories/gl-switch.d/tailscale.sh: the order of the
# "on" flip, the "off" flip, and ks_active(), the gate that releases the on flip's lockdown.
# Laptop-only, no router involved:
#   sh tests/unit/test-acc-switch.sh [target]          (also runs under: busybox ash)
#
# [target] defaults to the shipping accessory. Pass an older copy of the script to run the SAME
# cases against it. The pre-ACC2 baseline (tests/results/20261002-build/baselines/pre-ACC2/
# tailscale.sh) is the negative control: the cases on the kill-switch-first order, on br-iot and on
# the sourcing guard must FAIL there, and the cases on behaviour that did not change must pass.
#
# Two ways in, chosen from the target itself:
#   lib     the target carries the TS_FIX_SWITCH_LIB guard. It is SOURCED with TS_FIX_SWITCH_LIB=1,
#           which defines its functions and runs nothing, and its path variables are then pointed
#           at stand-ins. The cases drive switch_on, switch_off and ks_active directly, so they bind
#           to shipping code.
#   legacy  no guard (the baseline). A copy is made with every router path rewritten to a stand-in
#           and KILL_SWITCH read from the case; the rewrite is checked before anything is sourced.
#           The ks_active cases source the copy's helper section, and each flip runs the copy's own
#           top-level dispatch, sourced in a subshell with $1 set to on or off.
#
# ip, uci, curl, jsonfilter, logger, sleep and timeout are shell functions that append one line per
# call to a call log; timeout runs its program, as the real one does, and passes its exit status
# through. GL's switch scripts, ts_killswitch, gl_tailscale and the kill-switch engine are
# executable stand-ins in a temp directory that append to the same log. The cases assert on the
# ORDER of that log, not just on presence, and a case with a failure prints its whole log below it.
# Case 0 lints the instrument itself before any verdict is trusted.

# Never as root. The flips under test call `ip rule add/del` and `ip route add/del`; the fakes
# shadow those only while they bind, and as root a fake that failed to bind would let the real
# command rewrite this machine's routing policy. Nothing here needs privilege.
if [ "$(id -u)" = "0" ]; then
    echo "FAIL: this suite must not run as root (uid 0)"
    exit 1
fi

TARGET=${1:-$(dirname "$0")/../../accessories/gl-switch.d/tailscale.sh}
if [ ! -f "$TARGET" ]; then
    echo "FAIL: no script to test at $TARGET"
    exit 2
fi

TD=$(mktemp -d "${TMPDIR:-/tmp}/acc-switch-test.XXXXXX") || { echo "FAIL: mktemp -d"; exit 2; }
trap 'rm -rf "$TD"' EXIT
trap 'exit 130' INT TERM HUP
case "$TD" in
    *[!A-Za-z0-9/._-]*)
        echo "FAIL: temp dir '$TD' has characters the legacy path rewrite cannot carry"
        exit 2
        ;;
esac

LOG="$TD/calls.log"
ACC_TEST_LOG=$LOG
export ACC_TEST_LOG
: > "$LOG"
mkdir -p "$TD/bin" "$TD/gl-switch.d" || { echo "FAIL: mkdir in $TD"; exit 2; }
ENGINE="$TD/bin/ts-fix-ks"
SENTINEL="$TD/commit-failed"
T=$(printf '\t')

# ------------------------------------------------------------------------------ stand-ins
# mkstub <path> <label>: an executable that logs "exec <label> <args>" (no trailing space when it
# gets no arguments).
mkstub() {
    printf '#!/bin/sh\nline="exec %s $*"\necho "${line%% }" >> "$ACC_TEST_LOG"\n' "$2" > "$1" &&
        chmod 755 "$1"
}
mkstub "$TD/gl-switch.d/wireguard.sh" wireguard.sh
mkstub "$TD/gl-switch.d/openvpn.sh" openvpn.sh
mkstub "$TD/gl-switch.d/tor.sh" tor.sh
mkstub "$TD/bin/ts_killswitch" ts_killswitch
mkstub "$TD/bin/gl_tailscale" gl_tailscale
# The engine stand-in also exits with the case's arm status. It counts as installed when it is
# executable and as absent when it is not, which is all the accessory's `[ -x ]` test can tell.
printf '#!/bin/sh\nline="exec ts-fix-ks $*"\necho "${line%% }" >> "$ACC_TEST_LOG"\nexit "${ACC_TEST_ARM_RC:-0}"\n' > "$ENGINE"
chmod 755 "$ENGINE"
ACC_TEST_ARM_RC=0
export ACC_TEST_ARM_RC

# ------------------------------------------------------------------------------ the fakes
rec() { printf '%s\n' "$*" >> "$LOG"; }

RULE4_5279="" RULE4_5280="" RULE6_5279="" RULE6_5280="" RULE4_ALL="" RULE6_ALL=""
ROUTE4_100="" ROUTE6_100="" SEVERED=""
UCI_EXIT_IP="" UCI_TS_ENABLED="" WG_STATUS=0 TOR_ENABLE=false FW49=0 ACC_TEST_KS=true

# Canned policy-rule and table-100 reads, exactly as iproute2 prints them (a tab right after the
# leading "<priority>:"); every write is recorded and succeeds.
ip() {
    rec "ip $*"
    case "$2 $3" in
        "rule list")
            if [ "$4" = priority ]; then
                case "$1 $5" in
                    "-4 5279") printf '%s\n' "$RULE4_5279" ;;
                    "-4 5280") printf '%s\n' "$RULE4_5280" ;;
                    "-6 5279") printf '%s\n' "$RULE6_5279" ;;
                    "-6 5280") printf '%s\n' "$RULE6_5280" ;;
                esac
            else
                case "$1" in
                    -4) printf '%s\n' "$RULE4_ALL" ;;
                    -6) printf '%s\n' "$RULE6_ALL" ;;
                esac
            fi
            return 0
            ;;
        "route show")
            [ "$4 $5" = "table 100" ] || return 1
            case "$1" in
                -4) printf '%s\n' "$ROUTE4_100" ;;
                -6) printf '%s\n' "$ROUTE6_100" ;;
            esac
            return 0
            ;;
        "rule add"|"rule del"|"route add"|"route del")
            return 0
            ;;
    esac
    return 1
}

# -q is dropped before recording. tailscale.settings.enabled is stateful: a set or delete is seen
# by every later get in the same flip, so a flip that re-read it after writing it would be caught.
uci() {
    local v=""
    [ "$1" = -q ] && shift
    rec "uci $*"
    case "$1" in
        get)
            case "$2" in
                tailscale.settings.exit_node_ip) v=$UCI_EXIT_IP ;;
                tailscale.settings.enabled)      v=$UCI_TS_ENABLED ;;
                ts-fix.settings.ks_severed)      v=$SEVERED ;;
            esac
            [ -n "$v" ] || return 1
            printf '%s\n' "$v"
            ;;
        set)
            case "$2" in
                tailscale.settings.enabled=*) UCI_TS_ENABLED=${2#*=} ;;
            esac
            ;;
        delete)
            [ "$2" = tailscale.settings.enabled ] && UCI_TS_ENABLED=""
            ;;
        commit) ;;
        *) return 1 ;;
    esac
    return 0
}

# Records "rpc <module> <method> <argument object>" from the -d payload.
curl() {
    local d="" mm
    while [ $# -gt 0 ]; do
        if [ "$1" = -d ] && [ $# -ge 2 ]; then
            d=$2
            shift
        fi
        shift
    done
    mm=$(printf '%s\n' "$d" | sed -n 's/^.*"params":\["","\([^"]*\)","\([^"]*\)",\(.*\)],"id":[0-9]*}$/\1 \2 \3/p')
    rec "rpc ${mm:-UNPARSED $d}"
    case "$mm" in
        "wg-client get_status "*) printf '{"id":1,"jsonrpc":"2.0","result":{"status":%s}}\n' "$WG_STATUS" ;;
        "tor get_config "*)       printf '{"id":1,"jsonrpc":"2.0","result":{"enable":%s}}\n' "$TOR_ENABLE" ;;
    esac
    return 0
}

jsonfilter() {
    cat > /dev/null
    case "$2" in
        @.result.status) printf '%s\n' "$WG_STATUS" ;;
        @.result.enable) printf '%s\n' "$TOR_ENABLE" ;;
    esac
}

logger()  { rec "logger $*"; }
sleep()   { rec "sleep $*"; }
timeout() { rec "timeout $*"; shift; "$@"; }

# ------------------------------------------------------------------------------ assertions
PASS=0
FAIL=0
CASE_FAILS=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); CASE_FAILS=$((CASE_FAILS + 1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; fi; }
expect()     { local l=$1; shift; if "$@"; then ok "$l"; else bad "$l"; fi; }
expect_not() { local l=$1; shift; if "$@"; then bad "$l"; else ok "$l"; fi; }
case_start() { CASE_FAILS=0; echo "--- $1"; }
case_end() {
    [ "$CASE_FAILS" -eq 0 ] && return 0
    echo "       call log of the case above:"
    sed 's/^/       | /' "$LOG"
}

# Line numbers in the call log: of an exact line, or of a line matching an extended regex.
first()    { S=$1 awk '$0 == ENVIRON["S"] { print NR; exit }' "$LOG"; }
last()     { S=$1 awk '$0 == ENVIRON["S"] { n = NR } END { if (n) print n }' "$LOG"; }
first_re() { R=$1 awk '$0 ~ ENVIRON["R"] { print NR; exit }' "$LOG"; }
last_re()  { R=$1 awk '$0 ~ ENVIRON["R"] { n = NR } END { if (n) print n }' "$LOG"; }
count()    { S=$1 awk '$0 == ENVIRON["S"] { n++ } END { print n + 0 }' "$LOG"; }
count_re() { R=$1 awk '$0 ~ ENVIRON["R"] { n++ } END { print n + 0 }' "$LOG"; }
has()      { [ -n "$(first "$1")" ]; }

# before A B: both present, and every A precedes every B. before_re is the same over regexes.
before() {
    local a b
    a=$(last "$1")
    b=$(first "$2")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
before_re() {
    local a b
    a=$(last_re "$1")
    b=$(first_re "$2")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
# later A B: A is present and some B comes after its first occurrence. later_re takes a regex B.
later() {
    local a
    a=$(first "$1")
    [ -n "$a" ] || return 1
    N=$a S=$2 awk 'NR > ENVIRON["N"] + 0 && $0 == ENVIRON["S"] { f = 1 } END { exit !f }' "$LOG"
}
later_re() {
    local a
    a=$(first "$1")
    [ -n "$a" ] || return 1
    N=$a R=$2 awk 'NR > ENVIRON["N"] + 0 && $0 ~ ENVIRON["R"] { f = 1 } END { exit !f }' "$LOG"
}
# none_later A B: A is present (so the answer is never vacuous) and no B comes after it.
none_later()    { has "$1" && ! later "$1" "$2"; }
none_later_re() { has "$1" && ! later_re "$1" "$2"; }

# The lockdown's own lines. ld_line <fam> <add|del> <bridge>, rt_line <fam> <add|del>.
ld_line() { printf 'ip %s rule %s iif %s priority 5260 lookup 101' "$1" "$2" "$3"; }
rt_line() { printf 'ip %s route %s unreachable default table 101' "$1" "$2"; }
# lockdown_all <add|del> <bridge>...: that bridge's 5260 rule, in both families, for every bridge.
lockdown_all() {
    local v=$1 f b
    shift
    for f in -4 -6; do
        for b in "$@"; do
            has "$(ld_line "$f" "$v" "$b")" || return 1
        done
    done
    return 0
}
# lockdown_none <add|del> <bridge>: no line for that bridge in either family.
lockdown_none() { ! has "$(ld_line -4 "$1" "$2")" && ! has "$(ld_line -6 "$1" "$2")"; }
# rules_before_route <bridge>...: per family, each bridge's rule delete precedes the route delete.
rules_before_route() {
    local f b
    for f in -4 -6; do
        for b in "$@"; do
            before "$(ld_line "$f" del "$b")" "$(rt_line "$f" del)" || return 1
        done
    done
    return 0
}
no_release() { [ "$(count_re '^ip -[46] (rule|route) del ')" = 0 ]; }

# The configuration block's defaults (LAN_ENABLED=true, WAN_ENABLED=false, ROUTE_GUEST=false,
# ADVERTISE_EXIT_NODE=false, TAILSCALE_SSH=false) and the case's exit node shape these.
FIX_ON='rpc ts-fix set_config {"kill_switch":true,"route_guest":false,"advertise_exit_node":false,"tailscale_ssh":false}'
FIX_OFF='rpc ts-fix set_config {"kill_switch":false,"route_guest":false,"advertise_exit_node":false,"tailscale_ssh":false}'
GL_49='rpc tailscale set_config {"enabled":true,"lan_enabled":true,"masq":true,"wan_enabled":false,"exit_node_ip":"100.64.0.9"}'
GL_48='rpc tailscale set_config {"enabled":true,"lan_enabled":true,"wan_enabled":false,"exit_node_ip":"100.64.0.9"}'
ARM="timeout 30 $ENGINE arm"
GATE="ip -4 rule list priority 5279"
VPN_FIRST='rpc wg-client get_status {}'
VPN_LAST='exec tor.sh off'

# ------------------------------------------------------------------------------ case state
reset_layout() {
    RULE4_5279="" RULE4_5280="" RULE6_5279="" RULE6_5280="" RULE4_ALL="" RULE6_ALL=""
    ROUTE4_100="" ROUTE6_100="" SEVERED=""
    rm -f "$SENTINEL"
}
engine() { if [ "$1" = present ]; then chmod 755 "$ENGINE"; else chmod 644 "$ENGINE"; fi; }

# The routing layer an older plugin leaves armed (br-lan and br-guest), and the one the v1.0.22
# engine leaves armed (the same plus br-iot, "[detached]" where GL's IoT network does not exist).
layout_languest() {
    RULE4_5279="5279:${T}from all iif br-lan lookup 100
5279:${T}from all iif br-guest lookup 100"
    RULE6_5279=$RULE4_5279
    RULE6_ALL=$RULE6_5279
    ROUTE4_100="unreachable default"
    ROUTE6_100="unreachable default dev lo table 100 proto static metric 1024 pref medium"
}
layout_full() {
    layout_languest
    RULE4_5279="$RULE4_5279
5279:${T}from all iif br-iot [detached] lookup 100"
    RULE6_5279=$RULE4_5279
    RULE6_ALL=$RULE6_5279
}

# setup <engine present|absent> <KILL_SWITCH> <firmware 49|48> <arm exit status>
#       <tailscale.settings.enabled before the flip, "" for unset>
# Every VPN client reads as active, so every one of GL's switch scripts is called.
setup() {
    reset_layout
    engine "$1"
    ACC_TEST_KS=$2
    if [ "$3" = 49 ]; then
        FW49=1
        echo "4.11.0" > "$TD/glversion"
    else
        FW49=0
        echo "4.8.4" > "$TD/glversion"
    fi
    ACC_TEST_ARM_RC=$4
    UCI_TS_ENABLED=$5
    UCI_EXIT_IP=100.64.0.9
    WG_STATUS=1
    TOR_ENABLE=true
    chmod 755 "$TD/gl-switch.d/openvpn.sh" "$TD/bin/ts_killswitch"
}

# run_flow <on|off>: one flip in a subshell, with the call log reset first. The subshell waits for
# the off flip's backgrounded gl_tailscale, so its log line is in before any assertion reads it.
run_flow() {
    : > "$LOG"
    if [ "$MODE" = lib ]; then
        ( KILL_SWITCH=$ACC_TEST_KS; "switch_$1"; r=$?; wait; exit $r )
    else
        ( set -- "$1"; . "$COPY"; r=$?; wait; exit $r )
    fi
    FLOW_RC=$?
}

# ------------------------------------------------------------------------------ case 0
echo "Testing: $TARGET"
echo "--- case 0: instrument lint"

if grep -q 'TS_FIX_SWITCH_LIB' "$TARGET"; then
    MODE=lib
    # Prove the guard in a subshell first. With no $1, a guard that does not hold reaches only the
    # usage branch, never a flip.
    out=$( (set --; TS_FIX_SWITCH_LIB=1; . "$TARGET"; echo SOURCED) 2>&1 )
    if [ "$out" != SOURCED ] || [ -s "$LOG" ]; then
        echo "FAIL: sourcing $TARGET with TS_FIX_SWITCH_LIB=1 did not stop before its dispatch: [$out]"
        exit 2
    fi
    set --
    TS_FIX_SWITCH_LIB=1
    . "$TARGET"
    unset TS_FIX_SWITCH_LIB
    ok "0 the target sources with TS_FIX_SWITCH_LIB=1 without running anything"
    is "0 nothing was called while sourcing" "" "$(cat "$LOG")"
    is "0 KS_ENGINE defaults to the router path"        /usr/bin/ts-fix-ks           "$KS_ENGINE"
    is "0 GL_SWITCH_DIR defaults to the router path"    /etc/gl-switch.d             "$GL_SWITCH_DIR"
    is "0 GL_TS_KILLSWITCH defaults to the router path" /usr/bin/ts_killswitch       "$GL_TS_KILLSWITCH"
    is "0 GL_TAILSCALE defaults to the router path"     /usr/bin/gl_tailscale        "$GL_TAILSCALE"
    is "0 KS_COMMIT_FAIL defaults to the engine's path" /tmp/ts-fix-ks.commit-failed "$KS_COMMIT_FAIL"
    KS_ENGINE=$ENGINE
    GL_SWITCH_DIR="$TD/gl-switch.d"
    GL_TS_KILLSWITCH="$TD/bin/ts_killswitch"
    GL_TAILSCALE="$TD/bin/gl_tailscale"
    KS_COMMIT_FAIL=$SENTINEL
    RPC="http://127.0.0.1:80/rpc"
    is_fw49_plus() { [ "$FW49" = 1 ]; }
    for n in switch_on switch_off ks_active lockdown_install lockdown_remove; do
        case "$(type "$n" 2>&1)" in
            *function*) ok "0 the target defines $n" ;;
            *)          bad "0 the target defines $n" ;;
        esac
    done
else
    MODE=legacy
    bad "0 the target sources with TS_FIX_SWITCH_LIB=1 without running anything (it has no guard)"
    COPY="$TD/legacy.sh"
    sed -e "s#/tmp/ts-fix-ks\\.commit-failed#$SENTINEL#g" \
        -e "s#/etc/gl-switch\\.d/#$TD/gl-switch.d/#g" \
        -e "s#/usr/bin/ts_killswitch#$TD/bin/ts_killswitch#g" \
        -e "s#/usr/bin/gl_tailscale#$TD/bin/gl_tailscale#g" \
        -e "s#/etc/glversion#$TD/glversion#g" \
        -e "s#/etc/nginx/conf\\.d/gl\\.conf#$TD/gl.conf#g" \
        -e 's#^KILL_SWITCH=true #KILL_SWITCH=$ACC_TEST_KS #' \
        "$TARGET" > "$COPY"
    left=$(grep -v '^[[:space:]]*#' "$COPY" | \
        grep -nE '/tmp/ts-fix-ks|/etc/gl-switch\.d|/usr/bin/|/etc/glversion|/etc/nginx')
    if [ -n "$left" ] || ! grep -q '^KILL_SWITCH=\$ACC_TEST_KS ' "$COPY"; then
        echo "FAIL: the path rewrite of $TARGET did not take - refusing to source it: [$left]"
        exit 2
    fi
    ok "0 legacy copy: every router path rewritten to a stand-in"
    sed -n '/^# --- Helpers ---$/,/^# --- Logic ---$/p' "$COPY" > "$TD/helpers.sh"
    if ! grep -q '^ks_active()' "$TD/helpers.sh"; then
        echo "FAIL: ks_active() not found in the helper section of $TARGET"
        exit 2
    fi
    . "$TD/helpers.sh"
fi
echo "Mode: $MODE"

for n in ip uci curl jsonfilter logger sleep timeout; do
    case "$(type "$n" 2>&1)" in
        *function*) ok "0 $n resolves to the fake" ;;
        *)          bad "0 $n resolves to the fake (type says: $(type "$n" 2>&1))" ;;
    esac
done
case "$(type sed 2>&1)" in
    *function*) bad "0 the check discriminates: sed is not a function" ;;
    *)          ok "0 the check discriminates: sed is not a function" ;;
esac

: > "$LOG"
ip -4 rule add iif br-x priority 1 lookup 1
uci -q set a.b.c=1
curl -H 'glinet: 1' -s -k "http://127.0.0.1/rpc" -d '{"jsonrpc":"2.0","method":"call","params":["","tailscale","set_config",{"enabled":true,"exit_node_ip":"1.2.3.4"}],"id":1}' > /dev/null
logger -t lint one line
sleep 5
"$TD/gl-switch.d/openvpn.sh" off
"$TD/bin/ts_killswitch"
ACC_TEST_ARM_RC=3
timeout 30 "$ENGINE" arm
lint_rc=$?
ACC_TEST_ARM_RC=0
is "0 every fake and stand-in records, in call order" "ip -4 rule add iif br-x priority 1 lookup 1
uci set a.b.c=1
rpc tailscale set_config {\"enabled\":true,\"exit_node_ip\":\"1.2.3.4\"}
logger -t lint one line
sleep 5
exec openvpn.sh off
exec ts_killswitch
timeout 30 $ENGINE arm
exec ts-fix-ks arm" "$(cat "$LOG")"
is "0 timeout passes its program's exit status through" 3 "$lint_rc"
engine absent
expect_not "0 an engine stand-in without x reads as absent" [ -x "$ENGINE" ]
engine present
expect "0 an engine stand-in with x reads as present" [ -x "$ENGINE" ]

WG_STATUS=1
is "0 curl + jsonfilter answer the WireGuard status" 1 \
    "$(curl -s -d '{"jsonrpc":"2.0","method":"call","params":["","wg-client","get_status",{}],"id":1}' | jsonfilter -e '@.result.status')"
reset_layout
layout_full
is "0 the ip fake answers a priority read" "$RULE4_5279" "$(ip -4 rule list priority 5279)"
is "0 the ip fake answers the table-100 route" "unreachable default" "$(ip -4 route show table 100)"
is "0 the ip fake answers an unfiltered -6 rule list" "$RULE6_ALL" "$(ip -6 rule list)"
UCI_TS_ENABLED=0
is "0 uci get returns the value" 0 "$(uci -q get tailscale.settings.enabled)"
uci set tailscale.settings.enabled=1
is "0 a uci set is seen by a later get" 1 "$(uci -q get tailscale.settings.enabled)"
uci -q delete tailscale.settings.enabled
uci -q get tailscale.settings.enabled > /dev/null
is "0 a deleted option reads back rc 1" 1 "$?"

printf 'A\nB\n' > "$LOG"
expect     "0 before() holds for A then B"            before A B
expect_not "0 before() rejects B then A"              before B A
expect_not "0 before() rejects a missing line"        before A C
expect     "0 later() finds B after A"                later A B
expect_not "0 later() finds no A after B"             later B A
expect_not "0 none_later() is never vacuous"          none_later C A

# ------------------------------------------------------------------------------ the on flip
# The failed-arm cases share everything but the restore of tailscale.settings.enabled.
# assert_arm_failed <case id>
assert_arm_failed() {
    expect_not "$1: the flip exits non-zero" [ "$FLOW_RC" -eq 0 ]
    expect "$1: the lockdown went in for br-lan, br-guest and br-iot, both families" \
        lockdown_all add br-lan br-guest br-iot
    expect "$1: the plugin's RPC went out before the arm" before "$FIX_ON" "$ARM"
    is "$1: GL was never asked to start Tailscale" 0 "$(count_re '^rpc tailscale ')"
    expect "$1: the lockdown was NOT removed" no_release
    is "$1: exactly one log line" 1 "$(count_re '^logger ')"
    is "$1: ... tagged ts-fix-switch" 1 "$(count_re '^logger -t ts-fix-switch ')"
    for w in "could not be armed" "IoT" "not started" "off"; do
        is "$1: ... and saying \"$w\"" 1 "$(count_re "^logger .*$w")"
    done
}

case_start "a: engine present, KILL_SWITCH=true, arm exits 0 - armed before GL starts Tailscale"
setup present true 49 0 0
layout_full
run_flow on
is "a: the flip exits 0" 0 "$FLOW_RC"
for f in -4 -6; do
    for b in br-lan br-guest br-iot; do
        expect "a: lockdown $f $b installed" has "$(ld_line "$f" add "$b")"
    done
    expect "a: lockdown $f table-101 route installed" has "$(rt_line "$f" add)"
done
expect "a: the whole lockdown went in before the VPN checks" \
    before_re '^ip -[46] (rule|route) add ' "^rpc wg-client get_status"
for l in "$VPN_FIRST" "exec wireguard.sh off" "exec openvpn.sh off" 'rpc tor get_config {}' "$VPN_LAST"; do
    expect "a: VPN check: $l" has "$l"
done
expect "a: the VPN checks came before the pre-arm" before "$VPN_LAST" "uci set tailscale.settings.enabled=1"
expect "a: enabled was read before it was written" \
    before "uci get tailscale.settings.enabled" "uci set tailscale.settings.enabled=1"
expect "a: enabled=1 set, then committed" before "uci set tailscale.settings.enabled=1" "uci commit tailscale"
expect "a: committed before the plugin's RPC" before "uci commit tailscale" "$FIX_ON"
expect "a: the plugin's RPC (unchanged payload) before the arm" before "$FIX_ON" "$ARM"
expect "a: the engine ran" has "exec ts-fix-ks arm"
expect "a: the arm before GL's RPC" before "$ARM" "$GL_49"
expect "a: the plugin's RPC strictly before GL's RPC (unchanged payload)" before "$FIX_ON" "$GL_49"
expect "a: GL's RPC before the release gate" before "$GL_49" "$GATE"
expect "a: the release gate before the release" before "$GATE" "$(ld_line -4 del br-lan)"
expect "a: the release removed br-lan, br-guest and br-iot, both families" \
    lockdown_all del br-lan br-guest br-iot
expect "a: ... and both table-101 routes" eval 'has "$(rt_line -4 del)" && has "$(rt_line -6 del)"'
expect "a: ... rules first, then the route" rules_before_route br-lan br-guest br-iot
expect_not "a: no 5-second sleep in this order" has "sleep 5"
is "a: one plugin RPC" 1 "$(count "$FIX_ON")"
is "a: one GL RPC" 1 "$(count "$GL_49")"
is "a: one arm" 1 "$(count "$ARM")"
expect "a: enabled not rewritten after the arm" none_later_re "$ARM" '^uci (set|delete) tailscale\.settings\.enabled'
is "a: no log line" 0 "$(count_re '^logger ')"
case_end

case_start "b: arm exits 1 - lockdown held, GL never asked, enabled restored to '0'"
setup present true 49 1 0
run_flow on
assert_arm_failed b
expect "b: enabled was read before the pre-arm wrote it" \
    before "uci get tailscale.settings.enabled" "uci set tailscale.settings.enabled=1"
expect "b: enabled set back to '0' after the arm" later "$ARM" "uci set tailscale.settings.enabled=0"
expect "b: ... and committed" later "uci set tailscale.settings.enabled=0" "uci commit tailscale"
case_end

case_start "b2: arm exits 1 with enabled unset before the flip - the option is deleted again"
setup present true 49 1 ""
run_flow on
assert_arm_failed b2
expect "b2: enabled deleted after the arm" later "$ARM" "uci delete tailscale.settings.enabled"
expect "b2: ... and committed" later "uci delete tailscale.settings.enabled" "uci commit tailscale"
expect "b2: no enabled value written after the arm" \
    none_later_re "$ARM" '^uci set tailscale\.settings\.enabled='
case_end

case_start "c: arm exits 2 (not in Router mode) - same as b"
setup present true 49 2 0
run_flow on
assert_arm_failed c
expect "c: enabled set back to '0' after the arm" later "$ARM" "uci set tailscale.settings.enabled=0"
expect "c: ... and committed" later "uci set tailscale.settings.enabled=0" "uci commit tailscale"
case_end

case_start "d: enabled was already '1' and the arm exits 1 - enabled is not rewritten"
setup present true 49 1 1
run_flow on
assert_arm_failed d
expect "d: no enabled write after the arm" \
    none_later_re "$ARM" '^uci (set|delete) tailscale\.settings\.enabled'
expect "d: no tailscale commit after the arm" none_later "$ARM" "uci commit tailscale"
case_end

case_start "e: engine absent (plugin before v1.0.22) - the old order exactly"
setup absent true 48 0 0
layout_languest
run_flow on
is "e: the flip exits 0" 0 "$FLOW_RC"
expect "e: lockdown for br-lan and br-guest, both families" lockdown_all add br-lan br-guest
expect "e: no br-iot lockdown with an older plugin" lockdown_none add br-iot
is "e: no arm" 0 "$(count_re '^timeout ')"
expect_not "e: no pre-arm write of enabled" has "uci set tailscale.settings.enabled=1"
expect "e: the VPN checks before GL's RPC" before "$VPN_LAST" "$GL_48"
expect "e: GL's RPC (unchanged pre-4.9 payload) before the 5-second sleep" before "$GL_48" "sleep 5"
expect "e: the sleep before the plugin's RPC" before "sleep 5" "$FIX_ON"
expect "e: the plugin's RPC before the release gate" before "$FIX_ON" "$GATE"
expect "e: the gate before the release" before "$GATE" "$(ld_line -4 del br-lan)"
expect "e: the release removed br-lan and br-guest, rules before the route" \
    rules_before_route br-lan br-guest
expect "e: the release also removed br-iot, both families" lockdown_all del br-iot
is "e: no log line" 0 "$(count_re '^logger ')"
case_end

case_start "f: engine present, KILL_SWITCH=false - no arm, the original order"
setup present false 49 0 0
layout_full
run_flow on
is "f: the flip exits 0" 0 "$FLOW_RC"
is "f: no arm" 0 "$(count_re '^timeout ')"
expect_not "f: no pre-arm write of enabled" has "uci set tailscale.settings.enabled=1"
expect "f: the VPN checks before GL's RPC" before "$VPN_LAST" "$GL_49"
expect "f: GL's RPC before the 5-second sleep" before "$GL_49" "sleep 5"
expect "f: the sleep before the plugin's RPC (kill_switch false)" before "sleep 5" "$FIX_OFF"
expect "f: the plugin's RPC before the release" before "$FIX_OFF" "$(ld_line -4 del br-lan)"
is "f: no release gate (KILL_SWITCH is not true)" 0 "$(count_re '^ip -[46] rule list')"
expect "f: lockdown for br-lan, br-guest and br-iot (engine present), both families" \
    lockdown_all add br-lan br-guest br-iot
expect "f: the release removed all three, both families" lockdown_all del br-lan br-guest br-iot
case_end

# ------------------------------------------------------------------------------ the off flip
case_start "g1: off, GL's ts_killswitch executable"
setup present true 49 0 1
run_flow off
is "g1: the flip exits 0" 0 "$FLOW_RC"
expect "g1: lockdown removal for br-lan, br-guest and br-iot, both families" \
    lockdown_all del br-lan br-guest br-iot
expect "g1: ... rules first, then the route" rules_before_route br-lan br-guest br-iot
expect "g1: the removal before enabled=0" \
    before_re '^ip -[46] (rule|route) del ' '^uci set tailscale\.settings\.enabled=0$'
expect "g1: enabled=0 then committed" before "uci set tailscale.settings.enabled=0" "uci commit tailscale"
expect "g1: committed before ts_killswitch" before "uci commit tailscale" "exec ts_killswitch"
expect "g1: ts_killswitch before gl_tailscale restart" before "exec ts_killswitch" "exec gl_tailscale restart"
is "g1: no lockdown install" 0 "$(count_re '^ip -[46] (rule|route) add ')"
is "g1: no RPC" 0 "$(count_re '^rpc ')"
case_end

case_start "g2: off, GL's ts_killswitch not executable"
setup present true 49 0 1
chmod 644 "$TD/bin/ts_killswitch"
run_flow off
is "g2: the flip exits 0" 0 "$FLOW_RC"
expect "g2: lockdown removal for all three bridges, both families" lockdown_all del br-lan br-guest br-iot
expect_not "g2: ts_killswitch not run" has "exec ts_killswitch"
expect "g2: committed before gl_tailscale restart" before "uci commit tailscale" "exec gl_tailscale restart"
case_end

# ------------------------------------------------------------------------------ ks_active
# check_ks <label> <expected true|false>
check_ks() {
    local got
    : > "$LOG"
    if ks_active; then got=true; else got=false; fi
    if [ "$got" = "$2" ]; then
        ok "$1: expected=$2 got=$got"
    else
        bad "$1: expected=$2 got=$got"
    fi
}

case_start "h: ks_active and the br-iot rule"
reset_layout
engine present
layout_languest
check_ks "h1 engine present, every rule but br-iot's" false
reset_layout
engine absent
layout_languest
check_ks "h2 engine absent, no br-iot rule (lan+guest+routes present)" true
reset_layout
engine present
layout_full
RULE6_5279="5279:${T}from all iif br-lan lookup 100
5279:${T}from all iif br-guest lookup 100"
RULE6_ALL=$RULE6_5279
check_ks "h3 engine present, br-iot rule in IPv4 only" false
reset_layout
engine present
layout_languest
RULE4_5279="$RULE4_5279
5279:${T}from all iif br-iot0 lookup 100"
RULE6_5279=$RULE4_5279
RULE6_ALL=$RULE6_5279
check_ks "h4 engine present, near miss br-iot0 instead of br-iot" false
reset_layout
engine present
layout_full
check_ks "h5 engine present, the full v1.0.22 layout" true
case_end

# The 14 cases of tests/results/20261001-build/accessory-fix/test-ks-active.sh. Each sets a layout;
# the table below runs them with the engine absent (unchanged expectations), then with the engine
# present after add_iot has given each layout its br-iot rule (so every verdict still turns on the
# case's own defect), then 7 and 11 with the engine present and NO br-iot rule: the two cases the
# engine-present rule turns from true to false.
V6DEF="0:${T}from all lookup local
32766:${T}from all lookup main
32767:${T}from all lookup default"
V6R="unreachable default dev lo table 100 proto static metric 1024 pref medium"
LANGUEST="5279:${T}from all iif br-lan lookup 100
5279:${T}from all iif br-guest lookup 100"

ki_1()  { reset_layout; }
ki_2()  { reset_layout; layout_full; }
ki_3a() { reset_layout; RULE4_5279=$LANGUEST; RULE6_5279=$LANGUEST; RULE6_ALL=$LANGUEST; ROUTE6_100=$V6R; }
ki_3b() { reset_layout; RULE4_5279=$LANGUEST; RULE6_5279=$LANGUEST; RULE6_ALL=$LANGUEST; ROUTE4_100="unreachable default"; }
ki_4()  {
    reset_layout
    RULE4_5279="5279:${T}from all iif br-lan lookup 100"
    RULE6_5279=$RULE4_5279; RULE6_ALL=$RULE6_5279; ROUTE4_100="unreachable default"; ROUTE6_100=$V6R
}
ki_5()  {
    reset_layout
    RULE4_5279="5279:${T}from all iif br-lan lookup 1002
5279:${T}from all iif br-guest lookup 1002"
    RULE6_5279=$RULE4_5279; RULE6_ALL=$RULE6_5279; ROUTE4_100="unreachable default"; ROUTE6_100=$V6R
}
ki_6()  {
    reset_layout
    RULE4_5280="5280:${T}from all iif br-lan blackhole"
    RULE6_ALL=$V6DEF; ROUTE4_100="unreachable default"; ROUTE6_100=$V6R
}
ki_7()  {
    reset_layout
    RULE4_5280="5280:${T}from all iif br-lan lookup 100
5280:${T}from all iif br-guest lookup 100"
    RULE6_5280=$RULE4_5280; RULE6_ALL=$RULE6_5280; ROUTE4_100="unreachable default"; ROUTE6_100=$V6R
}
ki_8()  {
    reset_layout
    RULE4_5279="5279:${T}from all iif br-lan lookup 100
5279:${T}from all iif br-guest [detached] lookup 100
5279:${T}from all iif br-iot [detached] lookup 100"
    RULE6_5279=$RULE4_5279; RULE6_ALL=$RULE6_5279; ROUTE4_100="unreachable default"; ROUTE6_100=$V6R
}
ki_9()  { reset_layout; layout_languest; : > "$SENTINEL"; }
ki_10() { reset_layout; SEVERED="lan:wan guest:wan"; }
ki_11() { reset_layout; RULE4_5279=$LANGUEST; ROUTE4_100="unreachable default"; RULE6_ALL=""; }
ki_12() { reset_layout; RULE4_5279=$LANGUEST; ROUTE4_100="unreachable default"; RULE6_ALL=$V6DEF; }
ki_13() {
    reset_layout
    RULE4_5279="5279:${T}from 192.168.8.0/24 iif br-lan lookup 100
5279:${T}from all iif br-guest lookup 100"
    RULE6_5279=$LANGUEST; RULE6_ALL=$RULE6_5279; ROUTE4_100="unreachable default"; ROUTE6_100=$V6R
}

# add_iot: give the current layout a 5279 br-iot rule in every family that has KS rules at all.
add_iot() {
    local l="5279:${T}from all iif br-iot lookup 100"
    case "$RULE4_5279$RULE4_5280" in
        ""|*"iif br-iot "*) ;;
        *) RULE4_5279="${RULE4_5279:+$RULE4_5279
}$l" ;;
    esac
    case "$RULE6_5279$RULE6_5280" in
        ""|*"iif br-iot "*) ;;
        *)
            RULE6_5279="${RULE6_5279:+$RULE6_5279
}$l"
            RULE6_ALL="$RULE6_ALL
$l"
            ;;
    esac
}

KI="1:false 2:true 3a:false 3b:false 4:false 5:false 6:false 7:true 8:true 9:false 10:false
11:true 12:false 13:false"

case_start "i: the 14 earlier ks_active cases, engine absent"
for c in $KI; do
    "ki_${c%%:*}"
    engine absent
    check_ks "i${c%%:*} engine absent" "${c#*:}"
done
case_end

case_start "i: the same 14, engine present, each layout given its br-iot rule"
for c in $KI; do
    "ki_${c%%:*}"
    add_iot
    engine present
    check_ks "i${c%%:*} engine present + br-iot" "${c#*:}"
done
case_end

case_start "i: adapted - 7 and 11 with the engine present and no br-iot rule"
ki_7
engine present
check_ks "i7 engine present, legacy 5280 lan+guest, no br-iot" false
ki_11
engine present
check_ks "i11 engine present, IPv4-only lan+guest, no br-iot" false
case_end

# ------------------------------------------------------------------------------ the dispatch
case_start "u: the dispatch at the bottom of the script"
: > "$LOG"
if [ "$MODE" = lib ]; then usrc=$TARGET; else usrc=$COPY; fi
( set -- bogus; . "$usrc" ) > "$TD/u.out" 2> "$TD/u.err"
is "u: a bad argument exits 1" 1 "$?"
expect "u: ... with usage on stderr" grep -q '^Usage: ' "$TD/u.err"
is "u: ... and calls nothing" "" "$(cat "$LOG")"
# on and off through the real dispatch, with the script's own router paths. Only where none of them
# exists on this machine: then every flip step outside the fakes is a no-op or a "not found".
unsafe=""
for p in /usr/bin/ts-fix-ks /etc/gl-switch.d /usr/bin/ts_killswitch /usr/bin/gl_tailscale \
         /tmp/ts-fix-ks.commit-failed; do
    [ -e "$p" ] && unsafe="$unsafe $p"
done
if [ -n "$unsafe" ]; then
    echo "skip u: on/off through the real dispatch - router paths exist on this machine:$unsafe"
else
    reset_layout
    layout_languest
    UCI_EXIT_IP=100.64.0.9 UCI_TS_ENABLED=0 WG_STATUS=0 TOR_ENABLE=false
    : > "$LOG"
    ( set -- on; . "$TARGET"; wait ) > /dev/null 2>&1
    expect "u: 'on' reaches the on flip (GL's RPC went out)" has "$GL_48"
    expect "u: ... and released the lockdown" has "$(ld_line -4 del br-lan)"
    : > "$LOG"
    ( set -- off; . "$TARGET"; wait ) > /dev/null 2>&1
    expect "u: 'off' reaches the off flip" has "uci set tailscale.settings.enabled=0"
    is "u: ... and sends no RPC" 0 "$(count_re '^rpc ')"
fi
case_end

echo "---"
echo "passed $PASS / $((PASS + FAIL)) (mode: $MODE)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
