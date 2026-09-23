#!/bin/bash
# Firewall rules required by the IKEv2/IPsec server.
# Idempotent: safe to run repeatedly. Applied at boot by vpn-firewall.service.
set -eu

. /etc/vpn-strongswan.env

IPT=/usr/sbin/iptables
IP6T=/usr/sbin/ip6tables

# ensure <binary> <table> <chain> <rule...> -- appends only if not already present
ensure() {
    local bin="$1" table="$2" chain="$3"
    shift 3
    "$bin" -t "$table" -C "$chain" "$@" 2>/dev/null || "$bin" -t "$table" -A "$chain" "$@"
}

# drop_stale_mss <binary> <mss> -- removes TCPMSS rules left over from an older
# value, so changing TCP_MSS4/TCP_MSS6 and re-running replaces the clamp
# instead of stacking a second one next to it.
drop_stale_mss() {
    local bin="$1" mss="$2" line
    "$bin" -t mangle -S FORWARD | grep -- '-j TCPMSS' | grep -v -- "--set-mss $mss\$" |
    while read -r line; do
        read -ra rule <<<"${line#-A }"
        "$bin" -t mangle -D "${rule[@]}"
    done
}

MSS4="${TCP_MSS4:-1280}"
MSS6="${TCP_MSS6:-1260}"

# ---------- IPv4 ----------

# Let IKE and UDP-encapsulated ESP reach charon.
ensure "$IPT" filter INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT
ensure "$IPT" filter INPUT -p esp -j ACCEPT

# Traffic that is still under an IPsec policy must not be NATed.
ensure "$IPT" nat POSTROUTING -s "$POOL4" -o "$WAN_IF" -m policy --pol ipsec --dir out -j ACCEPT
# Everything else from the pool leaves as the server's own address.
ensure "$IPT" nat POSTROUTING -s "$POOL4" -o "$WAN_IF" -j MASQUERADE

# The tunnel eats ~60-80 bytes of header, and the client's own uplink (PPPoE,
# mobile) may eat more; ICMP "fragmentation needed" is often filtered on the
# way, so oversized packets black-hole instead of shrinking. Clamp MSS with
# margin -- 1360 was not enough for Windows clients behind a ~1350 path.
drop_stale_mss "$IPT" "$MSS4"
ensure "$IPT" mangle FORWARD -m policy --pol ipsec --dir in -s "$POOL4" -o "$WAN_IF" \
    -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss "$((MSS4 + 1)):65535" -j TCPMSS --set-mss "$MSS4"

# Forward only decrypted VPN traffic and its replies.
ensure "$IPT" filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ensure "$IPT" filter FORWARD -m policy --pol ipsec --dir in  --proto esp -s "$POOL4" -j ACCEPT
ensure "$IPT" filter FORWARD -m policy --pol ipsec --dir out --proto esp -d "$POOL4" -j ACCEPT
"$IPT" -P FORWARD DROP

# ---------- IPv6 ----------

if [ "${ENABLE_IPV6:-0}" = 1 ]; then
    ensure "$IP6T" filter INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT
    ensure "$IP6T" filter INPUT -p esp -j ACCEPT

    # NAT66 from the ULA pool to the server's global address, so clients get
    # working IPv6 through the tunnel instead of leaking it around the tunnel.
    ensure "$IP6T" nat POSTROUTING -s "$POOL6" -o "$WAN_IF" -m policy --pol ipsec --dir out -j ACCEPT
    ensure "$IP6T" nat POSTROUTING -s "$POOL6" -o "$WAN_IF" -j MASQUERADE

    drop_stale_mss "$IP6T" "$MSS6"
    ensure "$IP6T" mangle FORWARD -m policy --pol ipsec --dir in -s "$POOL6" -o "$WAN_IF" \
        -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss "$((MSS6 + 1)):65535" -j TCPMSS --set-mss "$MSS6"

    ensure "$IP6T" filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ensure "$IP6T" filter FORWARD -m policy --pol ipsec --dir in  --proto esp -s "$POOL6" -j ACCEPT
    ensure "$IP6T" filter FORWARD -m policy --pol ipsec --dir out --proto esp -d "$POOL6" -j ACCEPT
    "$IP6T" -P FORWARD DROP
fi

echo "vpn-firewall: rules applied (WAN=$WAN_IF, v4=$POOL4, v6=${ENABLE_IPV6:-0}, mss=$MSS4/$MSS6)"
