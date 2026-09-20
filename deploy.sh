#!/usr/bin/env bash
# vps-oneclick 一键部署入口
# 用法：sudo bash deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ $EUID -ne 0 ]]; then
  echo "[!] 请用 root 运行：sudo bash deploy.sh"
  exit 1
fi

# ---------- 系统检查 ----------
if [[ ! -r /etc/os-release ]]; then
  echo "[!] 未识别到 /etc/os-release，仅支持 Ubuntu / Debian"
  exit 1
fi
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) echo "[!] 当前系统 ${ID:-unknown} 不受支持，请用 Ubuntu 20.04+ / Debian 11+"; exit 1 ;;
esac
VER_MAJOR="${VERSION_ID%%.*}"
if [[ "${ID}" == "ubuntu" && "${VER_MAJOR}" -lt 20 ]] || \
   [[ "${ID}" == "debian" && "${VER_MAJOR}" -lt 11 ]]; then
  echo "[!] 系统版本过低（${PRETTY_NAME:-}），请用 Ubuntu 20.04+ / Debian 11+"
  exit 1
fi
echo "[*] 系统：${PRETTY_NAME:-$ID $VERSION_ID}"

# ---------- 加载配置 ----------
if [[ ! -f "$SCRIPT_DIR/config.env" ]]; then
  echo "[!] 缺少 config.env"
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"
set +a

# ServerStatus 安装模式：0 不安装；1 服务端 + 本机探针；2 仅接入已有服务端
SERVERSTATUS_MODE="${INSTALL_SERVERSTATUS:-1}"
case "${SERVERSTATUS_MODE}" in
  0|1|2) ;;
  *) echo "[!] INSTALL_SERVERSTATUS 仅支持 0、1、2，当前值：${SERVERSTATUS_MODE}"; exit 1 ;;
esac

# 生成型密钥：config.env 显式填写优先；否则首次自动生成并持久化
SECRETS_FILE="/etc/vps-oneclick/secrets.env"
GEN_KEYS=(UUID PRIVATE_KEY PUBLIC_KEY SHORT_ID PANEL_PORT PANEL_USER PANEL_PASS PANEL_PATH SS_USER SS_PASS)
declare -A EXPLICIT_VALUE=()
for _k in "${GEN_KEYS[@]}"; do
  _v="${!_k:-}"
  [[ -n "$_v" ]] && EXPLICIT_VALUE["$_k"]="$_v"
done
if [[ "${SERVERSTATUS_MODE}" == "2" ]]; then
  for _required in SS_SERVER SS_USER SS_PASS; do
    if [[ -z "${!_required:-}" ]]; then
      echo "[!] 仅安装探针客户端时，${_required} 不能为空"
      exit 1
    fi
  done
  [[ "${SS_PANEL_PORT:-35601}" =~ ^[0-9]+$ ]] || {
    echo "[!] SS_PANEL_PORT 端口格式不对：${SS_PANEL_PORT}"
    exit 1
  }
fi
mkdir -p /etc/vps-oneclick
if [[ -f "$SECRETS_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
  echo "[*] 复用已有密钥：$SECRETS_FILE"
fi
for _k in "${!EXPLICIT_VALUE[@]}"; do
  export "$_k=${EXPLICIT_VALUE[$_k]}"
done

reload_generated_secrets() {
  [[ -f "$SECRETS_FILE" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
  local _k
  for _k in "${!EXPLICIT_VALUE[@]}"; do
    export "$_k=${EXPLICIT_VALUE[$_k]}"
  done
}

mkdir -p "$SCRIPT_DIR/output"
exec > >(tee -a "$SCRIPT_DIR/deploy.log") 2>&1
echo "===== vps-oneclick 部署开始 $(date '+%F %T') ====="

bash scripts/10-init.sh
bash scripts/20-xray.sh
bash scripts/30-warp.sh

case "${SERVERSTATUS_MODE}" in
  1) bash scripts/40-serverstatus.sh ;;
  2) bash scripts/deploy-status-client.sh \
       --server "${SS_SERVER}" \
       --port "${SS_PANEL_PORT:-35601}" \
       --user "${SS_USER}" \
       --password "${SS_PASS}" ;;
esac
if [[ "${INSTALL_3XUI:-1}" == "1" ]]; then
  bash scripts/50-3xui.sh
fi
if [[ "${INSTALL_TUNNEL:-1}" == "1" ]]; then
  bash scripts/60-tunnel.sh
fi

# 子脚本生成密钥后只写回 secrets.env，主流程需要重新加载供 70-links 使用。
reload_generated_secrets

bash scripts/70-links.sh
echo "===== 部署完成 $(date '+%F %T') ====="
