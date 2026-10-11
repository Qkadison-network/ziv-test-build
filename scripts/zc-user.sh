#!/usr/bin/env bash
# Manage ZIVPN-compat users (talks to the local panel admin API).
#
#   zc-user add <password> <id> [quota]   e.g. zc-user add s3cret alice 10GB
#   zc-user list
#   zc-user usage
#   zc-user del <id>
#   zc-user reset <id>
set -euo pipefail

DIR=/etc/zivpn-compat
PORT="${PANEL_PORT:-8080}"
TOKEN="${ZC_TOKEN:-$(cat "$DIR/token" 2>/dev/null || true)}"
API="http://127.0.0.1:$PORT"

if [ -z "$TOKEN" ]; then echo "ERROR: no admin token (is the panel installed?)" >&2; exit 1; fi

cmd="${1:-}"; shift || true
case "$cmd" in
  add)
    pw="${1:?usage: zc-user add <password> <id> [quota]}"
    id="${2:?usage: zc-user add <password> <id> [quota]}"
    quota="${3:-0}"
    curl -fsS -X POST -H "Authorization: $TOKEN" \
      -d "{\"id\":\"$id\",\"password\":\"$pw\",\"quota\":\"$quota\",\"enabled\":true}" \
      "$API/users"
    echo
    ;;
  del)
    id="${1:?usage: zc-user del <id>}"
    curl -fsS -X DELETE -H "Authorization: $TOKEN" "$API/users?id=$id"; echo
    ;;
  reset)
    id="${1:?usage: zc-user reset <id>}"
    curl -fsS -X POST -H "Authorization: $TOKEN" "$API/users/reset?id=$id"; echo
    ;;
  list)
    curl -fsS -H "Authorization: $TOKEN" "$API/users"; echo
    ;;
  usage)
    curl -fsS -H "Authorization: $TOKEN" "$API/usage"; echo
    ;;
  *)
    sed -n '2,9p' "$0"
    exit 1
    ;;
esac
