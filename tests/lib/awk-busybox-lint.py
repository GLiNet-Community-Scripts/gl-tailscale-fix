#!/usr/bin/env python3
"""awkconcat-lint — find `name (expr)` concatenations that BusyBox 1.33 awk mis-parses as calls.

On the GL 4.9/4.11 targets (BusyBox v1.33.2) `s = s ("x")` fails at RUN time with "Call to
undefined function", while BusyBox 1.36 (desktop), gawk and mawk read it as concatenation. The
failure appears only when the line executes, so a parse test cannot find it; this lint reads the
source.

Scope: every awk program body in the given files — whole *.awk files, and in shell files every
single-quoted string that follows an `awk` command word (after any -v/-F/-f option words). Inside a
body, awk string literals ("...", with backslash escapes) and regex literals after `~`/`!~`/`(`/`,`
are skipped, as are comments. A hit is IDENT, one or more blanks, then "(", where IDENT is not an
awk keyword or builtin and is not the name in a `function IDENT (` definition. An IDENT right after
`$` counts too: 1.33 fails the same way on `$i ("x")` and `$NF ("x")`, while `$1 ("x")` (no IDENT)
works; checked against a host build of the 1.33.2 awk.c that GL 4.9.0 ships.

Usage: awkconcat-lint.py FILE... ; exit 1 when any hit is found, 0 otherwise.
"""
import re
import sys

KEYWORDS = {
    "if", "else", "while", "for", "do", "in", "return", "function", "func", "print", "printf",
    "getline", "next", "nextfile", "exit", "delete", "break", "continue", "BEGIN", "END",
    # builtins: a blank before "(" is legal for these and not a concatenation
    "length", "substr", "index", "split", "sub", "gsub", "match", "sprintf", "tolower", "toupper",
    "int", "sqrt", "exp", "log", "sin", "cos", "atan2", "rand", "srand", "system", "close",
    "fflush", "and", "or", "xor", "compl", "lshift", "rshift", "strftime", "systime",
}
IDENT_PAREN = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)[ \t]+\(")


def strip_literals(body):
    """Blank out awk string literals, regex literals and comments, keeping line structure."""
    out = []
    i, n = 0, len(body)
    prev_sig = ""  # last significant non-blank char, to tell a regex '/' from division
    while i < n:
        c = body[i]
        if c == "#":
            while i < n and body[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if c == '"':
            out.append("\x01")
            i += 1
            while i < n and body[i] != '"':
                if body[i] == "\\" and i + 1 < n:
                    out.append("\x01\x01")
                    i += 2
                    continue
                out.append("\n" if body[i] == "\n" else "\x01")
                i += 1
            out.append("\x01")
            i += 1
            prev_sig = '"'
            continue
        if c == "/" and prev_sig in ("", "(", ",", "~", "!", "{", ";", "&", "|", "\n", "="):
            out.append("\x01")
            i += 1
            while i < n and body[i] != "/":
                if body[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                if body[i] == "[":  # bracket expression may contain '/'
                    while i < n and body[i] != "]":
                        out.append(" ")
                        i += 1
                out.append(" " if body[i] != "\n" else "\n")
                i += 1
            out.append(" ")
            i += 1
            prev_sig = "/"
            continue
        out.append(c)
        if not c.isspace():
            prev_sig = c
        elif c == "\n":
            prev_sig = "\n"
        i += 1
    return "".join(out)


def awk_bodies_from_shell(text):
    """Yield (start_line, body) for every single-quoted string following an awk command word."""
    for m in re.finditer(r"(?<![A-Za-z0-9_./-])awk\b", text):
        j = m.end()
        # skip option words: -v x=y, -F sep, -f file (quoted or not), line continuations
        while True:
            k = j
            while k < len(text) and text[k] in " \t\\\n":
                k += 1
            if k < len(text) and text[k] == "-":
                # consume the option word and, for -v/-F/-f given apart, its argument word
                opt = re.match(r"-[vFf]\s*|-[A-Za-z-]+", text[k:])
                k2 = k + (opt.end() if opt else 1)
                if opt and opt.group(0).strip() in ("-v", "-F", "-f"):
                    while k2 < len(text) and text[k2] in " \t":
                        k2 += 1
                # consume one shell word (possibly quoted)
                if k2 < len(text) and text[k2] in "'\"":
                    q = text[k2]
                    e = text.find(q, k2 + 1)
                    k2 = len(text) if e < 0 else e + 1
                else:
                    while k2 < len(text) and not text[k2].isspace():
                        if text[k2] in "'\"":
                            q = text[k2]
                            e = text.find(q, k2 + 1)
                            k2 = len(text) if e < 0 else e + 1
                        else:
                            k2 += 1
                j = k2
                continue
            j = k
            break
        if j < len(text) and text[j] == "'":
            e = text.find("'", j + 1)
            if e > j:
                yield text.count("\n", 0, j + 1) + 1, text[j + 1:e]


def lint_body(path, start_line, body, hits):
    clean = strip_literals(body)
    for ln_off, line in enumerate(clean.split("\n")):
        for m in IDENT_PAREN.finditer(line):
            name = m.group(1)
            if name in KEYWORDS:
                continue
            before = line[:m.start()].rstrip()
            if before.endswith("function") or before.endswith("func"):
                continue
            orig = body.split("\n")[ln_off] if ln_off < len(body.split("\n")) else ""
            hits.append((path, start_line + ln_off, name, orig.strip()))


def main(paths):
    hits = []
    for p in paths:
        text = open(p, encoding="utf-8", errors="replace").read()
        if p.endswith(".awk"):
            lint_body(p, 1, text, hits)
        else:
            for start, body in awk_bodies_from_shell(text):
                lint_body(p, start, body, hits)
    for path, line, name, orig in hits:
        print(f"{path}:{line}: `{name} (` — {orig[:120]}")
    print(f"awkconcat-lint: {len(hits)} hit(s) in {len(paths)} file(s)", file=sys.stderr)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
