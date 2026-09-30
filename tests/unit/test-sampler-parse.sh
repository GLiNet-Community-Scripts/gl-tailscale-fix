#!/bin/sh
# Unit test for the parsers of tests/lib/router-sampler.sh and for fm2-wan-bounce.sh's analyze of
# the CSV it writes. Laptop only, no router:
#   sh tests/unit/test-sampler-parse.sh          (also runs under: busybox ash)
#
# The parse block is EXTRACTED from the sampler between its "---8<--- sampler-parse" markers, and
# the zone classifier from the engine between its "---8<--- ks-classify" markers, so these cases
# bind to shipping code. Every parser is asserted in BOTH directions: a fixture that must read
# present/protected and one that must read absent/open. The last section runs the whole sampler the
# way the suite runs it on a router — fed to `sh -s` on stdin — with fixture-backed fakes defined
# ahead of it in the same stream, which also proves that no command in it consumes its stdin.
TD=$(cd "$(dirname "$0")/../.." && pwd)
SAMPLER="$TD/tests/lib/router-sampler.sh"
ENGINE="$TD/src/scripts/ts-fix-ks"
FM2="$TD/tests/fm2-wan-bounce.sh"
T="${TMPDIR:-/tmp}/test-sampler-parse.$$"
mkdir -p "$T/bin" "$T/fx" || { echo "FAIL: cannot create $T"; exit 1; }
trap 'rm -rf "$T"' EXIT
fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) nok "$1" "text containing: $2" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) nok "$1" "text NOT containing: $2" "$3" ;; *) ok "$1" ;; esac; }

# block <start-regex> <end-regex> < file -> the block ONLY when both markers are present (else
# nothing): an end marker lost to an edit must never turn this into "eval the rest of the file".
block() {
  awk -v s="$1" -v e="$2" '!on && $0 ~ s { on = 1 } on { buf = buf $0 "\n" }
    on && $0 ~ e { printf "%s", buf; done = 1; exit } END { exit !done }'
}
eval "$(block '^# ---8<--- sampler-parse' '^# ---8<--- end sampler-parse' < "$SAMPLER")"
for f in zone_parse zone_list_parse net4_parse addr4_first watch_derive layers_parse classifier_block; do
  command -v "$f" >/dev/null 2>&1 || { echo "FAIL: $f not extracted from $SAMPLER (markers moved?)"; exit 1; }
done
[ -n "$LAYERS_HDR" ] || { echo "FAIL: LAYERS_HDR not extracted"; exit 1; }
eval "$(classifier_block < "$ENGINE")"
command -v ks_zone_class >/dev/null 2>&1 || { echo "FAIL: engine classifier not extracted"; exit 1; }

rl() { printf '%s:\t%s\n' "$1" "$2"; }
# layer <stream> -> one layers_parse row; lget <row> <column> -> value
layer() {
  printf '%s\n' "$1" | WATCH="${W:-wan zerotier wgclient}" NET_lan="${NL:-192.168.60.0/24}" \
    NET_guest="${NG:-192.168.160.0/24}" NET_iot="${NI:-none}" layers_parse
}
lget() {
  printf '%s\n%s\n' "$LAYERS_HDR" "$1" | awk -F, -v n="$2" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == n) c = i; next }
    { print (c ? $c : "NOCOL:" n) }'
}
stream() {  # $1 R4  $2 R6  $3 T4  $4 T6  $5 F4  $6 F6 ; "FAIL" = failed dump ; "SKIP" = not sampled
  for s in R4:"$1" R6:"$2" T4:"$3" T6:"$4" F4:"$5" F6:"$6"; do
    n=${s%%:*}; body=${s#*:}
    [ "$body" = SKIP ] && continue
    echo "@@$n"
    if [ "$body" = FAIL ]; then echo "@@rc 1"; else [ -n "$body" ] && printf '%s\n' "$body"; echo "@@rc 0"; fi
  done
}

# ---- fixtures (the brief's GL 4.9.0 list, verbatim but for the addresses, which are renumbered:
#      Beryl 7, Custom Exit Node engaged, 2026-09-29)
R4_ENGAGED=$(
  rl 0 "from all lookup local"
  rl 0 "from all to 192.168.60.0/24 lookup main"
  rl 0 "from all to 192.168.200.0/24 lookup main"
  rl 0 "from 192.168.160.0/24 lookup main"
  rl 1 "from all iif lo lookup 16800"
  rl 50 "from all to 100.100.100.100 lookup 52"
  rl 5210 "from all fwmark 0x80000/0xff0000 lookup main"
  rl 5230 "from all fwmark 0x80000/0xff0000 lookup default"
  rl 5250 "from all fwmark 0x80000/0xff0000 unreachable"
  rl 5269 "from all fwmark 0x80000/0x80000 lookup main"
  rl 5270 "from all lookup 52"
  rl 32766 "from all lookup main"
  rl 32767 "from all lookup default")
R4_IDLE=$(printf '%s\n' "$R4_ENGAGED" | grep -v 'from 192.168.160.0/24 lookup main' | grep -v '^5269:')
OURS=$(
  rl 5279 "from all iif br-lan lookup 100"
  rl 5279 "from all iif br-guest lookup 100"
  rl 5279 "from all iif br-iot [detached] lookup 100")
R6=$(rl 0 "from all lookup local"; rl 5270 "from all lookup 52"; rl 32766 "from all lookup main")
IPT_PROT='*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:zone_lan_forward - [0:0]
:zone_guest_forward - [0:0]
:zone_iot_forward - [0:0]
-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A zone_lan_forward -m comment --comment "!fw3: Zone lan to tailscale0 forwarding policy" -j zone_tailscale0_dest_ACCEPT
-A zone_lan_forward -m comment --comment "!fw3: Zone lan to wgserver forwarding policy" -j zone_wgserver_dest_ACCEPT
-A zone_lan_forward -m conntrack --ctstate DNAT -m comment --comment "!fw3: Accept port forwards" -j ACCEPT
-A zone_guest_forward -m comment --comment "!fw3: Zone guest to ovpnserver forwarding policy" -j zone_ovpnserver_dest_ACCEPT
COMMIT'
IPT_FLUSH='*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT'
IPT_JUMP=$(printf '%s\n' "$IPT_PROT" | sed '$d'; echo '-A zone_lan_forward -m comment --comment "!fw3: Zone lan to wan forwarding policy" -j zone_wan_dest_ACCEPT'
           echo '-A zone_guest_forward -j zone_wgclient_dest_ACCEPT'; echo COMMIT)

echo "== layers_parse: rule layer"
row=$(layer "$(stream "$R4_IDLE
$OURS" "$R6" "unreachable default" "unreachable default dev lo metric 1024 pref medium" "$IPT_PROT" "$IPT_PROT")")
is "ours present: r_lan4"                             1 "$(lget "$row" r_lan4)"
is "ours present: [detached] br-iot counts"           1 "$(lget "$row" r_iot4)"
is "ours present: t100_4"                             1 "$(lget "$row" t100_4)"
is "v6 unreachable default with trailing text"        1 "$(lget "$row" t100_6)"
is "no GL from rule: sh_guest4 = 0"                   0 "$(lget "$row" sh_guest4)"
is "no GL from rule: glfrom_guest4 = 0"               0 "$(lget "$row" glfrom_guest4)"
FOREIGN=$(rl 5279 "from all iif br-lan lookup 1002"; rl 5279 "from all iif br-guest lookup 1002"
          rl 5279 "from all iif br-lan2 lookup 100"; rl 5280 "from all iif br-iot lookup 100")
row=$(layer "$(stream "$R4_IDLE
$FOREIGN" "$FOREIGN" "" "" "$IPT_PROT" "$IPT_PROT")")
is "foreign lookup 1002 only: r_lan4 ABSENT"          0 "$(lget "$row" r_lan4)"
is "foreign lookup 1002 only: r_guest4 ABSENT"        0 "$(lget "$row" r_guest4)"
is "legacy 5280 lookup 100 is not the 5279 layer"     0 "$(lget "$row" r_iot4)"
is "foreign lookup 1002 only: r_lan6 ABSENT"          0 "$(lget "$row" r_lan6)"
is "empty table 100: t100_4 = 0"                      0 "$(lget "$row" t100_4)"
row=$(layer "$(stream "$OURS" "" "unreachable 192.0.2.0/24" "" "$IPT_PROT" "$IPT_PROT")")
is "table 100 with only a non-default unreachable: t100_4 = 0" 0 "$(lget "$row" t100_4)"
row=$(layer "$(stream "$R4_ENGAGED" "$R6" "" "" "$IPT_PROT" "$IPT_PROT")")
is "brief fixture: GL from rule present"              1 "$(lget "$row" glfrom_guest4)"
is "brief fixture: guest shadowed"                    1 "$(lget "$row" sh_guest4)"
is "brief fixture: lan not shadowed (to-rule only)"   0 "$(lget "$row" sh_lan4)"
row=$(layer "$(stream "$R4_ENGAGED
$OURS" "$R6" "unreachable default" "" "$IPT_PROT" "$IPT_PROT")")
is "ours present but shadowed: r_guest4 = 1"          1 "$(lget "$row" r_guest4)"
is "ours present but shadowed: sh_guest4 = 1"         1 "$(lget "$row" sh_guest4)"
SW=$(printf '%s\n' "$R4_ENGAGED" | grep -v 'from 192.168.160.0/24 lookup main'; rl 0 "from all to 192.168.160.0/24 lookup main")
row=$(layer "$(stream "$SW
$OURS" "$R6" "unreachable default" "" "$IPT_PROT" "$IPT_PROT")")
is "swapped: to_guest4 = 1"                           1 "$(lget "$row" to_guest4)"
is "swapped: GL from rule gone"                       0 "$(lget "$row" glfrom_guest4)"
is "swapped: not shadowed"                            0 "$(lget "$row" sh_guest4)"
row=$(NG=192.168.160.0/23 layer "$(stream "$(rl 0 "from 192.168.160.0/23 lookup main")" "" "" "" "$IPT_PROT" "$IPT_PROT")")
is "/23 guest network: GL rule recognised"            1 "$(lget "$row" glfrom_guest4)"
row=$(NG=192.168.160.0/23 layer "$(stream "$(rl 0 "from 192.168.176.0/24 lookup main")" "" "" "" "$IPT_PROT" "$IPT_PROT")")
is "/23 guest network: a disjoint /24 is no shadow"   0 "$(lget "$row" sh_guest4)"
row=$(layer "$(stream "" "$(rl 0 "from 2001:db8:5::/64 lookup main")" "" "" "$IPT_PROT" "$IPT_PROT")")
is "v6 source rule shadows every bridge (lan6)"       1 "$(lget "$row" sh_lan6)"
is "v6 source rule shadows every bridge (iot6)"       1 "$(lget "$row" sh_iot6)"
row=$(layer "$(stream FAIL "" "unreachable default" "" "$IPT_PROT" "$IPT_PROT")")
is "failed ip -4 rule: r_lan4 = ERR, never 0"         ERR "$(lget "$row" r_lan4)"
is "failed ip -4 rule: t100_4 = ERR"                  ERR "$(lget "$row" t100_4)"
BH=$(rl 5280 "from all iif br-lan blackhole"; rl 9920 "from all iif br-guest blackhole")
row=$(layer "$(stream "$BH" "" "" "" "$IPT_PROT" "$IPT_PROT")")
is "GL 5280 blackhole -> gl_ks4 = 1"                  1 "$(lget "$row" gl_ks4)"
is "GL 9920 blackhole counted"                        1 "$(lget "$row" gl9920_4)"
row=$(layer "$(stream "$OURS" "" "" "" "$IPT_PROT" "$IPT_PROT")")
is "no GL blackhole: gl_ks4 = 0"                      0 "$(lget "$row" gl_ks4)"

echo "== layers_parse: zone layer (netfilter)"
row=$(layer "$(stream "" "" "" "" "$IPT_PROT" "$IPT_PROT")")
is "policy DROP + chain + no jump: pol4"              DROP "$(lget "$row" pol4)"
is "policy DROP + chain + no jump: ch_lan4"           1 "$(lget "$row" ch_lan4)"
is "VPN SERVER jumps + DNAT accept not counted: j_lan4" 0 "$(lget "$row" j_lan4)"
is "guest -> ovpnserver (server) not counted: j_guest4" 0 "$(lget "$row" j_guest4)"
row=$(layer "$(stream "" "" "" "" "$IPT_FLUSH" "$IPT_FLUSH")")
is "flush: pol4 = ACCEPT"                             ACCEPT "$(lget "$row" pol4)"
is "flush: ch_lan6 = 0"                               0 "$(lget "$row" ch_lan6)"
row=$(layer "$(stream "" "" "" "" "$IPT_JUMP" "$IPT_PROT")")
is "jump into watched wan: j_lan4 = 1"                1 "$(lget "$row" j_lan4)"
is "jump into watched wgclient: j_guest4 = 1"         1 "$(lget "$row" j_guest4)"
row=$(W="wan" layer "$(stream "" "" "" "" "$IPT_JUMP" "$IPT_PROT")")
is "wgclient outside the watched set: j_guest4 = 0"   0 "$(lget "$row" j_guest4)"
row=$(layer "$(stream "" "" "" "" FAIL FAIL)")
is "failed iptables-save: pol4 = ERR"                 ERR "$(lget "$row" pol4)"
row=$(layer "$(stream "" "" "" "" SKIP SKIP)")
is "fw4 (netfilter not sampled): pol4 = NA"           NA "$(lget "$row" pol4)"
is "fw4: j_guest6 = NA"                               NA "$(lget "$row" j_guest6)"
is "row width = header width" "$(printf '%s\n' "$LAYERS_HDR" | awk -F, '{ print NF }')" "$(printf '%s\n' "$row" | awk -F, '{ print NF }')"

echo "== zone_parse (UCI half of the zone layer; iot pairs count)"
UCIFW="firewall.@zone[0]=zone
firewall.@zone[0].name='lan'
firewall.@zone[0].network='lan'
firewall.@zone[1]=zone
firewall.@zone[1].name='wan'
firewall.@zone[1].network='wan' 'wan6'
firewall.iot=zone
firewall.iot.name='iot'
firewall.iot.network='iot'
firewall.guest=zone
firewall.guest.name='guest'
firewall.guest.network='guest'
firewall.wgs=zone
firewall.wgs.name='wgserver'
firewall.wgs.network='wgserver'
firewall.wgc=zone
firewall.wgc.name='wgclient'
firewall.wgc.network='wgclient2'
firewall.ts=zone
firewall.ts.name='tailscale0'
firewall.ts.network='tailscale0'
firewall.@forwarding[0]=forwarding
firewall.@forwarding[0].src='lan'
firewall.@forwarding[0].dest='wan'
firewall.@forwarding[0].enabled='0'
firewall.gw=forwarding
firewall.gw.src='guest'
firewall.gw.dest='wan'
firewall.gw.enabled='0'
firewall.iw=forwarding
firewall.iw.src='iot'
firewall.iw.dest='wan'
firewall.iw.enabled='0'
firewall.l2t=forwarding
firewall.l2t.src='lan'
firewall.l2t.dest='tailscale0'"
is "all recorded pairs severed (incl. iot): nothing open" "3,0,0,0,0,1" "$(printf '%s\n' "$UCIFW" | zone_parse "lan:wan guest:wan iot:wan")"
is "iot pair re-enabled: counted, and split to iot" "3,1,0,0,1,1" "$(printf '%s\n' "$UCIFW" | sed "s/^firewall.iw.enabled='0'/firewall.iw.enabled='1'/" | zone_parse "lan:wan guest:wan iot:wan")"
is "absent enabled option = enabled = open (lan)" "3,1,1,0,0,1" "$(printf '%s\n' "$UCIFW" | grep -v "^firewall.@forwarding\[0\].enabled" | zone_parse "lan:wan guest:wan iot:wan")"
is "recorded pair with no forwarding at all = open" "1,1,0,1,0,1" "$(printf '%s\n' "$UCIFW" | zone_parse "guest:wgclient")"
is "no lan -> tailscale0: lan2ts = 0" "0,0,0,0,0,0" "$(printf '%s\n' "$UCIFW" | grep -v '^firewall.l2t' | zone_parse "")"

echo "== zone_list_parse / net4_parse / addr4_first"
is "zone list: wan networks" "wan|wan wan6" "$(printf '%s\n' "$UCIFW" | zone_list_parse | grep '^wan|')"
is "zone list: forwardings ignored" 7 "$(printf '%s\n' "$UCIFW" | zone_list_parse | grep -c .)"
is "ipcalc output -> network/prefix (/23)" 192.168.160.0/23 "$(printf 'IP=192.168.161.1\nNETWORK=192.168.160.0\nPREFIX=23\n' | net4_parse)"
is "ipcalc output without PREFIX -> nothing" "" "$(printf 'NETWORK=192.168.160.0\n' | net4_parse)"
is "first v4 address of a bridge" 192.168.160.1/24 "$(printf '9: br-guest    inet 192.168.160.1/24 brd 192.168.160.255 scope global br-guest\\ x\n9: br-guest    inet 10.0.0.1/8 scope global br-guest\\ x\n' | addr4_first)"
is "no address -> nothing" "" "$(printf '' | addr4_first)"

echo "== watch_derive (the ENGINE's classifier)"
# CLS_OK is read by the extracted watch_derive.
# shellcheck disable=SC2034
CLS_OK=1; watch_derive "$UCIFW" "lan:wan guest:customx"
has "uplink wan watched"                       " wan " " $WATCH "
has "GL wgclient (vpnclient) watched"          " wgclient " " $WATCH "
has "a recorded sidecar dest is watched"       " customx " " $WATCH "
hasnt "VPN server wgserver NOT watched"        " wgserver " " $WATCH "
hasnt "tailscale0 NOT watched"                 " tailscale0 " " $WATCH "
is "source zones present"                      "lan iot guest" "$ZONES"
# shellcheck disable=SC2034
CLS_OK=0; watch_derive "$UCIFW" ""
has "fallback: over-inclusive (wgserver)"      " wgserver " " $WATCH "
hasnt "fallback: never a source zone"          " lan " " $WATCH "
hasnt "fallback: never tailscale0"             " tailscale0 " " $WATCH "

echo "== classifier_block: only a COMPLETE block is ever evaluated (I3)"
printf '%s\n' '#!/bin/sh' 'echo before' '# ---8<--- ks-classify' 'ks_zone_class() { echo uplink; }' \
  '# ---8<--- end ks-classify' 'echo AFTER-THE-BLOCK' > "$T/eng-ok"
out=$(classifier_block < "$T/eng-ok"); rc=$?
is "complete block: rc 0" 0 "$rc"
has "complete block: the function is in it" "ks_zone_class()" "$out"
hasnt "complete block: nothing after the end marker" "AFTER-THE-BLOCK" "$out"
printf '%s\n' '#!/bin/sh' '# ---8<--- ks-classify' 'ks_zone_class() { echo uplink; }' \
  "touch '$T/SENTINEL'" '# ---8<--- end ks-classify-RENAMED-by-an-edit' > "$T/eng-noend"
out=$(classifier_block < "$T/eng-noend"); rc=$?
is "end marker renamed: rc 1" 1 "$rc"
is "end marker renamed: NOTHING is printed (so nothing can be eval'd)" "" "$out"
printf '%s\n' '#!/bin/sh' '# ---8<--- ks-classify' 'ks_zone_class() { echo uplink; }' "touch '$T/SENTINEL'" > "$T/eng-eof"
out=$(classifier_block < "$T/eng-eof"); rc=$?
is "end marker missing (EOF): rc 1 and nothing printed" "1:" "$rc:$out"

echo "== layers_parse raw log: the raw lines behind a CHANGE of the columns (M9)"
RAWF="$T/l.raw"; rm -f "$RAWF" "$RAWF.sig"
st1=$(stream "$R4_IDLE
$OURS" "$R6" "unreachable default" "" "$IPT_PROT" "$IPT_PROT")
printf '%s\n' "$st1" | WATCH=wan NET_lan=192.168.60.0/24 NET_guest=192.168.160.0/24 NET_iot=none \
  RAWLOG="$RAWF" STAMP=100 layers_parse >/dev/null
is "first sample: one dump" 1 "$(grep -c '^@@ ' "$RAWF")"
has "the dump holds our 5279 rule raw" "R4 5279:" "$(cat "$RAWF")"
has "the dump holds the FORWARD policy raw" "F4 :FORWARD DROP" "$(cat "$RAWF")"
printf '%s\n' "$st1" | WATCH=wan NET_lan=192.168.60.0/24 NET_guest=192.168.160.0/24 NET_iot=none \
  RAWLOG="$RAWF" STAMP=101 layers_parse >/dev/null
is "same columns again: no new dump" 1 "$(grep -c '^@@ ' "$RAWF")"
printf '%s\n' "$(stream "$R4_ENGAGED
$OURS" "$R6" "unreachable default" "" "$IPT_PROT" "$IPT_PROT")" \
  | WATCH=wan NET_lan=192.168.60.0/24 NET_guest=192.168.160.0/24 NET_iot=none RAWLOG="$RAWF" STAMP=102 layers_parse >/dev/null
is "a column changed (GL from rule): a second dump" 2 "$(grep -c '^@@ ' "$RAWF")"
has "the second dump names the rule behind the new sh_guest4" "from 192.168.160.0/24 lookup main" "$(sed -n '/^@@ 102 /,$p' "$RAWF")"

echo "== router-sampler.sh end to end, stdin-fed like on the router (sh -s)"
printf '%s\n%s\n' "$R4_ENGAGED" "$OURS" > "$T/fx/r4"
printf '%s\n' "$R6" > "$T/fx/r6"
printf 'unreachable default\n' > "$T/fx/t4"
printf '%s\n' "$IPT_PROT" > "$T/fx/ipt4"
printf '%s\n' "$IPT_FLUSH" > "$T/fx/ipt6"
printf '%s\n' "$UCIFW" > "$T/fx/uci"
for c in iptables-save:ipt4 ip6tables-save:ipt6; do
  printf '#!/bin/sh\ncat "%s"\n' "$T/fx/${c#*:}" > "$T/bin/${c%%:*}"; chmod +x "$T/bin/${c%%:*}"
done
cat > "$T/fakes.sh" <<EOF
ip() {
  case "\$*" in
    "-4 rule") cat "$T/fx/r4" ;;
    "-6 rule") cat "$T/fx/r6" ;;
    "-4 route show table 100") cat "$T/fx/t4" ;;
    "-6 route show table 100") : ;;
    "-4 -o addr show dev br-lan") echo "7: br-lan    inet 192.168.60.1/24 scope global br-lan" ;;
    "-4 -o addr show dev br-guest") echo "9: br-guest    inet 192.168.160.1/24 scope global br-guest" ;;
    "-4 route show default") echo "default via 192.168.200.254 dev apcli0" ;;
    *) return 1 ;;
  esac
}
uci() {
  case "\$*" in
    "show firewall") cat "$T/fx/uci" ;;
    "-q get ts-fix.settings.ks_severed") echo "lan:wan guest:wan iot:wan" ;;
    "-q get ts-fix.settings.kill_switch") echo 1 ;;
    "-q get tailscale.settings.exit_node_ip") echo 100.96.0.69 ;;
    *) return 1 ;;
  esac
}
pgrep() { return 1; }
# Adversarial on purpose: this fake DRAINS its stdin, so if the sampler ever called ipcalc without
# </dev/null it would swallow the rest of the stdin-fed script and the loop below would never run.
fake_ipcalc() { cat >/dev/null; case "\$1" in */24) printf 'NETWORK=%s.0\nPREFIX=24\n' "\${1%.*}" ;; *) return 1 ;; esac; }
EOF
for shell in sh "busybox ash"; do
  rm -rf "$T/out"
  { cat "$T/fakes.sh"; cat "$SAMPLER"; } | PATH="$T/bin:$PATH" DURATION=3 INTERVAL=1 LABEL=ut OUT="$T/out" \
    KS_ENGINE="$ENGINE" IPCALC=fake_ipcalc SWAP_MARK="$T/nomark" $shell -s 2>"$T/err"
  # shellcheck disable=SC2012  # one file the sampler named itself
  csv=$(ls "$T"/out/*-ut.csv 2>/dev/null | head -n 1)
  [ -n "$csv" ] || { nok "[$shell] sampler wrote a CSV" "a CSV" "none: $(cat "$T/err")"; continue; }
  hdr=$(head -n 1 "$csv"); r1=$(sed -n 2p "$csv")
  cget() { printf '%s\n%s\n' "$hdr" "$r1" | awk -F, -v n="$1" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == n) c = i; next } { print (c ? $c : "NOCOL") }'; }
  rows=$(awk 'NR > 1' "$csv" | grep -c .)
  if [ "$rows" -ge 2 ]; then ok "[$shell] stdin-fed sampler ran its loop ($rows rows): nothing ate its stdin"
  else nok "[$shell] stdin-fed sampler rows >= 2" ">=2" "$rows ($(cat "$T/err"))"; fi
  is "[$shell] header width = row width" "$(printf '%s\n' "$hdr" | awk -F, '{ print NF }')" "$(printf '%s\n' "$r1" | awk -F, '{ print NF }')"
  is "[$shell] r_guest4 (ours)" 1 "$(cget r_guest4)"
  is "[$shell] sh_guest4 (GL from rule)" 1 "$(cget sh_guest4)"
  is "[$shell] pol6 flushed" ACCEPT "$(cget pol6)"
  is "[$shell] ks_severed_n (iot pair counted)" 3 "$(cget ks_severed_n)"
  is "[$shell] sev_open_n" 0 "$(cget sev_open_n)"
  is "[$shell] watch derived by the engine" "wan wgclient" "$(cget watch)"
  is "[$shell] nets4" "lan=192.168.60.0/24 guest=192.168.160.0/24 iot=none" "$(cget nets4)"
  is "[$shell] zones" "lan iot guest" "$(cget zones)"
  is "[$shell] uci_exit_ip context kept" 100.96.0.69 "$(cget uci_exit_ip)"
  has "[$shell] the raw lines are written beside the CSV" "R4 5279:" "$(cat "${csv%.csv}.raw" 2>/dev/null)"
  is "[$shell] ... once: unchanged columns write no second dump" 1 "$(grep -c '^@@ ' "${csv%.csv}.raw" 2>/dev/null)"
done

for shell in sh "busybox ash"; do
  rm -rf "$T/out2"; rm -f "$T/SENTINEL"
  { cat "$T/fakes.sh"; cat "$SAMPLER"; } | PATH="$T/bin:$PATH" DURATION=2 INTERVAL=1 LABEL=ut2 OUT="$T/out2" \
    KS_ENGINE="$T/eng-noend" IPCALC=fake_ipcalc SWAP_MARK="$T/nomark" $shell -s 2>"$T/err2"
  # shellcheck disable=SC2012  # one file the sampler named itself
  csv2=$(ls "$T"/out2/*-ut2.csv 2>/dev/null | head -n 1)
  w2=$(printf '%s\n%s\n' "$(head -n 1 "$csv2")" "$(sed -n 2p "$csv2")" \
       | awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "watch") c = i; next } { print $c }')
  has "[$shell] engine with a renamed end marker: watch is FALLBACK" "FALLBACK:" "$w2"
  has "[$shell] ... and the sampler says so loudly" "WARNING: engine classifier unavailable" "$(cat "$T/err2")"
  if [ -e "$T/SENTINEL" ]; then nok "[$shell] ... and NOTHING from that engine ran" "no sentinel" "sentinel created"
  else ok "[$shell] ... and NOTHING from that engine ran (no sentinel)"; fi
done

echo "== fm2 start gate: the probe sent to the router requires BOTH layers (concern 5)"
PROBE=$(bash "$FM2" _armed_probe)
has "the probe script is printed" "priority 5279" "$PROBE"
# gate <shell> <r4 file> <r6 file> <table-100 v4 text> <table-100 v6 text> <uci show file> <sidecar>
#   -> the probe's verdict, the probe run exactly as the router gets it (fed to `sh -s`), with
#      ip and uci replaced by fixture-backed functions ahead of it in the same stream
GD="$T/gate"; mkdir -p "$GD"
cat > "$T/gatefakes.sh" <<'FAKES'
ip() {
  case "$*" in
    "-4 rule list priority 5279") cat "$GD/r4" ;;
    "-6 rule list priority 5279") cat "$GD/r6" ;;
    "-4 route show table 100") cat "$GD/t4" ;;
    "-6 route show table 100") cat "$GD/t6" ;;
    *) return 1 ;;
  esac
}
uci() {
  case "$*" in
    "show firewall") cat "$GD/uci" ;;
    "-q get ts-fix.settings.ks_severed") cat "$GD/sev" ;;
    "-q get "*) awk -v k="$3=" 'index($0, k) == 1 { v = substr($0, length(k) + 1); gsub(/\047/, "", v); print v; f = 1 }
                               END { exit !f }' "$GD/uci" ;;
    *) return 1 ;;
  esac
}
FAKES
gate() {
  cp "$2" "$GD/r4"; cp "$3" "$GD/r6"; printf '%s\n' "$4" > "$GD/t4"; printf '%s\n' "$5" > "$GD/t6"
  cp "$6" "$GD/uci"; printf '%s\n' "$7" > "$GD/sev"
  { printf 'GD=%s\n' "$GD"; cat "$T/gatefakes.sh"; printf '%s\n' "$PROBE"; } | $1 -s 2>/dev/null
}
printf '%s\n' "$OURS" > "$T/g-ours"; : > "$T/g-empty"
{ rl 5279 "from all iif br-lan lookup 100"; rl 5279 "from all iif br-guest lookup 100"; } > "$T/g-noiot"
{ rl 5279 "from all iif br-lan lookup 1002"; rl 5279 "from all iif br-guest lookup 1002"
  rl 5279 "from all iif br-iot lookup 1002"; } > "$T/g-1002"
printf '%s\n' "$UCIFW" > "$T/g-uci"
printf '%s\n' "$UCIFW" | sed "s/^firewall.iw.enabled='0'/firewall.iw.enabled='1'/" > "$T/g-uci-open"
SEVALL="lan:wan guest:wan iot:wan"
for shell in sh "busybox ash"; do
  is "[$shell] gate: both layers armed -> 1" 1 \
    "$(gate "$shell" "$T/g-ours" "$T/g-ours" "unreachable default" "unreachable default dev lo metric 1024" "$T/g-uci" "$SEVALL")"
  is "[$shell] gate: br-iot rule missing -> 0" 0 \
    "$(gate "$shell" "$T/g-noiot" "$T/g-ours" "unreachable default" "unreachable default dev lo" "$T/g-uci" "$SEVALL")"
  is "[$shell] gate: only GL lookup 1002 rules -> 0" 0 \
    "$(gate "$shell" "$T/g-1002" "$T/g-ours" "unreachable default" "unreachable default dev lo" "$T/g-uci" "$SEVALL")"
  is "[$shell] gate: v6 rules missing (v4 armed) -> 0" 0 \
    "$(gate "$shell" "$T/g-ours" "$T/g-empty" "unreachable default" "unreachable default dev lo" "$T/g-uci" "$SEVALL")"
  is "[$shell] gate: v6 table 100 empty -> 0" 0 \
    "$(gate "$shell" "$T/g-ours" "$T/g-ours" "unreachable default" "" "$T/g-uci" "$SEVALL")"
  is "[$shell] gate: rules armed, iot pair re-enabled -> 0" 0 \
    "$(gate "$shell" "$T/g-ours" "$T/g-ours" "unreachable default" "unreachable default dev lo" "$T/g-uci-open" "$SEVALL")"
  is "[$shell] gate: rules armed, a recorded pair with no forwarding -> 0" 0 \
    "$(gate "$shell" "$T/g-ours" "$T/g-ours" "unreachable default" "unreachable default dev lo" "$T/g-uci" "$SEVALL lan:wwan")"
  is "[$shell] gate: rules armed, empty sidecar -> 0" 0 \
    "$(gate "$shell" "$T/g-ours" "$T/g-ours" "unreachable default" "unreachable default dev lo" "$T/g-uci" "")"
done

echo "== fm2-wan-bounce.sh analyze"
E="$T/run"
printf 'ts_epoch,ts_iso,v4_ip,v4_class,v6_ip,v6_class\n100,x,,blocked,,blocked\n101,x,,blocked,,blocked\n' > "$E-egress.csv"
FH=$(head -n 1 "$csv")
frow() {  # $1 epoch, then NAME=VALUE overrides on an armed, fully protected row
  _r=$(printf '%s\n' "$FH" | awk -F, -v ep="$1" '{ for (i = 1; i <= NF; i++) {
        v = 0
        if ($i ~ /^r_/ || $i ~ /^t100_/ || $i ~ /^ch_/ || $i == "uci_ks") v = 1
        if ($i ~ /^pol/) v = "DROP"
        if ($i == "ts_epoch") v = ep; if ($i == "zones") v = "lan guest"; if ($i == "watch") v = "wan"
        if ($i == "nets4") v = "lan=192.168.60.0/24"
        printf "%s%s", (i > 1 ? "," : ""), v } print "" }')
  shift
  for kv in "$@"; do
    _r=$(printf '%s\n%s\n' "$FH" "$_r" | awk -F, -v OFS=, -v k="${kv%%=*}" -v v="${kv#*=}" \
         'NR == 1 { for (i = 1; i <= NF; i++) if ($i == k) c = i; next } { $c = v; print }')
  done
  printf '%s\n' "$_r"
}
{ echo "$FH"; frow 100; frow 101 pol4=ACCEPT ch_lan4=0 ch_guest4=0; frow 102 r_lan6=0 r_guest6=0 t100_6=0; } > "$T/prot.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/prot.csv" 2>&1)
has "protected run (flush covered by rules; wipe covered by zone): none lost" "none: 0 lost in 3 armed sample(s)" "$out"
hasnt "no NOTE for a two-layer artifact" "NOTE: this artifact" "$out"
{ echo "$FH"; frow 100; frow 101 pol4=ACCEPT ch_lan4=0 ch_guest4=0 r_lan4=0 r_guest4=0 t100_4=0; } > "$T/lost.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/lost.csv" 2>&1)
has "both layers down for lan4: LOST reported" "LOST lan4 @101:" "$out"
has "both layers down for guest4: LOST reported" "LOST guest4 @101:" "$out"
has "raw row printed beside the verdict" "raw: 101," "$out"
{ echo "$FH"; frow 100 sh_guest4=1 glfrom_guest4=1 pol4=ACCEPT ch_guest4=0; } > "$T/shadow.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/shadow.csv" 2>&1)
has "guest shadowed by GL's from rule while its zone is open: LOST guest4" "LOST guest4 @100:" "$out"
hasnt "the shadow does not touch lan4" "LOST lan4" "$out"
{ echo "$FH"; frow 100 sh_guest4=1 glfrom_guest4=1; } > "$T/shadow-held.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/shadow-held.csv" 2>&1)
has "guest shadowed but its ZONE layer holds: not lost (protected direction)" "none: 0 lost in 1 armed sample(s)" "$out"

echo "== fm2 predicate: every condition decides on its own (one row per condition, I1)"
# Each row fails EXACTLY ONE condition of one layer while the other layer is down, so deleting that
# condition from the predicate would turn the row protected — and this suite red.
iso() {  # $1 name, $2 key that must be LOST, then NAME=VALUE overrides
  _n=$1; _k=$2; shift 2
  { echo "$FH"; frow 100 "$@"; } > "$T/iso.csv"
  out=$(bash "$FM2" analyze --egress "$E" --router "$T/iso.csv" 2>&1)
  has "isolated $_n: LOST $_k" "LOST $_k @100:" "$out"
}
iso "r (rule present)"                    lan4 r_lan4=0 pol4=ACCEPT ch_lan4=0 ch_guest4=0 ch_iot4=0
iso "t100 (table-100 route, r=1 sh=0)"    lan4 t100_4=0 pol4=ACCEPT ch_lan4=0 ch_guest4=0 ch_iot4=0
iso "sh (shadow ahead of 5279, r=1 t=1)"  lan4 sh_lan4=1 pol4=ACCEPT ch_lan4=0 ch_guest4=0 ch_iot4=0
iso "pol (FORWARD policy, ch=1 j=0)"      lan4 r_lan4=0 pol4=ACCEPT
iso "ch (zone chain, pol=DROP j=0)"       lan4 r_lan4=0 ch_lan4=0
iso "j (ACCEPT jump, pol=DROP ch=1)"      lan4 r_lan4=0 j_lan4=1
iso "sev_open (UCI pair re-enabled)"      lan4 r_lan4=0 sev_open_lan=1 sev_open_n=1
{ echo "$FH"; frow 100 sev_open_n=1 sev_open_lan=1 r_lan4=0; } > "$T/uciopen.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/uciopen.csv" 2>&1)
has "recorded lan pair re-enabled in UCI + no lan rule: LOST lan4" "LOST lan4 @100:" "$out"
has "the UCI-open section keeps reporting it" "@100 sev_open_n=1" "$out"
{ echo "$FH"; frow 100 uci_ks=0 pol4=ACCEPT ch_lan4=0 r_lan4=0; } > "$T/unarmed.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/unarmed.csv" 2>&1)
has "a disarmed sample is not judged" "without armed intent were not judged" "$out"
{ echo "$FH"; frow 100 pol4=NA pol6=NA ch_lan4=NA ch_guest4=NA ch_iot4=NA r_lan4=0; } > "$T/fw4.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/fw4.csv" 2>&1)
has "fw4 (netfilter NA) counted conservatively and flagged" "NOTE: netfilter columns are NA (fw4)" "$out"
has "fw4: a sample without the lan rule counts as lost" "LOST lan4 @100:" "$out"
{ echo "$FH"; frow 100 pol4=NA r_lan4=0; } > "$T/na.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/na.csv" 2>&1)
has "an NA policy never holds, even beside a present chain" "LOST lan4 @100:" "$out"
{ echo "$FH"; frow 100 gl9920_4=2; } > "$T/g99.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/g99.csv" 2>&1)
has "GL 9920 attribution caveat" "VPN-client blackhole (priority 9920)" "$out"
printf 'ts_epoch,uci_ks,ks_severed_n,sev_open_n,lan2ts,t52_4,t52_6,gl_ks4,gl_ks6,daemon,backend,exitnodeid,uci_exit_ip,wan_def\n100,1,5,0,1,1,1,1,0,1,Running,nX,100.64.0.1,1\n' > "$T/zone.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/zone.csv" 2>&1)
has "zone-era artifact analyses with a NOTE" "predates the two-layer sampler" "$out"
hasnt "zone-era artifact: no combined verdict attempted" "Protection lost (armed" "$out"
has "zone-era artifact: sev_open_n keeps its old meaning" "sev_open_n > 0 = protection lost" "$out"
has "zone-era artifact: GL 5280 caveat still printed" "blackhole at 5280" "$out"
printf 'ts_epoch,lan4,guest4,lan6,guest6,t100_4,t100_6,t52_4,t52_6,bh4,bh6,daemon,backend,exitnodeid,uci_exit_ip,uci_ks,wan_def\n100,1,1,1,1,1,1,1,1,0,0,1,Running,nX,100.64.0.1,1,1\n' > "$T/rpdb.csv"
out=$(bash "$FM2" analyze --egress "$E" --router "$T/rpdb.csv" 2>&1)
has "RPDB-era artifact analyses with its NOTE" "predates the zone" "$out"
has "RPDB-era artifact: its rule columns are named for what they are" "rule layer as THAT era" "$out"

[ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
echo "$fails FAILED ($oks ok)"; exit 1
