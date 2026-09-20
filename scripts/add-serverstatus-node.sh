#!/usr/bin/env bash
# ServerStatus 新增探针节点（在主服务器上运行）
# 用法：sudo bash scripts/add-serverstatus-node.sh --name "东京-备用" --client-ip 1.2.3.4 [--location Tokyo] [--region JP]
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] add-serverstatus-node 需要 root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="/etc/vps-oneclick/secrets.env"
SS_CFG="/usr/local/ServerStatus/server/config.json"

NAME=""
CLIENT_IP=""
LOCATION="Unknown"
REGION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --client-ip) CLIENT_IP="${2:?}"; shift 2 ;;
    --location) LOCATION="${2:?}"; shift 2 ;;
    --region) REGION="${2:?}"; shift 2 ;;
    *) echo "[!] 未知参数：$1"; exit 1 ;;
  esac
done
[[ -n "$NAME" ]] || { echo "[!] 缺少 --name（节点显示名）"; exit 1; }
[[ -n "$CLIENT_IP" ]] || { echo "[!] 缺少 --client-ip（新服务器公网 IP，用于防火墙放行）"; exit 1; }
[[ "$CLIENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "[!] client-ip 格式不对：$CLIENT_IP"; exit 1; }

SS_PORT="35601"
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  # shellcheck disable=SC1091
  SS_PORT="$(grep -E '^SS_PANEL_PORT=' "$SCRIPT_DIR/config.env" | tail -n1 | cut -d= -f2 | tr -d '"')"
fi
[[ "$SS_PORT" =~ ^[0-9]+$ ]] || SS_PORT="35601"

[[ -f "$SS_CFG" ]] || { echo "[!] 未找到 $SS_CFG，请先在主服务器完成 deploy.sh"; exit 1; }

NEW_USER="node_$(openssl rand -hex 3)"
NEW_PASS="$(openssl rand -hex 8)"

echo "[*] 写入节点 ${NAME} 到 config.json..."
cp "$SS_CFG" "${SS_CFG}.bak.$(date +%Y%m%d%H%M%S)"
SS_USER="$NEW_USER" SS_PASS="$NEW_PASS" SS_NAME="$NAME" \
SS_LOCATION="$LOCATION" SS_REGION="$REGION" SS_CFG="$SS_CFG" python3 - <<'PY'
import json, os
cfg_path = os.environ["SS_CFG"]
with open(cfg_path, encoding="utf-8") as f:
    cfg = json.load(f)
cfg.setdefault("servers", [])
if any(s.get("name") == os.environ["SS_NAME"] for s in cfg["servers"]):
    raise SystemExit("[!] config.json 中已存在同名节点：" + os.environ["SS_NAME"])
cfg["servers"].append({
    "username": os.environ["SS_USER"],
    "password": os.environ["SS_PASS"],
    "name": os.environ["SS_NAME"],
    "type": "KVM",
    "host": "VPS",
    "location": os.environ["SS_LOCATION"],
    "disabled": False,
    "region": os.environ["SS_REGION"],
})
with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

NODE_KEY="${NEW_USER#node_}"
{
  echo "SS_NODE_${NODE_KEY}_USER=\"${NEW_USER}\""
  echo "SS_NODE_${NODE_KEY}_PASS=\"${NEW_PASS}\""
} >> "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE" 2>/dev/null || true

echo "[*] 防火墙放行 ${CLIENT_IP} ..."
ufw allow from "$CLIENT_IP" to any port "$SS_PORT" proto tcp > /dev/null

systemctl restart serverstatus
sleep 1
systemctl is-active --quiet serverstatus || { journalctl -u serverstatus -n 20 --no-pager; exit 1; }

MAIN_IP="$(curl -s4 --max-time 10 https://api.ipify.org || curl -s4 --max-time 10 https://ip.sb || echo 主服务器IP)"
echo
echo "==== 下一步：在新服务器 ${CLIENT_IP} 上执行 ===="
echo "1. 上传客户端脚本："
echo "   scp ${SCRIPT_DIR}/scripts/deploy-status-client.sh root@${CLIENT_IP}:/root/"
echo "2. 安装探针："
echo "   sudo bash deploy-status-client.sh --server ${MAIN_IP} --port ${SS_PORT} --user ${NEW_USER} --password ${NEW_PASS}"
echo
echo "凭据已保存：${SECRETS_FILE} 中的 SS_NODE_${NODE_KEY}_USER / SS_NODE_${NODE_KEY}_PASS"
