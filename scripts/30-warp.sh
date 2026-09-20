#!/usr/bin/env bash
# 安装 Cloudflare WARP（代理模式），为 AI 域名提供干净出口
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] 30-warp 需要 root"; exit 1; }

echo "[30] 安装 Cloudflare WARP 客户端..."
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp.gpg
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
if [[ -z "$CODENAME" ]]; then
  apt-get install -y lsb-release > /dev/null
  CODENAME="$(lsb_release -cs)"
fi
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
  > /etc/apt/sources.list.d/cloudflare-client.list
apt-get update -y
apt-get install -y cloudflare-warp

echo "[30] 注册并切换为代理模式（socks5 127.0.0.1:40000）..."
warp-cli --accept-tos registration show > /dev/null 2>&1 || \
  warp-cli --accept-tos registration new > /dev/null 2>&1 || \
  warp-cli --accept-tos register > /dev/null 2>&1 || true
warp-cli --accept-tos mode proxy > /dev/null 2>&1 || true
warp-cli --accept-tos proxy port 40000 > /dev/null 2>&1 || true
warp-cli --accept-tos connect > /dev/null 2>&1 || true

echo "[30] 验证 WARP..."
WARP_OK=0
for i in 1 2 3 4 5; do
  sleep 3
  if curl -s --max-time 10 --socks5-hostname 127.0.0.1:40000 \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp=on'; then
    WARP_OK=1
    break
  fi
done
if [[ $WARP_OK -eq 1 ]]; then
  echo "[30] WARP 正常：warp=on（Claude/OpenAI 将走 Cloudflare 出口）"
else
  echo "[!] WARP 验证失败，AI 域名分流暂不可用。"
  echo "    可稍后重跑：warp-cli connect && bash scripts/30-warp.sh"
fi

