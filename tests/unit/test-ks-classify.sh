#!/bin/sh
# Unit test for ks_zone_class()/ks_pair_in() in src/scripts/ts-fix-ks. Pure string logic —
# runs on the dev laptop, no router required:  sh tests/unit/test-ks-classify.sh
SRC="$(dirname "$0")/../../src/scripts/ts-fix-ks"
eval "$(awk '/^# ---8<--- ks-classify/,/^# ---8<--- end ks-classify/' "$SRC")"
command -v ks_zone_class >/dev/null 2>&1 || { echo "FAIL: extraction empty"; exit 1; }
fails=0
check() { got="$(ks_zone_class "$2" "$3")"
  [ "$got" = "$4" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s want=%s got=%s\n' "$1" "$4" "$got"; fails=$((fails+1)); }; }
check "one-zone wan layout"        wan       "wan wwan tethering wan6 wwan6 tethering6" uplink
check "named wan6 zone by name"    wan6      ""                                         uplink
check "wan6 zone by networks"      foo       "wan6 usbwan6 modem_cpu_6"                 uplink
check "simo membership"            cell      "simo simo6"                               uplink
check "secondwan membership"       dualwan   "secondwan"                                uplink
check "modem_ prefix network"      mzone     "modem_1_1_2"                              uplink
check "usbwan membership"          uzone     "usbwan"                                   uplink
check "zerotier exact"             zerotier  "zerotier"                                 vpnclient
check "wgclient1 prefix"           wgclient1 ""                                         vpnclient
check "ovpnclient prefix"          ovpnclient ""                                        vpnclient
check "awgclient prefix"           awgclient ""                                         vpnclient
check "tailscale0 is other"        tailscale0 ""                                        other
check "lan is other"               lan       "lan"                                      other
check "awg SERVER zone is other"   awg       "awg"                                      other
check "wgserver is other"          wgserver  ""                                         other
check "guest is other"             guest     "guest"                                    other
check "empty name+nets"            ""        ""                                         other
check "vpnclient outranks uplink nets" wgclient1 "wan wan6"                             vpnclient
check "near-miss name wanx"        wanx      ""                                         other
check "near-miss name xwan"        xwan      ""                                         other
check "near-miss network wanx"     zone1     "wanx xwan"                                other
p() { ks_pair_in "$2" "$3"; got=$?
  [ "$got" = "$4" ] && printf 'ok   %s\n' "$1" || { printf 'FAIL %s want-rc=%s got-rc=%s\n' "$1" "$4" "$got"; fails=$((fails+1)); }; }
p "pair present"        "lan:wan guest:wan"  "guest:wan" 0
p "pair absent"         "lan:wan"            "lan:wan6"  1
p "empty list"          ""                   "lan:wan"   1
p "no substring match"  "lan:wan6"           "lan:wan"   1
[ "$fails" = "0" ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
