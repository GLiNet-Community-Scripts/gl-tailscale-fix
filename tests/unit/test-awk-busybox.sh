#!/bin/sh
# Guard against one BusyBox 1.33 awk trap. Laptop only (needs python3); runs under sh and busybox ash:
#   sh tests/unit/test-awk-busybox.sh                the fixtures, then the listed repo files
#                                                    that run awk on a router
#   sh tests/unit/test-awk-busybox.sh --files F...   the fixtures, then the files given (selftest.sh
#                                                    uses this for the router-side instruments)
#
# GL 4.9 and 4.11 ship BusyBox v1.33.2, whose awk reads an identifier followed by blanks and "(" as a
# call to a function of that name: `s = s ("x")` stops with "Call to undefined function" when the line
# RUNS, while a parse check passes. gawk, mawk and BusyBox 1.36 read the same text as concatenation,
# so no desktop run finds it. Write an append as `x = (x == "" ? y : x "," y)`.
# tests/lib/awk-busybox-lint.py finds the form in source. This test
#   1. lints the fixtures in tests/unit/fixtures/awk-busybox/ in both directions: fx-pos.awk must give
#      its one hit, fx-shell.sh its two (lines 5 and 6, and nothing from the shell's own text) and
#      fx-pos-field.awk its two (`$i (`, `$NF (`); fx-neg.awk, fx-neg2.awk and fx-neg-field.awk must
#      give none. Each fixture's runtime verdict was checked on a host build of the 1.33.2 awk.c: the
#      positive forms stop with "Call to undefined function", the negative ones run;
#   2. lints the file set and asserts zero hits;
#   3. proves the lint read every awk program in the file set to its end: a canary line in the trapped
#      form is appended to each program (in memory), and every canary must be reported. A program the
#      lint cannot see, or loses track of halfway, would otherwise hide a real hit.
# A missing python3, linter, fixture or listed file is a FAIL, never a skip.
# Scope (the lint's own): *.awk files, and in shell files every single-quoted program after an `awk`
# command word. A program passed in double quotes or through a variable is not read — write router
# awk programs single-quoted, or as a *.awk file.
TD=$(cd "$(dirname "$0")/../.." && pwd)
LINT="$TD/tests/lib/awk-busybox-lint.py"
FXD="$TD/tests/unit/fixtures/awk-busybox"
fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) nok "$1" "text containing: $2" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) nok "$1" "text NOT containing: $2" "$3" ;; *) ok "$1" ;; esac; }
finish() {
  [ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
  echo "$fails FAILED ($oks ok)"; exit 1
}

command -v python3 >/dev/null 2>&1 || { nok "python3 present (the lint needs it)" "python3" "not found"; finish; }
[ -r "$LINT" ] || { nok "linter present" "$LINT" "missing"; finish; }

echo "== fixtures: the lint finds the trapped form, and only it"
for f in fx-pos.awk fx-neg.awk fx-neg2.awk fx-shell.sh fx-pos-field.awk fx-neg-field.awk; do
  [ -r "$FXD/$f" ] || nok "fixture $f present" "$FXD/$f" "missing"
done
out=$(cd "$FXD" && python3 "$LINT" fx-pos.awk 2>&1); rc=$?
is  "fx-pos.awk: exit 1 (a hit)" 1 "$rc"
has "fx-pos.awk: the hit is \`s (\` on line 1" "fx-pos.awk:1: \`s (\`" "$out"
has "fx-pos.awk: exactly one hit" "1 hit(s) in 1 file(s)" "$out"
out=$(cd "$FXD" && python3 "$LINT" fx-shell.sh 2>&1); rc=$?
is  "fx-shell.sh: exit 1 (hits)" 1 "$rc"
has "fx-shell.sh: \`dl (\` in the first awk program (line 5)" "fx-shell.sh:5: \`dl (\`" "$out"
has "fx-shell.sh: \`o (\` after -v/-F option words (line 6)" "fx-shell.sh:6: \`o (\`" "$out"
has "fx-shell.sh: exactly two hits" "2 hit(s) in 1 file(s)" "$out"
hasnt "fx-shell.sh: no hit from a shell echo of \"foo (bar)\"" "fx-shell.sh:2:" "$out"
hasnt "fx-shell.sh: no hit from the shell function \`foo ()\`" "fx-shell.sh:3:" "$out"
hasnt "fx-shell.sh: no hit from a call written without a blank" "fx-shell.sh:7:" "$out"
out=$(cd "$FXD" && python3 "$LINT" fx-pos-field.awk 2>&1); rc=$?
is  "fx-pos-field.awk: exit 1 (hits)" 1 "$rc"
has "fx-pos-field.awk: a field by variable, \`\$i (\`" "fx-pos-field.awk:1: \`i (\`" "$out"
has "fx-pos-field.awk: a field by special variable, \`\$NF (\`" "fx-pos-field.awk:1: \`NF (\`" "$out"
has "fx-pos-field.awk: exactly two hits" "2 hit(s) in 1 file(s)" "$out"
for f in fx-neg.awk fx-neg2.awk fx-neg-field.awk; do
  out=$(cd "$FXD" && python3 "$LINT" "$f" 2>&1); rc=$?
  is  "$f: exit 0 (none of its forms is a hit)" 0 "$rc"
  has "$f: zero hits" "0 hit(s) in 1 file(s)" "$out"
done

if [ "${1:-}" = "--files" ]; then
  shift
  [ "$#" -gt 0 ] || { nok "--files was given files" "at least one file" "none"; finish; }
  echo "== the files given ($#)"
else
  # The repo files whose awk runs on a router: the package and its scripts, and the test harness
  # files that run there (router-sampler, prerm-drain, fm2-wan-bounce, and the router-side boot
  # sampler and kill-switch candidates in tests/lib). Not listed: accessories/gl-switch.d/tailscale.sh
  # and install-gl-tailscale-fix.sh, whose only awk is `{print $1}` and `{print $NF}`.
  set -- "$TD"/src/scripts/* "$TD"/src/hotplug/* "$TD"/src/init.d/* \
    "$TD/pkg/postinst" "$TD/pkg/prerm" "$TD/pkg/postrm" \
    "$TD/tests/lib/router-sampler.sh" "$TD/tests/lib/boot-sampler.sh" "$TD/tests/lib/candidates.sh" \
    "$TD/tests/prerm-drain.sh" "$TD/tests/fm2-wan-bounce.sh"
  echo "== the repo files listed as running awk on a router ($#)"
fi
missing=0
for f in "$@"; do
  [ -f "$f" ] || { nok "listed file exists" "$f" "missing"; missing=1; }
done
[ "$missing" = 0 ] && ok "all $# listed files exist"

out=$(python3 "$LINT" "$@" 2>&1); rc=$?
is  "lint over the file set: exit 0" 0 "$rc"
has "lint over the file set: zero hits in all $# files" "0 hit(s) in $# file(s)" "$out"
[ "$rc" = 0 ] || printf '%s\n' "$out" | sed "s|$TD/||; s/^/       /"

# Every program read to its end: the linter's own extractor finds the programs, a canary line in the
# trapped form is appended to each, and each canary must come back as a hit. A file that shows awk
# with a quote on some non-comment line but yields no program at all fails too (an independent count).
# -B: importing the linter as a module must not leave a __pycache__ in tests/lib.
res=$(python3 -B - "$LINT" "$TD" "$@" <<'PY'
import importlib.util, os, re, sys
spec = importlib.util.spec_from_file_location("awk_busybox_lint", sys.argv[1])
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)
td = sys.argv[2]
CANARY = "{ zzcanary = zzcanary (1) }"
total = 0
for p in sys.argv[3:]:
    rel = os.path.relpath(p, td)
    try:
        text = open(p, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print(f"FAIL {rel}: unreadable ({e})")
        continue
    progs = [(1, text)] if p.endswith(".awk") else list(lint.awk_bodies_from_shell(text))
    loose = sum(1 for ln in text.splitlines()
                if re.search(r"(^|[^A-Za-z0-9_./-])awk\b", ln) and "'" in ln and not ln.lstrip().startswith("#"))
    if loose and not progs:
        print(f"FAIL {rel}: {loose} line(s) show awk with a quote, but the lint finds no awk program")
        continue
    lost = []
    for start, body in progs:
        hits = []
        lint.lint_body(p, start, body + "\n" + CANARY + "\n", hits)
        if not any(h[2] == "zzcanary" for h in hits):
            lost.append(start)
    total += len(progs)
    if lost:
        print(f"FAIL {rel}: the lint loses track inside the awk program(s) starting at line(s) {lost}")
    elif progs:
        print(f"ok   {rel}: {len(progs)} awk program(s), each read to its end")
    else:
        print(f"ok   {rel}: no inline awk program")
print(f"# {total} awk program(s) read")
PY
); rc=$?
printf '%s\n' "$res"
n=$(printf '%s\n' "$res" | grep -c '^ok   '); oks=$((oks + n))
n=$(printf '%s\n' "$res" | grep -c '^FAIL '); fails=$((fails + n))
if [ "$rc" != 0 ] || [ "$n" -gt 0 ]; then
  [ "$rc" = 0 ] || nok "canary helper ran" "exit 0" "exit $rc"
else
  ok "every canary was found"
fi
finish
