#!/bin/sh
# Unit test for the watchdog's Route Guest enforcement and its isolate6 backstop, in
# src/scripts/ts-fix-watchdog: ensure_route_guest_swap(), iso6_backstop(), the guest_net helper it
# loads from reapply, where the poll (wd_poll) calls both, and the masquerade repair's log text.
# Laptop-only, no router involved:
#   sh tests/unit/test-wd-guest.sh [watchdog]          (also runs under: busybox ash)
# The optional argument tests another copy of the watchdog instead of src/scripts/ts-fix-watchdog;
# the copy before this change must fail.
#
# The watchdog is SOURCED with TS_FIX_WD_LIB=1 (see tests/unit/test-wd-masq.sh for why and how), in
# a subshell per case, with TS_FIX_REAPPLY naming this repo's reapply so the guest_net it loads is
# the shipping helper, IPCALC naming a fake ipcalc, and TS_FIX_ISOLATE6 naming a fake isolate6.
#
# The fakes, linted in case 0 before any case relies on them:
#   ip      a shell function over $T/rules, one priority-0 rule per line exactly as
#           `ip -4 rule list priority 0` prints it ("0:<TAB>from <net> lookup main"). It answers
#           `ip -4 rule list priority 0` (FAKE_LIST_RC fails it; with N in $T/listok only the next N
#           succeed) and `ip -4 addr show br-guest`
#           (an inet line for FAKE_GUEST_INET, none when it is empty). `rule del` removes the FIRST
#           line matching every selector the call gives (from, to, lookup/table, priority), an
#           absent selector matching anything, as the kernel's delete does; no match is rc 2.
#           With N in $T/stubborn, a deleted source rule is appended again and N drops by one, so
#           "re-added by GL" can be staged. `rule add` appends the canonical line for "from <net>"
#           or "to <net>" at priority 0, duplicates included (so an add that should have been
#           skipped shows), or fails with FAKE_ADD_RC. Every call is recorded in $T/ipcalls; any
#           other form also in $T/unexpected.
#   uci     a shell function: `get` from one file per key in $T/state, recorded in $T/gets; any
#           other subcommand lands in $T/unexpected.
#   logger  a shell function recording its arguments in $T/log.
#   ipcalc  IPCALC names an executable fake answering 192.168.173.1/24 as GL's ipcalc.sh does;
#           calls recorded in $T/ipcalcs.
#   isolate6  TS_FIX_ISOLATE6 names an executable fake recording its arguments and its stdin in
#           $T/iso6calls, printing noise on stdout and stderr, exiting FAKE_ISO6_RC.

WD=${1:-"$(dirname "$0")/../../src/scripts/ts-fix-watchdog"}
case "$WD" in */*) ;; *) WD="./$WD" ;; esac
REAPPLY="$(dirname "$0")/../../src/scripts/ts-fix-reapply"
PRERM="$(dirname "$0")/../../pkg/prerm"
[ -r "$WD" ] || { echo "FAIL: cannot read $WD"; exit 1; }
[ -r "$REAPPLY" ] || { echo "FAIL: cannot read $REAPPLY"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/ts-fix-wd-guest.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
FAKE_IPCALC_LOG="$T/ipcalcs"
FAKE_ISO6_LOG="$T/iso6calls"
export FAKE_IPCALC_LOG FAKE_ISO6_LOG

fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
lines() { [ "$#" -eq 0 ] || printf '%s\n' "$@"; }

TAB=$(printf '\t')
NET=192.168.173.0/24
LOCAL="0:${TAB}from all lookup local"
LANTO="0:${TAB}from all to 192.168.8.0/24 lookup main"
FROM_G="0:${TAB}from $NET lookup main"
TO_G="0:${TAB}from all to $NET lookup main"
FROM_IOT="0:${TAB}from 192.168.10.0/24 lookup main"
FROM_G_IIF="0:${TAB}from $NET iif br-guest lookup main"
FROM_G_52="0:${TAB}from $NET lookup 52"
FROM_G_TRAIL="0:${TAB}from $NET lookup main proto static"
TO_G_TRAIL="0:${TAB}from all to $NET lookup main proto static"

LIST='ip -4 rule list priority 0'
ADDR='ip -4 addr show br-guest'
DEL="ip -4 rule del priority 0 from $NET lookup main"
ADD="ip -4 rule add to $NET lookup main priority 0"
GET_RG='get ts-fix.settings.route_guest'
OKLOG="-t ts-fix Route Guest: replaced GL's guest source rule (from $NET) with the destination rule"

# ------------------------------------------------------------------------------------- the fakes
cat > "$T/ipcalc.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_IPCALC_LOG"
case "$#:$1" in
    1:192.168.173.1/24)
        printf 'IP=192.168.173.1\nNETMASK=255.255.255.0\nBROADCAST=192.168.173.255\n'
        printf 'NETWORK=192.168.173.0\nPREFIX=24\n' ;;
    *) exit 1 ;;
esac
EOF
cat > "$T/isolate6" <<'EOF'
#!/bin/sh
in=$(cat)
printf 'isolate6 %s|stdin=[%s]\n' "$*" "$in" >> "$FAKE_ISO6_LOG"
echo "isolate6 stdout noise"
echo "isolate6 stderr noise" >&2
exit "${FAKE_ISO6_RC:-0}"
EOF
chmod +x "$T/ipcalc.sh" "$T/isolate6"

unexpected() { printf '%s\n' "$*" >> "$T/unexpected"; }

ip() {
    printf 'ip %s\n' "$*" >> "$T/ipcalls"
    _ia="$*"
    [ "$1" = "-4" ] && shift
    case "$1 $2" in
        "addr show")
            [ "$_ia" = "-4 addr show br-guest" ] || { unexpected "ip $_ia"; return 1; }
            printf '9: br-guest: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP\n'
            [ -z "$FAKE_GUEST_INET" ] ||
                printf '    inet %s brd 192.168.173.255 scope global br-guest\n' "$FAKE_GUEST_INET"
            return 0
            ;;
        "rule list")
            [ "$_ia" = "-4 rule list priority 0" ] || { unexpected "ip $_ia"; return 1; }
            [ "${FAKE_LIST_RC:-0}" = "0" ] || return "$FAKE_LIST_RC"
            if [ -f "$T/listok" ]; then
                _iok=$(cat "$T/listok")
                [ "$_iok" -gt 0 ] || return 1
                printf '%s\n' "$((_iok - 1))" > "$T/listok"
            fi
            cat "$T/rules"
            return 0
            ;;
        "rule del"|"rule add") ;;
        *) unexpected "ip $_ia"; return 1 ;;
    esac
    _iop=$2; shift 2
    _isf=""; _ist=""; _itb=""; _ipr=""
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || { unexpected "ip $_ia"; return 1; }
        case "$1" in
            from) _isf=$2 ;;
            to) _ist=$2 ;;
            lookup|table) _itb=$2 ;;
            priority|pref|preference) _ipr=$2 ;;
            *) unexpected "ip $_ia"; return 1 ;;
        esac
        shift 2
    done
    if [ "$_iop" = "add" ]; then
        if [ "$_ipr" != "0" ] || [ -z "$_itb" ]; then unexpected "ip $_ia"; return 1; fi
        [ "${FAKE_ADD_RC:-0}" = "0" ] || return "$FAKE_ADD_RC"
        if [ -n "$_ist" ] && [ -z "$_isf" ]; then
            printf '0:\tfrom all to %s lookup %s\n' "$_ist" "$_itb" >> "$T/rules"
        elif [ -n "$_isf" ] && [ -z "$_ist" ]; then
            printf '0:\tfrom %s lookup %s\n' "$_isf" "$_itb" >> "$T/rules"
        else
            unexpected "ip $_ia"; return 1
        fi
        return 0
    fi
    _in=$(awk -v sf="$_isf" -v st="$_ist" -v tb="$_itb" -v pr="$_ipr" '
        {
            p = $1; sub(/:$/, "", p); f = ""; t = "all"; l = ""
            for (j = 2; j < NF; j += 2) {
                if ($j == "from") f = $(j + 1)
                else if ($j == "to") t = $(j + 1)
                else if ($j == "lookup") l = $(j + 1)
            }
            if ((pr == "" || pr == p) && (sf == "" || sf == f) && (st == "" || st == t) &&
                (tb == "" || tb == l)) { print NR; exit }
        }' "$T/rules")
    if [ -z "$_in" ]; then
        echo "RTNETLINK answers: No such file or directory" >&2
        return 2
    fi
    _iline=$(sed -n "${_in}p" "$T/rules")
    sed "${_in}d" "$T/rules" > "$T/rules.new" && mv "$T/rules.new" "$T/rules"
    _istub=$(cat "$T/stubborn" 2>/dev/null)
    case "$_iline" in
        *"${TAB}from all "*) ;;
        *)
            if [ -n "$_istub" ] && [ "$_istub" -gt 0 ]; then
                printf '%s\n' "$_iline" >> "$T/rules"
                printf '%s\n' "$((_istub - 1))" > "$T/stubborn"
            fi
            ;;
    esac
    return 0
}

uci() {
    if [ "$1" = "-q" ]; then shift; fi
    if [ "$1" = "get" ] && [ "$#" = "2" ]; then
        printf 'get %s\n' "$2" >> "$T/gets"
        [ -f "$T/state/$2" ] || return 1
        cat "$T/state/$2"
        return 0
    fi
    unexpected "uci $*"
    return 1
}
logger() { printf '%s\n' "$*" >> "$T/log"; }

fresh() {   # empty state and recordings, fakes reset, br-guest at 192.168.173.1/24
    rm -rf "$T/state"; mkdir "$T/state"
    for _ff in rules ipcalls gets log rc ipcalcs iso6calls; do : > "$T/$_ff"; done
    rm -f "$T/stubborn" "$T/listok" "$T/iso6out" "$T/iso6outs" "$T/iso6seq"
    unset FAKE_LIST_RC FAKE_ADD_RC FAKE_ISO6_RC RG_REAPPLY
    FAKE_GUEST_INET="192.168.173.1/24"
    chmod +x "$T/isolate6"
}
put() { printf '%s\n' "$2" > "$T/state/$1"; }
rules() { : > "$T/rules"; for _r in "$@"; do printf '%s\n' "$_r" >> "$T/rules"; done; }

# in_watchdog <commands> — in a subshell, source the watchdog as a library, then run the commands
in_watchdog() {
    (
        if [ "$guard_ok" != "1" ]; then
            printf 'NOT SOURCED: no library guard ahead of the trap and the loop\n' >> "$T/ipcalls"
            exit 1
        fi
        TS_FIX_WD_LIB=1
        TS_FIX_GLVERSION="$T/glversion"
        TS_FIX_FW_INIT="$T/fw-init"
        TS_FIX_REAPPLY="${RG_REAPPLY:-$REAPPLY}"
        TS_FIX_ISOLATE6="$T/isolate6"
        IPCALC="$T/ipcalc.sh"
        . "$WD"
        for _fn in ensure_route_guest_swap iso6_backstop; do
            if ! command -v "$_fn" >/dev/null 2>&1; then
                printf 'MISSING: %s\n' "$_fn" >> "$T/ipcalls"
                exit 1
            fi
        done
        eval "$1"
    )
}
rg() {   # rg <enabled as the loop read it> [n] — n polls' calls, each rc appended to $T/rc
    _pn=0
    while [ "$_pn" -lt "${2:-1}" ]; do
        ensure_route_guest_swap "$1"
        printf '%s\n' "$?" >> "$T/rc"
        _pn=$((_pn + 1))
    done
}

# --------------------------------------------------------------------------------------- case 0
echo "--- case 0: the fakes (each behaviour a case relies on, and each recorder records)"
fresh
rules "$LOCAL" "$LANTO" "$FROM_G"
is "0 rule list prints the rules file" "$(lines "$LOCAL" "$LANTO" "$FROM_G")" "$(ip -4 rule list priority 0)"
is "0 FAKE_LIST_RC fails the list, printing nothing" "|1" "$(v=$(FAKE_LIST_RC=1; ip -4 rule list priority 0); printf '%s|%s' "$v" "$?")"
printf '1\n' > "$T/listok"
is "0 listok 1: the next list succeeds, the one after fails" "$FROM_G|0 |1" \
    "$(v=$(ip -4 rule list priority 0 | tail -n 1); printf '%s|%s ' "$v" "$?"; v=$(ip -4 rule list priority 0); printf '%s|%s' "$v" "$?")"
rm -f "$T/listok"
is "0 addr show br-guest: the inet line" "    inet 192.168.173.1/24 brd 192.168.173.255 scope global br-guest" \
    "$(ip -4 addr show br-guest | grep inet)"
is "0 addr show br-guest with FAKE_GUEST_INET empty: no inet line" "" \
    "$(FAKE_GUEST_INET=""; ip -4 addr show br-guest | grep inet)"
ip -4 rule del priority 0 from 192.168.99.0/24 lookup main 2>/dev/null
is "0 rule del with no match: rc 2, file unchanged" "2" "$?"
ip rule del from "$NET" lookup main
is "0 rule del from N lookup main (no -4, no priority) removes GL's rule" "$(lines "$LOCAL" "$LANTO")" "$(cat "$T/rules")"
ip -4 rule add to "$NET" lookup main priority 0
ip rule add to "$NET" table main priority 0
is "0 rule add to N: canonical line appended, 'table' read as 'lookup', duplicates kept" \
    "$(lines "$LOCAL" "$LANTO" "$TO_G" "$TO_G")" "$(cat "$T/rules")"
rules "$LOCAL" "$TO_G" "$FROM_G"
ip -4 rule del priority 0 to "$NET" lookup main
is "0 rule del to N: removes the destination rule only" "$(lines "$LOCAL" "$FROM_G")" "$(cat "$T/rules")"
rules "$LOCAL" "$FROM_G_IIF" "$FROM_G"
ip -4 rule del priority 0 from "$NET" lookup main
is "0 rule del: an absent selector matches anything, the first match goes (the kernel's hazard)" \
    "$(lines "$LOCAL" "$FROM_G")" "$(cat "$T/rules")"
rules "$FROM_G"
printf '1\n' > "$T/stubborn"
ip -4 rule del priority 0 from "$NET" lookup main
is "0 stubborn 1: the deleted source rule comes back once" "$FROM_G|0" "$(cat "$T/rules")|$(cat "$T/stubborn")"
ip -4 rule del priority 0 from "$NET" lookup main
is "0 ... and then stays deleted" "" "$(cat "$T/rules")"
(FAKE_ADD_RC=2; ip -4 rule add to "$NET" lookup main priority 0)
is "0 FAKE_ADD_RC: the add fails, nothing appended" "2|" "$?|$(cat "$T/rules")"
is "0 ipcalc fake answers GL's lines" "192.168.173.0 24" \
    "$("$T/ipcalc.sh" 192.168.173.1/24 | awk -F= '$1 == "NETWORK" { n = $2 } $1 == "PREFIX" { p = $2 } END { print n, p }')"
printf 'in\n' | FAKE_ISO6_RC=1 "$T/isolate6" sync >/dev/null 2>&1
is "0 isolate6 fake: rc from FAKE_ISO6_RC, args and stdin recorded" "1|isolate6 sync|stdin=[in]" \
    "$?|$(cat "$T/iso6calls")"
uci -q get nosuch.key >/dev/null
logger -t ts-fix "lint line"
is "0 recorders: ip calls in ipcalls, in order" \
    "$(lines "$LIST" "$LIST" "$LIST" "$LIST" "$ADDR" "$ADDR" 'ip -4 rule del priority 0 from 192.168.99.0/24 lookup main' \
        "ip rule del from $NET lookup main" "$ADD" "ip rule add to $NET table main priority 0" \
        "ip -4 rule del priority 0 to $NET lookup main" "$DEL" "$DEL" "$DEL" "$ADD")" "$(cat "$T/ipcalls")"
is "0 recorders: uci gets in gets, logger in log, ipcalc calls in ipcalcs" \
    "get nosuch.key|-t ts-fix lint line|192.168.173.1/24" "$(cat "$T/gets")|$(cat "$T/log")|$(cat "$T/ipcalcs")"
is "0 nothing so far is unexpected" "" "$(cat "$T/unexpected" 2>/dev/null)"
ip route show >/dev/null 2>&1
uci set x.y.z=1 >/dev/null 2>&1
is "0 an unmodelled ip or uci call lands in unexpected" "$(lines 'ip route show' 'uci set x.y.z=1')" "$(cat "$T/unexpected")"
rm -f "$T/unexpected"
fakes=""
for f in ip uci logger; do
    case "$(type "$f" 2>&1)" in *function*) fakes="$fakes $f" ;; esac
done
is "0 ip, uci and logger resolve to their fake functions in this shell" " ip uci logger" "$fakes"

# -------------------------------------------------------------------------------- static checks
echo "--- static: the library guard, the guest_net load, the call sites, the seams' defaults"
GUARD='[ "${TS_FIX_WD_LIB:-0}" = "1" ] && return 0'
g_n=$(grep -c -x -F -e "$GUARD" "$WD")
g_at=$(grep -n -x -F -e "$GUARD" "$WD" | head -n 1 | cut -d: -f1)
t_at=$(grep -n -x -F -e "trap 'exit 0' TERM INT" "$WD" | head -n 1 | cut -d: -f1)
l_at=$(grep -n -x -F -e 'while true; do' "$WD" | head -n 1 | cut -d: -f1)
guard_ok=0
if [ "$g_n" = "1" ] && [ -n "$t_at" ] && [ -n "$l_at" ] && [ "$g_at" -lt "$t_at" ] && [ "$g_at" -lt "$l_at" ]
then
    guard_ok=1
    ok "S1 the library guard appears once, ahead of the trap and the poll loop"
else
    nok "S1 the library guard appears once, ahead of the trap and the poll loop" \
        "1 guard line, guard < trap, guard < loop" "count=$g_n guard=[$g_at] trap=[$t_at] loop=[$l_at]"
fi
cat > "$T/evalline" <<'EOF'
eval "$(awk '/^# ---8<--- guest_net/,/^# ---8<--- end guest_net/' "${TS_FIX_REAPPLY:-/usr/bin/ts-fix-reapply}" 2>/dev/null)"
EOF
e_n=$(grep -c -x -F -f "$T/evalline" "$WD")
e_at=$(grep -n -x -F -f "$T/evalline" "$WD" | head -n 1 | cut -d: -f1)
if [ "$e_n" = "1" ] && [ -n "$e_at" ] && [ -n "$g_at" ] && [ "$e_at" -lt "$g_at" ]; then
    ok "S2 guest_net is loaded once from reapply's marker block (default /usr/bin/ts-fix-reapply), before the guard"
else
    nok "S2 guest_net is loaded once from reapply's marker block (default /usr/bin/ts-fix-reapply), before the guard" \
        "1 line, before the guard" "count=$e_n at=[$e_at] guard=[$g_at]"
fi
prog() { sed -n "s|^.*awk '\(/^# ---8<--- guest_net/[^']*\)'.*\$|\1|p" "$1" | head -n 1; }
is "S2 ... with the same awk range program pkg/prerm uses" "$(prog "$PRERM")" "$(prog "$WD")"
is "S2 ... and reapply carries both markers once each" "1 1" \
    "$(grep -c '^# ---8<--- guest_net' "$REAPPLY") $(grep -c '^# ---8<--- end guest_net' "$REAPPLY")"
is "S3 the isolate6 path defaults to /usr/bin/ts-fix-isolate6 (the -x test and the call)" "2" \
    "$(grep -c -F '${TS_FIX_ISOLATE6:-/usr/bin/ts-fix-isolate6}' "$WD")"
at() { grep -n -x -F -e "$1" "$WD" | head -n 1 | cut -d: -f1; }
cnt() { grep -c -x -F -e "$1" "$WD"; }
k_at=$(at '    /usr/bin/ts-fix-ks check')
m_at=$(at '    ensure_ts0_masq "$curr"')
r_at=$(at '    ensure_route_guest_swap "$curr"')
i_at=$(at '    iso6_backstop')
d_at=$(grep -n -x -F -e 'done' "$WD" | tail -n 1 | cut -d: -f1)
# The poll's body is wd_poll, which the loop calls once: the calls are placed within it.
p_at=$(grep -n -x -F -e 'wd_poll() {' "$WD" | head -n 1 | cut -d: -f1)
e_at=$(awk -v p="${p_at:-0}" 'p > 0 && NR > p && /^}$/ { print NR; exit }' "$WD")
w_at=$(at '    wd_poll')
got="$(cnt '    ensure_route_guest_swap "$curr"') $(cnt '    iso6_backstop') $(cnt '    wd_poll')"
if [ "$got" = "1 1 1" ] && [ -n "$l_at" ] && [ -n "$k_at" ] && [ -n "$m_at" ] && [ -n "$r_at" ] && [ -n "$i_at" ] &&
   [ -n "$d_at" ] && [ -n "$p_at" ] && [ -n "$e_at" ] && [ -n "$w_at" ] && [ "$p_at" -lt "$k_at" ] &&
   [ "$k_at" -lt "$m_at" ] && [ "$m_at" -lt "$r_at" ] && [ "$r_at" -lt "$i_at" ] && [ "$i_at" -lt "$e_at" ] &&
   [ "$l_at" -lt "$w_at" ] && [ "$w_at" -lt "$d_at" ]; then
    ok "S4 the poll calls each once: ts-fix-ks check < masq repair < Route Guest < isolate6 backstop; the loop calls the poll once"
else
    nok "S4 the poll calls each once: ts-fix-ks check < masq repair < Route Guest < isolate6 backstop; the loop calls the poll once" \
        "1 1 1, wd_poll < check < masq < guest < iso6 < its }, loop < wd_poll < done" \
        "counts=$got wd_poll=[$p_at] check=[$k_at] masq=[$m_at] guest=[$r_at] iso6=[$i_at] end=[$e_at] loop=[$l_at] call=[$w_at] done=[$d_at]"
fi

# ------------------------------------------------------------------- behaviour: the swap happens
echo "--- case 1: enabled, route_guest 1, GL's source rule present, no destination rule -> swapped"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
in_watchdog 'rg 1'
is "1 rules: GL's source rule gone, exactly one destination rule" "$(lines "$LOCAL" "$LANTO" "$TO_G")" "$(cat "$T/rules")"
is "1 ip calls: list, br-guest's address, one delete, the read-back, one add" \
    "$(lines "$LIST" "$ADDR" "$DEL" "$LIST" "$ADD")" "$(cat "$T/ipcalls")"
is "1 log: one line" "$OKLOG" "$(cat "$T/log")"
is "1 ipcalc asked once, for br-guest's address" "192.168.173.1/24" "$(cat "$T/ipcalcs")"
is "1 rc 0" "0" "$(cat "$T/rc")"

echo "--- case 2: same, but the destination rule is already there -> source rule deleted, no second add"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$TO_G" "$FROM_G"
in_watchdog 'rg 1'
is "2 rules: source rule gone, the destination rule still exactly once" "$(lines "$LOCAL" "$LANTO" "$TO_G")" "$(cat "$T/rules")"
is "2 ip calls: no add" "$(lines "$LIST" "$ADDR" "$DEL" "$LIST")" "$(cat "$T/ipcalls")"
is "2 log: one line" "$OKLOG" "$(cat "$T/log")"

echo "--- case 2b: a destination rule with a trailing token is not Route Guest's -> the exact one is added"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$TO_G_TRAIL" "$FROM_G"
in_watchdog 'rg 1'
is "2b rules: source rule gone, the exact destination rule added beside the other" \
    "$(lines "$LOCAL" "$TO_G_TRAIL" "$TO_G")" "$(cat "$T/rules")"
is "2b ip calls" "$(lines "$LIST" "$ADDR" "$DEL" "$LIST" "$ADD")" "$(cat "$T/ipcalls")"
is "2b log: one line" "$OKLOG" "$(cat "$T/log")"

# -------------------------------------------------------------------------- behaviour: no-ops
echo "--- case 3: quiet poll - route_guest 1, only the destination rule -> one rule list, nothing else"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$TO_G"
in_watchdog 'rg 1 3'
is "3 three polls: exactly one rule list each, no other ip call" "$(lines "$LIST" "$LIST" "$LIST")" "$(cat "$T/ipcalls")"
is "3 ... one uci read each" "$(lines "$GET_RG" "$GET_RG" "$GET_RG")" "$(cat "$T/gets")"
is "3 ... rules unchanged, no log, no ipcalc" "$(lines "$LOCAL" "$LANTO" "$TO_G")||" \
    "$(cat "$T/rules")|$(cat "$T/log")|$(cat "$T/ipcalcs")"
is "3 ... rc 0 each" "0 0 0" "$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"

echo "--- case 4: route_guest 0 or absent with GL's source rule present -> nothing touched"
fresh
put ts-fix.settings.route_guest 0
rules "$LOCAL" "$LANTO" "$FROM_G"
in_watchdog 'rg 1'
is "4 route_guest 0: no ip call, rules unchanged, no log" "|$(lines "$LOCAL" "$LANTO" "$FROM_G")|" \
    "$(cat "$T/ipcalls")|$(cat "$T/rules")|$(cat "$T/log")"
is "4 ... its one call is the uci read" "$GET_RG" "$(cat "$T/gets")"
fresh
rules "$LOCAL" "$LANTO" "$FROM_G"
in_watchdog 'rg 1'
is "4 route_guest absent: no ip call, rules unchanged, no log" "|$(lines "$LOCAL" "$LANTO" "$FROM_G")|" \
    "$(cat "$T/ipcalls")|$(cat "$T/rules")|$(cat "$T/log")"

echo "--- case 5: Tailscale disabled -> nothing at all"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
in_watchdog 'rg 0; rg ""'
is "5 enabled 0 and unset: not one ip or uci call, no log, rules unchanged" "|||$(lines "$LOCAL" "$LANTO" "$FROM_G")" \
    "$(cat "$T/ipcalls")|$(cat "$T/gets")|$(cat "$T/log")|$(cat "$T/rules")"
is "5 ... rc 0" "0 0" "$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"

echo "--- case 6: a source rule for another network only (iot), or of another shape -> untouched"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_IOT"
in_watchdog 'rg 1'
is "6 iot's rule: rules unchanged, no log" "$(lines "$LOCAL" "$LANTO" "$FROM_IOT")|" "$(cat "$T/rules")|$(cat "$T/log")"
is "6 ... ip calls: the list and br-guest's address only (no delete, no add)" "$(lines "$LIST" "$ADDR")" "$(cat "$T/ipcalls")"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$FROM_G_IIF" "$FROM_G_52" "$FROM_G_TRAIL"
in_watchdog 'rg 1'
is "6 guest's network with another selector, another table or a trailing token: untouched, no log" \
    "$(lines "$LOCAL" "$FROM_G_IIF" "$FROM_G_52" "$FROM_G_TRAIL")|" "$(cat "$T/rules")|$(cat "$T/log")"
is "6 ... no delete, no add" "$(lines "$LIST" "$ADDR")" "$(cat "$T/ipcalls")"

# ------------------------------------------------------------------- behaviour: GL re-adds it
echo "--- case 7: GL's rule comes back on the first two deletes -> deleted again, at most 5 deletes"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
printf '2\n' > "$T/stubborn"
in_watchdog 'rg 1'
is "7 rules: swapped in the end" "$(lines "$LOCAL" "$LANTO" "$TO_G")" "$(cat "$T/rules")"
is "7 three deletes, each read back, then the add" \
    "$(lines "$LIST" "$ADDR" "$DEL" "$LIST" "$DEL" "$LIST" "$DEL" "$LIST" "$ADD")" "$(cat "$T/ipcalls")"
is "7 log: still one line" "$OKLOG" "$(cat "$T/log")"

echo "--- case 7b: GL's rule keeps coming back -> stops after 5 deletes, says so in one ERROR line"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
printf '99\n' > "$T/stubborn"
in_watchdog 'rg 1'
is "7b exactly 5 deletes" "5" "$(grep -c -x -F -e "$DEL" "$T/ipcalls")"
is "7b ip calls: five delete + read-back pairs, then the add" \
    "$(lines "$LIST" "$ADDR" "$DEL" "$LIST" "$DEL" "$LIST" "$DEL" "$LIST" "$DEL" "$LIST" "$DEL" "$LIST" "$ADD")" \
    "$(cat "$T/ipcalls")"
is "7b log: one ERROR line, not the replaced line" \
    "-t ts-fix ERROR Route Guest: GL's guest source rule (from $NET) still present after 5 deletes" "$(cat "$T/log")"
is "7b rc 0" "0" "$(cat "$T/rc")"

# --------------------------------------------------------------------------- behaviour: failures
echo "--- case 8: the guest_net helper cannot be loaded -> nothing touched, no crash"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
RG_REAPPLY=/nonexistent/ts-fix-reapply
in_watchdog 'rg 1'
is "8 rules unchanged, no log, rc 0" "$(lines "$LOCAL" "$LANTO" "$FROM_G")||0" \
    "$(cat "$T/rules")|$(cat "$T/log")|$(cat "$T/rc")"
is "8 ip calls: the list only" "$LIST" "$(cat "$T/ipcalls")"

echo "--- case 8b: br-guest has no IPv4 address -> nothing touched"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
FAKE_GUEST_INET=""
in_watchdog 'rg 1'
is "8b rules unchanged, no log, ipcalc never asked" "$(lines "$LOCAL" "$LANTO" "$FROM_G")||" \
    "$(cat "$T/rules")|$(cat "$T/log")|$(cat "$T/ipcalcs")"
is "8b ip calls: the list and the address read" "$(lines "$LIST" "$ADDR")" "$(cat "$T/ipcalls")"

echo "--- case 8c: the rule list fails -> nothing at all"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
FAKE_LIST_RC=1
in_watchdog 'rg 1'
is "8c ip calls: the failed list only; rules unchanged; no log; rc 0" "$LIST|$(lines "$LOCAL" "$LANTO" "$FROM_G")||0" \
    "$(cat "$T/ipcalls")|$(cat "$T/rules")|$(cat "$T/log")|$(cat "$T/rc")"

echo "--- case 8d: the add fails and the read-back still lacks it -> one ERROR line"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
FAKE_ADD_RC=2
in_watchdog 'rg 1'
is "8d rules: source rule gone, no destination rule" "$(lines "$LOCAL" "$LANTO")" "$(cat "$T/rules")"
is "8d ip calls: the failed add is read back once" "$(lines "$LIST" "$ADDR" "$DEL" "$LIST" "$ADD" "$LIST")" "$(cat "$T/ipcalls")"
is "8d log: one ERROR line" \
    "-t ts-fix ERROR Route Guest: the destination rule (to $NET) could not be added" "$(cat "$T/log")"

echo "--- case 8e: the read-back after a delete fails -> one ERROR line, no add on a blind state"
fresh
put ts-fix.settings.route_guest 1
rules "$LOCAL" "$LANTO" "$FROM_G"
printf '1\n' > "$T/listok"
in_watchdog 'rg 1'
is "8e ip calls: list, address, delete, the failed read-back; no add" "$(lines "$LIST" "$ADDR" "$DEL" "$LIST")" \
    "$(cat "$T/ipcalls")"
is "8e log: one ERROR line naming the failed read" \
    "-t ts-fix ERROR Route Guest: 'ip -4 rule list priority 0' failed after deleting GL's guest source rule (from $NET) - the destination rule was not checked" \
    "$(cat "$T/log")"
is "8e rules: the delete happened, nothing added; rc 0" "$(lines "$LOCAL" "$LANTO")|0" "$(cat "$T/rules")|$(cat "$T/rc")"

# ------------------------------------------------------------------- behaviour: isolate6 backstop
echo "--- case 9: the isolate6 backstop runs sync on every sixth poll, quietly, stdin closed"
fresh
printf 'leak\n' | in_watchdog '
    _p=0; _seq=""
    while [ "$_p" -lt 12 ]; do
        iso6_backstop > "$T/iso6out" 2>&1
        printf "%s\n" "$?" >> "$T/rc"
        cat "$T/iso6out" >> "$T/iso6outs"
        _seq="$_seq$(wc -l < "$T/iso6calls" | tr -d " ") "
        _p=$((_p + 1))
    done
    printf "%s" "$_seq" > "$T/iso6seq"'
is "9 calls after each of 12 polls: the 6th and the 12th" "0 0 0 0 0 1 1 1 1 1 1 2 " "$(cat "$T/iso6seq" 2>&1)"
is "9 each call is 'sync' with stdin from /dev/null" "$(lines 'isolate6 sync|stdin=[]' 'isolate6 sync|stdin=[]')" \
    "$(cat "$T/iso6calls")"
is "9 nothing it prints reaches the watchdog's output" "" "$(cat "$T/iso6outs" 2>&1)"
is "9 rc 0 each poll" "0 0 0 0 0 0 0 0 0 0 0 0" "$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"
is "9 no ip, uci or logger call" "||" "$(cat "$T/ipcalls")|$(cat "$T/gets")|$(cat "$T/log")"
fresh
FAKE_ISO6_RC=1
export FAKE_ISO6_RC
in_watchdog '_p=0; while [ "$_p" -lt 6 ]; do iso6_backstop; printf "%s\n" "$?" >> "$T/rc"; _p=$((_p + 1)); done' \
    >/dev/null 2>&1 </dev/null
unset FAKE_ISO6_RC
is "9 isolate6 failing (rc 1): still rc 0 from the backstop, one call" "0 0 0 0 0 0|1" \
    "$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')|$(wc -l < "$T/iso6calls" | tr -d ' ')"
fresh
chmod -x "$T/isolate6"
in_watchdog '_p=0; while [ "$_p" -lt 12 ]; do iso6_backstop; printf "%s\n" "$?" >> "$T/rc"; _p=$((_p + 1)); done' \
    </dev/null
is "9 not executable: no call in 12 polls, rc 0 each" "|0 0 0 0 0 0 0 0 0 0 0 0" \
    "$(cat "$T/iso6calls")|$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"
chmod +x "$T/isolate6"
fresh
in_watchdog 'TS_FIX_ISOLATE6=/nonexistent/ts-fix-isolate6; _p=0
    while [ "$_p" -lt 6 ]; do iso6_backstop; printf "%s\n" "$?" >> "$T/rc"; _p=$((_p + 1)); done' </dev/null
is "9 missing: no call, rc 0 each" "|0 0 0 0 0 0" "$(cat "$T/iso6calls")|$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"

# ----------------------------------------------------------------------- the masq repair's text
echo "--- case 10: the masquerade repair's log line no longer names a GL version"
m_line=$(grep -F 'tailscale0 masquerade restored' "$WD")
is "10 one such line" "1" "$(grep -c -F 'tailscale0 masquerade restored' "$WD")"
case "$m_line" in
    *"4.9+"*) nok "10 the line does not say 4.9+" "no 4.9+" "$m_line" ;;
    *) ok "10 the line does not say 4.9+" ;;
esac
case "$m_line" in
    *"missing from the zone (GL drops it on a Tailscale off/on)\""*) ok "10 the line ends with the corrected reason" ;;
    *) nok "10 the line ends with the corrected reason" "... (GL drops it on a Tailscale off/on)\"" "$m_line" ;;
esac

# --------------------------------------------------------------------------------------- finish
echo "--- instrument: no unmodelled ip or uci call anywhere in the run"
is "no unexpected ip or uci call" "" "$(cat "$T/unexpected" 2>/dev/null)"

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
echo "$fails FAILED ($oks ok)"; exit 1
