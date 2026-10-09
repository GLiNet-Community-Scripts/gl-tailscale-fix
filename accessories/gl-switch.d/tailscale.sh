#!/bin/sh
#
# Toggle Tailscale (GL native) + gl-tailscale-fix Kill Switch and related preferences via
# the physical side switch on supported GL.iNet routers (Beryl AX, Slate AX, etc.).
#
# Leak protection: at the start of each "on" flip, the script installs a temporary blackhole at
# ip-rule priority 5260 (above Tailscale's exit-node routing at 5270 and above the plugin's own
# kill switch). It blocks LAN and guest forwarding — and IoT forwarding, with plugin v1.0.22 or
# later — from the competing-VPN teardown until the plugin's kill switch is confirmed. The
# lockdown is entirely self-contained: it owns its routing table (101) and installs and removes
# the table and its rules as one unit, so it neither depends on nor disturbs whatever mechanism
# the plugin itself uses.
#
# One path is beyond any 5260 rule. When GL starts Tailscale with a Custom Exit Node set, it adds
# "from <subnet> lookup main" at priority 0 for the guest network and, where GL has one, the IoT
# network. The kernel consults priority 0 before 5260, so from that moment guest and IoT traffic
# leaves through the real uplink unless the plugin's kill switch already blocks it at the firewall
# (its severed guest and IoT -> uplink forwardings). Starting Tailscale first and arming afterwards
# makes that a race. So with plugin v1.0.22 or later (it ships the kill-switch engine,
# /usr/bin/ts-fix-ks) and KILL_SWITCH=true, the script arms the plugin's kill switch FIRST and only
# then asks GL to start Tailscale: GL's rules land on a path that is already blocked, and the
# plugin swaps them out within one 5-second watchdog poll. If the engine's arm exits non-zero, GL
# is never asked to start Tailscale, the lockdown stays, and the failure is logged to syslog.
#
# This complete coverage applies with plugin v1.0.22 or later only. With older plugin versions
# the script behaves as before: GL starts Tailscale first, the plugin applies its kill switch
# afterwards, and the lockdown covers LAN and guest. KILL_SWITCH=false keeps that original order
# with any plugin version, since there is no kill switch to arm.
#
# The lockdown is released only once the plugin's kill switch is confirmed active — meaning its
# routing rules and table are actually in place, never merely the plugin's record of the
# forwardings it is severing, which can be read before anything is in force (see ks_active below
# for why that distinction matters). In the original order the plugin applies its kill switch
# asynchronously, so the script waits up to 20 seconds for that confirmation before releasing —
# expect the transition to take that long in the worst case. On abnormal exit, or if the
# confirmation never comes, the lockdown stays (fail-secure: LAN blackout instead of leak) and the
# hold is logged to syslog. The "off" path also cleans up any lingering lockdown from a prior "on".
#
# On firmware 4.9 and later, each "on" flip also turns on GL's IP Masquerading toggle for
# Tailscale. GL made that a separate setting in 4.9 and the plugin defers to it, but LAN
# clients cannot use the exit node without it — so the slider sets it rather than leaving you
# to find it in the GL UI after every flip. On pre-4.9 firmware the plugin's own masquerade
# handling covers this and the flip behaves exactly as it always has.
#
# Prerequisites — verify all of these BEFORE deploying this script:
#   1. gl-tailscale-fix v1.0.9 or later installed on the router.
#   2. Tailscale enabled in the GL admin UI at least once and bound to your Tailscale
#      account ("Bind Account" set).
#   3. A Custom Exit Node selected at least once in the GL UI (so an exit node IP is
#      stored in tailscale.settings.exit_node_ip — the script reuses GL's most recent
#      selection on each "on" flip).
#   4. Exit node(s) approved in the Tailscale admin console at
#      https://login.tailscale.com/admin/machines (Edit route settings → Use as exit node).
#   5. If LAN_ENABLED=true (the default): this router's LAN subnet route also approved
#      in the Tailscale admin console.
#   6. The script handles routing conflicts with GL's stock VPN clients (WireGuard,
#      OpenVPN, Tor) automatically — on every "on" flip, it installs a temporary
#      full-router lockdown then defensively disables those clients via their built-in
#      /etc/gl-switch.d/ scripts before bringing Tailscale up. You do NOT need to
#      manually disable GL's stock VPN clients in the GUI first. HOWEVER, any custom
#      routing (ZeroTier managed routes, third-party VPN apps, proxy clients, custom
#      iptables, etc.) is your responsibility to disable before relying on the
#      slider — the script can't auto-detect arbitrary user-installed routing.
#   7. End-to-end tested in the GL UI before relying on the slider — enable Tailscale,
#      select the exit node, confirm your LAN clients route through it and the kill
#      switch engages. On 4.9+ that path also needs GL's IP Masquerading toggle, which
#      the slider sets on every "on" flip; pre-4.9 the plugin handles it.
#
# Firmware compatibility:
#   - Tested with gl-tailscale-fix v1.0.22 on the GL-MT3000 (Beryl AX) running firmware 4.11.0,
#     the GL-MT3600BE (Beryl 7) running firmware 4.9.0 and the GL-AXT1800 (Slate AX) running
#     firmware 4.8.4.
#   - Designed to work on pre-4.8 firmware (4.6.x, 4.7.x — SlateAX, Brume 2, Mudi, etc.).
#     The 5260 lockdown is firmware-agnostic and is designed to overlay GL's pre-4.8
#     vpnpolicy.global.kill_switch mechanism. Pre-4.8 lab verification is pending — if
#     you encounter the slider on pre-4.8 producing a persistent LAN blackout after
#     Tailscale comes up, file an issue with the firmware version + router model.
#
# Install on the router:
#   wget -q https://raw.githubusercontent.com/RemoteToHome-io/gl-tailscale-fix/main/accessories/gl-switch.d/tailscale.sh -O /etc/gl-switch.d/tailscale.sh
#   chmod +x /etc/gl-switch.d/tailscale.sh
#
# Bind the physical slider to this script. The GL admin UI dropdown for Toggle Button
# Settings does NOT list Tailscale as an option, so this must be done via UCI:
#   uci set switch-button.@main[0].func='tailscale'
#   uci commit switch-button
#
# IMPORTANT: after the UCI binding, DO NOT open System → Toggle Button Settings in the
# GL admin UI. That page only knows about its hardcoded function list, so it will display
# "No Function" (or a stale prior selection) and clicking Apply will overwrite the UCI
# binding with whatever the GUI displays. To unbind cleanly, run:
#   uci set switch-button.@main[0].func='' && uci commit switch-button
#
# Then edit the Configuration block below to your preferred posture. Every "on" flip
# applies that posture in full, so a single edit here locks in your setup across switch
# toggles.
#
# Exit-node handling is special: by default the script reuses GL's most recently selected
# exit node (so changing the selection in the GL UI sticks across toggles). DEFAULT_EXIT_NODE_IP
# is used only as a fallback on first run, when nothing has been selected yet.
#
# By default this script treats slider "on" as "enable Tailscale + apply posture" and
# slider "off" as "disable everything." If you prefer the inverted convention (resting
# position is "off" with Tailscale active), swap the action names in the if/elif branches.
#
# To verify which physical slider position your router reports as "on", SSH in and run:
#   . /lib/functions/gl_util.sh; get_switch_button_status
# It prints the literal string "on" or "off". Flip the slider, run again, compare. GL
# handles per-model GPIO polarity quirks inside that function, so the semantic is
# portable across hardware.
#
# Released under the same terms as gl-tailscale-fix (GPL-3.0).

# --- Configuration ---

# Fallback exit node IP, used ONLY when GL has no current Custom Exit Node selection
# in UCI (first run, or after a manual clear). Once you've selected a Custom Exit Node
# in the GL admin UI, this value is ignored and the script reuses GL's current
# selection on every "on" flip — so changing the selection in the GL UI sticks across
# slider toggles.
DEFAULT_EXIT_NODE_IP="XX.XX.XX.XX"

# GL native settings
# Allow Remote Access LAN — required for tailnet peers to reach LAN devices behind this
# router. Subnet route must also be approved in the Tailscale admin console for this
# to take effect.
LAN_ENABLED=true
# Allow Remote Access WAN — only needed when advertising this router as an exit node.
WAN_ENABLED=false

# gl-tailscale-fix preferences — applied on every "on" because the plugin's watchdog
# tears these down to 0 when Tailscale is disabled.
KILL_SWITCH=true                      # Engage kill switch on enable
ROUTE_GUEST=false                     # Route guest network through Tailscale
ADVERTISE_EXIT_NODE=false             # Advertise this router as an exit node
TAILSCALE_SSH=false                   # Enable Tailscale's ACL-based SSH

# --- Helpers ---

# The paths the flips below run or check, kept in variables only so a unit test can point them at
# stand-ins after sourcing this file (see TS_FIX_SWITCH_LIB at the bottom). The values are the
# paths on the router, and nothing here reads them from the environment.
KS_ENGINE=/usr/bin/ts-fix-ks                  # the plugin's kill-switch engine (v1.0.22 and later)
GL_SWITCH_DIR=/etc/gl-switch.d                # GL's own switch scripts (wireguard, openvpn, tor)
GL_TS_KILLSWITCH=/usr/bin/ts_killswitch       # GL's own Tailscale kill-switch evaluator (4.9+)
GL_TAILSCALE=/usr/bin/gl_tailscale            # GL's Tailscale service script
KS_COMMIT_FAIL=/tmp/ts-fix-ks.commit-failed   # the engine's commit-failure sentinel

# Detect GL firmware 4.9+ (same shape the plugin's own scripts use). On 4.9+ GL owns the
# Tailscale IP Masquerading toggle natively; pre-4.9 the plugin handles masquerade itself.
is_fw49_plus() {
    local fw_ver major minor
    fw_ver=$(awk '{print $1}' /etc/glversion 2>/dev/null)
    [ -z "$fw_ver" ] && return 1
    major=$(echo "$fw_ver" | cut -d. -f1)
    minor=$(echo "$fw_ver" | cut -d. -f2)
    if [ "$major" -gt 4 ] 2>/dev/null || \
       { [ "$major" -eq 4 ] && [ "$minor" -ge 9 ]; } 2>/dev/null; then
        return 0
    fi
    return 1
}

# The lockdown is self-contained: its own unreachable-default route in table 101, plus the
# 5260 rules that point at it, installed and removed as one unit. It deliberately does NOT
# share a table with the plugin — the plugin deletes its own table-100 route whenever it takes
# its rule layer down, which would silently defang a lockdown built on top of it (5260
# rules over an emptied table simply fall through to the next rule and traffic leaks).
#
# Table 101 is chosen as unused: clear of Tailscale's table 52 and of the plugin's kill-switch
# table (100). Confirm it is free on your router before deploying — both
# `ip route show table 101` and `ip -6 route show table 101` should print nothing.
#
# br-iot is covered only when the plugin's kill-switch engine is installed (v1.0.22 and later):
# only that plugin covers GL's IoT network, so only then does the release gate (ks_active) wait for
# it, and with older plugins the lockdown stays exactly what it was. A rule for a bridge that does
# not exist is still kept by the kernel (iproute2 lists it as "[detached]"), so the IoT network
# need not exist.
lockdown_install() {
    for fam in -4 -6; do
        ip $fam route add unreachable default table 101 2>/dev/null
        ip $fam rule add iif br-lan priority 5260 lookup 101 2>/dev/null
        ip $fam rule add iif br-guest priority 5260 lookup 101 2>/dev/null
        if [ -x "$KS_ENGINE" ]; then
            ip $fam rule add iif br-iot priority 5260 lookup 101 2>/dev/null
        fi
    done
}

# Rules first, then the route: dropping the route first would leave the 5260 rules pointing
# at an empty table, which falls through instead of blocking. br-iot is removed whatever plugin
# is installed: a delete for a rule that is not there just fails, silently, and a lockdown put in
# while the engine was present must still come out if the plugin has changed since.
lockdown_remove() {
    for fam in -4 -6; do
        ip $fam rule del iif br-lan priority 5260 lookup 101 2>/dev/null
        ip $fam rule del iif br-guest priority 5260 lookup 101 2>/dev/null
        ip $fam rule del iif br-iot priority 5260 lookup 101 2>/dev/null
        ip $fam route del unreachable default table 101 2>/dev/null
    done
}

# ks_rule_present <fam> <bridge> -> rc 0 when a priority-5279 or -5280 rule for exactly that
# bridge is present, in the shape "from all iif <bridge> [detached] lookup 100" (see ks_active
# below for why each part of that shape is required).
ks_rule_present() {
    local fam="$1" br="$2" tab
    tab=$(printf '\t')
    { ip "$fam" rule list priority 5279; ip "$fam" rule list priority 5280; } 2>/dev/null | \
        grep -qE "^(5279|5280):[ ${tab}]+from all iif ${br}([ ${tab}]\[detached\])? lookup 100\$"
}

# ks_route_present <fam> -> rc 0 when table 100 holds a line beginning "unreachable default"
# (IPv6 prints more after it).
ks_route_present() {
    ip "$1" route show table 100 2>/dev/null | grep -qE "^unreachable default"
}

# ks_iot_present <fam> -> rc 0 when the br-iot rule is present in that exact shape, or when the
# plugin has no kill-switch engine (before v1.0.22), which never installs one.
ks_iot_present() {
    [ -x "$KS_ENGINE" ] || return 0
    ks_rule_present "$1" br-iot
}

# Is the plugin's kill switch ROUTING LAYER actually in place? Never trust the plugin's own
# record of the forwardings it is severing — see below for why. Version-agnostic over the rule
# priority, because the plugin changed it once already (5280 -> 5279) and this script is
# deployed standalone against either generation.
ks_active() {
    # Engine commit-failure sentinel: state staged, not persisted - hold the lockdown, fail-secure.
    [ -f "$KS_COMMIT_FAIL" ] && return 1

    # The plugin's own UCI record of severed uplink forwardings (ts-fix.settings.ks_severed) is
    # deliberately NOT read here, even though the plugin's own get_config status
    # (kill_switch_fw_active) reads a non-empty record as evidence that it is armed. The engine's
    # arm sweep stages that record with a plain
    # `uci add_list` BEFORE it commits UCI and reloads the firewall — and a staged, uncommitted
    # change is visible to `uci get` from any process immediately. So the record can read
    # non-empty while the firewall has not yet been reloaded and the routing rules below do not
    # yet exist. Trusting it would release this lockdown before any protection is actually in
    # force. The only sound signal is the routing layer itself, checked directly below: for each
    # LAN-side bridge, a rule into table 100, plus the table's own blackhole route.
    #
    # The exact rule shape required is "from all iif <bridge> lookup 100", optionally with
    # "[detached]" before "lookup" — the token iproute2 prints when the bridge device does
    # not currently exist; the kernel keeps the rule regardless and applies it once a device of
    # that name appears. "lookup 100" is anchored at the end of the line so it is never read
    # as a substring of another table number (GL's own WireGuard client uses table 1002), and
    # "from all iif <bridge>" is anchored at the start so a rule with any extra selector —
    # which would block less traffic than ours — cannot count. Rules at priority 5279 (v1.0.21+)
    # or 5280 (v1.0.9-v1.0.20) both count. GL 4.9's own kill switch also sits at priority 5280,
    # but as a plain blackhole with no table lookup at all, so it can never match this shape.
    #
    # br-lan and br-guest are always checked. br-iot is checked too, in each family, when the
    # plugin's kill-switch engine is installed (v1.0.22 and later): that engine puts a rule on
    # br-iot on every arm ("[detached]" where GL's IoT network does not exist), and lockdown_install
    # covers br-iot in exactly that case, so the gate must not release the lockdown before the
    # engine's rule is there. Older plugins never install a br-iot rule, and requiring one there
    # would hold the lockdown forever.
    #
    # IPv4 is always required. IPv6 is required only where v6 rules can exist: on an IPv4-only
    # router `ip -6 rule list` is empty, so demanding a v6 rule would mean this gate could never
    # pass and the 5260 lockdown would hold forever (permanent LAN blackout on every "on" flip).
    ks_rule_present -4 br-lan && ks_rule_present -4 br-guest && ks_route_present -4 || return 1
    ks_iot_present -4 || return 1
    [ -n "$(ip -6 rule list 2>/dev/null)" ] || return 0
    ks_rule_present -6 br-lan && ks_rule_present -6 br-guest && ks_route_present -6 || return 1
    ks_iot_present -6
}

# --- Logic ---

# The "on" flip. Returns non-zero, with GL never asked to start Tailscale, when the plugin's
# kill-switch engine exits non-zero on arm (STEP 4).
switch_on() {
    # STEP 1: Pre-emptive lockdown. LAN and guest forwarding — and IoT forwarding, with plugin
    # v1.0.22 or later — now blackholed at priority 5260 (above TS exit-node routing at 5270 and
    # above the plugin's own kill switch), via our own table 101. Forwarded traffic that reaches
    # these rules cannot leak during the transition that follows. The one way around them is GL's
    # priority-0 guest/IoT rules, which is why, with plugin v1.0.22 or later and KILL_SWITCH=true,
    # STEP 4 arms the plugin's kill switch before STEP 5 lets GL add them.
    lockdown_install

    # STEP 2: Defensive disable of competing VPN/proxy clients (WG, OpenVPN, Tor) only
    # if currently active. Their priority-6000 policy routing wins against Tailscale's
    # exit-node routing at priority 5270, so leaving any of them running would prevent
    # traffic from actually flowing through the Tailscale exit node. Backup for the
    # case where the slider was previously bound to one of those and is being rebound
    # here without explicit teardown. Pre-checks avoid spurious "Turning X OFF" MCU
    # notifications when the service wasn't on. With the 5260 lockdown in place above,
    # forwarded traffic that reaches it stays blocked during this teardown (GL's priority-0
    # guest/IoT rules, STEP 1, are the exception).
    wg_status=$(curl -H 'glinet: 1' -s -k "$RPC" -d '{"jsonrpc":"2.0","method":"call","params":["","wg-client","get_status",{}],"id":1}' | jsonfilter -e '@.result.status' 2>/dev/null)
    [ -n "$wg_status" ] && [ "$wg_status" != "0" ] && "$GL_SWITCH_DIR/wireguard.sh" off >/dev/null 2>&1
    # OpenVPN's switch script has its own internal status pre-check, so direct call is safe.
    [ -x "$GL_SWITCH_DIR/openvpn.sh" ] && "$GL_SWITCH_DIR/openvpn.sh" off >/dev/null 2>&1
    tor_enabled=$(curl -H 'glinet: 1' -s -k "$RPC" -d '{"jsonrpc":"2.0","method":"call","params":["","tor","get_config",{}],"id":1}' | jsonfilter -e '@.result.enable' 2>/dev/null)
    [ "$tor_enabled" = "true" ] && "$GL_SWITCH_DIR/tor.sh" off >/dev/null 2>&1

    # STEP 3: Reuse GL's most recently selected exit node IP; fall back to default only
    # when GL has nothing set (first run or after a manual clear).
    exit_node_ip=$(uci -q get tailscale.settings.exit_node_ip)
    [ -z "$exit_node_ip" ] && exit_node_ip="$DEFAULT_EXIT_NODE_IP"

    # STEPS 4 and 5 send these two RPC requests, in whichever order applies below.
    #
    # GL's (gl_req) enables Tailscale, passing the resolved exit node IP.
    #
    # On 4.9+ the same request turns on GL's IP Masquerading (tailscale.settings.masq). GL split
    # that into its own toggle in 4.9 and the plugin defers to it, but LAN clients cannot reach
    # the exit node without it — so without this a flip brings Tailscale up and leaves the LAN
    # unable to use it until someone enables the toggle by hand in the GL UI. Pre-4.9 the payload
    # is byte-for-byte what it always was: the plugin's own masquerade handling covers those
    # firmwares, and that RPC has no masq parameter to send.
    #
    # The plugin's (fix_req) applies the gl-tailscale-fix posture from the Configuration block.
    ts_masq=""
    if is_fw49_plus; then
        ts_masq="\"masq\":true,"
    fi
    gl_req="{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tailscale\",\"set_config\",{\"enabled\":true,\"lan_enabled\":$LAN_ENABLED,${ts_masq}\"wan_enabled\":$WAN_ENABLED,\"exit_node_ip\":\"$exit_node_ip\"}],\"id\":1}"
    fix_req="{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ts-fix\",\"set_config\",{\"kill_switch\":$KILL_SWITCH,\"route_guest\":$ROUTE_GUEST,\"advertise_exit_node\":$ADVERTISE_EXIT_NODE,\"tailscale_ssh\":$TAILSCALE_SSH}],\"id\":2}"

    if [ -x "$KS_ENGINE" ] && [ "$KILL_SWITCH" = "true" ]; then
        # STEP 4 (plugin v1.0.22 or later, KILL_SWITCH=true): arm the plugin's kill switch
        # BEFORE GL starts Tailscale. GL's restart adds "from <guest subnet> lookup main" and,
        # where GL has an IoT network, "from <IoT subnet> lookup main" at priority 0, which no
        # 5260 rule can outrank: from that moment guest and IoT traffic leaves through the real
        # uplink unless the plugin's firewall layer (its severed guest and IoT -> uplink
        # forwardings) is already in force. With the arm after GL's restart that is a race, and no
        # timing removes it; with the arm first, GL's rules land on a path that is already blocked.
        #
        # The engine arms only while Tailscale is enabled in UCI (and the kill switch is on), and
        # the plugin's RPC refuses any change while Tailscale is disabled. So enabled='1' is set
        # and committed first, WITHOUT a restart (GL starts Tailscale in STEP 5); the plugin's RPC
        # then records the posture; and `ts-fix-ks arm` runs synchronously under the engine's own
        # lock, so the arm has finished when it returns. timeout bounds that wait. A non-zero
        # exit — a failure, a timeout, or 2 when the router is not in Router mode — stops the
        # flip right here: the lockdown stays, enabled goes back to what it was before the flip
        # (left alone if that was already '1'), GL is never asked to start Tailscale, and one
        # syslog line says so. Flipping the switch off removes the lockdown.
        ts_enabled_before=$(uci -q get tailscale.settings.enabled)
        uci set tailscale.settings.enabled='1'
        uci commit tailscale
        curl -H 'glinet: 1' -s -k "$RPC" -d "$fix_req"
        timeout 30 "$KS_ENGINE" arm
        arm_rc=$?
        if [ "$arm_rc" != "0" ]; then
            if [ "$ts_enabled_before" != "1" ]; then
                if [ -n "$ts_enabled_before" ]; then
                    uci set tailscale.settings.enabled="$ts_enabled_before"
                else
                    uci -q delete tailscale.settings.enabled
                fi
                uci commit tailscale
            fi
            logger -t ts-fix-switch "kill switch could not be armed (ts-fix-ks arm exit ${arm_rc}; 2 = not in Router mode) - Tailscale was not started by this flip and the lockdown is HELD: LAN, guest and IoT stay blocked (fail-secure). Flip the switch off to recover."
            return 1
        fi

        # STEP 5: Enable Tailscale via GL's RPC. Its restart adds GL's guest/IoT rules onto paths
        # the firewall layer already blocks, and the plugin's engine swaps them out within one
        # 5-second watchdog poll. No settle delay is needed in this order: the plugin's own
        # hotplug handler re-applies its daemon-level settings after GL's restart, as it always
        # has.
        curl -H 'glinet: 1' -s -k "$RPC" -d "$gl_req"
    else
        # STEPS 4-5 in the original order, for a plugin without the kill-switch engine (before
        # v1.0.22) or a KILL_SWITCH that is not true: enable Tailscale via GL's RPC first.
        curl -H 'glinet: 1' -s -k "$RPC" -d "$gl_req"

        sleep 5

        # Apply gl-tailscale-fix posture in lock-step with Tailscale.
        curl -H 'glinet: 1' -s -k "$RPC" -d "$fix_req"
    fi

    # STEP 6: Release the lockdown only when the plugin's kill switch is confirmed active
    # (when KILL_SWITCH=true) or when the user has explicitly opted out of KS.
    #
    # The same gate serves both orders. After STEP 4 the arm has already finished, but its exit
    # status is not taken as proof that anything is in force — only the routing layer is (see
    # ks_active). In the original order it polls rather than checking once, because set_config
    # returns BEFORE the kill switch is holding: the plugin fires its kill-switch engine detached
    # and answers the RPC straight away, since severing the forwardings means committing UCI and
    # reloading the firewall — far too slow to hold an HTTP response open. A single immediate
    # check would therefore see "not armed yet" on essentially every flip and hold the lockdown
    # forever. The 20-second bound covers the detached start, the UCI commits and a slow fw3
    # firewall reload, and also the worst case where the spawn is lost entirely: the plugin's own
    # watchdog re-runs the arm within its 5-second poll, which still completes comfortably inside
    # the bound.
    #
    # If the bound expires the lockdown STAYS — something went wrong with set_config and we'd
    # rather fail-secure (LAN blackout) than risk a leak. Flip the switch off to recover, or clear
    # it by hand over SSH: `ip rule del iif br-lan priority 5260 lookup 101` (repeat for br-guest
    # and br-iot, and for all three with `ip -6`) plus `ip route del unreachable default table 101`
    # (and again with `ip -6`).
    if [ "$KILL_SWITCH" = "true" ]; then
        waited=0
        until ks_active || [ "$waited" -ge 20 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        if ks_active; then
            lockdown_remove
        else
            # Keep the lockdown — fail-secure. Logged because a slider flip has no console:
            # without this the only symptom is a dark LAN with nothing explaining it.
            logger -t ts-fix-switch "kill switch not confirmed after ${waited}s - lockdown HELD, LAN and guest (and IoT, with plugin v1.0.22+) stay blocked (fail-secure). Recover by flipping the switch off, or with 'ip rule del iif br-lan priority 5260 lookup 101' and 'ip route del unreachable default table 101' (repeat for br-guest and br-iot, and for all with ip -6); full list in the STEP 6 comment of $0"
        fi
    else
        lockdown_remove
    fi
}

# The "off" flip.
switch_off() {
    # Clean up any lingering lockdown (5260 rules + table 101) from a prior "on" — one that was
    # interrupted, or one held after a failed arm (STEP 4) or an unconfirmed kill switch (STEP 6).
    lockdown_remove

    # IP Masquerading is deliberately left alone here: on 4.9+ tailscale.settings.masq is
    # persistent user intent in GL's model, and with Tailscale disabled it does nothing anyway.
    #
    # Disable Tailscale via UCI directly, bypassing GL's RPC. This preserves
    # tailscale.settings.exit_node_ip so the next "on" flip reconnects to the same
    # node — calling GL's set_config would clear it. The gl-tailscale-fix watchdog
    # detects the enabled=0 transition and tears down the kill switch (both layers)
    # within ~5 seconds.
    uci set tailscale.settings.enabled='0'
    uci commit tailscale

    # GL firmware 4.9.0 and 4.11.0 keep their own IPv4 kill switch for the main LAN
    # (network.ts_block_lan_leak, a priority-5280 blackhole) armed while Tailscale is enabled with
    # an exit node set (and the router is not itself an exit node), and only GL's own
    # Tailscale settings path re-evaluates that rule — this path deliberately goes around that
    # (see above), so run GL's own evaluator directly. With Tailscale now disabled it removes
    # the rule; where the file doesn't exist (pre-4.9) this is a no-op.
    [ -x "$GL_TS_KILLSWITCH" ] && "$GL_TS_KILLSWITCH" >/dev/null 2>&1

    "$GL_TAILSCALE" restart >/dev/null 2>&1 &
}

# A unit test sources this file with TS_FIX_SWITCH_LIB=1 to call the functions above directly;
# nothing below runs then.
[ "${TS_FIX_SWITCH_LIB:-0}" = 1 ] && return 0

action=$1

# GL RPC endpoint — port lookup mirrors GL's own switch scripts in /etc/gl-switch.d/.
PORT=$(cat /etc/nginx/conf.d/gl.conf 2>/dev/null | grep -E "    listen [0-9]+;" | grep -oE '[0-9]+' | head -1)
[ -z "$PORT" ] && PORT=80
RPC="http://127.0.0.1:$PORT/rpc"

if [ "$action" = "on" ]; then
    switch_on
elif [ "$action" = "off" ]; then
    switch_off
else
    echo "Usage: $0 [on|off]" >&2
    exit 1
fi
