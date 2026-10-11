#!/usr/bin/env bash
set -euo pipefail

BIN_URL="${BIN_URL:-}"
LISTEN_PORT="${LISTEN_PORT:-5668}"
STATS_PORT="${STATS_PORT:-9999}"
STATS_SECRET="${STATS_SECRET:-change-me-stats-secret}"
OBFS_PASSWORD="${OBFS_PASSWORD:-zivpn}"
AUTH_PASSWORD="${AUTH_PASSWORD:-zi}"

DIR=/etc/zivpn-compat
BIN=/usr/local/bin/zivpn-compat
UNIT=/etc/systemd/system/zivpn-compat.service

if [ "$(id -u)" != "0" ]; then
  echo "run as root"
  exit 1
fi

mkdir -p "$DIR"

if [ -n "$BIN_URL" ]; then
  curl -fsSL "$BIN_URL" -o "$BIN"
elif [ -f ./zivpn-compat-linux-amd64 ]; then
  install -m 0755 ./zivpn-compat-linux-amd64 "$BIN"
elif [ -f ./zivpn-compat ]; then
  install -m 0755 ./zivpn-compat "$BIN"
else
  echo "set BIN_URL, or place zivpn-compat-linux-amd64 next to this script"
  exit 1
fi
chmod 0755 "$BIN"

if [ ! -f "$DIR/zivpn.crt" ] || [ ! -f "$DIR/zivpn.key" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$DIR/zivpn.key" -out "$DIR/zivpn.crt" -subj "/CN=zivpn" >/dev/null 2>&1
fi

cat > "$DIR/config.json" <<EOF
{
  "listen": ":$LISTEN_PORT",
  "tls": {
    "cert": "$DIR/zivpn.crt",
    "key": "$DIR/zivpn.key",
    "sniGuard": "disable"
  },
  "obfs": {
    "type": "salamander",
    "salamander": {
      "password": "$OBFS_PASSWORD"
    }
  },
  "auth": {
    "type": "password",
    "password": "$AUTH_PASSWORD"
  },
  "trafficStats": {
    "listen": "127.0.0.1:$STATS_PORT",
    "secret": "$STATS_SECRET"
  }
}
EOF

cat > "$UNIT" <<EOF
[Unit]
Description=ZIVPN-compat test server (patched Hysteria 2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN server -c $DIR/config.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now zivpn-compat.service

echo "listening on udp/$LISTEN_PORT"
echo "auth password: $AUTH_PASSWORD"
echo "obfs: salamander / $OBFS_PASSWORD"
echo "stats: curl -H 'Authorization: $STATS_SECRET' http://127.0.0.1:$STATS_PORT/traffic"
