#!/bin/sh
#
# Toggle Tailscale (GL native) + gl-tailscale-fix Kill Switch and related preferences via
# the physical side switch on supported GL.iNet routers (Beryl AX, Slate AX, etc.).
#
# Leak protection: at the start of each "on" flip, the script installs a temporary
# blackhole at ip-rule priority 5260 (above Tailscale's exit-node routing at 5270 and
# above the plugin's own kill switch). This blocks all LAN/guest forwarding for the
# duration of the transition — between competing-VPN teardown and Tailscale being fully
# up — eliminating the IP-leak window that would otherwise exist. The lockdown is
# entirely self-contained: it owns its routing table (101) and installs and removes the
# table and its rules as one unit, so it neither depends on nor disturbs whatever
# mechanism the plugin itself uses. It is released only once the plugin's kill switch is
# confirmed active — on current plugin versions that means the record of severed uplink
# forwardings the plugin keeps in UCI, on older ones its priority-5279/5280 routing rules.
# The plugin applies its kill switch asynchronously, so the script waits up to 20 seconds
# for that confirmation before releasing — expect the transition to take that long in the
# worst case. On abnormal exit, or if the confirmation never comes, the lockdown stays
# (fail-secure: LAN blackout instead of leak) and the hold is logged to syslog. The "off"
# path also cleans up any lingering lockdown from an interrupted prior "on".
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
#   - Verified on firmware 4.8.x (and 4.9.0 by inference — plugin works on both).
#   - Designed to work on pre-4.8 firmware (4.6.x, 4.7.x — SlateAX, Brume 2, Mudi, etc.).
#     The 5260 lockdown is firmware-agnostic and overlays cleanly on GL's pre-4.8
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
# share a table with the plugin — current plugin versions delete the routing table their
# older kill switch used, which would silently defang a lockdown built on top of it (5260
# rules over an emptied table simply fall through to the next rule and traffic leaks).
#
# Table 101 is chosen as unused: clear of Tailscale's table 52 and of the table the plugin's
# older kill switch used (100). Confirm it is free on your router before deploying — both
# `ip route show table 101` and `ip -6 route show table 101` should print nothing.
lockdown_install() {
    for fam in -4 -6; do
        ip $fam route add unreachable default table 101 2>/dev/null
        ip $fam rule add iif br-lan priority 5260 lookup 101 2>/dev/null
        ip $fam rule add iif br-guest priority 5260 lookup 101 2>/dev/null
    done
}

# Rules first, then the route: dropping the route first would leave the 5260 rules pointing
# at an empty table, which falls through instead of blocking.
lockdown_remove() {
    for fam in -4 -6; do
        ip $fam rule del iif br-lan priority 5260 lookup 101 2>/dev/null
        ip $fam rule del iif br-guest priority 5260 lookup 101 2>/dev/null
        ip $fam route del unreachable default table 101 2>/dev/null
    done
}

# Is the plugin's kill switch actually holding? Version-agnostic, because the plugin changed
# enforcement mechanism and this script is deployed standalone against either generation.
ks_active() {
    # Engine commit-failure sentinel: state staged, not persisted - hold the lockdown, fail-secure.
    [ -f /tmp/ts-fix-ks.commit-failed ] && return 1
    # Current plugin versions: the kill switch severs the LAN/guest uplink firewall
    # forwardings and records each one it disabled in this UCI list. A non-empty list means
    # the kill switch is engaged; the plugin clears the list when it disarms.
    [ -n "$(uci -q get ts-fix.settings.ks_severed 2>/dev/null)" ] && return 0
    # Older plugin versions (routing-rule kill switch): v1.0.22 and earlier used 5279 (v1.0.21+)
    # or 5280 (v1.0.9-v1.0.20) -> table 100, so both priorities are probed. The "lookup 100"
    # qualifier is what keeps that honest: GL 4.9's own kill switch also sits at 5280, but as a
    # blackhole rule with no table lookup, so it can never satisfy this gate by itself.
    # IPv4 is always required. IPv6 is required only where v6 rules can exist: on an IPv4-only
    # router `ip -6 rule list` is empty, so demanding a v6 rule would mean the release gate below
    # could never pass and the 5260 lockdown would hold forever (permanent LAN blackout on every
    # "on" flip).
    { ip -4 rule list priority 5279; ip -4 rule list priority 5280; } 2>/dev/null | grep -q "lookup 100" || return 1
    [ -n "$(ip -6 rule list 2>/dev/null)" ] || return 0
    { ip -6 rule list priority 5279; ip -6 rule list priority 5280; } 2>/dev/null | grep -q "lookup 100"
}

# --- Logic ---
action=$1

# GL RPC endpoint — port lookup mirrors GL's own switch scripts in /etc/gl-switch.d/.
PORT=$(cat /etc/nginx/conf.d/gl.conf 2>/dev/null | grep -E "    listen [0-9]+;" | grep -oE '[0-9]+' | head -1)
[ -z "$PORT" ] && PORT=80
RPC="http://127.0.0.1:$PORT/rpc"

if [ "$action" = "on" ]; then
    # STEP 1: Pre-emptive lockdown. LAN/guest forwarding now blackholed at priority 5260
    # (above TS exit-node routing at 5270 and above the plugin's own kill switch), via our
    # own table 101. No traffic can leak during the transition that follows.
    lockdown_install

    # STEP 2: Defensive disable of competing VPN/proxy clients (WG, OpenVPN, Tor) only
    # if currently active. Their priority-6000 policy routing wins against Tailscale's
    # exit-node routing at priority 5270, so leaving any of them running would prevent
    # traffic from actually flowing through the Tailscale exit node. Backup for the
    # case where the slider was previously bound to one of those and is being rebound
    # here without explicit teardown. Pre-checks avoid spurious "Turning X OFF" MCU
    # notifications when the service wasn't on. With the 5260 lockdown in place above,
    # there is no leak window during this teardown.
    wg_status=$(curl -H 'glinet: 1' -s -k "$RPC" -d '{"jsonrpc":"2.0","method":"call","params":["","wg-client","get_status",{}],"id":1}' | jsonfilter -e '@.result.status' 2>/dev/null)
    [ -n "$wg_status" ] && [ "$wg_status" != "0" ] && /etc/gl-switch.d/wireguard.sh off >/dev/null 2>&1
    # OpenVPN's switch script has its own internal status pre-check, so direct call is safe.
    [ -x /etc/gl-switch.d/openvpn.sh ] && /etc/gl-switch.d/openvpn.sh off >/dev/null 2>&1
    tor_enabled=$(curl -H 'glinet: 1' -s -k "$RPC" -d '{"jsonrpc":"2.0","method":"call","params":["","tor","get_config",{}],"id":1}' | jsonfilter -e '@.result.enable' 2>/dev/null)
    [ "$tor_enabled" = "true" ] && /etc/gl-switch.d/tor.sh off >/dev/null 2>&1

    # STEP 3: Reuse GL's most recently selected exit node IP; fall back to default only
    # when GL has nothing set (first run or after a manual clear).
    exit_node_ip=$(uci -q get tailscale.settings.exit_node_ip)
    [ -z "$exit_node_ip" ] && exit_node_ip="$DEFAULT_EXIT_NODE_IP"

    # STEP 4: Enable Tailscale via GL's RPC, passing the resolved exit node IP.
    #
    # On 4.9+ the same request turns on GL's IP Masquerading (tailscale.settings.masq). GL split
    # that into its own toggle in 4.9 and the plugin defers to it, but LAN clients cannot reach
    # the exit node without it — so without this a flip brings Tailscale up and leaves the LAN
    # unable to use it until someone enables the toggle by hand in the GL UI. Pre-4.9 the payload
    # is byte-for-byte what it always was: the plugin's own masquerade handling covers those
    # firmwares, and that RPC has no masq parameter to send.
    ts_masq=""
    if is_fw49_plus; then
        ts_masq="\"masq\":true,"
    fi
    curl -H 'glinet: 1' -s -k "$RPC" -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tailscale\",\"set_config\",{\"enabled\":true,\"lan_enabled\":$LAN_ENABLED,${ts_masq}\"wan_enabled\":$WAN_ENABLED,\"exit_node_ip\":\"$exit_node_ip\"}],\"id\":1}"

    sleep 5

    # STEP 5: Apply gl-tailscale-fix posture in lock-step with Tailscale.
    curl -H 'glinet: 1' -s -k "$RPC" -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ts-fix\",\"set_config\",{\"kill_switch\":$KILL_SWITCH,\"route_guest\":$ROUTE_GUEST,\"advertise_exit_node\":$ADVERTISE_EXIT_NODE,\"tailscale_ssh\":$TAILSCALE_SSH}],\"id\":2}"

    # STEP 6: Release the lockdown only when the plugin's kill switch is confirmed active
    # (when KILL_SWITCH=true) or when the user has explicitly opted out of KS.
    #
    # This polls rather than checking once, because set_config returns BEFORE the kill switch
    # is holding: the plugin fires its kill-switch engine detached and answers the RPC straight
    # away, since severing the forwardings means committing UCI and reloading the firewall —
    # far too slow to hold an HTTP response open. A single immediate check would therefore see
    # "not armed yet" on essentially every flip and hold the lockdown forever. The 20-second
    # bound covers the detached start, the UCI commits and a slow fw3 firewall reload, and also
    # the worst case where the spawn is lost entirely: the plugin's own watchdog re-runs the arm
    # within its 5-second poll, which still completes comfortably inside the bound.
    #
    # If the bound expires the lockdown STAYS — something went wrong with set_config and we'd
    # rather fail-secure (LAN blackout) than risk a leak. SSH in and run `lockdown_remove` from
    # this script manually, or clear via `ip rule del iif br-lan priority 5260 lookup 101`
    # (repeat for br-guest, and for both with `ip -6`) plus
    # `ip route del unreachable default table 101` to recover.
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
            logger -t ts-fix-switch "kill switch not confirmed after ${waited}s - lockdown HELD, LAN and guest stay blocked (fail-secure). Recover with 'ip rule del iif br-lan priority 5260 lookup 101' and 'ip route del unreachable default table 101' (repeat for br-guest, and for both with ip -6); full list in the STEP 6 comment of $0"
        fi
    else
        lockdown_remove
    fi

elif [ "$action" = "off" ]; then
    # Clean up any lingering lockdown (5260 rules + table 101) from an interrupted prior "on".
    lockdown_remove

    # IP Masquerading is deliberately left alone here: on 4.9+ tailscale.settings.masq is
    # persistent user intent in GL's model, and with Tailscale disabled it does nothing anyway.
    #
    # Disable Tailscale via UCI directly, bypassing GL's RPC. This preserves
    # tailscale.settings.exit_node_ip so the next "on" flip reconnects to the same
    # node — calling GL's set_config would clear it. The gl-tailscale-fix watchdog
    # detects the enabled=0 transition and tears down the kill switch routing rules
    # within ~5 seconds.
    uci set tailscale.settings.enabled='0'
    uci commit tailscale
    /usr/bin/gl_tailscale restart >/dev/null 2>&1 &

else
    echo "Usage: $0 [on|off]" >&2
    exit 1
fi
