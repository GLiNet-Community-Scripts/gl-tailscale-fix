#!/bin/sh
# Unit test for src/scripts/ts-fix-isolate6, the IPv6 half of GL's "Block WAN Subnets", and for the
# files that ship and call it: src/hotplug/98-ts-fix-isolate6, the removal block in pkg/postrm and
# its lock, the hotplug removal in pkg/prerm, the sync at the end of pkg/postinst, and the
# pkg/build.sh and keep.d entries. Laptop only, no router:
#   sh tests/unit/test-isolate6.sh [root]       (also runs under: busybox ash)
# root defaults to the repo. Another tree with the same files at the same relative paths can be
# given instead; a tree without the script must fail.
#
# The script is SOURCED with ISO6_NO_MAIN=1 in a subshell per case, so the cases bind to shipping
# code: the pure parsers (iso6_gl_pairs, iso6_route_prefixes, iso6_ours) are fed fixture text, and
# every behavioural case calls iso6_main, the function the script's last line runs. Case 16 also
# runs that last line itself, sourced and as a process.
#
# The fakes are shell functions, written once to $T/fakes.sh and linted in case 0. Functions, not
# executables on PATH: Ubuntu's busybox ash runs its own ip, logger and awk applets ahead of PATH
# (checked on BusyBox 1.36.1), so a PATH fake would have let the laptop's real ip and logger run
# under busybox ash. A function wins over both PATH and applets in dash and in BusyBox ash.
#   uci         over $T/fw.show, kept in `uci show firewall` format. show prints it; set, add_list
#               and delete edit it the way uci does (an option needs its section, a delete of a
#               missing entry fails, staged changes show at once). commit exits FAKE_UCI_COMMIT_RC
#               (default 0) and copies the state to $T/fw.committed; a set or add_list of the key
#               named by FAKE_UCI_FAIL fails, and so does a delete of the key named by
#               FAKE_UCI_DELFAIL; a set of the key named by FAKE_UCI_DROP returns 0 and stores
#               nothing (uci's lost update), every time or only FAKE_UCI_DROP_N times when that is
#               set; FAKE_UCI_DROP_OP=delete moves that drop to a delete of the key (rc 0, the
#               entry kept). Every call is recorded in $T/uci,
#               every write in $T/writes (and for the whole run in $T/allwrites), and a call
#               outside that set, or with a key outside firewall.[A-Za-z0-9_.], in $T/unexpected.
#               While FAKE_UCI_SNAP names a directory, every call, read or write, failed or not,
#               leaves there <n>.call (its arguments) and <n>.show (the state right after it):
#               what another writer's commit landing between two of our calls would find.
#               (uci itself is a thin wrapper doing that around _uci_impl, the fake proper.)
#   ubus        `call network.interface.<x> status` prints $T/ubus.d/<x>, or fails with 4 (Not found)
#               when there is no such file, or with 7 (Timeout) when FAKE_UBUS_FAIL names <x>; ubus
#               exits with its status code and prints "Command failed" on stderr, so does the fake.
#   jsonfilter  `-e @.l3_device` / `-e @.device` prints that string from the JSON on stdin; exits 1
#               when the field is absent, 126 when the input does not start with "{" (empty input
#               included) - jsonfilter's two codes: 1 for an expression that matches nothing, 126
#               for input it cannot parse, with "Failed to parse json data" on stderr.
#   ip          `-6 route show dev <dev>` prints $T/routes/<dev>, or fails as iproute2 does for a
#               device that does not exist.
#   logger      records its arguments in $T/log.
#   flock       returns FAKE_FLOCK_RC when set, else 1 while FAKE_FLOCK_HELD=1, else 0.
#   the firewall init script: TS_FIX_FW_INIT names an executable fake that records "fw <args>" in
#               $T/writes (an absolute path cannot be a shell function), exits 1 while the
#               file $T/fw-fail exists, and records in $T/fd9 whether it was started with fd 9
#               (the lock's) open or closed - read from /proc, so this suite is Linux only.
# The lock cases (P2) use the real flock(1) on a real file: the fake cannot block, and blocking is
# what they test. Fixtures use documentation and private ranges only: 2001:db8::/32, fd00:db8::/48
# ULA, RFC 1918.

R=${1:-"$(dirname "$0")/../.."}
R=$(cd "$R" && pwd) || { echo "FAIL: cannot enter the tree"; exit 1; }
SCRIPT="$R/src/scripts/ts-fix-isolate6"
HOTPLUG="$R/src/hotplug/98-ts-fix-isolate6"
PRERM="$R/pkg/prerm"
POSTRM="$R/pkg/postrm"
POSTINST="$R/pkg/postinst"
BUILD="$R/pkg/build.sh"
KEEPD="$R/src/upgrade/keep.d/gl-tailscale-fix"

T=$(mktemp -d "${TMPDIR:-/tmp}/ts-fix-iso6.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT

fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
lines() { [ "$#" -eq 0 ] || printf '%s\n' "$@"; }
content() { if [ -e "$1" ]; then cat "$1"; else printf '<absent>'; fi; }
finish() {
    echo
    [ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
    echo "$fails FAILED ($oks ok)"; exit 1
}

# $T goes into sed replacements and generated scripts, so it must hold nothing special to either.
case "$T" in
    *[!A-Za-z0-9._/-]*) nok "the temp dir is safe in sed replacements and scripts" "[A-Za-z0-9._/-] only" "$T"; finish ;;
esac
for f in "$PRERM" "$POSTRM" "$POSTINST" "$BUILD" "$KEEPD"; do
    [ -r "$f" ] || { nok "readable: ${f#"$R"/}" "readable" "missing"; finish; }
done
for f in "$SCRIPT" "$HOTPLUG"; do
    if [ -r "$f" ]; then ok "present: ${f#"$R"/}"; else nok "present: ${f#"$R"/}" "readable" "missing"; fi
done

# ------------------------------------------------------------------------------------- the fakes
cat > "$T/fakes.sh" <<'EOF'
_unexp() { printf '%s\n' "$*" >> "$T/unexpected"; }
_wr() { printf '%s\n' "$1" >> "$T/writes"; printf '%s\n' "$1" >> "$T/allwrites"; }
uci() {
    _uci_impl "$@"
    _urc=$?
    if [ -n "${FAKE_UCI_SNAP:-}" ]; then
        _usn=$(cat "$FAKE_UCI_SNAP/n" 2>/dev/null || echo 0)
        _usn=$((_usn + 1))
        echo "$_usn" > "$FAKE_UCI_SNAP/n"
        printf '%s\n' "$*" > "$FAKE_UCI_SNAP/$_usn.call"
        cp "$T/fw.show" "$FAKE_UCI_SNAP/$_usn.show"
    fi
    return "$_urc"
}
_uci_impl() {
    printf '%s\n' "$*" >> "$T/uci"
    if [ "$1" = "-q" ]; then shift; fi
    case "$1" in
        show)
            if [ "$#" -ne 2 ] || [ "$2" != "firewall" ]; then _unexp "uci $*"; return 1; fi
            cat "$T/fw.show"
            return 0
            ;;
        commit)
            _wr "uci commit $2"
            if [ "$#" -ne 2 ] || [ "$2" != "firewall" ]; then _unexp "uci $*"; fi
            cp "$T/fw.show" "$T/fw.committed"
            return "${FAKE_UCI_COMMIT_RC:-0}"
            ;;
        set|add_list|delete) ;;
        *) _unexp "uci $*"; return 1 ;;
    esac
    _wr "uci $1 $2"
    if [ "$#" -ne 2 ]; then _unexp "uci $* (argument count)"; return 1; fi
    _uk=${2%%=*}
    case "$_uk" in
        firewall.*) ;;
        *) _unexp "uci $1 $2 (not the firewall package)"; return 1 ;;
    esac
    case "${_uk#firewall.}" in
        ''|*[!A-Za-z0-9_.]*) _unexp "uci $1 $2 (invalid key)"; return 1 ;;
    esac
    if [ "$1" != "delete" ] && [ -n "${FAKE_UCI_FAIL:-}" ] && [ "$_uk" = "$FAKE_UCI_FAIL" ]; then
        return 1
    fi
    if [ "$1" = "delete" ] && [ -n "${FAKE_UCI_DELFAIL:-}" ] && [ "$_uk" = "$FAKE_UCI_DELFAIL" ]; then
        return 1
    fi
    if [ "$1" = "${FAKE_UCI_DROP_OP:-set}" ] && [ -n "${FAKE_UCI_DROP:-}" ] && [ "$_uk" = "$FAKE_UCI_DROP" ]; then
        _ud=$(cat "$T/dropped" 2>/dev/null || echo 0)
        if [ -z "${FAKE_UCI_DROP_N:-}" ] || [ "$_ud" -lt "$FAKE_UCI_DROP_N" ]; then
            echo "$((_ud + 1))" > "$T/dropped"
            return 0
        fi
    fi
    if awk -v op="$1" -v arg="$2" -f "$T/uci.awk" "$T/fw.show" > "$T/fw.new"; then
        mv -f "$T/fw.new" "$T/fw.show"
        return 0
    fi
    rm -f "$T/fw.new"
    return 1
}
ubus() {
    printf '%s\n' "$*" >> "$T/ubus"
    if [ "$#" -eq 3 ] && [ "$1" = "call" ] && [ "$3" = "status" ]; then
        case "$2" in
            network.interface.*) ;;
            *) _unexp "ubus $*"; return 1 ;;
        esac
        _ui=${2#network.interface.}
        case "$_ui" in
            ''|*[!A-Za-z0-9_]*) _unexp "ubus $* (invalid object)"; return 1 ;;
        esac
        if [ -n "${FAKE_UBUS_FAIL:-}" ] && [ "$_ui" = "$FAKE_UBUS_FAIL" ]; then
            echo "Command failed: Request timed out" >&2
            return 7
        fi
        [ -f "$T/ubus.d/$_ui" ] || { echo "Command failed: Not found" >&2; return 4; }
        cat "$T/ubus.d/$_ui"
        return 0
    fi
    _unexp "ubus $*"
    return 1
}
jsonfilter() {
    printf '%s\n' "$*" >> "$T/jsonfilter"
    if [ "$#" -ne 2 ] || [ "$1" != "-e" ]; then _unexp "jsonfilter $*"; return 1; fi
    case "$2" in
        @.l3_device|@.device) ;;
        *) _unexp "jsonfilter $*"; return 1 ;;
    esac
    _jin=$(cat)
    case "$_jin" in
        '{'*) ;;
        *) echo "Failed to parse json data" >&2; return 126 ;;
    esac
    _jv=$(printf '%s\n' "$_jin" | sed -n "s/^[[:space:]]*\"${2#@.}\": *\"\\([^\"]*\\)\".*/\\1/p" | head -n 1)
    [ -n "$_jv" ] || return 1
    printf '%s\n' "$_jv"
}
ip() {
    printf '%s\n' "$*" >> "$T/ip"
    if [ "$#" -eq 5 ] && [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "show" ] && [ "$4" = "dev" ]; then
        case "$5" in
            ''|.|..|*[!A-Za-z0-9._-]*) _unexp "ip $* (invalid device)"; return 1 ;;
        esac
        if [ ! -f "$T/routes/$5" ]; then
            printf 'Cannot find device "%s"\n' "$5" >&2
            return 1
        fi
        cat "$T/routes/$5"
        return 0
    fi
    _unexp "ip $*"
    return 1
}
logger() { printf '%s\n' "$*" >> "$T/log"; }
flock() {
    printf '%s\n' "$*" >> "$T/flock"
    [ -n "${FAKE_FLOCK_RC:-}" ] && return "$FAKE_FLOCK_RC"
    [ "${FAKE_FLOCK_HELD:-0}" = "1" ] && return 1
    return 0
}
EOF

# The uci edit, as an awk program over the `uci show` text: op is set, add_list or delete; arg is
# the key, with =value for set and add_list. Exit 1, printing nothing, wherever real uci refuses.
cat > "$T/uci.awk" <<'EOF'
BEGIN {
    q = "\047"
    eq = index(arg, "=")
    if (eq > 0) { key = substr(arg, 1, eq - 1); val = substr(arg, eq + 1) } else { key = arg; val = "" }
    rest = substr(key, 10)
    dot = index(rest, ".")
    if (dot > 0) { sec = substr(rest, 1, dot - 1); opt = substr(rest, dot + 1) } else { sec = rest; opt = "" }
    bad = 0
    if (op == "delete" && eq > 0) bad = 1
    if (op != "delete" && eq == 0) bad = 1
    if (op == "add_list" && opt == "") bad = 1
    n = 0
}
{ n++; line[n] = $0 }
END {
    if (bad) exit 1
    sp = "firewall." sec "="; pp = "firewall." sec "."; okey = "firewall." sec "." opt "="
    secl = 0; last = 0; optl = 0
    for (i = 1; i <= n; i++) {
        if (index(line[i], sp) == 1) { secl = i; last = i }
        else if (index(line[i], pp) == 1) { last = i; if (opt != "" && index(line[i], okey) == 1) optl = i }
    }
    ins = ""; dropsec = 0; drop = 0
    if (op == "delete" && opt == "") { if (!secl) exit 1; dropsec = 1 }
    else if (op == "delete") { if (!optl) exit 1; drop = optl }
    else if (opt == "") { if (secl) line[secl] = sp val; else ins = sp val }
    else {
        if (!secl) exit 1
        if (op == "set") { if (optl) line[optl] = okey q val q; else ins = okey q val q }
        else { if (optl) line[optl] = line[optl] " " q val q; else ins = okey q val q }
    }
    for (i = 1; i <= n; i++) {
        if (dropsec && (index(line[i], sp) == 1 || index(line[i], pp) == 1)) continue
        if (i == drop) continue
        print line[i]
        if (ins != "" && i == last) { print ins; ins = "" }
    }
    if (ins != "") print ins
}
EOF

printf '%s\n' '#!/bin/sh' "printf 'fw %s\\n' \"\$*\" >> '$T/writes'" "printf 'fw %s\\n' \"\$*\" >> '$T/allwrites'" \
    "if [ -e /proc/\$\$/fd/9 ]; then echo open; else echo closed; fi >> '$T/fd9'" \
    "[ -f '$T/fw-fail' ] && exit 1" 'exit 0' > "$T/fw-init"
chmod 755 "$T/fw-init"

# ------------------------------------------------------------------------------------ fixtures
base() {    # firewall config that has nothing to do with isolation
    lines "firewall.@defaults[0]=defaults" "firewall.@defaults[0].forward='REJECT'" \
        "firewall.@zone[1]=zone" "firewall.@zone[1].name='guest'" "firewall.@zone[1].network='guest'" \
        "firewall.@rule[0]=rule" "firewall.@rule[0].name='Allow-DHCP-Renew'" "firewall.@rule[0].src='wan'" \
        "firewall.@rule[0].proto='udp'" "firewall.@rule[0].dest_port='68'" "firewall.@rule[0].target='ACCEPT'" \
        "firewall.@forwarding[0]=forwarding" "firewall.@forwarding[0].src='lan'" "firewall.@forwarding[0].dest='wan'"
}
gl_rule() {     # gl_rule <uplink> <net> <IPv4 NET/PFX>: GL's own isolate rule, as uci show prints it
    _gs="firewall.$1_$2_isolate"
    lines "$_gs=rule" "$_gs.name='isolate $2 and $1'" "$_gs.src='$2'" "$_gs.dest='wan'" "$_gs.proto='all'" \
        "$_gs.target='REJECT'" "$_gs.dest_ip='$3'"
}
ours_sec() {    # ours_sec <uplink> <net> <prefix>...: one of our sections, as this script leaves it
    _os="firewall.ts_fix_$1_$2_isolate6"; _ou=$1; _on=$2; shift 2
    _ol=""; for _op in "$@"; do _ol="$_ol '$_op'"; done
    lines "$_os=rule" "$_os.src='$_on'" "$_os.dest='*'" "$_os.family='ipv6'" "$_os.proto='all'" \
        "$_os.target='REJECT'" "$_os.name='ts-fix: isolate $_on and $_ou (IPv6)'" "$_os.dest_ip=${_ol# }"
}
create_put() {      # create_put <uplink> <net> <prefix>...: the writes of a create, the rule disabled
    _cs="firewall.ts_fix_$1_$2_isolate6"; _cu=$1; _cn=$2; shift 2
    lines "uci set $_cs=rule" "uci set $_cs.enabled=0" "uci set $_cs.src=$_cn" "uci set $_cs.dest=*" \
        "uci set $_cs.family=ipv6" "uci set $_cs.proto=all" "uci set $_cs.target=REJECT" \
        "uci set $_cs.name=ts-fix: isolate $_cn and $_cu (IPv6)"
    for _cp in "$@"; do lines "uci add_list $_cs.dest_ip=$_cp"; done
}
create_writes() {   # create_writes <uplink> <net> <prefix>...: what creating that section writes
    create_put "$@"; lines "uci delete firewall.ts_fix_$1_$2_isolate6.enabled"
}
update_put() {      # update_put <uplink> <net> <prefix>...: the writes of an update, the rule disabled
    _us="firewall.ts_fix_$1_$2_isolate6"; _uu=$1; _un=$2; shift 2
    lines "uci set $_us.enabled=0" "uci set $_us.src=$_un" "uci set $_us.dest=*" \
        "uci set $_us.family=ipv6" "uci set $_us.proto=all" "uci set $_us.target=REJECT" \
        "uci set $_us.name=ts-fix: isolate $_un and $_uu (IPv6)" "uci delete $_us.dest_ip"
    for _up in "$@"; do lines "uci add_list $_us.dest_ip=$_up"; done
}
update_writes() {   # update_writes <uplink> <net> <prefix>...: what updating that section writes
    update_put "$@"; lines "uci delete firewall.ts_fix_$1_$2_isolate6.enabled"
}
COMMIT_RELOAD=$(lines "uci commit firewall" "fw reload")
iface() {   # iface <uplink> <l3_device | -> [device | -]: what ubus reports for it ("-": field absent)
    {
        printf '{\n\t"up": true'
        [ "${2:--}" = "-" ] || printf ',\n\t"l3_device": "%s"' "$2"
        [ "${3:--}" = "-" ] || printf ',\n\t"device": "%s"' "$3"
        printf '\n}\n'
    } > "$T/ubus.d/$1"
}
routes() { _rd=$1; shift; lines "$@" > "$T/routes/$_rd"; }     # routes <dev> <line>...
sec_of() { grep -e "^firewall\.$1=" -e "^firewall\.$1\." "$T/fw.show"; }    # sec_of <section>
not_ours() { grep -v -e '^firewall\.ts_fix_' "$T/fw.show"; }
drop_sec() {    # drop_sec <section>: delete it from the state, as GL or the user would
    grep -v -e "^firewall\.$1=" -e "^firewall\.$1\." "$T/fw.show" > "$T/fw.tmp"; mv -f "$T/fw.tmp" "$T/fw.show"
}
log_line() { printf '%s\n' "-t ts-fix isolate6: $1"; }

# The route fixture of plan case 2: two of these lines are the uplink's on-link prefixes.
FX_ROUTES=$(lines '2001:db8:1::/64 proto ra metric 256 expires 1800sec pref medium' \
    '2001:db8:1::/64 proto kernel metric 256 pref medium' \
    'fd00:db8:a::/64 proto kernel metric 256' \
    'fe80::/64 proto kernel metric 256' \
    'default via fe80::1 proto ra metric 1024' \
    'unreachable 2001:db8:2::/56 metric 2147483647' \
    '2001:DB8:3::1 proto kernel' \
    'ff00::/8 table local')
FX_P1=2001:db8:1::/64
FX_P2=fd00:db8:a::/64

reset_rec() {   # empty the recordings; the router state (fw.show, ubus.d, routes) is kept
    for _f in uci writes log ubus jsonfilter ip flock notes rc out err fd9; do : > "$T/$_f"; done
}
fresh() {       # the base config, no interfaces, no routes, empty recordings, fakes reset
    rm -rf "$T/ubus.d" "$T/routes" "$T/commit-failed" "$T/reload-failed" "$T/fw-fail" "$T/dropped" \
        "$T/fw.committed"
    mkdir -p "$T/ubus.d" "$T/routes"
    base > "$T/fw.show"
    reset_rec
    unset FAKE_UCI_COMMIT_RC FAKE_UCI_FAIL FAKE_UCI_DELFAIL FAKE_UCI_DROP FAKE_UCI_DROP_N FAKE_FLOCK_HELD FAKE_FLOCK_RC
    unset FAKE_UBUS_FAIL FAKE_UCI_DROP_OP FAKE_UCI_SNAP
}

# run <commands>: in a subshell, the fakes, then the script as a library, then the commands.
# ISO6_SELF names the script itself, a file that exists: the installed copy the script checks for.
run() {
    (
        . "$T/fakes.sh"
        if [ ! -r "$SCRIPT" ]; then printf 'NOT SOURCED: no script\n' >> "$T/notes"; exit 1; fi
        ISO6_NO_MAIN=1
        TS_FIX_FW_INIT="$T/fw-init"
        ISO6_LOCK="$T/lock"
        ISO6_COMMIT_FAIL="$T/commit-failed"
        ISO6_RELOAD_FAIL="$T/reload-failed"
        ISO6_SELF="$SCRIPT"
        . "$SCRIPT"
        for _fn in iso6_gl_pairs iso6_route_prefixes iso6_ours iso6_main; do
            command -v "$_fn" >/dev/null 2>&1 || { printf 'MISSING: %s\n' "$_fn" >> "$T/notes"; exit 1; }
        done
        eval "$1"
    )
}
# do_main <verb>: iso6_main as the script's last line would run it, rc in $T/rc, output in out/err
do_main() { run "iso6_main $1 > \"\$T/out\" 2> \"\$T/err\"; printf '%s\n' \"\$?\" > \"\$T/rc\""; }
quiet() {   # quiet <label>: rc, nothing on stdout or stderr
    is "$1: rc ${2:-0}, nothing on stdout or stderr" "${2:-0}||" "$(cat "$T/rc")|$(cat "$T/out")|$(cat "$T/err")"
}

# --------------------------------------------------------------------------------------- case 0
echo "--- case 0: the fakes (each behaviour a case relies on, and each recorder records)"
fresh
: > "$T/fw.show"
: > "$T/unexpected"; : > "$T/allwrites"
got=$(
    . "$T/fakes.sh"
    uci set firewall.s1=rule; printf '%s ' "$?"
    uci set firewall.s1.src=guest; printf '%s ' "$?"
    uci set firewall.nosuch.src=guest; printf '%s ' "$?"
    uci add_list firewall.s1.dest_ip=2001:db8::/64; printf '%s ' "$?"
    uci add_list firewall.s1.dest_ip=fd00:db8::/64; printf '%s ' "$?"
    uci set firewall.s1.enabled=0; printf '%s ' "$?"
    uci -q delete firewall.s1.enabled; printf '%s ' "$?"
    uci -q delete firewall.s1.enabled; printf '%s ' "$?"
    uci -q delete firewall.nosuch; printf '%s' "$?"
)
is "0 uci set/add_list/delete: rc as real uci (option needs its section, missing delete fails)" "0 0 1 0 0 0 0 1 1" "$got"
is "0 recorders: all 9 calls in uci, all 9 writes (-q dropped) in writes, in order" \
    "9|9|uci set firewall.s1=rule|uci delete firewall.s1.enabled" \
    "$(grep -c . "$T/uci")|$(grep -c . "$T/writes")|$(head -n 1 "$T/writes")|$(sed -n 7p "$T/writes")"
is "0 ... the state, in uci show format, a list space-joined and quoted per value" \
    "$(lines "firewall.s1=rule" "firewall.s1.src='guest'" "firewall.s1.dest_ip='2001:db8::/64' 'fd00:db8::/64'")" \
    "$(cat "$T/fw.show")"
got=$(. "$T/fakes.sh"; uci set firewall.s2=rule; uci set firewall.s1.src=lan; uci set firewall.s2.src=iot; cat "$T/fw.show")
is "0 uci set: an option replaces in place, a new one lands after its own section's lines" \
    "$(lines "firewall.s1=rule" "firewall.s1.src='lan'" "firewall.s1.dest_ip='2001:db8::/64' 'fd00:db8::/64'" \
        "firewall.s2=rule" "firewall.s2.src='iot'")" "$got"
got=$(. "$T/fakes.sh"; uci -q delete firewall.s1; printf '%s|' "$?"; cat "$T/fw.show")
is "0 uci delete of a section takes all its lines" "0|$(lines "firewall.s2=rule" "firewall.s2.src='iot'")" "$got"
is "0 uci show prints the state" "$(cat "$T/fw.show")" "$(. "$T/fakes.sh"; uci -q show firewall)"
is "0 uci commit: rc 0 by default, FAKE_UCI_COMMIT_RC otherwise" "0 1" \
    "$(. "$T/fakes.sh"; uci commit firewall; printf '%s ' "$?"; FAKE_UCI_COMMIT_RC=1; uci commit firewall; printf '%s' "$?")"
is "0 FAKE_UCI_FAIL: a set of that key fails and stores nothing, others still work" "1 0|firewall.s2.src='lan'" \
    "$(. "$T/fakes.sh"; FAKE_UCI_FAIL=firewall.s2.dest; uci set firewall.s2.dest=x; printf '%s ' "$?"
       uci set firewall.s2.src=lan; printf '%s|' "$?"; grep -e '^firewall\.s2\.' "$T/fw.show")"
: > "$T/unexpected"
got=$(. "$T/fakes.sh"; uci set 'firewall.s;x.src=a'; printf '%s ' "$?"; uci show network; printf '%s' "$?")
is "0 uci: a key outside the charset, or another package, fails and is recorded as unexpected" "1 1|2" \
    "$got|$(grep -c . "$T/unexpected")"
iface wwan sta0 sta0
iface wan - eth0
got=$(. "$T/fakes.sh"
    ubus call network.interface.wwan status | jsonfilter -e @.l3_device; printf '%s|' "$?"
    ubus call network.interface.wan status | jsonfilter -e @.l3_device; printf '%s|' "$?"
    ubus call network.interface.wan status | jsonfilter -e @.device; printf '%s|' "$?"
    ubus call network.interface.none status 2>/dev/null; printf '%s' "$?")
is "0 ubus + jsonfilter: l3_device, its absence (rc 1, nothing), device, a missing interface (rc 4)" \
    "sta0
0|1|eth0
0|4" "$got"
got=$(. "$T/fakes.sh"; FAKE_UBUS_FAIL=wwan
    ubus call network.interface.wwan status 2>/dev/null; printf '%s|' "$?"
    ubus call network.interface.wan status 2>/dev/null | jsonfilter -e @.device; printf '%s|' "$?"
    ubus call network.interface.wwan status 2>&1 >/dev/null; ubus call network.interface.none status 2>&1 >/dev/null)
is "0 FAKE_UBUS_FAIL: that interface's status fails with rc 7 and nothing on stdout, another's still works; both failures say so on stderr" \
    "7|eth0
0|Command failed: Request timed out
Command failed: Not found" "$got"
got=$(. "$T/fakes.sh"
    printf 'not json\n' | jsonfilter -e @.l3_device 2>/dev/null; printf '%s|' "$?"
    : | jsonfilter -e @.device 2>/dev/null; printf '%s|' "$?"
    printf '%s\n' '{ "up": false }' | jsonfilter -e @.device 2>/dev/null; printf '%s|' "$?"
    printf 'not json\n' | jsonfilter -e @.device 2>&1 >/dev/null)
is "0 jsonfilter: input that is not JSON, or empty, rc 126 and nothing on stdout (the error on stderr); JSON without the field rc 1" \
    "126|126|1|Failed to parse json data" "$got"
routes sta0 "$FX_P1 proto kernel"
got=$(. "$T/fakes.sh"; ip -6 route show dev sta0; printf '%s|' "$?"; ip -6 route show dev eth9 2>&1; printf '%s' "$?")
is "0 ip: the device's routes, or a missing device's error and rc 1" "$FX_P1 proto kernel
0|Cannot find device \"eth9\"
1" "$got"
got=$(. "$T/fakes.sh"; flock -n 9; printf '%s ' "$?"; FAKE_FLOCK_HELD=1; flock -n 9; printf '%s' "$?")
is "0 flock: free rc 0, held rc 1" "0 1" "$got"
is "0 flock: FAKE_FLOCK_RC overrides both (127, and 1 with FAKE_FLOCK_HELD unset)" "127 1" \
    "$(. "$T/fakes.sh"; FAKE_FLOCK_RC=127; flock -n 9; printf '%s ' "$?"; FAKE_FLOCK_RC=1; flock -n 9; printf '%s' "$?")"
got=$(. "$T/fakes.sh"; uci set firewall.d1=rule; FAKE_UCI_DELFAIL=firewall.d1; uci -q delete firewall.d1
    printf '%s %s ' "$?" "$(grep -c -e '^firewall\.d1=' "$T/fw.show")"
    unset FAKE_UCI_DELFAIL; uci -q delete firewall.d1; printf '%s %s' "$?" "$(grep -c -e '^firewall\.d1=' "$T/fw.show")")
is "0 FAKE_UCI_DELFAIL: that delete fails and the section stays; without it the delete works" "1 1 0 0" "$got"
got=$(. "$T/fakes.sh"; uci set firewall.d2=rule; FAKE_UCI_DROP=firewall.d2.src; FAKE_UCI_DROP_N=1
    uci set firewall.d2.src=a; printf '%s %s ' "$?" "$(grep -c -e '^firewall\.d2\.src=' "$T/fw.show")"
    uci set firewall.d2.src=b; printf '%s %s ' "$?" "$(grep -c -e "^firewall\.d2\.src='b'" "$T/fw.show")"
    unset FAKE_UCI_DROP_N; uci set firewall.d2.src=c; printf '%s %s' "$?" "$(grep -c -e "^firewall\.d2\.src='c'" "$T/fw.show")"
    uci -q delete firewall.d2)
rm -f "$T/dropped"
is "0 FAKE_UCI_DROP: rc 0 and nothing stored, FAKE_UCI_DROP_N times (then stored), every time without it" \
    "0 0 0 1 0 0" "$got"
got=$(. "$T/fakes.sh"; uci set firewall.d3=rule; FAKE_UCI_DROP=firewall.d3.enabled; FAKE_UCI_DROP_OP=delete
    FAKE_UCI_DROP_N=1
    uci set firewall.d3.enabled=0; printf '%s %s ' "$?" "$(grep -c -e "^firewall\.d3\.enabled='0'" "$T/fw.show")"
    uci -q delete firewall.d3.enabled; printf '%s %s ' "$?" "$(grep -c -e '^firewall\.d3\.enabled=' "$T/fw.show")"
    uci -q delete firewall.d3.enabled; printf '%s %s' "$?" "$(grep -c -e '^firewall\.d3\.enabled=' "$T/fw.show")"
    uci -q delete firewall.d3)
rm -f "$T/dropped"
is "0 FAKE_UCI_DROP_OP=delete: a set of the key is stored; its delete returns 0 and keeps it once, then deletes" \
    "0 1 0 1 0 0" "$got"
rm -rf "$T/snaplint"; mkdir -p "$T/snaplint"
(. "$T/fakes.sh"; FAKE_UCI_SNAP=$T/snaplint
    uci set firewall.s9=rule; uci set firewall.nosuch.src=x; uci -q show firewall > /dev/null
    uci set firewall.s9.src=lan; uci -q delete firewall.s9)
got=""
for i in 1 2 3 4 5; do
    got="$got$i:$(cat "$T/snaplint/$i.call" 2>&1)=$(grep -e '^firewall\.s9' "$T/snaplint/$i.show" 2>&1 | tr '\n' ' ')|"
done
is "0 FAKE_UCI_SNAP: every call, a failed one and a read included, leaves its call and the state after it" \
    "5|1:set firewall.s9=rule=firewall.s9=rule |2:set firewall.nosuch.src=x=firewall.s9=rule |3:-q show firewall=firewall.s9=rule |4:set firewall.s9.src=lan=firewall.s9=rule firewall.s9.src='lan' |5:-q delete firewall.s9=|" \
    "$(cat "$T/snaplint/n" 2>&1)|$got"
cp "$T/fw.show" "$T/fw.expect"; (. "$T/fakes.sh"; uci commit firewall)
is "0 uci commit copies the state to fw.committed" "same" "$(cmp -s "$T/fw.expect" "$T/fw.committed" && echo same)"
(. "$T/fakes.sh"; logger -t ts-fix "lint line")
"$T/fw-init" reload
is "0 logger records its arguments; the firewall fake records into writes" "-t ts-fix lint line|fw reload" \
    "$(cat "$T/log")|$(tail -n 1 "$T/writes")"
got=$(. "$T/fakes.sh"; for f in uci ubus jsonfilter ip logger flock; do
    case "$(type "$f" 2>&1)" in *function*) printf ' %s' "$f" ;; esac; done)
is "0 every fake resolves to its function in this shell (not PATH, not an applet)" " uci ubus jsonfilter ip logger flock" "$got"
if [ -x "$T/fw-init" ]; then ok "0 the firewall fake is executable"; else nok "0 the firewall fake is executable" "-x" "not"; fi
: > "$T/fw-fail"; "$T/fw-init" reload; rc1=$?; rm -f "$T/fw-fail"; "$T/fw-init" reload; rc2=$?
is "0 the firewall fake exits 1 while fw-fail exists and 0 otherwise, recording both calls" "1 0|fw reload
fw reload" "$rc1 $rc2|$(tail -n 2 "$T/writes")"
: > "$T/fd9"; "$T/fw-init" reload 9>/dev/null; "$T/fw-init" reload 9>&-
is "0 the firewall fake records fd 9 open when started with it open, closed when started without" "open
closed" "$(cat "$T/fd9")"
: > "$T/unexpected"; : > "$T/allwrites"

# ------------------------------------------------------------------------------- pure functions
echo "--- case 1: iso6_gl_pairs finds GL's IPv4 isolate rules and nothing else"
{
    base
    gl_rule wwan guest 192.168.25.0/24
    gl_rule wan guest 192.168.71.0/24
    gl_rule modem_1_1_4 iot 10.4.0.0/24
    # a suffix mismatch: the name says _isolate, but its own src (lan) is not in it
    lines "firewall.foo_isolate=rule" "firewall.foo_isolate.src='lan'" "firewall.foo_isolate.target='REJECT'" \
        "firewall.foo_isolate.dest_ip='192.168.8.0/24'"
    # target ACCEPT
    gl_rule tethering guest 192.168.9.0/24 | sed "s/'REJECT'/'ACCEPT'/"
    # an IPv6 dest_ip
    gl_rule secondwan guest 192.168.10.0/24 | sed "s|'192.168.10.0/24'|'2001:db8:9::/64'|"
    # an anonymous rule with everything else right
    lines "firewall.@rule[3]=rule" "firewall.@rule[3].src='guest'" "firewall.@rule[3].target='REJECT'" \
        "firewall.@rule[3].dest_ip='192.168.11.0/24'"
    # ours, and one of ours that ends in _isolate
    ours_sec wwan guest "$FX_P1"
    lines "firewall.ts_fix_x_guest_isolate=rule" "firewall.ts_fix_x_guest_isolate.src='guest'" \
        "firewall.ts_fix_x_guest_isolate.target='REJECT'" "firewall.ts_fix_x_guest_isolate.dest_ip='192.168.12.0/24'"
    # a name with a character outside [A-Za-z0-9_]
    lines "firewall.bad;x_guest_isolate=rule" "firewall.bad;x_guest_isolate.src='guest'" \
        "firewall.bad;x_guest_isolate.target='REJECT'" "firewall.bad;x_guest_isolate.dest_ip='192.168.13.0/24'"
    # a section that is not of type rule
    gl_rule wwan lan 192.168.14.0/24 | sed 's/=rule$/=redirect/'
    # disabled (enabled '0'): GL's IPv4 block is off, so there is nothing to mirror
    { gl_rule usbwan guest 192.168.15.0/24; lines "firewall.usbwan_guest_isolate.enabled='0'"; }
} > "$T/fx1"
is "1 exactly modem_1_1_4 iot, wan guest, wwan guest (sorted)" "$(lines 'modem_1_1_4 iot' 'wan guest' 'wwan guest')" \
    "$(run 'iso6_gl_pairs < "$T/fx1"')"
is "1 no GL rule at all: nothing" "" "$(run 'base | iso6_gl_pairs')"
is "1 enabled '1' still counts" "wwan guest" \
    "$(run "{ gl_rule wwan guest 192.168.25.0/24; lines \"firewall.wwan_guest_isolate.enabled='1'\"; } | iso6_gl_pairs")"

echo "--- case 2: iso6_route_prefixes keeps the on-link prefixes, lower-case, sorted, unique"
is "2 the plan's fixture: exactly the global and the ULA /64" "$(lines "$FX_P1" "$FX_P2")" \
    "$(run 'printf "%s\n" "$FX_ROUTES" | iso6_route_prefixes')"
FX_MORE=$(lines '2001:db8:4::/48 via fe80::1 dev sta0 proto ra metric 1024 pref medium' \
    '2001:db8:5::/48 proto static metric 1024 pref medium' \
    '	nexthop via fe80::1 weight 1' \
    '	nexthop via fe80::2 weight 1' \
    '2001:DB8:6::/64 proto kernel metric 256 pref medium' \
    '2001:db8:7::/128 proto kernel metric 256' \
    '::/0 proto static metric 1024' \
    '2001:db8:8::/64 proto kernel metric 256 linkdown pref medium' \
    'febf:1::/64 proto kernel metric 256' \
    'blackhole 2001:db8:9::/48 metric 1024')
is "2 a gateway route (via, or a multipath with nexthop lines), /128, /0, fe80::/10, blackhole dropped; upper case folded" \
    "$(lines '2001:db8:6::/64' '2001:db8:8::/64')" "$(run 'printf "%s\n" "$FX_MORE" | iso6_route_prefixes')"
is "2 a destination that is not a well-formed prefix is passed on as a candidate (the caller validates it)" \
    "$(lines '2001:db8:5::/129' '2001:db8:zz::/64')" \
    "$(run 'lines "2001:db8:zz::/64 proto kernel" "2001:DB8:5::/129 proto kernel" | iso6_route_prefixes')"
is "2 no routes: nothing" "" "$(run ': | iso6_route_prefixes')"

echo "--- case 3: iso6_ours lists our sections and their dest_ip"
{
    base
    gl_rule wwan guest 192.168.25.0/24
    ours_sec wwan guest "$FX_P1" "$FX_P2"
    ours_sec wan iot 2001:db8:2::/64
    lines "firewall.ts_fix_tethering_guest_isolate6=rule" "firewall.ts_fix_tethering_guest_isolate6.src='guest'"
    lines "firewall.ts_fix_x_isolate6=redirect" "firewall.ts_fix_x_isolate6.dest_ip='2001:db8:3::/64'"
    lines "firewall.ts_fix_bogus_isolate=rule" "firewall.ts_fix_bogus_isolate.dest_ip='2001:db8:4::/64'"
} > "$T/fx3"
is "3 each rule named ts_fix_*_isolate6 with its list space-joined (none: the name alone), sorted" \
    "$(lines 'ts_fix_tethering_guest_isolate6' 'ts_fix_wan_iot_isolate6 2001:db8:2::/64' \
        "ts_fix_wwan_guest_isolate6 $FX_P1 $FX_P2")" "$(run 'iso6_ours < "$T/fx3"')"
is "3 ... the list read exactly as uci prints it" \
    "firewall.ts_fix_wwan_guest_isolate6.dest_ip='$FX_P1' '$FX_P2'" \
    "$(grep -e '^firewall\.ts_fix_wwan_guest_isolate6\.dest_ip=' "$T/fx3")"
is "3 none of ours: nothing" "" "$(run '{ base; gl_rule wwan guest 192.168.25.0/24; } | iso6_ours')"

echo "--- case 3b: iso6_render renders every option we own, absent ones included"
TAB=$(printf '\t')
tj() { _tj=$1; shift; for _tx in "$@"; do _tj="$_tj$TAB$_tx"; done; printf '%s\n' "$_tj"; }
{
    base
    gl_rule wwan guest 192.168.25.0/24
    ours_sec wwan guest "$FX_P1" "$FX_P2"
    ours_sec wan iot 2001:db8:2::/64
    lines "firewall.ts_fix_wan_iot_isolate6.enabled='0'"
    ours_sec tethering guest "$FX_P1" | sed -e '/\.family=/d' -e "s/\.dest='\*'/.dest='wan'/"
    lines "firewall.ts_fix_x_isolate6=redirect" "firewall.ts_fix_x_isolate6.src='guest'"
} > "$T/fx3b"
is "3b one line per rule of ours, sorted: the section, then enabled src dest family proto target name dest_ip" \
    "$(tj ts_fix_tethering_guest_isolate6 enabled src=guest dest=wan family proto=all target=REJECT \
            'name=ts-fix: isolate guest and tethering (IPv6)' "dest_ip=$FX_P1"
       tj ts_fix_wan_iot_isolate6 enabled=0 src=iot 'dest=*' family=ipv6 proto=all target=REJECT \
            'name=ts-fix: isolate iot and wan (IPv6)' dest_ip=2001:db8:2::/64
       tj ts_fix_wwan_guest_isolate6 enabled src=guest 'dest=*' family=ipv6 proto=all target=REJECT \
            'name=ts-fix: isolate guest and wwan (IPv6)' "dest_ip=$FX_P1 $FX_P2")" \
    "$(run 'command -v iso6_render >/dev/null 2>&1 || { echo "MISSING iso6_render"; exit 0; }; iso6_render < "$T/fx3b"')"

# ----------------------------------------------------------------------------------- sync cases
echo "--- case 4: no GL isolate rule -> nothing written, nothing reloaded"
fresh
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
do_main sync
quiet "4"
is "4 one read of the firewall config and no other uci call" "-q show firewall" "$(cat "$T/uci")"
is "4 no write, no reload" "" "$(cat "$T/writes")"
is "4 no ubus and no ip call" "|" "$(cat "$T/ubus")|$(cat "$T/ip")"
is "4 no log" "" "$(cat "$T/log")"

echo "--- case 5: GL's wwan guest rule, sta0 with the case-2 routes -> one section per the contract"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
before=$(not_ours)
do_main sync
quiet "5"
is "5 writes: the section, disabled until whole, then one commit and one reload" \
    "$(create_writes wwan guest "$FX_P1" "$FX_P2"; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "5 the section, exactly" "$(ours_sec wwan guest "$FX_P1" "$FX_P2")" "$(sec_of ts_fix_wwan_guest_isolate6)"
is "5 everything that is not ours is untouched" "$before" "$(not_ours)"
is "5 one log line" "$(log_line 'added ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
is "5 asked ubus for wwan, read l3_device, listed sta0's routes" \
    "call network.interface.wwan status|-e @.l3_device|-6 route show dev sta0" \
    "$(cat "$T/ubus")|$(cat "$T/jsonfilter")|$(cat "$T/ip")"
is "5 took the lock without waiting" "-n 9" "$(cat "$T/flock")"
is "5 the reload ran with the lock's fd 9 closed" "closed" "$(cat "$T/fd9")"

echo "--- case 6: a second sync with nothing changed -> zero writes, zero reloads, no log"
reset_rec
do_main sync
quiet "6"
is "6 no write, no reload" "" "$(cat "$T/writes")"
is "6 no log" "" "$(cat "$T/log")"
is "6 the section is as it was" "$(ours_sec wwan guest "$FX_P1" "$FX_P2")" "$(sec_of ts_fix_wwan_guest_isolate6)"
is "6 its uci calls: the one read" "-q show firewall" "$(cat "$T/uci")"

echo "--- case 7: GL's rule deleted -> ours deleted, one commit, one reload"
drop_sec wwan_guest_isolate
before=$(not_ours)
reset_rec
do_main sync
quiet "7"
is "7 writes: the delete, one commit, one reload" \
    "$(lines 'uci delete firewall.ts_fix_wwan_guest_isolate6'; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "7 the section is gone" "" "$(sec_of ts_fix_wwan_guest_isolate6)"
is "7 everything else untouched" "$before" "$(not_ours)"
is "7 one log line" "$(log_line 'removed ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
is "7 no ubus or ip call (no GL rule left to follow)" "|" "$(cat "$T/ubus")|$(cat "$T/ip")"

echo "--- case 8: the uplink's prefix changed -> the section rewritten, one reload"
fresh
{ gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"; } >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 '2001:db8:7::/64 proto ra metric 256 expires 1800sec pref medium' 'fe80::/64 proto kernel metric 256'
do_main sync
quiet "8"
is "8 writes: disabled, rewritten, list replaced, re-enabled, one commit, one reload" \
    "$(update_writes wwan guest 2001:db8:7::/64; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "8 the section, exactly, with the new prefix" "$(ours_sec wwan guest 2001:db8:7::/64)" "$(sec_of ts_fix_wwan_guest_isolate6)"
is "8 one log line" "$(log_line 'updated ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
reset_rec
do_main sync
is "8 then quiet" "0||" "$(cat "$T/rc")|$(cat "$T/writes")|$(cat "$T/log")"

echo "--- case 9: an uplink with no device or no prefix -> no section (an existing one is removed)"
fresh
{ gl_rule wan guest 192.168.71.0/24; ours_sec wan guest 2001:db8:71::/64; } >> "$T/fw.show"
iface wan - -
do_main sync
quiet "9a"
is "9a no device reported: ours removed" "$(lines 'uci delete firewall.ts_fix_wan_guest_isolate6'; printf '%s\n' "$COMMIT_RELOAD")" \
    "$(cat "$T/writes")"
is "9a ... no ip call, both device fields asked for" "|-e @.l3_device
-e @.device" "$(cat "$T/ip")|$(cat "$T/jsonfilter")"
is "9a ... logged" "$(log_line 'removed ts_fix_wan_guest_isolate6')" "$(cat "$T/log")"
fresh
gl_rule wan guest 192.168.71.0/24 >> "$T/fw.show"
iface wan eth0 eth0
routes eth0 'fe80::/64 proto kernel metric 256' 'default via fe80::1 proto ra metric 1024'
do_main sync
quiet "9b"
is "9b a device with no on-link prefix: nothing written" "" "$(cat "$T/writes")"
# A ubus or ip call that fails is a read failure, not an absence: case 21 (the former 9c and 9d).
fresh
gl_rule wan guest 192.168.71.0/24 >> "$T/fw.show"
iface wan - eth0
routes eth0 '2001:db8:71::/64 proto kernel metric 256'
do_main sync
quiet "9e"
is "9e no l3_device: falls back to device" "-6 route show dev eth0" "$(cat "$T/ip")"
is "9e ... and the section is made from it" "$(ours_sec wan guest 2001:db8:71::/64)" "$(sec_of ts_fix_wan_guest_isolate6)"

echo "--- case 10: iot and vlan10 rules beside guest, two uplinks -> one section per (uplink, network)"
fresh
{
    gl_rule wwan guest 192.168.25.0/24; gl_rule wwan iot 192.168.25.0/24; gl_rule wwan vlan10 192.168.25.0/24
    gl_rule wan guest 192.168.71.0/24
} >> "$T/fw.show"
iface wwan sta0 sta0
iface wan eth0 eth0
routes sta0 "$FX_ROUTES"
routes eth0 '2001:db8:71::/64 proto kernel metric 256'
do_main sync
quiet "10"
for n in guest iot vlan10; do
    is "10 wwan $n: its own section, src $n" "$(ours_sec wwan "$n" "$FX_P1" "$FX_P2")" "$(sec_of "ts_fix_wwan_${n}_isolate6")"
done
is "10 wan guest: its own section, from eth0's prefix" "$(ours_sec wan guest 2001:db8:71::/64)" "$(sec_of ts_fix_wan_guest_isolate6)"
is "10 one commit and one reload for all four" "1 1" "$(grep -c -x -e 'uci commit firewall' "$T/writes") $(grep -c -x -e 'fw reload' "$T/writes")"
is "10 ... and they are the last two writes" "$COMMIT_RELOAD" "$(tail -n 2 "$T/writes")"
is "10 one log line naming all four" \
    "$(log_line 'added ts_fix_wan_guest_isolate6 ts_fix_wwan_guest_isolate6 ts_fix_wwan_iot_isolate6 ts_fix_wwan_vlan10_isolate6')" \
    "$(cat "$T/log")"

echo "--- case 11: an invalid prefix, network, uplink or device never reaches uci -> one ERROR line each"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 '2001:db8:zz::/64 proto kernel metric 256' "$FX_P1 proto ra metric 256"
do_main sync
quiet "11a" 1
is "11a a non-hex prefix: skipped, the valid one kept" "$(ours_sec wwan guest "$FX_P1")" "$(sec_of ts_fix_wwan_guest_isolate6)"
is "11a ... it never reached a uci call" "0" "$(grep -c -e 'zz' "$T/uci")"
is "11a ... one ERROR line, then the change" \
    "$(log_line "ERROR uplink wwan (sta0): route destination '2001:db8:zz::/64' is not an IPv6 prefix - skipped"
       log_line 'added ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 '2001:db8:5::/129 proto kernel metric 256'
do_main sync
quiet "11b" 1
is "11b a /129: no section, no write" "|" "$(sec_of ts_fix_wwan_guest_isolate6)|$(cat "$T/writes")"
is "11b ... one ERROR line" "$(log_line "ERROR uplink wwan (sta0): route destination '2001:db8:5::/129' is not an IPv6 prefix - skipped")" \
    "$(cat "$T/log")"
for bad in 'wwan gu;est' 'w-an guest' 'wwan gu$(x)est'; do
    fresh
    iface wwan sta0 sta0
    routes sta0 "$FX_ROUTES"
    BADPAIR=$bad
    run "iso6_gl_pairs() { cat > /dev/null; printf '%s\n' \"\$BADPAIR\"; }
        iso6_main sync > \"\$T/out\" 2> \"\$T/err\"; printf '%s\n' \"\$?\" > \"\$T/rc\""
    quiet "11c pair [$bad]" 1
    is "11c pair [$bad]: no write, no ubus or ip call" "||" "$(cat "$T/writes")|$(cat "$T/ubus")|$(cat "$T/ip")"
    is "11c pair [$bad]: one ERROR line" \
        "$(log_line "ERROR GL isolate rule for network '${bad#* }' on uplink '${bad%% *}': a name outside [A-Za-z0-9_] - skipped")" \
        "$(cat "$T/log")"
done
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan 'sta0;reboot' sta0
routes sta0 "$FX_ROUTES"
do_main sync
quiet "11d" 1
is "11d an invalid device name: no ip call, no write" "|" "$(cat "$T/ip")|$(cat "$T/writes")"
is "11d ... one ERROR line" "$(log_line "ERROR uplink wwan reports device 'sta0;reboot', not a valid device name - guest is not isolated over IPv6")" \
    "$(cat "$T/log")"

echo "--- case 12: remove deletes ours only"
fresh
{ gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1"; ours_sec wan iot 2001:db8:2::/64; } >> "$T/fw.show"
before=$(not_ours)
do_main remove
quiet "12"
is "12 writes: both of ours deleted, one commit, one reload" \
    "$(lines 'uci delete firewall.ts_fix_wan_iot_isolate6' 'uci delete firewall.ts_fix_wwan_guest_isolate6'
       printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "12 none of ours left; everything else, GL's rule included, untouched" "|$before" \
    "$(grep -e '^firewall\.ts_fix_' "$T/fw.show")|$(not_ours)"
is "12 one log line" "$(log_line 'removed ts_fix_wan_iot_isolate6 ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
is "12 no ubus or ip call" "|" "$(cat "$T/ubus")|$(cat "$T/ip")"
reset_rec
do_main remove
quiet "12 again"
is "12 remove with none of ours: no write, no reload, no log" "|" "$(cat "$T/writes")|$(cat "$T/log")"

echo "--- case 13: the lock is held -> nothing at all, rc 0"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
FAKE_FLOCK_HELD=1
do_main sync
quiet "13 sync"
is "13 sync: flock -n tried; no uci call, no write, no log" "-n 9|||" \
    "$(cat "$T/flock")|$(cat "$T/uci")|$(cat "$T/writes")|$(cat "$T/log")"
reset_rec
do_main remove
quiet "13 remove"
is "13 remove: no uci call either" "|" "$(cat "$T/uci")|$(cat "$T/writes")"
unset FAKE_FLOCK_HELD

echo "--- case 14: the commit fails -> ERROR, rc 1, no reload; the next sync commits and reloads"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
FAKE_UCI_COMMIT_RC=1
do_main sync
quiet "14 first" 1
is "14 first: the writes and the commit, no reload" \
    "$(create_writes wwan guest "$FX_P1" "$FX_P2"; lines 'uci commit firewall')" "$(cat "$T/writes")"
is "14 first: one ERROR line" \
    "$(log_line 'ERROR uci commit firewall failed (added ts_fix_wwan_guest_isolate6) - not persisted, firewall not reloaded (full or read-only overlay?); retrying on the next sync')" \
    "$(cat "$T/log")"
is "14 first: the retry flag is set" "" "$(content "$T/commit-failed")"
unset FAKE_UCI_COMMIT_RC
reset_rec
do_main sync
quiet "14 second"
is "14 second: the staged section reads back as converged, yet it commits and reloads" "$COMMIT_RELOAD" "$(cat "$T/writes")"
is "14 second: one log line" "$(log_line 'committed what an earlier sync staged')" "$(cat "$T/log")"
is "14 second: the flag is cleared" "<absent>" "$(content "$T/commit-failed")"
reset_rec
do_main sync
is "14 third: quiet" "0||" "$(cat "$T/rc")|$(cat "$T/writes")|$(cat "$T/log")"

echo "--- case 15: a uci write fails -> the half-written section is deleted, never committed half-written"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
FAKE_UCI_FAIL=firewall.ts_fix_wwan_guest_isolate6.target
do_main sync
quiet "15 create" 1
is "15 create: no section left, nothing committed, no reload" "|0|0" \
    "$(sec_of ts_fix_wwan_guest_isolate6)|$(grep -c -e 'commit' "$T/writes")|$(grep -c -e '^fw ' "$T/writes")"
is "15 create: the last write deletes the section" "uci delete firewall.ts_fix_wwan_guest_isolate6" "$(tail -n 1 "$T/writes")"
is "15 create: one ERROR line" \
    "$(log_line 'ERROR a uci write for ts_fix_wwan_guest_isolate6 failed - removed rather than left half-written (another writer committed the firewall config mid-write, or the overlay is full/read-only); retrying on the next sync')" \
    "$(cat "$T/log")"
fresh
{ gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"; } >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 '2001:db8:7::/64 proto ra metric 256'
FAKE_UCI_FAIL=firewall.ts_fix_wwan_guest_isolate6.target
do_main sync
quiet "15 update" 1
is "15 update: the old section is deleted and that deletion committed and reloaded" "|$COMMIT_RELOAD" \
    "$(sec_of ts_fix_wwan_guest_isolate6)|$(tail -n 2 "$T/writes")"
is "15 update: the ERROR line, then the change" \
    "$(log_line 'ERROR a uci write for ts_fix_wwan_guest_isolate6 failed - removed rather than left half-written (another writer committed the firewall config mid-write, or the overlay is full/read-only); retrying on the next sync'
       log_line 'removed ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
unset FAKE_UCI_FAIL
reset_rec
do_main sync
is "15 the next sync, writes working again, creates it" "$(ours_sec wwan guest 2001:db8:7::/64)" "$(sec_of ts_fix_wwan_guest_isolate6)"

echo "--- case 16: the entry point: an unknown or missing verb -> usage on stderr, rc 2, nothing touched"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
rm -f "$T/lock"
for v in bogus ""; do
    if [ -r "$SCRIPT" ]; then
        (
            . "$T/fakes.sh"
            TS_FIX_FW_INIT="$T/fw-init"; ISO6_LOCK="$T/lock"; ISO6_COMMIT_FAIL="$T/commit-failed"
            unset ISO6_NO_MAIN
            if [ -n "$v" ]; then set -- "$v"; else set --; fi
            . "$SCRIPT"
        ) > "$T/out" 2> "$T/err"
        rc=$?
    else
        rc=missing; : > "$T/out"; : > "$T/err"
    fi
    is "16 sourced, verb [$v]: rc 2, the usage line on stderr only" "2||usage: ts-fix-isolate6 sync|remove" \
        "$rc|$(cat "$T/out")|$(cat "$T/err")"
done
for shl in sh "busybox ash"; do
    ISO6_LOCK="$T/lock" $shl "$SCRIPT" bogus > "$T/out" 2> "$T/err"; rc=$?
    is "16 as a $shl process, verb bogus: rc 2, the usage line on stderr only" "2||usage: ts-fix-isolate6 sync|remove" \
        "$rc|$(cat "$T/out")|$(cat "$T/err")"
done
is "16 no uci call, no lock file made" "|<absent>" "$(cat "$T/uci")|$(content "$T/lock")"

echo "--- case 17: every option we own is converged, not only dest_ip"
# A rule of ours with the right dest_ip but anything else wrong - left disabled by a commit that
# landed mid-write, or edited by hand - is rewritten in place and logged as updated.
conv_case() {   # conv_case <label> <sed program for our correct section> [extra line for it]
    fresh
    { gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2" | sed -e "$2"; } >> "$T/fw.show"
    [ -z "${3:-}" ] || lines "$3" >> "$T/fw.show"
    iface wwan sta0 sta0
    routes sta0 "$FX_ROUTES"
    do_main sync
    quiet "17 $1"
    is "17 $1: rewritten in place, one commit, one reload" \
        "$(update_writes wwan guest "$FX_P1" "$FX_P2"; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
    is "17 $1: the section is exactly ours again (line order aside)" \
        "$(ours_sec wwan guest "$FX_P1" "$FX_P2" | LC_ALL=C sort)" "$(sec_of ts_fix_wwan_guest_isolate6 | LC_ALL=C sort)"
    is "17 $1: one log line" "$(log_line 'updated ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
    reset_rec
    do_main sync
    is "17 $1: the next sync is quiet" "0||" "$(cat "$T/rc")|$(cat "$T/writes")|$(cat "$T/log")"
}
conv_case "(a) enabled '0' committed with the right dest_ip" '' "firewall.ts_fix_wwan_guest_isolate6.enabled='0'"
conv_case "(a) enabled '1'" '' "firewall.ts_fix_wwan_guest_isolate6.enabled='1'"
conv_case "(b) family missing" '/\.family=/d'
conv_case "(b) dest 'wan'" "s/\.dest='\*'/.dest='wan'/"
conv_case "(b) target ACCEPT" "s/'REJECT'/'ACCEPT'/"
conv_case "(b) src 'lan'" "s/\.src='guest'/.src='lan'/"
conv_case "(b) proto 'tcp'" "s/\.proto='all'/.proto='tcp'/"
conv_case "(b) name missing" '/\.name=/d'
fresh
{ gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"; } >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
do_main sync
quiet "17 (c)"
is "17 (c) a fully correct rule this run did not write: no write, no commit, no reload, no log" "||-q show firewall" \
    "$(cat "$T/writes")|$(cat "$T/log")|$(cat "$T/uci")"

echo "--- case 18: the firewall reload fails -> ERROR, rc 1, flag; later syncs reload (no commit) until it works"
reload_err() { log_line "ERROR firewall reload failed ($1) - rules committed but not applied; retrying on the next sync"; }
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
: > "$T/fw-fail"
do_main sync
quiet "18 first" 1
is "18 first: the writes, one commit, the reload attempt" \
    "$(create_writes wwan guest "$FX_P1" "$FX_P2"; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "18 first: one ERROR line, nothing logged as added" "$(reload_err 'added ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
is "18 first: the reload flag is set, the commit flag is not" "|<absent>" "$(content "$T/reload-failed")|$(content "$T/commit-failed")"
reset_rec
do_main sync
quiet "18 second, still failing" 1
is "18 second, still failing: a reload attempt and nothing else" "fw reload" "$(cat "$T/writes")"
is "18 second, still failing: the ERROR again, the flag kept" \
    "$(reload_err 'retry for what an earlier sync committed')|" "$(cat "$T/log")|$(content "$T/reload-failed")"
rm -f "$T/fw-fail"
reset_rec
do_main sync
quiet "18 third, the reload works"
is "18 third: one reload, no commit (nothing was staged)" "fw reload" "$(cat "$T/writes")"
is "18 third: one log line, the flag cleared" \
    "$(log_line 'reloaded the firewall for what an earlier sync committed')|<absent>" "$(cat "$T/log")|$(content "$T/reload-failed")"
reset_rec
do_main sync
is "18 fourth: quiet" "0||" "$(cat "$T/rc")|$(cat "$T/writes")|$(cat "$T/log")"
: > "$T/fw-fail"
routes sta0 '2001:db8:7::/64 proto ra metric 256'
reset_rec
do_main sync
rm -f "$T/fw-fail"
routes sta0 '2001:db8:8::/64 proto ra metric 256'
reset_rec
do_main sync
quiet "18b a change while the flag is set"
is "18b the change is committed and reloaded the normal way" \
    "$(update_writes wwan guest 2001:db8:8::/64; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "18b logged as the change, and the flag cleared" "$(log_line 'updated ts_fix_wwan_guest_isolate6')|<absent>" \
    "$(cat "$T/log")|$(content "$T/reload-failed")"

echo "--- case 19: flock fails other than 'held' -> WARNING, and the sync runs unserialized"
for frc in 127 2; do
    fresh
    gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
    iface wwan sta0 sta0
    routes sta0 "$FX_ROUTES"
    FAKE_FLOCK_RC=$frc
    do_main sync
    quiet "19 flock rc $frc"
    is "19 flock rc $frc: a WARNING, then the change" \
        "$(log_line "WARNING flock unavailable (rc $frc) - running unserialized"; log_line 'added ts_fix_wwan_guest_isolate6')" \
        "$(cat "$T/log")"
    is "19 flock rc $frc: the rule is written" "$(ours_sec wwan guest "$FX_P1" "$FX_P2")" "$(sec_of ts_fix_wwan_guest_isolate6)"
done
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
FAKE_FLOCK_RC=1
do_main sync
quiet "19 flock rc 1 (held)"
is "19 flock rc 1 (held): no uci call, no write, no log" "||" "$(cat "$T/uci")|$(cat "$T/writes")|$(cat "$T/log")"
unset FAKE_FLOCK_RC

echo "--- case 20: every rule written is read back before the commit; a lost set is rewritten or removed"
# The read-back happens twice: in the write, before the rule is enabled, and once more for the
# whole pass before the commit. A rule that reads back short is rewritten, still disabled.
SHOW='-q show firewall'
lost_case() {   # the wwan guest rule to create, with FAKE_UCI_DROP on its src set
    fresh
    gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
    iface wwan sta0 sta0
    routes sta0 "$FX_ROUTES"
    FAKE_UCI_DROP=firewall.ts_fix_wwan_guest_isolate6.src
}
lost_case
FAKE_UCI_DROP_N=1
do_main sync
quiet "20 (a) src lost once"
is "20 (a) the create (never enabled), the rewrite its read-back called for, enabled, one commit, one reload" \
    "$(create_put wwan guest "$FX_P1" "$FX_P2"; update_writes wwan guest "$FX_P1" "$FX_P2"; printf '%s\n' "$COMMIT_RELOAD")" \
    "$(cat "$T/writes")"
is "20 (a) four reads: the sync's, the write's two (short, then whole), the pass's read-back" "4" \
    "$(grep -c -x -e "$SHOW" "$T/uci")"
is "20 (a) what was committed: the rule, exactly per the contract (line order aside)" \
    "$(ours_sec wwan guest "$FX_P1" "$FX_P2" | LC_ALL=C sort)" \
    "$(grep -e '^firewall\.ts_fix_wwan_guest_isolate6[.=]' "$T/fw.committed" 2>/dev/null | LC_ALL=C sort)"
is "20 (a) one log line: added" "$(log_line 'added ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
lost_case
do_main sync
quiet "20 (b) src lost every time" 1
is "20 (b) the create, the one rewrite (neither enabled), the delete, then one commit and one reload" \
    "$(create_put wwan guest "$FX_P1" "$FX_P2"; update_put wwan guest "$FX_P1" "$FX_P2"
       lines 'uci delete firewall.ts_fix_wwan_guest_isolate6'; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "20 (b) three reads: the sync's and the write's two" "3" "$(grep -c -x -e "$SHOW" "$T/uci")"
is "20 (b) nothing of ours committed, and nothing of ours left" "|" \
    "$(grep -e '^firewall\.ts_fix_' "$T/fw.committed" 2>/dev/null)|$(grep -e '^firewall\.ts_fix_' "$T/fw.show")"
is "20 (b) the ERROR line, then the change" \
    "$(log_line 'ERROR ts_fix_wwan_guest_isolate6 did not read back as written (another writer committed mid-write) - removed; retrying on the next sync'
       log_line 'removed ts_fix_wwan_guest_isolate6')" "$(cat "$T/log")"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
do_main sync
quiet "20 (c) a normal create"
is "20 (c) a normal create: three reads (the sync's, the write's, the pass's read-back), no rewrite" "3|$(create_writes wwan guest "$FX_P1" "$FX_P2"
       printf '%s\n' "$COMMIT_RELOAD")" "$(grep -c -x -e "$SHOW" "$T/uci")|$(cat "$T/writes")"
reset_rec
do_main sync
quiet "20 (c) quiet"
is "20 (c) quiet: exactly one uci show, no write, no commit, no log" "$SHOW||" \
    "$(cat "$T/uci")|$(cat "$T/writes")|$(cat "$T/log")"

echo "--- case 21: a read that fails is not an absence: the pair's rule is left as it is, WARNING, rc 1"
# A read of the uplink that fails (ubus exits non-zero, jsonfilter cannot parse the status, ip exits
# non-zero) says nothing about the uplink: the pair's rule is neither rewritten nor removed, one
# WARNING, rc 1. A read that succeeds and finds no device is an absence, and removes it, as in 9a.
unread() { log_line "WARNING could not read uplink $1 ($2) - its IPv6 isolate rule left as it is; retrying on the next sync"; }
kept_case() {   # kept_case <label> <what failed>: the wwan guest rule in place and its read set up to fail
    do_main sync
    quiet "21 $1" 1
    is "21 $1: no write, no commit, no reload" "" "$(cat "$T/writes")"
    is "21 $1: one WARNING line" "$(unread wwan "$2")" "$(cat "$T/log")"
}
fresh
{ gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"; } >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
FAKE_UBUS_FAIL=wwan
kept_case "(a) ubus fails" "ubus status rc 7"
is "21 (a) the section exactly as it was" "$(ours_sec wwan guest "$FX_P1" "$FX_P2")" "$(sec_of ts_fix_wwan_guest_isolate6)"
is "21 (a) ... no jsonfilter and no ip call" "|" "$(cat "$T/jsonfilter")|$(cat "$T/ip")"
unset FAKE_UBUS_FAIL
reset_rec
do_main sync
is "21 (a) the next sync, ubus answering: quiet" "0||" "$(cat "$T/rc")|$(cat "$T/writes")|$(cat "$T/log")"
fresh
{ gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"; lines "firewall.ts_fix_wwan_guest_isolate6.enabled='0'"; } >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
FAKE_UBUS_FAIL=wwan
kept_case "(a) ubus fails, the section wrong" "ubus status rc 7"
is "21 (a) a section that would be rewritten is left as it is too, enabled '0' included" \
    "$(ours_sec wwan guest "$FX_P1" "$FX_P2"; lines "firewall.ts_fix_wwan_guest_isolate6.enabled='0'")" "$(sec_of ts_fix_wwan_guest_isolate6)"
unset FAKE_UBUS_FAIL
fresh
{ gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"; } >> "$T/fw.show"
iface wwan sta0 sta0
kept_case "(b) ip -6 route fails" "ip -6 route show dev sta0 rc 1"
is "21 (b) the section exactly as it was; ip was asked" "$(ours_sec wwan guest "$FX_P1" "$FX_P2")|-6 route show dev sta0" \
    "$(sec_of ts_fix_wwan_guest_isolate6)|$(cat "$T/ip")"
routes sta0 "$FX_ROUTES"
reset_rec
do_main sync
is "21 (b) the next sync, the device back: quiet" "0||" "$(cat "$T/rc")|$(cat "$T/writes")|$(cat "$T/log")"
for st in 'not json' ''; do
    fresh
    { gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"; } >> "$T/fw.show"
    printf '%s' "$st" > "$T/ubus.d/wwan"
    routes sta0 "$FX_ROUTES"
    kept_case "(b) a status jsonfilter cannot parse [${st:-empty}]" "jsonfilter rc 126 on its status"
    is "21 (b) [${st:-empty}] the section exactly as it was; no ip call" "$(ours_sec wwan guest "$FX_P1" "$FX_P2")|" \
        "$(sec_of ts_fix_wwan_guest_isolate6)|$(cat "$T/ip")"
done
fresh
{ gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"; } >> "$T/fw.show"
iface wwan - -
routes sta0 "$FX_ROUTES"
do_main sync
quiet "21 (c) reads OK, no device"
is "21 (c) reads OK, no device: an absence - the section removed, one commit, one reload" \
    "$(lines 'uci delete firewall.ts_fix_wwan_guest_isolate6'; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "21 (c) ... both device fields asked for; no WARNING, the one log line is the change" "-e @.l3_device
-e @.device|$(log_line 'removed ts_fix_wwan_guest_isolate6')" "$(cat "$T/jsonfilter")|$(cat "$T/log")"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
do_main sync
quiet "21 (d) no section, ubus knows no such interface" 1
is "21 (d) nothing created, no write, no ip call" "||" "$(sec_of ts_fix_wwan_guest_isolate6)|$(cat "$T/writes")|$(cat "$T/ip")"
is "21 (d) the WARNING still logs" "$(unread wwan 'ubus status rc 4')" "$(cat "$T/log")"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
iface wwan eth9 eth9
do_main sync
quiet "21 (d) no section, the device does not exist" 1
is "21 (d) ... nothing created, the WARNING" "|$(unread wwan 'ip -6 route show dev eth9 rc 1')" "$(cat "$T/writes")|$(cat "$T/log")"
fresh
{
    gl_rule wwan guest 192.168.25.0/24; ours_sec wwan guest "$FX_P1" "$FX_P2"
    gl_rule wan guest 192.168.71.0/24; ours_sec wan guest 2001:db8:71::/64
} >> "$T/fw.show"
iface wwan sta0 sta0
routes sta0 "$FX_ROUTES"
iface wan eth0 eth0
routes eth0 '2001:db8:72::/64 proto kernel metric 256'
FAKE_UBUS_FAIL=wwan
do_main sync
quiet "21 (e) two pairs, one unread" 1
is "21 (e) the other pair's rule updated, one commit, one reload, no write to the unread pair's" \
    "$(update_writes wan guest 2001:db8:72::/64; printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "21 (e) the unread pair's section exactly as it was" "$(ours_sec wwan guest "$FX_P1" "$FX_P2")" "$(sec_of ts_fix_wwan_guest_isolate6)"
is "21 (e) the other's, with the new prefix" "$(ours_sec wan guest 2001:db8:72::/64)" "$(sec_of ts_fix_wan_guest_isolate6)"
is "21 (e) the WARNING, then the change" "$(unread wwan 'ubus status rc 7'; log_line 'updated ts_fix_wan_guest_isolate6')" "$(cat "$T/log")"
unset FAKE_UBUS_FAIL

echo "--- case 22: a rule is enabled only after it read back whole while disabled"
# Another writer's `uci commit firewall` landing between any two of our uci calls commits what that
# call left (FAKE_UCI_SNAP keeps each such state). Our rule live there - enabled absent, or anything
# but '0' - while an owned option is missing or wrong is a live partial rule: without its src, fw3
# puts it in OUTPUT and REJECTs the router's own IPv6. f4_classify sorts every snapshot: off
# (enabled '0'), whole (live, every owned option as wanted), empty (live, a section with no option
# at all: the accepted create window between `set <sec>=rule` and enabled=0), PARTIAL (live,
# anything else), none (no section of ours).
F4SEC=ts_fix_wwan_guest_isolate6
F4W=$(run 'ours_sec wwan guest "$FX_P1" "$FX_P2" | iso6_render')
f4_classify() {     # f4_classify <dir> <wanted render line>: "<n> TAB <class> TAB <call>" per snapshot
    _fn=1
    while [ -f "$1/$_fn.show" ]; do
        _fc=$(iso6_render < "$1/$_fn.show" | awk -F "$TAB" -v want="$2" -v tab="$TAB" '
            BEGIN {
                nw = split(want, w, tab); wr = ""; for (i = 3; i <= nw; i++) wr = wr "|" w[i]
                br = "|src|dest|family|proto|target|name|dest_ip"
            }
            {
                r = ""; for (i = 3; i <= NF; i++) r = r "|" $i
                if ($2 == "enabled=0") c = "off"; else if (r == wr) c = "whole"
                else if (r == br) c = "empty"; else c = "PARTIAL"
                printf "%s%s", (NR > 1 ? " " : ""), c
            }')
        printf '%s\t%s\t%s\n' "$_fn" "${_fc:-none}" "$(cat "$1/$_fn.call")"
        _fn=$((_fn + 1))
    done
}
is "22 instrument: the wanted rule renders as one line, enabled absent" "1|$F4SEC${TAB}enabled${TAB}src=guest" \
    "$(printf '%s\n' "$F4W" | grep -c .)|$(printf '%s\n' "$F4W" | cut -f 1-3)"
rm -rf "$T/f4lint"; mkdir -p "$T/f4lint"
ours_sec wwan guest "$FX_P1" "$FX_P2" | grep -v -e '\.src=' > "$T/f4lint/1.show"
{ ours_sec wwan guest "$FX_P1" "$FX_P2" | grep -v -e '\.src='; lines "firewall.$F4SEC.enabled='0'"; } > "$T/f4lint/2.show"
ours_sec wwan guest "$FX_P1" "$FX_P2" > "$T/f4lint/3.show"
lines "firewall.$F4SEC=rule" > "$T/f4lint/4.show"
{ ours_sec wwan guest "$FX_P1" "$FX_P2"; lines "firewall.$F4SEC.enabled='1'"; } > "$T/f4lint/5.show"
base > "$T/f4lint/6.show"
ours_sec wwan guest "$FX_P1" > "$T/f4lint/7.show"
for i in 1 2 3 4 5 6 7; do echo "c$i" > "$T/f4lint/$i.call"; done
is "22 instrument: live without src PARTIAL, disabled off, whole, type only empty, enabled '1' whole, none, short list PARTIAL" \
    "$(printf '%s\t%s\t%s\n' 1 PARTIAL c1 2 off c2 3 whole c3 4 empty c4 5 whole c5 6 none c6 7 PARTIAL c7)" \
    "$(run 'f4_classify "$T/f4lint" "$F4W"')"
f4_setup() {    # the wwan guest rule to create, every uci call snapshotted
    fresh
    gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
    iface wwan sta0 sta0
    routes sta0 "$FX_ROUTES"
    rm -rf "$T/snaps"; mkdir -p "$T/snaps"
    FAKE_UCI_SNAP=$T/snaps
}
f4_partial() { printf '%s\n' "$1" | awk -F "$TAB" '$2 ~ /PARTIAL/'; }
f4_enables() {  # the uci call before each enable of our rule, one per line
    awk -v e="-q delete firewall.$F4SEC.enabled" '$0 == e { print p } { p = $0 }' "$T/uci"
}
f4_setup
FAKE_UCI_DROP=firewall.$F4SEC.src
FAKE_UCI_DROP_N=1
do_main sync
unset FAKE_UCI_SNAP
cls=$(run 'f4_classify "$T/snaps" "$F4W"')
quiet "22 (a) src lost once"
is "22 (a) the fault was injected: one src set dropped; a snapshot after every uci call" \
    "1|$(grep -c . "$T/uci")" "$(content "$T/dropped")|$(content "$T/snaps/n")"
is "22 (a) never live while partial: no snapshot has the rule enabled with an option missing or wrong" "" \
    "$(f4_partial "$cls")"
is "22 (a) the one live empty rule is the create window, right after set <sec>=rule" "set firewall.$F4SEC=rule" \
    "$(printf '%s\n' "$cls" | awk -F "$TAB" '$2 == "empty" { print $3 }')"
is "22 (a) enabled once, and straight after a read of the config" "$SHOW" "$(f4_enables)"
is "22 (a) the rule in the end, exactly, and committed so (line order aside)" \
    "$(ours_sec wwan guest "$FX_P1" "$FX_P2" | LC_ALL=C sort)|$(ours_sec wwan guest "$FX_P1" "$FX_P2" | LC_ALL=C sort)" \
    "$(sec_of "$F4SEC" | LC_ALL=C sort)|$(grep -e "^firewall\.$F4SEC[.=]" "$T/fw.committed" 2>/dev/null | LC_ALL=C sort)"
is "22 (a) one log line: added" "$(log_line "added $F4SEC")" "$(cat "$T/log")"
f4_setup
FAKE_UCI_DROP=firewall.$F4SEC.enabled
FAKE_UCI_DROP_OP=delete
FAKE_UCI_DROP_N=1
do_main sync
unset FAKE_UCI_SNAP
cls=$(run 'f4_classify "$T/snaps" "$F4W"')
quiet "22 (b) the enable lost once"
is "22 (b) the fault was injected: one delete of enabled dropped" "1" "$(content "$T/dropped")"
is "22 (b) right after the lost enable the rule reads disabled (fail-closed)" "off" \
    "$(printf '%s\n' "$cls" | awk -F "$TAB" -v c="-q delete firewall.$F4SEC.enabled" '$3 == c { print $2; exit }')"
is "22 (b) never live while partial" "" "$(f4_partial "$cls")"
is "22 (b) the pass's read-back found it disabled and rewrote it: create, enable, rewrite, enable, commit, reload" \
    "$(create_writes wwan guest "$FX_P1" "$FX_P2"; update_writes wwan guest "$FX_P1" "$FX_P2"; printf '%s\n' "$COMMIT_RELOAD")" \
    "$(cat "$T/writes")"
is "22 (b) each enable straight after a read" "$(lines "$SHOW" "$SHOW")" "$(f4_enables)"
is "22 (b) the rule in the end, exactly, and committed so (line order aside)" \
    "$(ours_sec wwan guest "$FX_P1" "$FX_P2" | LC_ALL=C sort)|$(ours_sec wwan guest "$FX_P1" "$FX_P2" | LC_ALL=C sort)" \
    "$(sec_of "$F4SEC" | LC_ALL=C sort)|$(grep -e "^firewall\.$F4SEC[.=]" "$T/fw.committed" 2>/dev/null | LC_ALL=C sort)"
is "22 (b) one log line: added" "$(log_line "added $F4SEC")" "$(cat "$T/log")"
unset FAKE_UCI_DROP FAKE_UCI_DROP_OP FAKE_UCI_DROP_N
reset_rec
do_main sync
quiet "22 (c) the next sync, nothing changed"
is "22 (c) no write, and one read: the uci calls of a quiet sync before this change" "$SHOW|" \
    "$(cat "$T/uci")|$(cat "$T/writes")"

echo "--- case 23: its installed file gone (the package is being removed) -> nothing at all, rc 0"
self_state() {  # a sync would create wwan guest and remove wan iot; remove would delete wan iot
    fresh
    { gl_rule wwan guest 192.168.25.0/24; ours_sec wan iot 2001:db8:2::/64; } >> "$T/fw.show"
    iface wwan sta0 sta0
    routes sta0 "$FX_ROUTES"
}
self_run() {    # self_run <verb> <ISO6_SELF> [ISO6_LOCK]: iso6_main as do_main runs it
    SELF=$2; SLOCK=${3:-$T/lock}
    run "ISO6_SELF=\$SELF; ISO6_LOCK=\$SLOCK; iso6_main $1 > \"\$T/out\" 2> \"\$T/err\"; printf '%s\n' \"\$?\" > \"\$T/rc\""
}
for verb in sync remove; do
    self_state
    self_run "$verb" "$SCRIPT"
    is "23 $verb, the file there (the control): it writes" "yes" "$([ -s "$T/writes" ] && echo yes)"
    self_state
    before=$(cat "$T/fw.show")
    self_run "$verb" "$T/gone"
    quiet "23 $verb, the file gone"
    is "23 $verb, the file gone: the lock taken, then no uci call, no write, no reload, no log" "-n 9|||" \
        "$(cat "$T/flock")|$(cat "$T/uci")|$(cat "$T/writes")|$(cat "$T/log")"
    is "23 $verb, the file gone: the config unchanged" "$before" "$(cat "$T/fw.show")"
done
self_state
FAKE_FLOCK_RC=127
self_run sync "$T/gone"
quiet "23 flock unavailable, the file gone"
is "23 flock unavailable, the file gone: no uci call, no write; the lock's WARNING only" \
    "||$(log_line 'WARNING flock unavailable (rc 127) - running unserialized')" \
    "$(cat "$T/uci")|$(cat "$T/writes")|$(cat "$T/log")"
unset FAKE_FLOCK_RC
self_state
self_run sync "$T/gone" "$T/nodir/lock"
quiet "23 no lock file to be had, the file gone"
is "23 no lock file to be had, the file gone: no uci call, no write; the lock's WARNING only" \
    "||$(log_line "WARNING cannot create $T/nodir/lock - running unserialized")" \
    "$(cat "$T/uci")|$(cat "$T/writes")|$(cat "$T/log")"

# ------------------------------------------------------------------------------------- hotplug
echo "--- case H: the hotplug spawns one detached sync per uplink event and returns at once"
mkdir -p "$T/hp"
printf '%s\n' '#!/bin/sh' "printf '%s %s %s\\n' \"\$HP_TAG\" \"\$*\" \"\$(date +%s)\" >> '$T/hp/calls'" > "$T/hp/iso6"
chmod 755 "$T/hp/iso6"
: > "$T/hp/calls"
if [ -r "$HOTPLUG" ]; then
    hp_code=$(sed "s|/usr/bin/ts-fix-isolate6|$T/hp/iso6|g" "$HOTPLUG")
    hp_absent=$(sed "s|/usr/bin/ts-fix-isolate6|$T/hp/absent|g" "$HOTPLUG")
else
    hp_code="exit 9"; hp_absent="exit 9"
fi
left=$(printf '%s\n' "$hp_code" | grep -v -e '^[[:space:]]*#' | sed "s|$T/[A-Za-z0-9._/-]*|@T@|g" |
    grep -e '/usr/' -e '/etc/' -e '/bin/' -e '/sbin/' -e '/tmp/' -e '/lib/')
is "H instrument lint: the script path is the only absolute path in the code, now the fake" "" "$left"
is "H the spawn detaches stdin, stdout and stderr" "1" \
    "$(grep -c -x -F -e '( sleep 3; /usr/bin/ts-fix-isolate6 sync ) </dev/null >/dev/null 2>&1 &' "$HOTPLUG" 2>/dev/null)"
t0=$(date +%s)
for a in ifup ifupdate ifdown add remove -; do
    (
        HP_TAG=$a; export HP_TAG
        if [ "$a" = "-" ]; then unset ACTION; else ACTION=$a; fi
        INTERFACE=wwan
        eval "$hp_code"
    ) > "$T/hp/out.$a" 2>&1
    printf '%s ' "$?" >> "$T/hp/rcs"
done
( ACTION=ifup; INTERFACE=wwan; eval "$hp_absent" ) > "$T/hp/out.absent" 2>&1
printf '%s' "$?" >> "$T/hp/rcs"
t1=$(date +%s)
if [ $((t1 - t0)) -le 1 ]; then ok "H all seven ran without waiting ($((t1 - t0)) s)"
else nok "H all seven ran without waiting" "<= 1 s" "$((t1 - t0)) s"; fi
is "H each returned 0 and printed nothing (the script absent included)" "0 0 0 0 0 0 0|" \
    "$(cat "$T/hp/rcs")|$(cat "$T/hp/out."*)"
_w=0
while [ "$_w" -lt 10 ] && [ "$(grep -c . "$T/hp/calls")" -lt 3 ]; do sleep 1; _w=$((_w + 1)); done
sleep 1
is "H ifup, ifupdate and ifdown each ran one sync; add, remove and no ACTION none" \
    "$(lines 'ifdown sync' 'ifup sync' 'ifupdate sync')" "$(cut -d' ' -f1,2 "$T/hp/calls" | LC_ALL=C sort)"
late=$(awk -v t0="$t0" '$3 - t0 < 2 { print }' "$T/hp/calls")
is "H each sync started only after the delay (>= 2 s after the event)" "" "$late"

# ---------------------------------------------------------------------------------------- postrm
echo "--- case P: pkg/postrm deletes ours, and only on a real removal"
pr_code=$(sed -e "s|/lib/upgrade/keep\.d/|$T/pr/lib/upgrade/keep.d/|g" -e "s|/etc/init\.d/nginx|$T/pr/etc/init.d/nginx|g" \
    -e "s|/etc/init\.d/firewall|$T/fw-init|g" -e "s|/tmp/ts-fix-isolate6\.lock|$T/iso6.lock|g" "$POSTRM")
left=$(printf '%s\n' "$pr_code" | grep -v -e '^[[:space:]]*#' | sed "s|$T/[A-Za-z0-9._/-]*|@T@|g" |
    grep -e '/etc/' -e '/lib/' -e '/usr/' -e '/tmp/' -e '/rom/' -e '/sbin/' -e '/bin/')
is "P instrument lint: every path in postrm's code now points into the temp dir" "" "$left"
is "P postrm names ts_fix_*_isolate6 (the block is there)" "1" "$(grep -c -F -e 'ts_fix_[A-Za-z0-9_]*_isolate6' "$POSTRM")"
g_at=$(grep -n -x -F -e '[ "$PKG_UPGRADE" = "1" ] && exit 0' "$POSTRM" | head -n 1 | cut -d: -f1)
b_at=$(grep -n -F -e 'ts_fix_[A-Za-z0-9_]*_isolate6' "$POSTRM" | head -n 1 | cut -d: -f1)
if [ -n "$g_at" ] && [ -n "$b_at" ] && [ "$g_at" -lt "$b_at" ]; then ok "P ... after the PKG_UPGRADE guard"
else nok "P ... after the PKG_UPGRADE guard" "guard < block" "guard=[$g_at] block=[$b_at]"; fi
pr_setup() {    # an empty $T/pr with a fake nginx init that records "<args> fd9 open|closed" in $T/nginx
    rm -rf "$T/pr"; mkdir -p "$T/pr/lib/upgrade/keep.d" "$T/pr/etc/init.d"
    printf '%s\n' '#!/bin/sh' \
        "if [ -e /proc/\$\$/fd/9 ]; then s=open; else s=closed; fi; printf '%s fd9 %s\\n' \"\$*\" \"\$s\" >> '$T/nginx'" \
        > "$T/pr/etc/init.d/nginx"
    chmod 755 "$T/pr/etc/init.d/nginx"
    : > "$T/nginx"
    reset_rec
}
run_postrm() {  # run_postrm <PKG_UPGRADE value | unset> [code]: rc; the code defaults to postrm's
    pr_setup
    (
        . "$T/fakes.sh"
        pgrep() { return 1; }
        kill() { :; }
        sleep() { :; }
        if [ "$1" = "unset" ]; then unset PKG_UPGRADE; else PKG_UPGRADE=$1; fi
        eval "${2:-$pr_code}"
    ) > "$T/out" 2>&1
    printf '%s' "$?"
}
pr_state() {
    fresh
    {
        gl_rule wwan guest 192.168.25.0/24
        ours_sec wwan guest "$FX_P1"
        ours_sec wan iot 2001:db8:2::/64
        lines "firewall.ts_fix_x_isolate6=redirect" "firewall.ts_fix_x_isolate6.src='guest'"
    } >> "$T/fw.show"
}
pr_state
before=$(cat "$T/fw.show")
: > "$T/iso6.lock"
is "P PKG_UPGRADE=1 (an opkg upgrade): rc 0, no uci call, the config unchanged" "0||$before" \
    "$(run_postrm 1)|$(cat "$T/uci")|$(cat "$T/fw.show")"
is "P PKG_UPGRADE=1: no lock taken, the lock file left alone, no nginx restart" "|present|" \
    "$(cat "$T/flock")|$([ -e "$T/iso6.lock" ] && echo present)|$(cat "$T/nginx")"
P_DEL=$(lines 'uci delete firewall.ts_fix_wwan_guest_isolate6' 'uci delete firewall.ts_fix_wan_iot_isolate6')
for v in 0 unset; do
    pr_state
    before=$(grep -v -e '^firewall\.ts_fix_wwan_guest_isolate6' -e '^firewall\.ts_fix_wan_iot_isolate6' "$T/fw.show")
    : > "$T/iso6.lock"
    rc=$(run_postrm "$v")
    is "P PKG_UPGRADE=$v: rc 0, nothing printed" "0|" "$rc|$(cat "$T/out")"
    is "P PKG_UPGRADE=$v: both rules of ours deleted, one commit, one reload" \
        "$(printf '%s\n' "$P_DEL" "$COMMIT_RELOAD")" "$(cat "$T/writes")"
    is "P PKG_UPGRADE=$v: everything else (GL's rule, a non-rule section by our name) untouched" "$before" "$(cat "$T/fw.show")"
    is "P PKG_UPGRADE=$v: nothing logged" "" "$(cat "$T/log")"
    is "P PKG_UPGRADE=$v: ts-fix-isolate6's lock taken with a blocking flock on fd 9" "9" "$(cat "$T/flock")"
    is "P PKG_UPGRADE=$v: the reload ran with fd 9 closed, and nginx restarted with it closed" \
        "closed|$(lines 'stop fd9 closed' 'start fd9 closed')" "$(cat "$T/fd9")|$(cat "$T/nginx")"
    is "P PKG_UPGRADE=$v: the lock file removed at the end" "<absent>" "$(content "$T/iso6.lock")"
done
pr_state
pr_mut=$(printf '%s\n' "$pr_code" | sed -e '/^exec 9>&-$/d')
run_postrm 0 "$pr_mut" > /dev/null
is "P instrument: with postrm's close of fd 9 taken out, nginx would start holding it (the fake sees it)" \
    "$(lines 'stop fd9 open' 'start fd9 open')" "$(cat "$T/nginx")"
pr_state
FAKE_FLOCK_RC=127
rc=$(run_postrm 0)
is "P flock missing (rc 127): rc 0, nothing printed; the rules deleted, committed, reloaded unserialized" \
    "0||$(printf '%s\n' "$P_DEL" "$COMMIT_RELOAD")" "$rc|$(cat "$T/out")|$(cat "$T/writes")"
is "P ... one WARNING line, and postrm went on to the nginx restart" \
    "-t ts-fix postrm: WARNING flock on $T/iso6.lock failed (rc 127) - removing the IPv6 isolate rules unserialized|$(lines 'stop fd9 closed' 'start fd9 closed')" \
    "$(cat "$T/log")|$(cat "$T/nginx")"
unset FAKE_FLOCK_RC
pr_state
rc=$(run_postrm 0 "$(printf '%s\n' "$pr_code" | sed -e "s|$T/iso6\.lock|$T/nodir/iso6.lock|g")")
is "P no lock file to be had: rc 0, nothing printed, no flock; the rules deleted, committed, reloaded" \
    "0|||$(printf '%s\n' "$P_DEL" "$COMMIT_RELOAD")" "$rc|$(cat "$T/out")|$(cat "$T/flock")|$(cat "$T/writes")"
is "P ... one WARNING line, and postrm went on to the nginx restart" \
    "-t ts-fix postrm: WARNING cannot create $T/nodir/iso6.lock - removing the IPv6 isolate rules unserialized|$(lines 'stop fd9 closed' 'start fd9 closed')" \
    "$(cat "$T/log")|$(cat "$T/nginx")"
fresh
gl_rule wwan guest 192.168.25.0/24 >> "$T/fw.show"
is "P none of ours: rc 0, no write, no commit, no reload" "0|" "$(run_postrm 0)|$(cat "$T/writes")"
pr_state
FAKE_UCI_DELFAIL=firewall.ts_fix_wan_iot_isolate6
rc=$(run_postrm 0)
is "P a delete that fails: rc 0, nothing printed" "0|" "$rc|$(cat "$T/out")"
is "P ... one log line naming the section" \
    "-t ts-fix postrm: could not delete ts_fix_wan_iot_isolate6 - IPv6 isolate rule left in place" "$(cat "$T/log")"
is "P ... the other is deleted, and the commit and reload still happen" \
    "$(lines 'uci delete firewall.ts_fix_wwan_guest_isolate6' 'uci delete firewall.ts_fix_wan_iot_isolate6'
       printf '%s\n' "$COMMIT_RELOAD")" "$(cat "$T/writes")"
is "P ... the one that failed is still there" "firewall.ts_fix_wan_iot_isolate6=rule" \
    "$(grep -e '^firewall\.ts_fix_wan_iot_isolate6=' "$T/fw.show")"
unset FAKE_UCI_DELFAIL
pr_state
FAKE_UCI_COMMIT_RC=1
rc=$(run_postrm 0)
is "P a commit that fails: rc 0, nothing printed" "0|" "$rc|$(cat "$T/out")"
is "P ... both deletes and the commit, and no reload" \
    "$(lines 'uci delete firewall.ts_fix_wwan_guest_isolate6' 'uci delete firewall.ts_fix_wan_iot_isolate6' 'uci commit firewall')" \
    "$(cat "$T/writes")"
is "P ... one log line" "-t ts-fix postrm: uci commit firewall failed - IPv6 isolate rules removed in staging only, firewall not reloaded" \
    "$(cat "$T/log")"
unset FAKE_UCI_COMMIT_RC

echo "--- case P2: postrm holds ts-fix-isolate6's lock across its cleanup (the real flock, real processes)"
# A sync that is running when postrm starts must finish before postrm reads and deletes, and a
# sync tried while postrm holds the lock must skip. The holder and every sync here are separate
# processes taking flock(1) on the same file, $T/iso6.lock, which postrm's rewritten code locks too.
p2_ok=1
if [ "$(command -v flock 2>/dev/null | cut -c1)" = "/" ]; then ok "P2 a real flock(1) is on PATH: $(command -v flock)"
else nok "P2 a real flock(1) is on PATH (these cases need one)" "a path" "$(command -v flock 2>&1)"; p2_ok=0; fi
try_sync() {    # one ts-fix-isolate6 sync with the real flock on $T/iso6.lock: "rc <rc> uci <calls it made>"
    _t0=$(grep -c . "$T/uci")
    (
        . "$T/fakes.sh"
        unset -f flock
        ISO6_NO_MAIN=1; TS_FIX_FW_INIT="$T/fw-init"; ISO6_LOCK="$T/iso6.lock"; ISO6_SELF="$SCRIPT"
        ISO6_COMMIT_FAIL="$T/commit-failed"; ISO6_RELOAD_FAIL="$T/reload-failed"
        . "$SCRIPT"
        iso6_main sync > /dev/null 2>&1
    )
    _trc=$?
    printf 'rc %s uci %s\n' "$_trc" "$(($(grep -c . "$T/uci") - _t0))"
}
hold_lock() {   # a background process holding $T/iso6.lock until $T/go exists (30 s at most); pid in HP
    rm -f "$T/held" "$T/go"
    (
        exec 9>"$T/iso6.lock"
        flock 9 || exit 1
        : > "$T/held"
        _hw=0
        while [ ! -e "$T/go" ] && [ "$_hw" -lt 300 ]; do sleep 0.1; _hw=$((_hw + 1)); done
        printf 'holder released\n' >> "$T/events"
    ) &
    HP=$!
    _hw=0
    while [ ! -e "$T/held" ] && [ "$_hw" -lt 50 ]; do sleep 0.1; _hw=$((_hw + 1)); done
    [ -e "$T/held" ]
}
release_lock() { : > "$T/go"; wait "$HP"; }
postrm_real() { # postrm_real <PKG_UPGRADE value>: postrm with the real flock; rc in $T/pr-rc; events
    (
        . "$T/fakes.sh"
        unset -f flock
        pgrep() { return 1; }
        kill() { :; }
        sleep() { :; }
        uci() {
            case "$1 $2" in
                "-q show"|"-q delete"|"commit firewall") printf 'uci %s\n' "$*" >> "$T/events" ;;
            esac
            _uci_impl "$@"
            _prc=$?
            [ "$1" = "commit" ] && printf 'a sync tried meanwhile: %s\n' "$(try_sync)" >> "$T/events"
            return "$_prc"
        }
        PKG_UPGRADE=$1
        eval "$pr_code"
    ) > "$T/out" 2>&1
    printf '%s\n' "$?" > "$T/pr-rc"
    printf 'postrm finished\n' >> "$T/events"
}
P2_EVENTS=$(lines 'uci -q show firewall' 'uci -q delete firewall.ts_fix_wwan_guest_isolate6' \
    'uci -q delete firewall.ts_fix_wan_iot_isolate6' 'uci commit firewall' 'a sync tried meanwhile: rc 0 uci 0' \
    'postrm finished')
if [ "$p2_ok" = "1" ]; then
    pr_state; rm -f "$T/iso6.lock"
    got=$(try_sync)
    case "$got" in
        "rc "*" uci 0"|"") nok "P2 instrument: a sync tried with the lock free runs (makes uci calls)" "rc <n> uci <n > 0>" "$got" ;;
        "rc "*" uci "*) ok "P2 instrument: a sync tried with the lock free runs ($got)" ;;
        *) nok "P2 instrument: a sync tried with the lock free runs (makes uci calls)" "rc <n> uci <n > 0>" "$got" ;;
    esac
    pr_state; : > "$T/events"
    if hold_lock; then ok "P2 instrument: the holder took the lock"; got=$(try_sync); release_lock
    else nok "P2 instrument: the holder took the lock" "held" "not held"; got=""; release_lock; fi
    is "P2 instrument: a sync tried while another process holds the lock skips: rc 0, no uci call" "rc 0 uci 0" "$got"

    pr_state; pr_setup; : > "$T/events"; : > "$T/iso6.lock"
    postrm_real 0
    is "P2 (a) postrm alone: it reads, deletes and commits under the lock; a sync tried mid-commit skips" \
        "$P2_EVENTS" "$(cat "$T/events")"
    is "P2 (a) ... rc 0; the reload ran with fd 9 closed, nginx restarted with it closed; the lock file gone" \
        "0|closed|$(lines 'stop fd9 closed' 'start fd9 closed')|<absent>" \
        "$(content "$T/pr-rc")|$(cat "$T/fd9")|$(cat "$T/nginx")|$(content "$T/iso6.lock")"

    pr_state; pr_setup; : > "$T/events"; rm -f "$T/pr-rc"
    if hold_lock; then
        printf 'postrm started\n' >> "$T/events"
        postrm_real 0 &
        PP=$!
        sleep 1
        st=$(kill -0 "$PP" 2>/dev/null && echo waiting)
        release_lock
        wait "$PP"
        is "P2 (b) a sync holding the lock when postrm starts: postrm still waiting 1 s on" "waiting" "$st"
        is "P2 (b) ... and it reads and deletes only after the holder released" \
            "$(printf '%s\n' 'postrm started' 'holder released' "$P2_EVENTS")" "$(cat "$T/events")"
        is "P2 (b) ... rc 0, both rules of ours deleted" "0|" \
            "$(content "$T/pr-rc")|$(grep -e '^firewall\.ts_fix_[A-Za-z0-9_]*_isolate6=rule' "$T/fw.show")"
    else
        nok "P2 (b) the holder took the lock" "held" "not held"; release_lock
    fi

    pr_state; pr_setup; : > "$T/events"; rm -f "$T/pr-rc"
    if hold_lock; then
        postrm_real 1 &
        PP=$!
        _hw=0
        while [ ! -e "$T/pr-rc" ] && [ "$_hw" -lt 30 ]; do sleep 0.1; _hw=$((_hw + 1)); done
        release_lock
        wait "$PP"
        is "P2 (c) PKG_UPGRADE=1 while a sync holds the lock: postrm returns at once, before the holder lets go" \
            "$(lines 'postrm finished' 'holder released')|0" "$(cat "$T/events")|$(content "$T/pr-rc")"
    else
        nok "P2 (c) the holder took the lock" "held" "not held"; release_lock
    fi
fi

# ----------------------------------------------------------------------------------------- prerm
echo "--- case R: pkg/prerm deletes hotplug 98 with 10 and 20, after the upgrade guard, before the service stop"
rm_at=$(grep -n -e '^rm -f /etc/hotplug\.d/iface/' "$PRERM" | cut -d: -f1)
is "R one rm command deletes the hotplug handlers" "1" "$(printf '%s\n' "$rm_at" | grep -c .)"
rmcmd=$(awk '/^rm -f \/etc\/hotplug\.d\/iface\// { f = 1 } f { print; if ($0 !~ /\\$/) exit }' "$PRERM")
is "R it names 10-ts-fix-ks, 20-ts-fix and 98-ts-fix-isolate6, and nothing else" \
    "$(lines /etc/hotplug.d/iface/10-ts-fix-ks /etc/hotplug.d/iface/20-ts-fix /etc/hotplug.d/iface/98-ts-fix-isolate6)" \
    "$(printf '%s\n' "$rmcmd" | tr ' \\' '\n\n' | grep -e '^/etc/hotplug\.d/' | LC_ALL=C sort)"
g_at=$(grep -n -x -F -e '[ "$PKG_UPGRADE" = "1" ] && exit 0' "$PRERM" | head -n 1 | cut -d: -f1)
s_at=$(grep -n -e '^[[:space:]]*/etc/init\.d/ts-fix stop' "$PRERM" | head -n 1 | cut -d: -f1)
rm_at=$(printf '%s\n' "$rm_at" | head -n 1)
if [ -n "$g_at" ] && [ -n "$rm_at" ] && [ -n "$s_at" ] && [ "$g_at" -lt "$rm_at" ] && [ "$rm_at" -lt "$s_at" ]; then
    ok "R ... after the PKG_UPGRADE guard and before the service stop"
else
    nok "R ... after the PKG_UPGRADE guard and before the service stop" "guard < rm < stop" \
        "guard=[$g_at] rm=[$rm_at] stop=[$s_at]"
fi

# ------------------------------------------------------------------------------ static packaging
echo "--- case S: the package ships both files, keeps them across firmware upgrades, and syncs on install"
eff=$(sed -ne '/^[[:space:]]*$/d; /^#/d; p' "$KEEPD")
for p in /usr/bin/ts-fix-isolate6 /etc/hotplug.d/iface/98-ts-fix-isolate6; do
    is "S keep.d lists $p once" "1" "$(printf '%s\n' "$eff" | grep -c -x -F -e "$p")"
done
is "S build.sh installs the script at 755" "1" \
    "$(grep -c -x -F -e 'install -m 755 "$ROOT_DIR/src/scripts/ts-fix-isolate6" "$DATA/usr/bin/ts-fix-isolate6"' "$BUILD")"
is "S build.sh installs the hotplug at 755" "1" \
    "$(grep -c -x -F -e 'install -m 755 "$ROOT_DIR/src/hotplug/98-ts-fix-isolate6" "$DATA/etc/hotplug.d/iface/98-ts-fix-isolate6"' "$BUILD")"
SYNC='[ -x /usr/bin/ts-fix-isolate6 ] && ( /usr/bin/ts-fix-isolate6 sync ) </dev/null >/dev/null 2>&1 &'
code=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$POSTINST")
is "S postinst: one line names the script, and it is the detached sync" "$SYNC" \
    "$(printf '%s\n' "$code" | grep -F -e 'ts-fix-isolate6')"
is "S postinst: that sync is its last command before the final exit 0" "$SYNC
exit 0" "$(printf '%s\n' "$code" | tail -n 2)"

# ---------------------------------------------------------------------------------------- finish
echo "--- instrument: no unmodelled call anywhere; every write in the run touched only ours"
is "no unexpected fake call" "" "$(cat "$T/unexpected" 2>/dev/null)"
bad=$(grep -E -e '^uci (set|add_list|delete) ' "$T/allwrites" | sed -e 's/^uci [a-z_]* //' -e 's/=.*//' |
    grep -v -E -e '^firewall\.ts_fix_[A-Za-z0-9_]+_isolate6(\.[a-z_]+)?$')
is "every uci write in the run was to a ts_fix_*_isolate6 section" "" "$bad"
badp=$(grep -E -e '^uci add_list ' "$T/allwrites" | sed -e 's/^[^=]*=//' | grep -v -E -e '^[0-9a-f:]+/[0-9]+$')
is "every dest_ip written was an IPv6 prefix" "" "$badp"
n=$(grep -c -E -e '^uci (set|add_list|delete) ' "$T/allwrites")
if [ "$n" -gt 0 ]; then ok "... and those two checks read $n writes"
else nok "... and those two checks read writes" "> 0" "$n"; fi

finish
