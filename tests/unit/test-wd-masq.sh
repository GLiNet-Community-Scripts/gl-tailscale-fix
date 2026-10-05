#!/bin/sh
# Unit test for the tailscale0 masquerade repair in src/scripts/ts-fix-watchdog: ensure_ts0_masq(),
# the copied is_fw49_plus(), the library guard, and where the poll (wd_poll) calls the repair.
# Laptop-only, no router involved:
#   sh tests/unit/test-wd-masq.sh [watchdog]          (also runs under: busybox ash)
# The optional argument tests another copy of the watchdog instead of src/scripts/ts-fix-watchdog,
# e.g. the pre-change baseline in tests/results/20261002-build/baselines/pre-M5/, which must fail.
#
# The watchdog is SOURCED with TS_FIX_WD_LIB=1, so the cases bind to shipping code, and its library
# guard returns before the trap and the poll loop. A copy without that exact guard line ahead of the
# loop is never sourced (it would enter the loop and never return): every case then fails, because
# the run records a marker where the case expects its writes. Each case sources the watchdog afresh
# in a subshell, so the firmware test it runs once at startup sees that case's glversion, and the
# back-off counter starts at 0.
#
# The fakes, linted in case 0 before any case relies on them:
#   uci     a shell function over one file per key in $T/state. `get` prints the value, or a
#           section's type, and for a missing key prints nothing and fails. `set` of an option needs
#           its section to exist, as in real uci (libuci's uci_set asserts it): otherwise rc 1 and
#           nothing stored. `commit` exits FAKE_UCI_COMMIT_RC (default 0). With FAKE_UCI_NOSTICK=1 a
#           set reports success and stores nothing. Gets are recorded in $T/gets, every other call in
#           $T/writes, and a subcommand the watchdog has no business making also in $T/unexpected.
#   logger  a shell function recording its arguments in $T/log.
#   the firewall init script: TS_FIX_FW_INIT names an executable fake that records "fw <args>" in
#           $T/writes (an absolute path cannot be a shell function name).
#   /etc/glversion: TS_FIX_GLVERSION names $T/glversion, which a case writes or removes.

WD=${1:-"$(dirname "$0")/../../src/scripts/ts-fix-watchdog"}
case "$WD" in */*) ;; *) WD="./$WD" ;; esac
REAPPLY="$(dirname "$0")/../../src/scripts/ts-fix-reapply"
[ -r "$WD" ] || { echo "FAIL: cannot read $WD"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/ts-fix-wd-masq.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
FAKE_FW_LOG="$T/writes"
export FAKE_FW_LOG

fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
lines() { [ "$#" -eq 0 ] || printf '%s\n' "$@"; }

# ------------------------------------------------------------------------------------- the fakes
cat > "$T/fw-init" <<'EOF'
#!/bin/sh
printf 'fw %s\n' "$*" >> "$FAKE_FW_LOG"
EOF
chmod +x "$T/fw-init"

uci() {
    if [ "$1" = "-q" ]; then shift; fi
    case "$1" in
        get)
            printf 'get %s\n' "$2" >> "$T/gets"
            [ -f "$T/state/$2" ] || return 1
            cat "$T/state/$2"
            ;;
        set)
            printf 'uci set %s\n' "$2" >> "$T/writes"
            _fk=${2%%=*}
            case "$_fk" in
                *.*.*) ;;
                *) printf 'uci set %s (not an option)\n' "$2" >> "$T/unexpected"; return 1 ;;
            esac
            [ -f "$T/state/${_fk%.*}" ] || return 1
            [ "${FAKE_UCI_NOSTICK:-0}" = "1" ] && return 0
            printf '%s\n' "${2#*=}" > "$T/state/$_fk"
            ;;
        commit)
            printf 'uci commit %s\n' "$2" >> "$T/writes"
            return "${FAKE_UCI_COMMIT_RC:-0}"
            ;;
        *)
            printf 'uci %s\n' "$*" >> "$T/writes"
            printf 'uci %s\n' "$*" >> "$T/unexpected"
            return 1
            ;;
    esac
}
logger() { printf '%s\n' "$*" >> "$T/log"; }

fresh() {   # empty state and recordings (snapshots too: a stale one could pass), fakes reset
    rm -rf "$T/state"; mkdir "$T/state"
    rm -f "$T/gets."* "$T/writes."* "$T/log."*
    : > "$T/gets"; : > "$T/writes"; : > "$T/log"; : > "$T/rc"
    unset FAKE_UCI_NOSTICK FAKE_UCI_COMMIT_RC
}
put() { printf '%s\n' "$2" > "$T/state/$1"; }
val() { if [ -f "$T/state/$1" ]; then cat "$T/state/$1"; else printf '<absent>'; fi; }
zone_state() { printf 'masq=%s masq6=%s' "$(val firewall.tailscale0.masq)" "$(val firewall.tailscale0.masq6)"; }

# router <glversion | - for none> <GL toggle tailscale.settings.masq | -> <zone masq | -> \
#        <zone masq6 | -> <type of section firewall.tailscale0 | - for none>
router() {
    fresh
    if [ "$1" = "-" ]; then rm -f "$T/glversion"; else printf '%s\n' "$1" > "$T/glversion"; fi
    [ "$2" = "-" ] || put tailscale.settings.masq "$2"
    [ "$5" = "-" ] || put firewall.tailscale0 "$5"
    [ "$3" = "-" ] || put firewall.tailscale0.masq "$3"
    [ "$4" = "-" ] || put firewall.tailscale0.masq6 "$4"
}

# in_watchdog <commands> — in a subshell, source the watchdog as a library, then run the commands
in_watchdog() {
    (
        if [ "$guard_ok" != "1" ]; then
            printf 'NOT SOURCED: no library guard ahead of the trap and the loop\n' >> "$T/writes"
            exit 1
        fi
        TS_FIX_WD_LIB=1
        TS_FIX_GLVERSION="$T/glversion"
        TS_FIX_FW_INIT="$T/fw-init"
        . "$WD"
        if ! command -v ensure_ts0_masq >/dev/null 2>&1; then
            printf 'MISSING: ensure_ts0_masq\n' >> "$T/writes"
            exit 1
        fi
        eval "$1"
    )
}
poll() {   # poll <enabled as the loop read it> [n] — n polls' calls, each rc appended to $T/rc
    _pn=0
    while [ "$_pn" -lt "${2:-1}" ]; do
        ensure_ts0_masq "$1"
        printf '%s\n' "$?" >> "$T/rc"
        _pn=$((_pn + 1))
    done
}
snap() { for _sf in gets writes log; do cp "$T/$_sf" "$T/$_sf.$1"; done; }

SET_M='uci set firewall.tailscale0.masq=1'
SET_M6='uci set firewall.tailscale0.masq6=1'
COMMIT='uci commit firewall'
RELOAD='fw reload'
okline() {
    printf '%s\n' "-t ts-fix tailscale0 masquerade restored ($1) - missing from the zone (GL drops it on a Tailscale off/on)"
}
errline() {
    printf '%s\n' "-t ts-fix ERROR tailscale0 masquerade ($1) not restored (commit rc $2, still not 1: $3) - overlay full or read-only? Retrying in a minute"
}

# --------------------------------------------------------------------------------------- case 0
echo "--- case 0: the fakes (each behaviour a case relies on, and each recorder records)"
fresh
put firewall.tailscale0 zone
put firewall.tailscale0.masq 1
is "0 uci get of an option: its value, rc 0" "1|0" "$(v=$(uci -q get firewall.tailscale0.masq); printf '%s|%s' "$v" "$?")"
is "0 uci get of a section: its type, rc 0" "zone|0" "$(v=$(uci -q get firewall.tailscale0); printf '%s|%s' "$v" "$?")"
is "0 uci get of a missing key: nothing, rc 1" "|1" "$(v=$(uci -q get firewall.tailscale0.masq6); printf '%s|%s' "$v" "$?")"
is "0 uci set of an option in an existing section: rc 0, stored" "0 1" \
    "$(uci set firewall.tailscale0.masq6=1; printf '%s ' "$?"; val firewall.tailscale0.masq6)"
is "0 uci set of an option in a missing section: rc 1, nothing stored (real uci's uci_set refuses it)" \
    "1 <absent>" "$(uci set firewall.nosuch.masq=1; printf '%s ' "$?"; val firewall.nosuch.masq)"
rm -f "$T/state/firewall.tailscale0.masq6"
is "0 FAKE_UCI_NOSTICK=1: the set reports rc 0 and stores nothing" "0 <absent>" \
    "$(FAKE_UCI_NOSTICK=1; uci set firewall.tailscale0.masq6=1; printf '%s ' "$?"; val firewall.tailscale0.masq6)"
is "0 uci commit: rc 0 by default, FAKE_UCI_COMMIT_RC otherwise" "0 1" \
    "$(uci commit firewall; printf '%s ' "$?"; FAKE_UCI_COMMIT_RC=1; uci commit firewall; printf '%s' "$?")"
"$T/fw-init" reload >/dev/null 2>&1
logger -t ts-fix "lint line"
is "0 recorders: gets in gets" "$(lines 'get firewall.tailscale0.masq' 'get firewall.tailscale0' 'get firewall.tailscale0.masq6')" \
    "$(cat "$T/gets")"
is "0 recorders: sets, commits and the firewall fake in writes, in order" \
    "$(lines "$SET_M6" 'uci set firewall.nosuch.masq=1' "$SET_M6" "$COMMIT" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "0 recorders: logger arguments in log" "-t ts-fix lint line" "$(cat "$T/log")"
uci show firewall >/dev/null 2>&1
is "0 an unmodelled subcommand lands in unexpected" "uci show firewall" "$(cat "$T/unexpected")"
rm -f "$T/unexpected"
fakes=""
for f in uci logger; do
    case "$(type "$f" 2>&1)" in *function*) fakes="$fakes $f" ;; esac
done
is "0 uci and logger resolve to their fake functions in this shell" " uci logger" "$fakes"
if [ -x "$T/fw-init" ]; then ok "0 the firewall fake is executable"; else nok "0 the firewall fake is executable" "-x" "not"; fi

# -------------------------------------------------------------------------------- static checks
echo "--- static: the library guard, the call site, the copied firmware test, the seams' defaults"
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
# The poll's body is wd_poll (sourced in library mode by test-ts-state.sh), and the loop calls it
# once; so the call is placed within wd_poll, from its first line to its closing brace.
CALL='    ensure_ts0_masq "$curr"'
c_n=$(grep -c -F -e 'ensure_ts0_masq "$curr"' "$WD")
c_at=$(grep -n -x -F -e "$CALL" "$WD" | head -n 1 | cut -d: -f1)
k_at=$(grep -n -x -F -e '    /usr/bin/ts-fix-ks check' "$WD" | head -n 1 | cut -d: -f1)
d_at=$(grep -n -x -F -e 'done' "$WD" | tail -n 1 | cut -d: -f1)
p_at=$(grep -n -x -F -e 'wd_poll() {' "$WD" | head -n 1 | cut -d: -f1)
e_at=$(awk -v p="${p_at:-0}" 'p > 0 && NR > p && /^}$/ { print NR; exit }' "$WD")
w_n=$(grep -c -x -F -e '    wd_poll' "$WD")
w_at=$(grep -n -x -F -e '    wd_poll' "$WD" | head -n 1 | cut -d: -f1)
if [ "$c_n" = "1" ] && [ -n "$c_at" ] && [ -n "$k_at" ] && [ -n "$d_at" ] && [ -n "$l_at" ] &&
   [ -n "$p_at" ] && [ -n "$e_at" ] && [ "$w_n" = "1" ] && [ -n "$w_at" ] &&
   [ "$p_at" -lt "$k_at" ] && [ "$k_at" -lt "$c_at" ] && [ "$c_at" -lt "$e_at" ] &&
   [ "$l_at" -lt "$w_at" ] && [ "$w_at" -lt "$d_at" ]; then
    ok "S2 the poll calls ensure_ts0_masq \"\$curr\" once, after the ts-fix-ks check pass; the loop calls the poll once"
else
    nok "S2 the poll calls ensure_ts0_masq \"\$curr\" once, after the ts-fix-ks check pass; the loop calls the poll once" \
        "1 call, wd_poll < check < call < its }, loop < one wd_poll < done" \
        "count=$c_n wd_poll=[$p_at] check=[$k_at] call=[$c_at] end=[$e_at] loop=[$l_at] calls=$w_n at=[$w_at] done=[$d_at]"
fi
fn_body() { awk '/^is_fw49_plus\(\) \{/,/^}/' "$1"; }
want=$(fn_body "$REAPPLY" | sed 's|/etc/glversion|"$TS_FIX_GLVERSION"|')
if [ -n "$want" ]; then
    is "S3 is_fw49_plus is reapply's, with only the glversion path a variable" "$want" "$(fn_body "$WD")"
else
    nok "S3 is_fw49_plus is reapply's, with only the glversion path a variable" "reapply's function" "not found in $REAPPLY"
fi
got=$(
    if [ "$guard_ok" != "1" ]; then echo "NOT SOURCED"; exit 0; fi
    unset TS_FIX_GLVERSION TS_FIX_FW_INIT
    TS_FIX_WD_LIB=1
    . "$WD"
    printf '%s %s' "$TS_FIX_GLVERSION" "$TS_FIX_FW_INIT"
)
is "S4 unset, the seams default to the production paths" "/etc/glversion /etc/init.d/firewall" "$got"
got=$(
    if [ "$guard_ok" != "1" ]; then echo "NOT SOURCED"; exit 0; fi
    TS_FIX_WD_LIB=1
    TS_FIX_GLVERSION="$T/glversion"
    TS_FIX_FW_INIT="$T/fw-init"
    . "$WD"
    command -v is_fw49_plus >/dev/null 2>&1 || { echo "MISSING is_fw49_plus"; exit 0; }
    for v in 4.8.4 4.9.0 4.11.0 "4.9.0 release1" 4.10 5.0.1 3.215 "" garbage -; do
        if [ "$v" = "-" ]; then rm -f "$T/glversion"; else printf '%s\n' "$v" > "$T/glversion"; fi
        if is_fw49_plus; then r=1; else r=0; fi
        printf '[%s]=%s ' "$v" "$r"
    done
)
is "S5 is_fw49_plus over a glversion table (- is no file: non-GL firmware)" \
    "[4.8.4]=0 [4.9.0]=1 [4.11.0]=1 [4.9.0 release1]=1 [4.10]=1 [5.0.1]=1 [3.215]=0 []=0 [garbage]=0 [-]=0 " "$got"

# ------------------------------------------------------------------------------ behaviour: 4.9+
echo "--- case a: 4.11.0, Tailscale on, zone without masq and masq6, GL's toggle 1 -> both restored"
router 4.11.0 1 - - zone
in_watchdog 'poll 1'
is "a writes: both set, one commit, one reload (not a restart)" "$(lines "$SET_M" "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "a log: one line naming both" "$(okline "masq masq6")" "$(cat "$T/log")"
is "a the zone now carries both" "masq=1 masq6=1" "$(zone_state)"
is "a reads: zone, toggle, masq, masq6, then both read back after the commit" \
    "$(lines 'get firewall.tailscale0' 'get tailscale.settings.masq' 'get firewall.tailscale0.masq' \
        'get firewall.tailscale0.masq6' 'get firewall.tailscale0.masq' 'get firewall.tailscale0.masq6')" "$(cat "$T/gets")"
is "a rc 0" "0" "$(cat "$T/rc")"

echo "--- case b: 4.9.0, GL's toggle 0 or absent -> masq6 only; masq is GL's and is never set or cleared"
router 4.9.0 0 - - zone
in_watchdog 'poll 1'
is "b toggle 0, zone masq absent: only masq6 set" "$(lines "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "b ... log names masq6 only" "$(okline masq6)" "$(cat "$T/log")"
is "b ... zone masq still absent" "masq=<absent> masq6=1" "$(zone_state)"
router 4.9.0 - - - zone
in_watchdog 'poll 1'
is "b toggle absent, zone masq absent: only masq6 set" "$(lines "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "b ... zone masq still absent" "masq=<absent> masq6=1" "$(zone_state)"
router 4.9.0 0 0 - zone
in_watchdog 'poll 1'
is "b toggle 0, zone masq '0' (GL's own write): only masq6 set" "$(lines "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "b ... zone masq stays '0'" "masq=0 masq6=1" "$(zone_state)"
router 4.9.0 0 1 1 zone
in_watchdog 'poll 1'
is "b toggle 0, zone masq '1': not cleared, nothing written" "" "$(cat "$T/writes")"
is "b ... no log" "" "$(cat "$T/log")"

echo "--- case c: 4.9.0 release1, GL's toggle 1, zone masq '0' -> masq set to 1"
router "4.9.0 release1" 1 0 1 zone
in_watchdog 'poll 1'
is "c writes: masq set, one commit, one reload" "$(lines "$SET_M" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "c log names masq" "$(okline masq)" "$(cat "$T/log")"
is "c zone state" "masq=1 masq6=1" "$(zone_state)"

# --------------------------------------------------------------------------- behaviour: pre-4.9
echo "--- case d: 4.8.4 -> masq is the plugin's: set whatever GL's toggle says"
router 4.8.4 0 - - zone
in_watchdog 'poll 1'
is "d zone masq and masq6 absent, toggle 0: both set" "$(lines "$SET_M" "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "d ... log names both" "$(okline "masq masq6")" "$(cat "$T/log")"
is "d ... zone state" "masq=1 masq6=1" "$(zone_state)"
router 4.8.4 - 0 1 zone
in_watchdog 'poll 1'
is "d zone masq '0': set to 1" "$(lines "$SET_M" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "d ... log names masq" "$(okline masq)" "$(cat "$T/log")"

echo "--- case e: no glversion file (non-GL firmware) -> treated as pre-4.9, as reapply does"
router - 0 - - zone
in_watchdog 'poll 1'
is "e writes: both set" "$(lines "$SET_M" "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
is "e log names both" "$(okline "masq masq6")" "$(cat "$T/log")"

# ---------------------------------------------------------------------------- behaviour: no-ops
echo "--- case f: everything already 1 -> no set, no commit, no reload, no log; a few reads only"
router 4.11.0 1 1 1 zone
in_watchdog 'poll 1'
is "f 4.11.0, toggle 1: nothing written" "" "$(cat "$T/writes")"
is "f ... no log" "" "$(cat "$T/log")"
is "f ... four reads" "$(lines 'get firewall.tailscale0' 'get tailscale.settings.masq' 'get firewall.tailscale0.masq' \
    'get firewall.tailscale0.masq6')" "$(cat "$T/gets")"
is "f ... rc 0" "0" "$(cat "$T/rc")"
router 4.8.4 - 1 1 zone
in_watchdog 'poll 1'
is "f 4.8.4: nothing written" "" "$(cat "$T/writes")"
is "f ... three reads" "$(lines 'get firewall.tailscale0' 'get firewall.tailscale0.masq' 'get firewall.tailscale0.masq6')" \
    "$(cat "$T/gets")"
router 4.9.0 0 - 1 zone
in_watchdog 'poll 1'
is "f 4.9.0, toggle 0, masq6 1, zone masq absent: nothing written" "" "$(cat "$T/writes")"
is "f ... three reads, zone masq not among them" \
    "$(lines 'get firewall.tailscale0' 'get tailscale.settings.masq' 'get firewall.tailscale0.masq6')" "$(cat "$T/gets")"

echo "--- case g: no tailscale0 zone section -> nothing at all (never a set on a missing section)"
router 4.11.0 1 - - -
in_watchdog 'poll 1'
is "g zone absent: nothing written" "" "$(cat "$T/writes")"
is "g ... no log" "" "$(cat "$T/log")"
is "g ... its one call is the read of the zone" "get firewall.tailscale0" "$(cat "$T/gets")"
router 4.11.0 1 - - forwarding
in_watchdog 'poll 1'
is "g firewall.tailscale0 not a zone: nothing written" "" "$(cat "$T/writes")"
is "g ... no log" "" "$(cat "$T/log")"

echo "--- case h: Tailscale disabled -> nothing at all"
router 4.11.0 1 - - zone
in_watchdog 'poll 0'
is "h enabled 0: not one uci call, no write, no log" "||" "$(cat "$T/gets")|$(cat "$T/writes")|$(cat "$T/log")"
in_watchdog 'poll ""'
is "h enabled unset (empty): not one uci call, no write, no log" "||" "$(cat "$T/gets")|$(cat "$T/writes")|$(cat "$T/log")"

# ------------------------------------------------------------------------- behaviour: back-off
echo "--- case i: the write does not take -> one ERROR, then nothing for 11 polls, then a retry"
router 4.11.0 1 - - zone
in_watchdog '
    FAKE_UCI_NOSTICK=1
    poll 1; snap 1      # poll 1: the attempt, sets that do not stick
    poll 1 11; snap 2   # polls 2-12, within 60 s of poll 1 at one 5 s sleep per poll
    poll 1; snap 3      # poll 13, 60 s after poll 1: the retry, still not sticking
    FAKE_UCI_NOSTICK=0
    poll 1 11; snap 4   # polls 14-24
    poll 1; snap 5      # poll 25: the retry takes
    poll 1; snap 6      # poll 26: quiet'
ATTEMPT=$(lines "$SET_M" "$SET_M6" "$COMMIT" "$RELOAD")
is "i poll 1: sets, one commit, one reload" "$ATTEMPT" "$(cat "$T/writes.1" 2>&1)"
is "i poll 1: one ERROR line, nothing logged as restored" "$(errline "masq masq6" 0 "masq masq6")" "$(cat "$T/log.1" 2>&1)"
is "i polls 2-12: no uci call at all, no reload, no log" "same same same" \
    "$(for f in gets writes log; do cmp -s "$T/$f.1" "$T/$f.2" && printf 'same ' || printf 'DIFFERENT '; done | sed 's/ $//')"
is "i poll 13: retried - the same writes again" "$ATTEMPT
$ATTEMPT" "$(cat "$T/writes.3" 2>&1)"
is "i poll 13: a second ERROR line" "$(errline "masq masq6" 0 "masq masq6"; errline "masq masq6" 0 "masq masq6")" \
    "$(cat "$T/log.3" 2>&1)"
is "i polls 14-24: nothing again" "same same same" \
    "$(for f in gets writes log; do cmp -s "$T/$f.3" "$T/$f.4" && printf 'same ' || printf 'DIFFERENT '; done | sed 's/ $//')"
is "i poll 25: retried, and this time it takes" "$ATTEMPT
$ATTEMPT
$ATTEMPT" "$(cat "$T/writes.5" 2>&1)"
is "i poll 25: logged as restored" "$(errline "masq masq6" 0 "masq masq6"; errline "masq masq6" 0 "masq masq6"; okline "masq masq6")" \
    "$(cat "$T/log.5" 2>&1)"
is "i poll 26: quiet - no write, no log" "same same" \
    "$(for f in writes log; do cmp -s "$T/$f.5" "$T/$f.6" && printf 'same ' || printf 'DIFFERENT '; done | sed 's/ $//')"
is "i the zone ends with both" "masq=1 masq6=1" "$(zone_state)"
is "i rc per poll: 1 on each failed attempt, 0 otherwise" "1 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0" \
    "$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"

echo "--- case i2: the commit fails while the staged value reads back as 1 (a read-only overlay)"
router 4.9.0 0 - - zone
in_watchdog '
    FAKE_UCI_COMMIT_RC=1
    poll 1; snap 1
    poll 1; snap 2'
is "i2 poll 1: set, commit, reload" "$(lines "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes.1" 2>&1)"
is "i2 poll 1: an ERROR naming the commit's rc, not a restored line" "$(errline masq6 1 none)" "$(cat "$T/log.1" 2>&1)"
is "i2 poll 2: the back-off holds - nothing at all" "same same same" \
    "$(for f in gets writes log; do cmp -s "$T/$f.1" "$T/$f.2" && printf 'same ' || printf 'DIFFERENT '; done | sed 's/ $//')"

# --------------------------------------------------------------------------- firmware test, once
echo "--- case j: the firmware test runs once at startup, not per poll"
router 4.9.0 0 - - zone
in_watchdog 'printf "4.8.4\n" > "$T/glversion"; poll 1'
is "j started on 4.9.0, glversion rewritten to 4.8.4 after: still the 4.9+ rule (masq6 only)" \
    "$(lines "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"
router 4.8.4 0 - - zone
in_watchdog 'printf "4.11.0\n" > "$T/glversion"; poll 1'
is "j started on 4.8.4, glversion rewritten to 4.11.0 after: still the pre-4.9 rule (both)" \
    "$(lines "$SET_M" "$SET_M6" "$COMMIT" "$RELOAD")" "$(cat "$T/writes")"

# --------------------------------------------------------------------------------------- finish
echo "--- instrument: no unmodelled uci call anywhere in the run"
is "no unexpected uci subcommand" "" "$(cat "$T/unexpected" 2>/dev/null)"

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
echo "$fails FAILED ($oks ok)"; exit 1
