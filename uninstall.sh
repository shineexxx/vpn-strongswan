#!/bin/bash
# Remove what install.sh added.
#
# Keeps, unless --purge is given:
#   /etc/swanctl/vpn-users              the user database
#   /etc/letsencrypt/                   the certificate
#   the strongswan packages
set -euo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

info "stopping services"
systemctl disable --now strongswan.service   >/dev/null 2>&1 || true
systemctl disable --now vpn-reap.timer       >/dev/null 2>&1 || true
systemctl disable --now vpn-firewall.service >/dev/null 2>&1 || true

info "flushing VPN firewall rules"
for t in filter nat mangle; do
    iptables  -t "$t" -F 2>/dev/null || true
    ip6tables -t "$t" -F 2>/dev/null || true
done
iptables  -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true

info "removing files"
rm -f /etc/systemd/system/vpn-firewall.service \
      /etc/systemd/system/vpn-reap.service \
      /etc/systemd/system/vpn-reap.timer
rm -f /usr/local/sbin/vpn-firewall.sh /usr/local/sbin/vpn-user \
      /usr/local/sbin/vpn-profile /usr/local/sbin/vpn-reap
rm -f /usr/local/libexec/vpn-sas.py
rm -f /etc/letsencrypt/renewal-hooks/deploy/10-strongswan.sh
rm -f /etc/sysctl.d/99-vpn-ikev2.conf
rm -f /etc/swanctl/conf.d/ikev2.conf /etc/swanctl/conf.d/users.conf
rm -f /etc/swanctl/x509/server-cert.pem /etc/swanctl/private/server-key.pem
rm -f /etc/swanctl/x509ca/le-chain-*.pem
systemctl daemon-reload

if [ "$PURGE" = 1 ]; then
    info "purging user database, profiles and configuration"
    rm -f /etc/swanctl/vpn-users /etc/vpn-strongswan.env
    rm -rf /srv/vpn
    echo "The Let's Encrypt certificate was left in place. To drop it too:"
    echo "    certbot delete --cert-name \$DOMAIN"
else
    echo
    echo "Kept: /etc/swanctl/vpn-users, /etc/vpn-strongswan.env, /srv/vpn, the certificate."
    echo "Re-run with --purge to remove those as well."
fi

info "done"
