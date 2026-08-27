#!/bin/bash
# Publish the Let's Encrypt certificate into strongSwan.
# Runs from certbot's deploy hook on every successful issue/renewal, and can
# be run by hand at any time.
set -eu

. /etc/vpn-strongswan.env

LIVE="/etc/letsencrypt/live/$DOMAIN"

[ -f "$LIVE/cert.pem" ] || { echo "no certificate at $LIVE"; exit 0; }

umask 077

install -m 0644 "$LIVE/cert.pem"    /etc/swanctl/x509/server-cert.pem
install -m 0600 "$LIVE/privkey.pem" /etc/swanctl/private/server-key.pem

# Clients trust the ISRG root but not the intermediate, so charon has to be
# able to send the chain. chain.pem may hold more than one certificate and
# swanctl reads one per file, so split it.
rm -f /etc/swanctl/x509ca/le-chain-*.pem
awk 'BEGIN { n = 0 }
     /-----BEGIN CERTIFICATE-----/ { n++ }
     n > 0 { print > sprintf("/etc/swanctl/x509ca/le-chain-%02d.pem", n) }' "$LIVE/chain.pem"
chmod 0644 /etc/swanctl/x509ca/le-chain-*.pem 2>/dev/null || true

if systemctl is-active --quiet strongswan.service; then
    # --load-all adds credentials but does not evict ones already in memory, so
    # a replaced certificate needs a restart to actually take effect.
    systemctl restart strongswan.service
    echo "strongswan: restarted with renewed certificate"
fi
