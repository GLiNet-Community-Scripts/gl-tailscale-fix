#!/bin/sh
# Unit test for ts_domain_clean() in src/scripts/ts-fix-reapply.
# Pure string logic — runs on the dev laptop, no router required.
#   sh tests/unit/test-domain-clean.sh
#
# The function is extracted from the real source between its marker comments rather than
# duplicated here, so this tests shipping code. If the markers or the name change, extraction
# yields nothing and every case fails loudly — which is the intended signal.

SRC="$(dirname "$0")/../../src/scripts/ts-fix-reapply"

eval "$(awk '/^# ---8<--- ts_domain_clean/,/^# ---8<--- end ts_domain_clean/' "$SRC")"

if ! command -v ts_domain_clean >/dev/null 2>&1; then
    echo "FAIL: could not extract ts_domain_clean from $SRC (markers missing or renamed?)"
    exit 1
fi

fails=0
check() {
    # $1 = description, $2 = input, $3 = expected output
    got="$(ts_domain_clean "$2")"
    if [ "$got" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n     input=[%s]\n     want =[%s]\n     got  =[%s]\n' "$1" "$2" "$3" "$got"
        fails=$((fails + 1))
    fi
}

check "4.9 replace form (bare suffix)"        "rove-lenok.ts.net"          ""
check "4.8 append form"                       "rove-lenok.ts.net lan"      "lan"
check "4.8 append, custom local domain"       "rove-lenok.ts.net home"     "home"
check "GL bare ts.net fallback alone"         "ts.net"                     ""
check "GL bare ts.net fallback, appended"     "ts.net lan"                 "lan"
check "already clean"                         "lan"                        "lan"
check "already clean, multi-token"            "lan guest wan"              "lan guest wan"
check "empty input"                           ""                           ""
check "duplicate tailnet tokens"              "a.ts.net b.ts.net lan"      "lan"
check "suffix in the middle"                  "lan rove-lenok.ts.net wan"  "lan wan"
check "lookalike domain is NOT stripped"      "notts.net lan"              "notts.net lan"
check "lookalike subdomain is NOT stripped"   "ts.net.example.com lan"     "ts.net.example.com lan"

[ "$fails" -eq 0 ] && { echo "PASS (all cases)"; exit 0; }
echo "$fails case(s) failed"; exit 1
