#!/bin/sh
# Unit test for the config-restore block in pkg/postinst. Laptop only, no router involved:
#   sh tests/unit/test-postinst-config.sh              the shipping block, from pkg/postinst
#   sh tests/unit/test-postinst-config.sh <postinst>   the block from another copy of the script
#                                                      (a RED run against an older one)
# Also runs under: busybox ash.
#
# The block is extracted from the script between its marker comments rather than copied here, so
# this tests shipping code; a missing or duplicated marker fails the run loudly. Its three absolute
# paths are rewritten to the same paths under a throwaway fake root, and the rewrite is linted
# before anything runs: a path the rewrite missed would point the block at the real /etc or /tmp,
# so the run stops instead. Each case lays out the fake root, runs the block in a subshell of the
# shell running this suite, and asserts what the three files hold afterwards.

POSTINST=${1:-"$(dirname "$0")/../../pkg/postinst"}
fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
finish() {
    [ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
    echo "$fails FAILED ($oks ok)"; exit 1
}

ROOT=$(mktemp -d) || { echo "FAIL: mktemp -d"; exit 1; }
trap 'rm -rf "$ROOT"' EXIT

echo "== the block, extracted and rewritten to the fake root"
is "the start marker appears exactly once" 1 "$(grep -c -e '^# ---8<--- config restore$' "$POSTINST")"
is "the end marker appears exactly once" 1 "$(grep -c -e '^# ---8<--- end config restore$' "$POSTINST")"
block=$(awk '/^# ---8<--- config restore$/,/^# ---8<--- end config restore$/' "$POSTINST")
[ -n "$block" ] || { nok "the block was extracted" "a non-empty block" "nothing"; finish; }
# $ROOT goes into a sed replacement, so it must hold nothing sed would read as special.
case "$ROOT" in
    *[!A-Za-z0-9._/-]*) nok "the fake root is safe inside a sed replacement" "[A-Za-z0-9._/-] only" "$ROOT"; finish ;;
esac
fake=$(printf '%s\n' "$block" |
    sed -e "s|/etc/config/ts-fix|$ROOT/etc/config/ts-fix|g" \
        -e "s|/tmp/ts-fix-config\.saved|$ROOT/tmp/ts-fix-config.saved|g")
# Instrument lint: with every "$ROOT/" prefix turned into a slash-free tag, no /etc/ or /tmp/ path
# may remain in the code — one that did would reach the real file system. Comment lines name paths
# but run nothing.
left=$(printf '%s\n' "$fake" | grep -v -e '^[[:space:]]*#' | sed "s|$ROOT/|@ROOT@:|g" | grep -e '/etc/' -e '/tmp/')
is "every /etc/ and /tmp/ path in the code now points into the fake root" "" "$left"
[ -z "$left" ] || finish
is "the code names the live file, the saved copy and the default, all under the fake root" \
    "$ROOT/etc/config/ts-fix
$ROOT/etc/config/ts-fix.default
$ROOT/tmp/ts-fix-config.saved" \
    "$(printf '%s\n' "$fake" | grep -v -e '^[[:space:]]*#' | grep -o -e "$ROOT/[A-Za-z0-9._/-]*" | sort -u)"

LIVE="$ROOT/etc/config/ts-fix"
SAVED="$ROOT/tmp/ts-fix-config.saved"
DEFAULT="$ROOT/etc/config/ts-fix.default"

# setup <live content|-> <saved content|-> — the fake root with the default always present, and
# the live file and the saved copy each present with that content, or absent for "-".
setup() {
    rm -rf "$ROOT/etc" "$ROOT/tmp"
    mkdir -p "$ROOT/etc/config" "$ROOT/tmp"
    printf 'default\n' > "$DEFAULT"
    [ "$1" = "-" ] || printf '%s\n' "$1" > "$LIVE"
    [ "$2" = "-" ] || printf '%s\n' "$2" > "$SAVED"
}
run_block() { ( eval "$fake" ); }
content() { if [ -f "$1" ]; then cat "$1"; else echo "(absent)"; fi; }

echo "== live file present, no saved copy (an upgrade on apk, which has no prerm on upgrade)"
setup "live" -
run_block; rc=$?
is "rc 0" 0 "$rc"
is "the live file is kept as it was" "live" "$(content "$LIVE")"
is "no saved copy appears" "(absent)" "$(content "$SAVED")"
is "the default is untouched" "default" "$(content "$DEFAULT")"

echo "== no live file, saved copy present (removal or --force-reinstall after a successful disarm)"
setup - "saved"
run_block; rc=$?
is "rc 0" 0 "$rc"
is "the saved copy becomes the live file" "saved" "$(content "$LIVE")"
is "the saved copy is gone (moved, not copied)" "(absent)" "$(content "$SAVED")"
is "the default is untouched" "default" "$(content "$DEFAULT")"

echo "== neither (a first install)"
setup - -
run_block; rc=$?
is "rc 0" 0 "$rc"
is "the default template becomes the live file" "default" "$(content "$LIVE")"
is "the default template is still there" "default" "$(content "$DEFAULT")"
is "no saved copy appears" "(absent)" "$(content "$SAVED")"

echo "== live file AND saved copy (an opkg upgrade; also a --force-reinstall whose disarm failed)"
# The live file carries a ks_severed record the saved copy does not: a reapply armed the kill
# switch between prerm's copy and this script. The record must survive.
setup "config settings 'settings'
	option kill_switch '1'
	list ks_severed 'lan:wan'" "config settings 'settings'
	option kill_switch '1'"
run_block; rc=$?
is "rc 0" 0 "$rc"
is "the live file wins, its severed-forwarding record intact" "config settings 'settings'
	option kill_switch '1'
	list ks_severed 'lan:wan'" "$(content "$LIVE")"
is "the saved copy is gone" "(absent)" "$(content "$SAVED")"
is "the default is untouched" "default" "$(content "$DEFAULT")"

finish
