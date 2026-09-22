# vpn-strongswan

A self-hosted IKEv2/IPsec VPN server on strongSwan, deployable to a fresh
Debian/Ubuntu box in about five minutes.

**Nothing gets installed on the client.** The server authenticates with a Let's
Encrypt certificate that every device already trusts, and clients authenticate
with a username and password over EAP-MSCHAPv2. iOS, macOS, Windows and Android
all connect with their built-in VPN client — no app, no CA file to sideload, no
"trust this certificate" step. That is the whole point of choosing IKEv2 over
WireGuard here: it is the only protocol every mainstream OS ships a client for.

| | |
|---|---|
| Protocol | IKEv2 / IPsec, full tunnel (IPv4 + IPv6) |
| Server auth | Let's Encrypt certificate, renewed automatically |
| Client auth | EAP-MSCHAPv2 (username + password) |
| Ports | UDP 500, UDP 4500, TCP 80 (certificate renewal only) |
| Clients | iOS, macOS, Windows, Android 11+, Linux — all built-in |
| Tested on | Ubuntu 24.04 LTS; should work on Debian 12 and Ubuntu 22.04 |

---

## Requirements

- A VPS running Debian 12+ or Ubuntu 22.04+ with root access.
- A public IPv4 address. IPv6 is optional but recommended — see
  [IPv6](#ipv6-and-why-it-matters) below.
- A domain name you control, with an **A record pointing at the server**
  (and an AAAA record if the server has IPv6). Let's Encrypt validates over it,
  and clients match it against the certificate.
- **TCP port 80 free and reachable from the internet.** Certificate issuance and
  every renewal bind it for a few seconds. If you already run a web server, see
  [Certificate](#certificate) for the webroot alternative.

---

## Deployment

### 1. Point DNS at the server

Create an `A` record for the hostname you will use, e.g.
`vpn.example.com → 203.0.113.10`. If the server has a global IPv6 address, add
an `AAAA` record too. Wait for it to resolve:

```bash
dig +short vpn.example.com
```

Do not continue until this returns the server's address. The installer checks
it and refuses to run otherwise.

### 2. Get the code onto the server

```bash
ssh root@203.0.113.10
apt-get update && apt-get install -y git
git clone https://github.com/shineexxx/vpn-strongswan.git
cd vpn-strongswan
chmod +x install.sh uninstall.sh
```

### 3. Configure

```bash
cp vpn.env.example vpn.env
nano vpn.env
```

Only two fields are mandatory:

```bash
DOMAIN=vpn.example.com      # must match the DNS record from step 1
LE_EMAIL=you@example.com    # Let's Encrypt expiry warnings
```

Everything else has a working default. Worth knowing about:

| Variable | Default | Notes |
|---|---|---|
| `WAN_IF` | autodetect | Taken from the default route. Set it manually only on multi-homed hosts. |
| `POOL4` | `10.10.10.0/24` | Addresses handed to clients. Must not collide with the networks your clients sit on at home — `192.168.0.0/24` and `192.168.1.0/24` are terrible choices for this reason. |
| `POOL6` | random ULA | Generated per install. Never copy one between servers. |
| `ENABLE_IPV6` | `auto` | Enabled when the WAN interface has a global IPv6 address. |
| `DNS4` / `DNS6` | Cloudflare + Google | DNS servers pushed to clients. |
| `VPN_NAME` | `MyVPN` | Name shown on the device for Apple profiles. |
| `CREDS_LANG` | `en` | `en` or `ru` — language of the credentials block `vpn-user` prints. |

### 4. Install

```bash
sudo ./install.sh
```

It will, in order: verify DNS and that port 80 is free, install strongSwan and
certbot, write `/etc/vpn-strongswan.env`, enable IP forwarding, install the `vpn-*`
tools and systemd units, apply the firewall rules, obtain the certificate, and
start the daemon.

Re-running it later is safe — it upgrades the scripts and re-renders the config
without touching the user database or the certificate. If the connection config
on disk differs from what it would write, the old one is kept as
`/etc/swanctl/conf.d/ikev2.conf.bak`.

Useful flags:

```bash
sudo ./install.sh --no-cert          # skip certbot (certificate already exists)
sudo ./install.sh --skip-dns-check   # behind a 1:1 NAT, or DNS not propagated yet
sudo ./install.sh --config /path/to/vpn.env
```

### 5. Create a user

```bash
sudo vpn-user add alice
```

This prints a ready-to-forward block with the server address, login and
generated password, plus where to find the VPN screen on each platform. Pass a
password as a second argument to choose your own.

### 6. Connect

Enter four things in the device's built-in VPN settings:

| Field | Value |
|---|---|
| Server / Server address | `vpn.example.com` |
| Remote ID | `vpn.example.com` |
| Local ID | leave empty |
| Username / Password | from `vpn-user add` |

`Remote ID` must be exactly the hostname — it is matched against the
certificate, so an IP address there will fail.

- **iOS** — Settings → General → VPN & Device Management → VPN → Add VPN
  Configuration → Type `IKEv2`.
- **macOS** — System Settings → VPN → Add VPN Configuration → IKEv2.
- **Windows** — Settings → Network & Internet → VPN → Add VPN. Provider
  `Windows (built-in)`, VPN type `IKEv2`, sign-in info `User name and password`.
  Works as-is; see [Crypto](#crypto) for why it negotiates a weaker DH group and
  how to fix that per machine.
- **Android 11+** — Settings → Network & internet → VPN → **+** → Type
  `IKEv2/IPSec MSCHAPv2`. Leave "IPSec identifier" empty and "IPSec CA
  certificate" on the default ("Receive from server" / "(none)") — Let's Encrypt
  is in Android's trust store.
- **Android 10 and older**, or if the built-in client misbehaves — the
  *strongSwan VPN Client* app, profile type `IKEv2 EAP (Username/Password)`,
  "CA certificate" on **Select automatically**.
- **Linux** — NetworkManager with `network-manager-strongswan`, gateway
  `vpn.example.com`, authentication `EAP`. Leave the CA field empty to use the
  system trust store.

### 7. Optional: one-tap profile for Apple devices

```bash
sudo vpn-profile alice        # -> /srv/vpn/alice.mobileconfig
```

Copy it to the device and open it; every field is filled in automatically.

```bash
scp you@vpn.example.com:/srv/vpn/alice.mobileconfig ~/Downloads/
```

The file **contains the password in clear text** — treat it like a password.
`/srv/vpn` is `root:vpn` mode `0750`; the installer adds the invoking user to the
`vpn` group so profiles can be fetched without sudo (log out and back in for the
group to take effect).

---

## Administration

```bash
vpn-user add <name> [password]     # add user (random password if omitted)
vpn-user passwd <name> [password]  # change password
vpn-user del <name>                # remove user, drop only their sessions
vpn-user list                      # all users and passwords
vpn-user show <name>               # reprint one user's credentials block
vpn-user who                       # who is connected, with source IP and uptime
vpn-user reload                    # re-apply /etc/swanctl/vpn-users

vpn-profile <name>                 # build .mobileconfig
vpn-reap --dry-run                 # show which idle sessions would be reclaimed

vpn-proxy status                   # proxy state, exposure, authorized keys
vpn-proxy key add "ssh-ed25519 …"  # authorize a client to tunnel in
vpn-proxy key list                 # fingerprints of authorized keys
vpn-proxy key remove <fragment>    # revoke by comment or fingerprint

swanctl --list-sas                 # raw session list
swanctl --list-conns               # loaded connection config
swanctl --list-pools --leases      # pool usage
systemctl status strongswan
journalctl -u strongswan -f
```

The user database is `/etc/swanctl/vpn-users`, one `name:password` per line, in
clear text (EAP-MSCHAPv2 needs the plaintext password server-side — that is a
property of the protocol, not a shortcut taken here). `vpn-user` regenerates
`/etc/swanctl/conf.d/users.conf` from it and reloads the daemon; you can also
edit the database by hand and run `vpn-user reload`.

After editing `/etc/swanctl/conf.d/ikev2.conf` by hand:

```bash
swanctl --load-all
```

Note that `--load-all` adds credentials but does not evict ones already in
memory, and does not retime SAs that already exist. After replacing a
certificate or changing timers, use `systemctl restart strongswan` — which drops
every live tunnel.

---

## Selective routing: the HTTP proxy

The VPN is all-or-nothing: turn it on and every packet leaves through this
server. That is usually what you want, and sometimes exactly what you don't —
a bank that dislikes foreign logins, a video service that geoblocks the server's
country, a slow path to a site that was fine before.

The optional proxy covers the other case. It routes *only* the requests a client
deliberately sends to it, so you can push a handful of sites through this server
while everything else takes the local route, with the VPN switched off.

Enable it in `vpn.env` before installing:

```bash
ENABLE_PROXY=1
PROXY_PORT=8888
PROXY_SSH_KEY="ssh-ed25519 AAAAC3Nza... laptop"
```

`install.sh` then installs tinyproxy, binds it to `127.0.0.1:$PROXY_PORT`,
creates the unprivileged account `proxyswitch`, and authorizes that key for one
thing: forwarding to the proxy port.

### Reaching it

The proxy is not published to the internet — there is no open port and no
password. A client opens an SSH tunnel and talks to its own loopback:

```bash
ssh -N -L 8888:127.0.0.1:8888 proxyswitch@<server>
curl -x http://127.0.0.1:8888 https://example.com
```

Point a browser's proxy setting, a PAC file, or `HTTPS_PROXY` at
`http://127.0.0.1:8888` and those requests exit from this server.

### Why an SSH tunnel rather than a password

An HTTP proxy on a public address is found by scanners within minutes, and
`Basic` auth over a proxy is a password sent on every request. Keeping the
listener on loopback removes the attack surface instead of guarding it, and SSH
already solves authentication with keys.

The authorization line each key gets is deliberately narrow:

```
restrict,port-forwarding,permitopen="127.0.0.1:8888",command="/bin/false"
```

`restrict` drops pty, agent and X11 forwarding; `permitopen` allows exactly one
forward destination; the forced command closes the remaining gap, because
`restrict` on its own still permits `ssh host <command>`. A leaked key buys an
attacker the use of your proxy — not a shell on the machine that routes your
traffic.

### Notes

* `ConnectPort` in the rendered config limits HTTPS tunnelling to 443 and 563.
  Add ports there if you need a site on a non-standard one.
* The log at `/var/log/tinyproxy/tinyproxy.log` records every `CONNECT` and is
  the only reliable way to answer "did that request really go through the
  proxy?" — clients fail over to a direct connection more often than you would
  expect.
* `ENABLE_PROXY=0` on a re-run stops and disables a proxy from an earlier
  install; `uninstall.sh --purge` also deletes the account and its keys.

---

## How it works

| Path | What |
|---|---|
| `/etc/vpn-strongswan.env` | generated runtime config; every `vpn-*` script sources it |
| `/etc/swanctl/conf.d/ikev2.conf` | connection, pools, crypto proposals |
| `/etc/swanctl/conf.d/users.conf` | generated from the database — do not edit |
| `/etc/swanctl/vpn-users` | user database, source of truth |
| `/etc/swanctl/x509/server-cert.pem` | deployed server certificate |
| `/etc/swanctl/x509ca/le-chain-*.pem` | Let's Encrypt chain, one cert per file |
| `/etc/swanctl/private/server-key.pem` | server private key |
| `/etc/letsencrypt/renewal-hooks/deploy/10-strongswan.sh` | redeploys the cert on renewal |
| `/usr/local/sbin/vpn-firewall.sh` | NAT, forwarding and MSS rules |
| `/etc/systemd/system/vpn-firewall.service` | applies them at boot |
| `/etc/systemd/system/vpn-reap.timer` | reclaims abandoned sessions every 6h |
| `/etc/sysctl.d/99-vpn-ikev2.conf` | IP forwarding and redirect hardening |
| `/srv/vpn/` | generated Apple profiles (`root:vpn`, `0750`) |

Firewall rules are applied by an idempotent script at boot rather than restored
from `iptables-save`, so there is one authoritative source for them and no
chance of a stale saved ruleset diverging from the config. They cover exactly
four things: letting IKE/ESP reach the daemon, NAT for the client pools,
forwarding only decrypted VPN traffic, and clamping TCP MSS (the tunnel eats
~60 bytes of header, and without the clamp large packets silently black-hole).

`iptables -P FORWARD DROP` is set. **If you later install Docker or another
container runtime on the same host, that policy will affect it** — Docker
inserts its own FORWARD rules but expects to coexist with a permissive policy.
This is meant for a dedicated VPN box.

### IPv6, and why it matters

Clients get an address from a ULA pool, NAT66'ed to the server's global IPv6.
Handing out IPv6 is not a nicety: a client with working IPv6 at home, given a
v4-only tunnel, will happily send IPv6 traffic *around* it — straight to the
destination, outside the VPN. Giving the tunnel a v6 address closes that leak.

Enabling IPv6 forwarding makes the Linux kernel stop accepting Router
Advertisements, since a router is not supposed to take routing orders from one.
On hosts whose own IPv6 address comes from SLAAC (Hetzner, DigitalOcean, most
clouds) that silently drops the server off IPv6 minutes after install, when the
current lease expires. The installer therefore writes
`net.ipv6.conf.<wan>.accept_ra = 2` — "accept RA even while forwarding" — which
is the documented fix and harmless on statically-addressed hosts.

### Session handling, and the two bugs that shaped it

The connection config disables server-initiated rekey, reauth **and** DPD:

```
rekey_time  = 0
reauth_time = 0
dpd_delay   = 0
```

This is deliberate, and each zero has a specific incident behind it. Both
produced the same user-visible symptom — *"VPN says connected but there is no
internet"*, fixed by reconnecting manually.

**Server-initiated IKE_SA rekey.** Road-warrior clients sit behind NAT and
sleep. They answer DPD, which they treat as liveness, but routinely ignore a
server-initiated rekey:

```
generating INFORMATIONAL request 61 [ ]      <- DPD, client ANSWERS
parsed INFORMATIONAL response 61 [ ]
giving up after 5 retransmits                <- the rekey got no answer
rekeying IKE_SA failed, peer not responding
lease 10.10.10.4 by 'alice' went offline     <- server tore the SA down
generating INFORMATIONAL request 62 [ ]      <- DPD works again, peer alive
```

charon declares the peer dead and destroys the SA; the client never learns and
keeps showing "connected" while its traffic black-holes. Clients drive their own
rekeying perfectly well, and the server answers — so it no longer initiates.

**Server-side DPD.** With the stock `dpd_delay = 30s` the server probed every SA
twice a minute and destroyed any that missed the exchange — roughly 15 seconds
of silence was enough. Phones and laptops go quiet the moment the screen sleeps.
On the machine this config came from that meant **139 teardowns in a single day
for about five devices**, every one of them a healthy tunnel. As a responder the
server has no reason to poll; it still answers DPD from clients that ask.

**The trade-off, and what covers it.** With rekey, reauth and DPD all off,
nothing reaps an SA whose client vanished without sending a DELETE, and those
hold a pool address forever. `vpn-reap` does that instead: it terminates
sessions that have carried **no traffic for 48 hours**, run every 6 hours by
`vpn-reap.timer`. That is vastly more forgiving than the DPD it replaces — two
days of complete silence means the device is not in use — and terminating sends
a DELETE, so a merely-idle client learns the session ended instead of
black-holing. Tune `IDLE_SECONDS` in `/usr/local/sbin/vpn-reap`, or override per
run:

```bash
VPN_REAP_IDLE=3600 vpn-reap --dry-run
```

Note that both fixes needed a **restart**, not just `swanctl --load-all`:
reloading does not retime existing SAs, and with rekey disabled those SAs never
cycle on their own, so they would have kept misbehaving indefinitely.

### One credential per device, or one shared?

`unique = never` in the shipped config, which allows the same login to be
connected from several devices at once. That suits a shared household login.

If you give every device its own credential — which you should, if you can —
change it to `unique = replace`: a reconnecting device then displaces its own
stale session, which reaps abandoned sessions far faster than the 48-hour timer.
`replace` keys on the login, so with a shared login it would instead make people
kick each other offline.

What a shared login gives up, so it is on the record: no individual revocation
(cutting one person off means changing the password for everybody), and no
visibility (every session shows the same name, so an unfamiliar source address
cannot be told apart from a family member's).

---

## Crypto

`proposals` is ordered strongest-first. strongSwan, as responder, walks the list
and takes the first entry the client can also do, so server preference wins and a
capable client is never downgraded.

DH groups offered: ECP-384, ECP-256, MODP-3072, MODP-2048, MODP-1024. iOS,
macOS, Android and Linux all negotiate AES-256-GCM over ECP-256/384.

The last four IKE entries use **MODP-1024** (1024-bit DH), which is considered
breakable by a well-resourced attacker (Logjam). They exist for exactly one
reason: the built-in Windows client offers no other group by default — it sends
18 proposals and every one of them is MODP-1024. Without those entries Windows
fails at IKE_SA_INIT with "policy match error" (error 13868).

To hold a Windows machine to strong crypto anyway, run this once in an
**administrator** PowerShell, substituting the connection's name:

```powershell
Set-VpnConnectionIPsecConfiguration -ConnectionName "vpn.example.com" `
  -AuthenticationTransformConstants GCMAES256 `
  -CipherTransformConstants GCMAES256 `
  -EncryptionMethod AES256 `
  -IntegrityCheckMethod SHA256 `
  -DHGroup Group14 -PfsGroup PFS2048 -Force
```

If every Windows client is configured that way — or you have none — delete the
four `modp1024` entries from `proposals` in
`/etc/swanctl/conf.d/ikev2.conf` and restart strongSwan.

---

## Certificate

Issued by Let's Encrypt, valid 90 days, renewed by `certbot.timer` (twice daily,
renews at 30 days remaining). On every successful renewal
`/etc/letsencrypt/renewal-hooks/deploy/10-strongswan.sh` copies the certificate,
key and split chain into `/etc/swanctl/` and restarts the daemon — a restart
rather than a reload, because `swanctl --load-all` adds credentials without
evicting the ones already in memory. It drops live tunnels, once every 60 days.

The chain is split into one certificate per file because clients trust the ISRG
root but not the intermediate, so charon has to send the chain, and swanctl
reads one certificate per file.

Check status:

```bash
certbot certificates
systemctl list-timers certbot.timer
```

Renew by hand:

```bash
certbot renew --force-renewal
```

**Port 80 must stay free and reachable.** The standalone authenticator binds it
for a few seconds on every renewal; if that fails, the certificate eventually
expires and clients stop trusting the server. If you need to run a web server on
the same host, switch to the webroot authenticator instead:

```bash
certbot certonly --webroot -w /var/www/html -d vpn.example.com --force-renewal
```

or keep standalone and stop the web server around renewal:

```bash
certbot renew --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
```

---

## Troubleshooting

**Connects, then immediately drops.** Almost always the certificate. Check that
`Remote ID` on the client is exactly the hostname, and that the chain deployed:

```bash
swanctl --list-certs | grep -A2 subject
journalctl -u strongswan -n 50
```

**Windows: "policy match error" (13868).** The MODP-1024 entries are missing
from `proposals`, or the client was pinned to a group the server does not offer.
See [Crypto](#crypto).

**Connected, but no internet.** Check forwarding and NAT first:

```bash
sysctl net.ipv4.ip_forward             # must be 1
iptables -t nat -S POSTROUTING         # must show MASQUERADE for the pool
systemctl status vpn-firewall
```

If those are fine, it is likely the MSS clamp missing or the session-teardown
behaviour described in [Session handling](#session-handling-and-the-two-bugs-that-shaped-it).

**Some sites load, large pages hang.** MSS clamp. Confirm the mangle rule
exists, and re-run `vpn-firewall.sh`.

**Useful checks:**

```bash
swanctl --list-sas                    # per-SA byte counters; 0/0 on an old SA is suspect
swanctl --list-pools --leases         # a "(null)" online lease means leaked bookkeeping
journalctl -u strongswan | grep -E 'giving up|not responding|CHILD_SA closed'
```

---

## Security notes

- **The installer sets no inbound firewall.** `iptables INPUT` policy stays
  `ACCEPT`; only VPN-specific NAT and FORWARD rules are enforced. Any port a
  service on this host opens is reachable from the internet. Add `ufw` or your
  own INPUT rules if the box does anything else — remember to allow UDP 500/4500
  and TCP 80.
- **Passwords are stored in clear text** in `/etc/swanctl/vpn-users`
  (mode `0600`, root-only). EAP-MSCHAPv2 requires the plaintext password
  server-side; there is no way around it short of switching to certificate
  authentication, which would defeat the "nothing to install on the client" goal.
- **Generated `.mobileconfig` files embed the password.** They live in
  `/srv/vpn` as `root:vpn` `0750`. Anyone in the `vpn` group can read every
  user's password.
- Port 80 is exposed permanently for renewal, though nothing serves it in
  between.
- MODP-1024 is accepted as a last-resort DH group. See [Crypto](#crypto).
- Harden SSH separately — this repo does not touch `sshd_config`.

## Uninstall

```bash
sudo ./uninstall.sh            # stops everything, keeps users and certificate
sudo ./uninstall.sh --purge    # also removes the user database and profiles
```

## License

MIT — see [LICENSE](LICENSE).
