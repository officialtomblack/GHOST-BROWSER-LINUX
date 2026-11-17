#!/usr/bin/env bash
# Kill-switch test for Ghost Browser. It cuts the VPN tunnel on purpose and checks that nothing gets out.
# Real VPN - run it WHILE Ghost Browser is open:
#   sudo bash killswitch-test.sh
# No VPN account - it builds its own namespace with a dead WireGuard tunnel (to 192.0.2.1), tests it, removes it:
#   sudo bash killswitch-test.sh --dummy
# It prints how the namespace routes and filters, takes the tunnel interface DOWN (what a dropped VPN looks like),
# then tries to reach the internet from inside the namespace as your user.
# PASS = nothing gets out after the cut. A real namespace stays broken afterwards: close Ghost Browser when it finishes.
# It only acts inside Ghost Browser's own namespace (vo_*); your computer's own network and VPN are not touched.
set -uo pipefail

[[ $(id -u) -eq 0 ]] || { echo "Run with sudo."; exit 1; }
user="${SUDO_USER:-}"
[[ -n $user && $user != root ]] || { echo "Run with sudo from your normal user."; exit 1; }

if [[ ${1:-} == --dummy ]]; then
    [[ -z $(ip netns list | awk '/^vo_/') ]] || { echo "Close Ghost Browser first: a vopono namespace is already running."; exit 1; }
    work="$(mktemp -d /run/ghost-killswitch.XXXXXXXX)"
    chmod 755 "$work"
    {
        printf '[Interface]\nPrivateKey = %s\nAddress = 10.66.66.2/32\nDNS = 10.66.66.1\n\n' "$(wg genkey)"
        printf '[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 192.0.2.1:51820\n' "$(wg genkey | wg pubkey)"
    } > "$work/blackhole.conf"
    chmod 600 "$work/blackhole.conf"
    iface="$(ip -o route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
    # Same vopono flags as ghost-browser.sh; the app is just "sleep" - no browser needed for this test.
    vopono exec -u "$user" -i "$iface" --disable-ipv6 --custom "$work/blackhole.conf" --protocol Wireguard "sleep 300" \
        > "$work/vopono.log" 2>&1 &
    teardown() {
        for p in $(ip netns list | awk '/^vo_/ {print $1}' | xargs -r -n1 ip netns pids); do kill "$p" 2>/dev/null; done
        wait 2>/dev/null
        rm -rf -- "$work"
        echo "== dummy namespace removed: $(ip netns list | awk '/^vo_/' | wc -l) vopono namespaces left"
    }
    trap teardown EXIT
    for _ in $(seq 30); do [[ -n $(ip netns list | awk '/^vo_/') ]] && break; sleep 1; done
    sleep 3   # let vopono finish its firewall rules after the namespace appears
fi

mapfile -t nss < <(ip netns list | awk '/^vo_/ {print $1}')
[[ ${#nss[@]} -eq 1 ]] || { echo "Need exactly one vopono namespace running; found: ${nss[*]:-none}"; exit 1; }
ns="${nss[0]}"
inns()  { ip netns exec "$ns" "$@"; }
asuser() { ip netns exec "$ns" runuser -u "$user" -- "$@"; }
probe() {   # prints the IP the internet sees, or "no answer"
    asuser curl -sS -m 10 https://am.i.mullvad.net/ip 2>&1 || true
    if asuser curl -sS -m 8 -o /dev/null https://1.1.1.1 2>/dev/null; then echo "direct 1.1.1.1: REACHED"; else echo "direct 1.1.1.1: no answer"; fi
}

tun="$(inns ip -o link show | awk -F': ' '/POINTOPOINT/ {sub(/@.*/, "", $2); print $2; exit}')"
[[ -n $tun ]] || { echo "No tunnel interface found in $ns."; exit 1; }

echo "== namespace $ns, tunnel interface $tun"
inns ip -br link
echo "== ip rule";  inns ip rule
echo "== routes (all tables)"; inns ip route show table all | grep -v -E '^(local|broadcast|multicast) |fe80::|^ff00::'
echo "== firewall inside the namespace"; inns nft list ruleset
echo "== BEFORE the cut"; probe

inns ip link set "$tun" down
echo "== tunnel $tun is now DOWN"; inns ip -br link show "$tun"; inns ip route
echo "== AFTER the cut"
after="$(probe)"; echo "$after"

if grep -q -E '^[0-9a-f.:]+$' <<< "$(head -n1 <<< "$after")" || grep -q 'REACHED' <<< "$after"; then
    echo "RESULT: FAIL - traffic got out with the tunnel down (LEAK)"; exit 1
fi
echo "RESULT: PASS - nothing gets out with the tunnel down."
[[ ${1:-} == --dummy ]] || echo "Close Ghost Browser now - its tunnel is down."
