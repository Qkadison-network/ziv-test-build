#!/usr/bin/env bash
# ZIVPN-compat one-command installer + tester.
#
# Run on the VPS (as root):
#   REPO=<owner>/<repo> bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/quick-install.sh)
#
# Optional env overrides:
#   LISTEN_PORT=5668   STATS_PORT=9999   PANEL_PORT=8080
#   AUTH_PASSWORD=zi   OBFS_PASSWORD=zivpn   QUOTA=1GB
set -euo pipefail

REPO="${REPO:-OWNER/REPO}"
LISTEN_PORT="${LISTEN_PORT:-5668}"
STATS_PORT="${STATS_PORT:-9999}"
PANEL_PORT="${PANEL_PORT:-8080}"
AUTH_PASSWORD="${AUTH_PASSWORD:-zi}"
OBFS_PASSWORD="${OBFS_PASSWORD:-zivpn}"
QUOTA="${QUOTA:-1GB}"

DIR=/etc/zivpn-compat
BIN=/usr/local/bin/zivpn-compat
PANEL=/usr/local/bin/zivpn-compat-panel

if [ "$(id -u)" != "0" ]; then echo "ERROR: run as root" >&2; exit 1; fi
if [ "$REPO" = "OWNER/REPO" ]; then
  echo "ERROR: set REPO, e.g. REPO=yourname/opudp-hysteria-zivpn ..." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "ERROR: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

command -v curl >/dev/null || { echo "ERROR: curl required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl required" >&2; exit 1; }

BASE="https://github.com/$REPO/releases/latest/download"
echo ">> downloading binaries from $BASE"
curl -fsSL "$BASE/zivpn-compat-linux-$ARCH"        -o "$BIN"
curl -fsSL "$BASE/zivpn-compat-panel-linux-$ARCH"  -o "$PANEL"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/scripts/zc-user.sh" -o /usr/local/bin/zc-user
chmod 0755 "$BIN" "$PANEL" /usr/local/bin/zc-user

mkdir -p "$DIR"
if [ ! -f "$DIR/zivpn.crt" ]; then
  echo ">> generating self-signed certificate"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$DIR/zivpn.key" -out "$DIR/zivpn.crt" -subj "/CN=zivpn" >/dev/null 2>&1
fi

STATS_SECRET="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cat > "$DIR/config.json" <<EOF
{
  "listen": ":$LISTEN_PORT",
  "tls": { "cert": "$DIR/zivpn.crt", "key": "$DIR/zivpn.key", "sniGuard": "disable" },
  "obfs": { "type": "salamander", "salamander": { "password": "$OBFS_PASSWORD" } },
  "auth": { "type": "http", "http": { "url": "http://127.0.0.1:$PANEL_PORT/auth" } },
  "trafficStats": { "listen": "127.0.0.1:$STATS_PORT", "secret": "$STATS_SECRET" }
}
EOF

cat > /etc/systemd/system/zivpn-compat-panel.service <<EOF
[Unit]
Description=ZIVPN-compat panel (auth + per-user quota)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$PANEL -listen 127.0.0.1:$PANEL_PORT -stats http://127.0.0.1:$STATS_PORT -stats-secret $STATS_SECRET -data $DIR
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/zivpn-compat.service <<EOF
[Unit]
Description=ZIVPN-compat server (patched Hysteria 2)
After=network-online.target zivpn-compat-panel.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN server -c $DIR/config.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo ">> starting panel + server"
systemctl enable --now zivpn-compat-panel.service
for _ in $(seq 1 20); do [ -f "$DIR/token" ] && break; sleep 0.5; done
systemctl enable --now zivpn-compat.service
sleep 2

TOKEN="$(cat "$DIR/token" 2>/dev/null || true)"
if [ -n "$TOKEN" ]; then
  curl -fsS -X POST -H "Authorization: $TOKEN" \
    -d "{\"id\":\"demo\",\"password\":\"$AUTH_PASSWORD\",\"quota\":\"$QUOTA\",\"enabled\":true}" \
    "http://127.0.0.1:$PANEL_PORT/users" >/dev/null && \
    echo ">> seeded demo user (id=demo password=$AUTH_PASSWORD quota=$QUOTA)"
fi

IP="$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

echo
echo "============================================================"
echo " ZIVPN-compat installed"
echo "------------------------------------------------------------"
echo " Server   : UDP $IP:$LISTEN_PORT   (patched Hysteria 2)"
echo " Obfs     : salamander / password '$OBFS_PASSWORD'"
echo " Login    : password '$AUTH_PASSWORD'  (demo user)"
echo " Quota    : $QUOTA"
echo " Panel API: http://127.0.0.1:$PANEL_PORT   token: $TOKEN"
echo " Stats    : http://127.0.0.1:$STATS_PORT   secret: $STATS_SECRET"
echo "------------------------------------------------------------"
echo " Test 1) app connects to $IP:$LISTEN_PORT (obfs '$OBFS_PASSWORD', pass '$AUTH_PASSWORD')"
echo " Test 2) usage:  curl -H 'Authorization: $TOKEN' http://127.0.0.1:$PANEL_PORT/usage"
echo " Manage : /usr/local/bin/zc-user add <password> <id> [quota]"
echo "============================================================"
