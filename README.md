# opudp-hysteria-zivpn (dev / test)

Standalone research + build project for a **ZIVPN-app-compatible UDP server** with
**per-user traffic quotas**.

This is a separate dev project. It does **not** touch `OFFICIAL-ONEPESEWA-UDP`, its
`install.sh`, or any `/etc/zivpn` files. It installs differently-named services
(`zivpn-compat`, `zivpn-compat-panel`) under `/etc/zivpn-compat/`.

---

## Why this exists

`udp-zivpn` is a closed-source fork of **Hysteria 2** (`github.com/apernet/hysteria`).
Findings from binary analysis:

- The ZIVPN app/server speak a **modified** Hysteria 2 wire protocol: all auth headers
  were renamed `Hysteria-*` -> `Zivpnudp-*` (`-Auth`, `-UDP`, `-CC-RX`, `-Padding`).
- ZIVPN **deleted** Hysteria's `trafficStats` feature, so the stock binary exposes
  **no** per-user byte counters.
- All users share one QUIC port, so per-**password** accounting is impossible at the
  network layer. Only the server (which reads the auth) can attribute bytes.

Conclusion: real per-user quotas require running your own server that is
**wire-compatible with the ZIVPN app** and keeps `trafficStats` enabled.

## What this project builds

| Binary | Role |
| --- | --- |
| `zivpn-compat` | Patched Hysteria 2 server (ZIVPN wire-compat). |
| `zivpn-compat-panel` | Auth + quota service (per-password ids, usage, enforcement). |

The patch (`tools/apply_compat.py`) is tiny:

1. renames the 4 protocol header constants `Hysteria-*` -> `Zivpnudp-*`;
2. relaxes the server's auth-request detection so host/path differences don't break auth.

> After the rename the **official Hysteria client** no longer talks to this build.
> It is intended for the **ZIVPN app**.

---

## One command on the VPS

1. Push this folder to a **new** GitHub repo (say `yourname/opudp-hysteria-zivpn`).
2. Create a release so the binaries have a stable URL:
   ```
   git tag v0.1.0
   git push origin main --tags
   ```
   The `build` workflow compiles all four binaries and publishes them to the release.
3. On the VPS (as root):
   ```
   REPO=yourname/opudp-hysteria-zivpn \
     bash <(curl -fsSL https://raw.githubusercontent.com/yourname/opudp-hysteria-zivpn/main/scripts/quick-install.sh)
   ```

That installs and starts both services, generates a self-signed cert, and seeds a
demo user. It prints the connect details and the panel admin token.

Override defaults with env vars:
`LISTEN_PORT=5668 STATS_PORT=9999 PANEL_PORT=8080 AUTH_PASSWORD=zi OBFS_PASSWORD=zivpn QUOTA=1GB`.

### Test

1. Point the **ZIVPN app** at `<vps-ip>:5668`, obfs password `zivpn`, login `zi`.
2. Watch usage grow:
   ```
   zc-user usage
   curl -s -H "Authorization: $(cat /etc/zivpn-compat/token)" http://127.0.0.1:8080/usage
   ```

When a user hits its quota the panel disables the password and kicks the session.

### Manage users

```
zc-user add <password> <id> [quota]   # zc-user add s3cret alice 10GB
zc-user list
zc-user usage
zc-user del <id>
zc-user reset <id>
```

Quota accepts `10GB`, `500MB`, `0`/`unlimited`.

---

## Manual / local build (optional, needs Go)

```
git clone --depth 1 --branch core/v2.13.0 https://github.com/apernet/hysteria upstream
python3 tools/apply_compat.py upstream
cd upstream/app && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ../../zivpn-compat-linux-amd64 .
cd ../../panel && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ../zivpn-compat-panel-linux-amd64 ./cmd/panel
```

## How quotas work

The server's `auth` is set to `http` pointing at the panel:

```
"auth": { "type": "http", "http": { "url": "http://127.0.0.1:8080/auth" } }
```

- On each connection the server POSTs `{"addr","auth","tx"}`; the panel validates the
  password and returns the matching **user id**.
- The panel polls `trafficStats` (`GET /traffic?clear=1`) every few seconds and adds
  `tx+rx` to that user's usage.
- When usage reaches the quota it flips the user to disabled (auth now returns
  `ok:false`) and POSTs the id to `/kick` to drop the live session.

## Known assumptions to verify first

- **Obfs**: assumed Salamander with password `zivpn` (ZIVPN config `"obfs":"zivpn"`).
  If the app does not connect, the fork may use a custom obfuscator. Adjust
  `obfs` in `/etc/zivpn-compat/config.json`.
- **TLS**: self-signed cert with `sniGuard` disabled; the app is expected to skip
  verification. If it rejects the cert, supply a matching cert/key.
- **Host/path**: assumed unchanged (`hysteria` / `/auth`). The patch relaxes this,
  but if the app still fails to authenticate we may need to mirror further changes.
