#!/usr/bin/env bash
# 安装 cloudflared，接入 Zero Trust Tunnel
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] 60-tunnel 需要 root"; exit 1; }

ARCH="$(dpkg --print-architecture)"
SS_WEB_PORT="${SS_WEB_PORT:-35602}"
if ! command -v cloudflared > /dev/null 2>&1; then
  echo "[60] 安装 cloudflared (${ARCH})..."
  curl -fsSL -o /tmp/cloudflared.deb \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
  dpkg -i /tmp/cloudflared.deb
  rm -f /tmp/cloudflared.deb
fi

if [[ -z "${TUNNEL_TOKEN:-}" ]]; then
  cat <<EOF
[60] 未配置 TUNNEL_TOKEN，cloudflared 已安装但未接入。

  接入步骤：
  1. Cloudflare Zero Trust 后台 -> Networks -> Tunnels -> Create tunnel
  2. 选择 Cloudflared 类型，命名后复制 token
  3. 填入 config.env 的 TUNNEL_TOKEN，重跑 sudo bash deploy.sh
  4. 在 Tunnel 的 Public Hostname 里添加两条：
     panel.你的域名   -> http://127.0.0.1:<PANEL_PORT>/<PANEL_PATH>
     status.你的域名  -> http://127.0.0.1:${SS_WEB_PORT}
EOF
  exit 0
fi

echo "[60] 接入 Cloudflare Tunnel..."
if systemctl list-unit-files cloudflared.service --type=service --no-legend 2>/dev/null | grep -q '^cloudflared\.service'; then
  echo "[60] cloudflared 服务已存在，跳过重复安装..."
  systemctl enable cloudflared
  systemctl start cloudflared
else
  cloudflared service install "$TUNNEL_TOKEN"
  systemctl enable --now cloudflared
fi
systemctl is-active --quiet cloudflared || { journalctl -u cloudflared -n 20 --no-pager; exit 1; }
echo "[60] Tunnel 已连接。请在 Zero Trust 后台配置 Public Hostname："
echo "     面板  -> http://127.0.0.1:${PANEL_PORT:-未安装}/${PANEL_PATH:-未安装}"
echo "     探针  -> http://127.0.0.1:${SS_WEB_PORT}"
echo "     并为两个 hostname 添加 Access 策略（限定你的 Google 邮箱）"
