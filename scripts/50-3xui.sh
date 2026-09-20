#!/usr/bin/env bash
# 安装 3x-ui 管理面板（端口不对外开放，经 Tunnel 访问）
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] 50-3xui 需要 root"; exit 1; }

SECRETS_FILE="/etc/vps-oneclick/secrets.env"

if [[ -z "${PANEL_PORT:-}" ]]; then
  PANEL_PORT="$((RANDOM % 30000 + 20000))"
  echo "PANEL_PORT=\"${PANEL_PORT}\"" >> "$SECRETS_FILE"
fi
if [[ -z "${PANEL_USER:-}" ]]; then
  PANEL_USER="admin"
  echo "PANEL_USER=\"${PANEL_USER}\"" >> "$SECRETS_FILE"
fi
if [[ -z "${PANEL_PASS:-}" ]]; then
  PANEL_PASS="$(openssl rand -hex 10)"
  echo "PANEL_PASS=\"${PANEL_PASS}\"" >> "$SECRETS_FILE"
fi
if [[ -z "${PANEL_PATH:-}" ]]; then
  PANEL_PATH="$(openssl rand -hex 6)"
  echo "PANEL_PATH=\"${PANEL_PATH}\"" >> "$SECRETS_FILE"
fi
export PANEL_PORT PANEL_USER PANEL_PASS PANEL_PATH

echo "[50] 安装 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) < /dev/null

echo "[50] 设置随机端口 / 账号 / 加密路径..."
/usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" \
  -port "$PANEL_PORT" -webBasePath "/${PANEL_PATH}" > /dev/null 2>&1 || \
  /usr/local/x-ui/x-ui setting --username "$PANEL_USER" --password "$PANEL_PASS" \
  --port "$PANEL_PORT" --webBasePath "/${PANEL_PATH}" > /dev/null
systemctl restart x-ui
sleep 2
systemctl is-active --quiet x-ui || { journalctl -u x-ui -n 20 --no-pager; exit 1; }
echo "[50] 3x-ui 就绪（防火墙未放行端口，仅 Tunnel 可达）"

