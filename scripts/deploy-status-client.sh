#!/usr/bin/env bash
# ServerStatus 探针客户端一键部署（在新的 VPS 上运行）
# 用法：sudo bash deploy-status-client.sh --server 主服务器IP [--port 35601] --user node_xxx --password xxxx
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] deploy-status-client 需要 root"; exit 1; }

INSTALL_DIR="/usr/local/ServerStatus-client"
CLIENT_SCRIPT="${INSTALL_DIR}/status-client.py"
SERVICE_NAME="serverstatus-probe"

SS_SERVER=""
SS_PORT="35601"
SS_USER=""
SS_PASS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SS_SERVER="${2:?}"; shift 2 ;;
    --port) SS_PORT="${2:?}"; shift 2 ;;
    --user) SS_USER="${2:?}"; shift 2 ;;
    --password) SS_PASS="${2:?}"; shift 2 ;;
    *) echo "[!] 未知参数：$1"; exit 1 ;;
  esac
done
[[ -n "$SS_SERVER" ]] || { echo "[!] 缺少 --server（主服务器公网 IP）"; exit 1; }
[[ -n "$SS_USER" ]] || { echo "[!] 缺少 --user"; exit 1; }
[[ -n "$SS_PASS" ]] || { echo "[!] 缺少 --password"; exit 1; }
[[ "$SS_PORT" =~ ^[0-9]+$ ]] || { echo "[!] 端口格式不对：$SS_PORT"; exit 1; }

if ! command -v python3 > /dev/null; then
  if command -v apt-get > /dev/null; then
    apt-get update -y
    apt-get install -y python3
  else
    echo "[!] 未找到 python3 且无法自动安装，请先手动安装"; exit 1
  fi
fi
command -v curl > /dev/null || { echo "[!] 未找到 curl，请先安装"; exit 1; }
command -v systemctl > /dev/null || { echo "[!] 需要 systemd 环境"; exit 1; }

mkdir -p "$INSTALL_DIR"

download_client() {
  local dest="$1" url
  for url in \
    "https://raw.githubusercontent.com/cokemine/ServerStatus-Hotaru/master/clients/status-client.py" \
    "https://cdn.jsdelivr.net/gh/cokemine/ServerStatus-Hotaru@master/clients/status-client.py"; do
    echo "[*] 下载探针：${url}"
    if curl -fsSL --max-time 60 "$url" -o "${dest}.tmp" && grep -q "^USER = " "${dest}.tmp"; then
      mv "${dest}.tmp" "$dest"
      return 0
    fi
  done
  rm -f "${dest}.tmp"
  return 1
}

if ! download_client "$CLIENT_SCRIPT"; then
  if [[ -f "$CLIENT_SCRIPT" ]]; then
    echo "[!] 下载失败，继续使用已存在的探针脚本"
  else
    echo "[!] 探针脚本下载失败，请检查网络后重试"; exit 1
  fi
fi

# 探针脚本不解析命令行参数，连接信息只能以常量形式写入文件
sed -i -E "s|^SERVER = .*|SERVER = \"${SS_SERVER}\"|; s|^PORT = .*|PORT = ${SS_PORT}|; s|^USER = .*|USER = \"${SS_USER}\"|; s|^PASSWORD = .*|PASSWORD = \"${SS_PASS}\"|" "$CLIENT_SCRIPT"
chmod 600 "$CLIENT_SCRIPT"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=ServerStatus Probe (remote client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${CLIENT_SCRIPT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 2
systemctl is-active --quiet "$SERVICE_NAME" || { journalctl -u "$SERVICE_NAME" -n 20 --no-pager; exit 1; }

SS_SERVER="$SS_SERVER" SS_PORT="$SS_PORT" python3 - <<'PY'
import os, socket, sys
server, port = os.environ["SS_SERVER"], int(os.environ["SS_PORT"])
try:
    socket.create_connection((server, port), timeout=5).close()
except OSError as exc:
    sys.exit(f"[!] 无法连接 {server}:{port} - {exc}（检查主服务器 ufw 是否已放行本机 IP）")
print("[+] 主服务器端口连通")
PY

sleep 3
if journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null | grep -q "Wrong username"; then
  echo "[!] 采集端拒绝凭据（Wrong username），请核对 --user / --password 是否与主服务器 secrets.env 一致"
  exit 1
fi

echo
echo "[+] 部署完成：上报 ${SS_SERVER}:${SS_PORT}，几秒后可在 ServerStatus 面板看到本机"
echo "    查看日志：journalctl -u ${SERVICE_NAME} -n 20 --no-pager"
echo "    卸载：systemctl disable --now ${SERVICE_NAME} && rm -rf ${INSTALL_DIR} /etc/systemd/system/${SERVICE_NAME}.service"
