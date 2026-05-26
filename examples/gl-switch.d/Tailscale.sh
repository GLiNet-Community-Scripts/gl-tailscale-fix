#!/bin/sh
#
# Toggle Tailscale (GL native) + gl-tailscale-fix Kill Switch and related
# preferences together via the physical side switch on supported GL.iNet
# routers (Beryl AX, Slate AX, etc.).
#
# Install on the router:
#   wget -q https://raw.githubusercontent.com/RemoteToHome-io/gl-tailscale-fix/main/examples/gl-switch.d/Tailscale.sh -O /etc/gl-switch.d/Tailscale.sh
#   chmod +x /etc/gl-switch.d/Tailscale.sh
#
# Then edit the Configuration block below to your preferred posture.
# Every "on" flip applies that posture in full, so a single edit here
# locks in your setup across switch toggles.
#
# Exit-node handling is special: by default the script reuses GL's most
# recently selected exit node (so changing the selection in the GL UI
# sticks across toggles). DEFAULT_EXIT_NODE_IP is used only as a fallback
# on first run, when nothing has been selected yet.
#
# By default this script treats slider "on" as "enable Tailscale + apply
# posture" and slider "off" as "disable everything." If you prefer the
# inverted convention (resting position is "off" with Tailscale active),
# swap the action names in the if/elif branches below.
#
# Requires gl-tailscale-fix v1.0.9 or later for the ts-fix RPC.
# Released under the same terms as gl-tailscale-fix (GPL-3.0).

# --- Configuration ---
DEFAULT_EXIT_NODE_IP="XX.XX.XX.XX"   # Fallback only — see note above

# GL native settings
LAN_ENABLED=false                     # Allow Remote Access LAN
WAN_ENABLED=false                     # Allow Remote Access WAN

# gl-tailscale-fix settings — restored on every "on" because the plugin's
# watchdog tears these down to 0 when Tailscale is disabled.
KILL_SWITCH=true                      # Engage kill switch on enable
ROUTE_GUEST=false                     # Route guest network through Tailscale
ADVERTISE_EXIT_NODE=false             # Advertise this router as an exit node
TAILSCALE_SSH=false                   # Enable Tailscale's ACL-based SSH

# --- Logic ---
action=$1

if [ "$action" = "on" ]; then
    # Reuse GL's most recently selected exit node IP; fall back to default
    # only when GL has nothing set (first run or after a manual clear).
    exit_node_ip=$(uci -q get tailscale.settings.exit_node_ip)
    [ -z "$exit_node_ip" ] && exit_node_ip="$DEFAULT_EXIT_NODE_IP"

    # Enable Tailscale via GL's RPC, passing the resolved exit node IP.
    curl -H 'glinet: 1' -s -k http://127.0.0.1/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tailscale\",\"set_config\",{\"enabled\":true,\"lan_enabled\":$LAN_ENABLED,\"wan_enabled\":$WAN_ENABLED,\"exit_node_ip\":\"$exit_node_ip\"}],\"id\":1}"

    sleep 5

    # Apply gl-tailscale-fix posture in lock-step with Tailscale.
    curl -H 'glinet: 1' -s -k http://127.0.0.1/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ts-fix\",\"set_config\",{\"kill_switch\":$KILL_SWITCH,\"route_guest\":$ROUTE_GUEST,\"advertise_exit_node\":$ADVERTISE_EXIT_NODE,\"tailscale_ssh\":$TAILSCALE_SSH}],\"id\":2}"

elif [ "$action" = "off" ]; then
    # Disable Tailscale via UCI directly, bypassing GL's RPC. This
    # preserves tailscale.settings.exit_node_ip so the next "on" flip
    # reconnects to the same node — calling GL's set_config would clear
    # it. The gl-tailscale-fix watchdog detects the enabled=0 transition
    # and tears down the kill switch routing rules within ~5 seconds.
    uci set tailscale.settings.enabled='0'
    uci commit tailscale
    /usr/bin/gl_tailscale restart >/dev/null 2>&1 &

else
    echo "Usage: $0 [on|off]" >&2
    exit 1
fi
