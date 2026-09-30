#!/bin/bash
#
# gl-tailscale-fix test suite — laptop-side egress leak monitor
#
# Runs ON the monitored LAN client (the laptop). Time-boxed: every INTERVAL
# seconds for DURATION seconds it fetches the public IPv4 AND IPv6 egress
# concurrently, classifies each against the known tunnel (exit-node) egress, and
# writes a CSV plus a JSON summary. It is entirely local, so a WAN/kill-switch
# blackhole does NOT stop it — the curls simply time out and are recorded as
# "blocked" (the desired result when the KS is holding). Observation only; it
# never changes anything on the router or the laptop.
#
# Classification (per family):
#   ok      = egress equals the tunnel baseline (normal tunnelling)
#   blocked = no usable response (KS holding — also the desired result)
#   LEAK    = some other public IP answered (real address exposed)
# If no tunnel baseline is supplied for a family, ANY response on that family is
# treated as a LEAK and no-response as ok (correct privacy stance).
#
# TWO-LAYER KILL SWITCH — what "blocked" looks like on the wire depends on which
# layer stops the packet, while the leak semantics above do NOT. Neither layer
# touches this client's own routes:
#   rule layer  once the exit node's route is gone, the router's priority-5279
#               rules send the forwarded packet to an "unreachable default" in
#               table 100, and the router answers with an ICMP host unreachable;
#   zone layer  the router's lan/guest/iot -> uplink forwardings are severed, so
#               the packet dies in its forward chain — a rejection or a silent
#               drop.
# Two consequences for this instrument, both benign:
#   1. have_route()'s "no route at all" fast-skip is never a kill-switch signal:
#      an armed router leaves this client its route, so each armed sample really
#      does attempt a connection. Cadence is bounded by MAXTIME either way, and an
#      ICMP unreachable or a REJECT answers faster than a timeout.
#   2. "blocked" therefore means "no usable answer" rather than "no route", which
#      is what the verdict logic already required. A LEAK is still, and only, a
#      non-tunnel public IP that actually answered.
#
# Env: DURATION INTERVAL LABEL TUNNEL_V4 TUNNEL_V6 MAXTIME OUTDIR CSV JSON
#      V4_URLS V6_URLS
#
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix

set -u

DURATION="${DURATION:-180}"
INTERVAL="${INTERVAL:-1}"
LABEL="${LABEL:-egress}"
TUNNEL_V4="${TUNNEL_V4:-}"
TUNNEL_V6="${TUNNEL_V6:-}"
MAXTIME="${MAXTIME:-3}"
CONNTIME="${CONNTIME:-2}"
OUTDIR="${OUTDIR:-$(cd "$(dirname "$0")/.." && pwd)/results}"
V4_URLS="${V4_URLS:-https://v4.ident.me https://api.ipify.org}"
V6_URLS="${V6_URLS:-https://v6.ident.me https://api6.ipify.org}"
V4_PROBE="${V4_PROBE:-1.1.1.1}"
V6_PROBE="${V6_PROBE:-2606:4700:4700::1111}"

mkdir -p "$OUTDIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
csv="${CSV:-$OUTDIR/${stamp}-${LABEL}-egress.csv}"
json="${JSON:-$OUTDIR/${stamp}-${LABEL}-egress.json}"
ts_start="$(date +%s)"

# Client routing precondition, recorded into the artifact.
#
# A leak detector running on a multi-homed client can be silently wrong: with a second default
# route present, probes may egress a path other than the one under test and return a public IP
# that is neither the tunnel baseline nor a timeout — which this script scores as LEAK. The
# realistic way that happens mid-run is NetworkManager reconnecting a wifi interface it had
# dropped, precisely because an armed kill switch makes the wired path look offline to it.
#
# Captured at start AND end so a change during the run lands in the JSON instead of quietly
# rewriting the verdict. Expected shape for a valid run: exactly one v4 and one v6 default, both
# on the interface facing the router under test.
snapshot_routes() { { ip -4 route show default; ip -6 route show default; } 2>/dev/null | tr '\n' ';'; }
routes_start="$(snapshot_routes)"

valid_ip() {
  case "$1" in
    "" | *[!0-9a-fA-F:.]*) return 1 ;;
    *) return 0 ;;
  esac
}

fetch() {
  # $1 = -4|-6 ; $2 = space-separated URLs ; prints a valid IP from PARALLEL
  # attempts (first to land wins), else empty. Parallel so a dead/slow fallback
  # URL can't serialize the timeouts — family wall-time stays ~MAXTIME regardless
  # of how many URLs are listed, keeping sampling cadence tight during a blackhole.
  local fam="$1" urls="$2" url d f n=0
  d="$(mktemp -d)"
  for url in $urls; do
    (
      o="$(curl "$fam" -s --connect-timeout "$CONNTIME" --max-time "$MAXTIME" "$url" 2>/dev/null | tr -d '[:space:]')"
      valid_ip "$o" && printf '%s' "$o" > "$d/r$n"
    ) &
    n=$(( n + 1 ))
  done
  wait
  for f in "$d"/r*; do
    if [ -s "$f" ]; then head -n1 "$f"; rm -rf "$d"; return 0; fi
  done
  rm -rf "$d"
  printf ''
}

have_route() {
  # $1 = -4|-6 ; $2 = probe dest ; returns 0 if ANY non-unreachable route exists.
  # Under the zone kill switch this is true even while armed (severing a forwarding
  # does not touch the client's routes), so it is now purely a no-connectivity
  # fast-skip rather than a KS-state signal — see the header note. It is kept
  # because it still saves a full MAXTIME wait on a family the client cannot use
  # at all, and because a false "blocked" from skipping a usable path would hide
  # a leak.
  # We deliberately do NOT require a global v6 source. GL hands clients a ULA, and
  # a ULA can be NAT6'd straight to the real WAN when the tunnel drops — i.e. a ULA
  # source can still LEAK. The earlier "require global v6 src" optimization produced
  # a FALSE NEGATIVE: it recorded "blocked" and would have missed exactly that v6
  # leak. Correctness over cadence for a leak detector — curl v6 whenever a route
  # exists; the only fast-skip is "no route at all". (Fixed 2026-06-24.)
  local fam="$1" line
  line="$(ip "$fam" route get "$2" 2>/dev/null)" || return 1
  case "$line" in "" | *unreachable*) return 1 ;; *) return 0 ;; esac
}

sample_fam() {
  # $1 = -4|-6 ; $2 = urls ; $3 = probe dest ; prints egress IP or empty (blocked)
  if have_route "$1" "$3"; then fetch "$1" "$2"; else printf ''; fi
}

classify() {
  # $1 = v4|v6 ; $2 = ip ; prints ok|blocked|LEAK
  local fam="$1" ip="$2" tun=""
  [ "$fam" = "v4" ] && tun="$TUNNEL_V4" || tun="$TUNNEL_V6"
  if [ -z "$ip" ]; then printf 'blocked'; return; fi
  if [ -n "$tun" ] && [ "$ip" = "$tun" ]; then printf 'ok'; return; fi
  printf 'LEAK'
}

printf 'ts_epoch,ts_iso,v4_ip,v4_class,v6_ip,v6_class\n' > "$csv"
{
  echo "[egress-monitor] start=$stamp duration=${DURATION}s interval=${INTERVAL}s label=$LABEL"
  echo "[egress-monitor] tunnel_v4=${TUNNEL_V4:-<none>} tunnel_v6=${TUNNEL_V6:-<none>}"
  echo "[egress-monitor] artifact=$csv"
} >&2

leak4=0; leak6=0; samples=0; first_leak=""; saw_event=0; saw_ok=0
tmp4="$(mktemp)"; tmp6="$(mktemp)"
trap 'rm -f "$tmp4" "$tmp6"' EXIT
end=$(( ts_start + DURATION ))

while [ "$(date +%s)" -lt "$end" ]; do
  ( sample_fam -4 "$V4_URLS" "$V4_PROBE" > "$tmp4" ) & j4=$!
  ( sample_fam -6 "$V6_URLS" "$V6_PROBE" > "$tmp6" ) & j6=$!
  wait "$j4" "$j6"
  v4="$(cat "$tmp4")"; v6="$(cat "$tmp6")"
  c4="$(classify v4 "$v4")"; c6="$(classify v6 "$v6")"
  now="$(date +%s)"
  iso="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s,%s,%s,%s,%s,%s\n' "$now" "$iso" "${v4:-}" "$c4" "${v6:-}" "$c6" >> "$csv"
  samples=$(( samples + 1 ))
  if [ "$c4" = "LEAK" ]; then leak4=$(( leak4 + 1 )); [ -z "$first_leak" ] && first_leak="$now"; fi
  if [ "$c6" = "LEAK" ]; then leak6=$(( leak6 + 1 )); [ -z "$first_leak" ] && first_leak="$now"; fi
  # Positive control: did the protected path EVER work inside this window? Without at
  # least one "ok" sample there is no way to tell "the kill switch blocked it" from
  # "this client never had egress at all" — and an all-blocked run with no tunnel
  # baseline satisfies saw_event on its very first sample, so it would score PASS
  # having exercised nothing.
  [ "$c4" = "ok" ] && saw_ok=1
  # Did we actually observe the tunnel-down event? (v4 leaving "ok", or any v6 leak.)
  { [ "$c4" != "ok" ] || [ "$c6" = "LEAK" ]; } && saw_event=1
  printf '[%s] v4=%-15s(%s)  v6=%-25s(%s)\n' "$iso" "${v4:-none}" "$c4" "${v6:-none}" "$c6" >&2
  sleep "$INTERVAL"
done

# A leak detector must NEVER report PASS unless it actually OBSERVED the tunnel go
# down (v4 leaving "ok", or any v6 leak). If v4 stayed "ok" the whole run, the test
# event never fell inside the window -> INCONCLUSIVE, not pass. (2026-06-24: a fixed
# 300s countdown expired before the operator acted and the monitor falsely PASSed.)
if [ "$leak4" -gt 0 ] || [ "$leak6" -gt 0 ]; then
    verdict=LEAK
elif [ "$saw_ok" = "1" ] && [ "$saw_event" = "1" ]; then
    verdict=PASS
else
    verdict=INCONCLUSIVE
fi
routes_end="$(snapshot_routes)"
if [ "$routes_start" != "$routes_end" ]; then
  echo "[egress-monitor] WARNING: client default routes CHANGED during the run." >&2
  echo "[egress-monitor]   start: $routes_start" >&2
  echo "[egress-monitor]   end  : $routes_end" >&2
  echo "[egress-monitor]   Treat this run's verdict as suspect — probes may have egressed a" >&2
  echo "[egress-monitor]   path other than the one under test. Re-run with a stable client." >&2
fi

cat > "$json" <<JSON
{
  "label": "$LABEL",
  "start_epoch": $ts_start,
  "end_epoch": $(date +%s),
  "duration_s": $DURATION,
  "interval_s": $INTERVAL,
  "tunnel_v4": "$TUNNEL_V4",
  "tunnel_v6": "$TUNNEL_V6",
  "samples": $samples,
  "leak_v4_count": $leak4,
  "leak_v6_count": $leak6,
  "tunnel_down_observed": $saw_event,
  "tunnel_baseline_observed": $saw_ok,
  "client_default_routes_start": "$routes_start",
  "client_default_routes_end": "$routes_end",
  "client_routes_stable": $( [ "$routes_start" = "$routes_end" ] && echo true || echo false ),
  "first_leak_epoch": "$first_leak",
  "csv": "$csv",
  "verdict": "$verdict"
}
JSON

echo "[egress-monitor] done samples=$samples leak_v4=$leak4 leak_v6=$leak6 verdict=$verdict" >&2
