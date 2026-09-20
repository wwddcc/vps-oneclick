#!/usr/bin/env bash
# 安装 Xray，生成 Reality 密钥，渲染服务端配置
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] 20-xray 需要 root"; exit 1; }

SECRETS_FILE="/etc/vps-oneclick/secrets.env"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates}"
XRAY_CONF="/usr/local/etc/xray/config.json"

echo "[20] 安装 Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null

# ---------- 密钥生成（已有则复用） ----------
if [[ -z "${UUID:-}" ]]; then
  UUID="$(/usr/local/bin/xray uuid)"
  echo "UUID=\"${UUID}\"" >> "$SECRETS_FILE"
fi
if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" ]]; then
  KEYS="$(/usr/local/bin/xray x25519)"
  PRIVATE_KEY="$(echo "$KEYS" | awk -F': ' '/Private/{print $2}')"
  PUBLIC_KEY="$(echo "$KEYS" | awk -F': ' '/Public/{print $2}')"
  {
    echo "PRIVATE_KEY=\"${PRIVATE_KEY}\""
    echo "PUBLIC_KEY=\"${PUBLIC_KEY}\""
  } >> "$SECRETS_FILE"
fi
if [[ -z "${SHORT_ID:-}" ]]; then
  SHORT_ID="$(openssl rand -hex 8)"
  echo "SHORT_ID=\"${SHORT_ID}\"" >> "$SECRETS_FILE"
fi
export UUID PRIVATE_KEY PUBLIC_KEY SHORT_ID

# ---------- CDN 备用节点 ----------
CDN_BLOCK=""
if [[ -n "${CDN_DOMAIN:-}" ]]; then
  CDN_DIR="/etc/vps-oneclick/cdn"
  mkdir -p "$CDN_DIR"
  if [[ ! -s "$CDN_DIR/cert.pem" || ! -s "$CDN_DIR/key.pem" ]]; then
    PROJECT_DIR="$(cd "$TEMPLATE_DIR/.." && pwd)"
    if [[ -s "$PROJECT_DIR/cert.pem" && -s "$PROJECT_DIR/key.pem" ]]; then
      cp "$PROJECT_DIR/cert.pem" "$CDN_DIR/cert.pem"
      cp "$PROJECT_DIR/key.pem" "$CDN_DIR/key.pem"
      echo "[20] 使用项目自带证书"
    else
      echo "[20] 未找到证书，生成 10 年自签证书（Cloudflare SSL 模式请用 Full）"
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CDN_DIR/key.pem" -out "$CDN_DIR/cert.pem" \
        -subj "/CN=${CDN_DOMAIN}" > /dev/null 2>&1
    fi
  fi
  CDN_BLOCK=",{\"tag\":\"cdn\",\"listen\":\"0.0.0.0\",\"port\":${CDN_PORT:-2053},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"xhttp\",\"security\":\"tls\",\"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"${CDN_DIR}/cert.pem\",\"keyFile\":\"${CDN_DIR}/key.pem\"}]},\"xhttpSettings\":{\"mode\":\"auto\"}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}}"
fi

# ---------- 渲染配置 ----------
echo "[20] 渲染 Xray 配置..."
mkdir -p /usr/local/etc/xray
sed -e "s|__REALITY_PORT__|${REALITY_PORT:-443}|g" \
    -e "s|__UUID__|${UUID}|g" \
    -e "s|__REALITY_SNI__|${REALITY_SNI:-www.samsung.com}|g" \
    -e "s|__PRIVATE_KEY__|${PRIVATE_KEY}|g" \
    -e "s|__SHORT_ID__|${SHORT_ID}|g" \
    -e "s|__CDN_BLOCK__|${CDN_BLOCK}|g" \
    "$TEMPLATE_DIR/xray-server.json.tmpl" > "$XRAY_CONF"

jq . "$XRAY_CONF" > /dev/null
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager; exit 1; }
echo "[20] Xray 已运行：Reality :${REALITY_PORT:-443}${CDN_DOMAIN:+ / CDN :${CDN_PORT:-2053}}"

