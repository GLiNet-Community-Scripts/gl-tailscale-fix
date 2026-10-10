#!/bin/sh
# gl-tailscale-fix test suite — boot-window kill-switch sampler (formalized from the ad-hoc
# 2026-08 instrument, with the instrument-quality fixes the cold audit demanded).
#
# ############################################################################################
# RETIRED with the two-layer kill switch — kept for the record, not for the current build.
#
# It samples the routing layer only: its rules (priority 5280 through v1.0.20, 5279 from v1.0.21)
# and the table-100 unreachable default. In the v1.0.12-v1.0.21 releases (and the RPDB-era
# v1.0.22 dev builds) that layer was the whole kill switch, and netifd's start flushes the entire
# policy rulebase, so there was a gap
# before the rules were re-asserted: on a GL-MT3000 on 4.9.0, v1.0.21 installed them 10.85 s after
# the router's internet route appeared (22.2 s on a second boot), before the S19 + netlink-guard
# fix. In the one boot watched from a LAN client, IPv6 traffic reached the internet in that gap
# (on a connection with IPv6) while IPv4 stayed blocked. The current build's boot protection rests
# on the firewall layer instead: the severed
# lan/guest/iot -> uplink-class forwardings in /etc/config/firewall, applied by
# /etc/init.d/firewall at S19, ahead of netifd, so before any WAN route exists. The rules are
# re-installed after netifd's flush, at the first non-loopback ifup (the 10-ts-fix-ks hotplug
# handler). The interval before that is covered by the firewall layer, which this sampler cannot
# see, so a verdict drawn from its columns (ks4/ks6/t100v4/t100v6) would score that interval as
# exposure on a correct build: a false red.
#
# It also references two things only the RPDB-era v1.0.22 dev builds had: the plugin's detached
# boot guard and its /tmp/ts-fix-boottrace hook (item 5 below) — neither is in any release.
#
# Boot verification is now a plain reboot smoke plus an egress check: reboot the DUT, confirm
# both layers are back — the recorded pairs still severed and the rule layer in place (the
# both-layer probe fm2_armed_probe_script in tests/fm2-wan-bounce.sh checks exactly that) — and
# run the laptop-side egress monitor across the boot to confirm no non-tunnel egress at any
# point. Do NOT deploy this sampler to a router running a two-layer build.
# ############################################################################################
#
# Deploys as a TEMPORARY init script on the router under test. Install for a boot test:
#   scp -O tests/lib/boot-sampler.sh root@<router>:/etc/init.d/ks-boot-sampler
#   ssh root@<router> 'chmod 755 /etc/init.d/ks-boot-sampler; /etc/init.d/ks-boot-sampler enable'
# Remove after the window:
#   ssh root@<router> '/etc/init.d/ks-boot-sampler disable; rm -f /etc/init.d/ks-boot-sampler'
#
# Instrument-quality contract (each item exists because its absence weakened a prior claim):
#   1. START=19 with a name that sorts BEFORE ts-fix ("ks-boot-sampler" < "ts-fix"), so
#      sampling begins before the plugin's own S19 install — no pre-instrument blind lead-in.
#   2. Cadence self-audit: every row carries the delta from the previous sample; any delta
#      over STALL_FACTOR x INTERVAL additionally emits an explicit STALL row. Blind intervals
#      are DATA in the artifact, not silence — analysis must treat a STALL overlapping a
#      wandef transition as a failed sample set, not as absence of exposure.
#   3. Uptime is the axis (early-boot epoch shifts under NTP; both are recorded).
#   4. Pair every armed run with a disarmed control run (observability + no-misfire proof).
#   5. Create /tmp/ts-fix-boottrace before reboot to also collect the plugin's guard-side
#      uptime-stamped re-assert records (/tmp/ts-fix-boottrace.log) — the guard's own trace
#      covers the moments a stalled sampler cannot.
#
# Columns: uptime,epoch,delta,ks4,ks6,t100v4,t100v6,wandef
#   ks4/ks6   = count of "lookup 100" rules at priority 5279 per family (2 = br-lan+br-guest)
#   t100v4/v6 = unreachable default present in table 100 per family
#   wandef    = v4 default route present in main
START=19
STOP=99

OUT=/tmp/ks-boot-sample.csv
INTERVAL_US=500000
SAMPLES=240
STALL_FACTOR=3   # delta > (STALL_FACTOR * 0.5s) => explicit STALL row

start() {
    (
        echo "uptime,epoch,delta,ks4,ks6,t100v4,t100v6,wandef" > "$OUT"
        prev=""
        n=0
        while [ "$n" -lt "$SAMPLES" ]; do
            up=$(awk '{print $1}' /proc/uptime)
            ep=$(date +%s)
            ks4=$(ip -4 rule list priority 5279 2>/dev/null | grep -c "lookup 100")
            ks6=$(ip -6 rule list priority 5279 2>/dev/null | grep -c "lookup 100")
            t4=$(ip -4 route show table 100 2>/dev/null | grep -c "unreachable default")
            t6=$(ip -6 route show table 100 2>/dev/null | grep -c "unreachable default")
            wd=$(ip -4 route show default 2>/dev/null | grep -c "^default")
            if [ -n "$prev" ]; then
                d=$(awk -v a="$up" -v b="$prev" 'BEGIN{printf "%.2f", a-b}')
                big=$(awk -v d="$d" -v f="$STALL_FACTOR" 'BEGIN{print (d > f*0.5) ? 1 : 0}')
                [ "$big" = "1" ] && echo "$up,$ep,$d,STALL,STALL,STALL,STALL,STALL" >> "$OUT"
            else
                d=0
            fi
            echo "$up,$ep,$d,$ks4,$ks6,$t4,$t6,$wd" >> "$OUT"
            prev="$up"
            usleep "$INTERVAL_US"
            n=$((n + 1))
        done
    ) &
}

stop() {
    :
}
