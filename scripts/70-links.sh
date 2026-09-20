#!/usr/bin/env bash
# 生成客户端分享链接、二维码与自检报告
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] 70-links 需要 root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/output"
mkdir -p "$OUT_DIR"
REALITY_PORT="${REALITY_PORT:-443}"
CDN_PORT="${CDN_PORT:-2053}"
SS_PANEL_PORT="${SS_PANEL_PORT:-35601}"
SS_WEB_PORT="${SS_WEB_PORT:-35602}"

for _required in UUID PUBLIC_KEY SHORT_ID; do
  if [[ -z "${!_required:-}" ]]; then
    echo "[!] 缺少 ${_required}，请检查 /etc/vps-oneclick/secrets.env 或重新运行 deploy.sh"
    exit 1
  fi
done

SERVER_IP="$(curl -s4 --max-time 10 https://api.ipify.org || curl -s4 --max-time 10 https://ip.sb)"
[[ -n "$SERVER_IP" ]] || { echo "[!] 无法获取服务器公网 IP"; exit 1; }

MAIN_LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F&mode=auto#LA-Reality-XHTTP"
CDN_LINK=""
if [[ -n "${CDN_DOMAIN:-}" ]]; then
  CDN_LINK="vless://${UUID}@${CDN_DOMAIN}:${CDN_PORT}?encryption=none&security=tls&sni=${CDN_DOMAIN}&fp=chrome&type=xhttp&host=${CDN_DOMAIN}&path=%2F&mode=auto#LA-CDN-XHTTP"
fi

umask 077
{
  echo "main = ${MAIN_LINK}"
  [[ -n "$CDN_LINK" ]] && echo "cdn  = ${CDN_LINK}"
} > "$OUT_DIR/client-links.txt"
echo "$MAIN_LINK" | qrencode -t PNG -s 8 -o "$OUT_DIR/main-qrcode.png"
[[ -n "$CDN_LINK" ]] && echo "$CDN_LINK" | qrencode -t PNG -s 8 -o "$OUT_DIR/cdn-qrcode.png"

echo ""
echo "================ 客户端导入 ================"
echo "主节点（Reality XHTTP）："
echo "$MAIN_LINK"
echo "$MAIN_LINK" | qrencode -t ANSIUTF8 -m 2
if [[ -n "$CDN_LINK" ]]; then
  echo ""
  echo "备用节点（CDN XHTTP）："
  echo "$CDN_LINK"
fi
echo ""
echo "链接已保存：$OUT_DIR/client-links.txt（权限 600）"
echo "二维码：$OUT_DIR/main-qrcode.png"

# ---------- 自检 ----------
DIRECT_IP="$(curl -s4 --max-time 10 https://api.ipify.org || echo unknown)"
WARP_IP="$(curl -s4 --max-time 10 --socks5-hostname 127.0.0.1:40000 https://api.ipify.org 2>/dev/null || echo unavailable)"
XRAY_STATE="$(systemctl is-active xray 2>/dev/null || echo inactive)"
LISTEN="$(ss -tlnp | awk '{print $4}' | grep -E ":(${REALITY_PORT}|${CDN_PORT})$" | sort -u | tr '\n' ' ')"
XUI_STATE="未安装"
SS_STATE="未安装"
SS_WEB_STATE="未安装"
SS_PROBE_STATE="未安装"
CLOUDFLARED_STATE="未安装"
if [[ "${INSTALL_3XUI:-1}" == "1" ]]; then
  XUI_STATE="$(systemctl is-active x-ui 2>/dev/null || echo inactive)"
fi
if [[ "${INSTALL_SERVERSTATUS:-1}" == "1" ]]; then
  SS_STATE="$(systemctl is-active serverstatus 2>/dev/null || echo inactive)"
  SS_WEB_STATE="$(systemctl is-active serverstatus-web 2>/dev/null || echo inactive)"
  SS_PROBE_STATE="$(systemctl is-active serverstatus-probe 2>/dev/null || echo inactive)"
elif [[ "${INSTALL_SERVERSTATUS:-1}" == "2" ]]; then
  SS_PROBE_STATE="$(systemctl is-active serverstatus-probe 2>/dev/null || echo inactive)"
fi
if [[ "${INSTALL_TUNNEL:-1}" == "1" ]]; then
  CLOUDFLARED_STATE="$(systemctl is-active cloudflared 2>/dev/null || echo inactive)"
fi
PANEL_PUBLIC_URL="待配置"
STATUS_PUBLIC_URL="待配置"
if [[ -n "${PANEL_PUBLIC_DOMAIN:-}" ]]; then
  PANEL_PUBLIC_URL="https://${PANEL_PUBLIC_DOMAIN}/${PANEL_PATH}"
fi
if [[ -n "${STATUS_PUBLIC_DOMAIN:-}" ]]; then
  STATUS_PUBLIC_URL="https://${STATUS_PUBLIC_DOMAIN}"
fi
CF_PUBLIC_HOSTNAMES="   - 3x-ui：\`http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}\`，对应你的面板域名。"
CF_ACCESS_TARGETS="给面板域名"
VERIFY_TARGETS="用面板域名登录 3x-ui"
if [[ "${INSTALL_SERVERSTATUS:-1}" == "1" ]]; then
  CF_PUBLIC_HOSTNAMES+=$'\n   - ServerStatus：`http://127.0.0.1:35602`，对应探针域名。'
  CF_ACCESS_TARGETS+="和探针域名"
  VERIFY_TARGETS+="和 ServerStatus"
fi
REPORT_FILE="$OUT_DIR/deployment-report.md"

echo ""
echo "================ 部署自检 ================"
echo "服务器 IP（直连出口）：${DIRECT_IP}"
echo "WARP 出口 IP（AI 域名）：${WARP_IP}"
echo "Xray 状态：${XRAY_STATE}"
echo "监听端口：${LISTEN:-未检测到}"
if [[ "${INSTALL_3XUI:-1}" == "1" ]]; then
  echo "3x-ui：http://localhost:${PANEL_PORT}/${PANEL_PATH}  账号 ${PANEL_USER} / ${PANEL_PASS}"
fi
if [[ "${INSTALL_SERVERSTATUS:-1}" == "1" ]] && systemctl is-active --quiet serverstatus 2>/dev/null; then
  echo "ServerStatus Web：http://localhost:${SS_WEB_PORT}（经 Tunnel 发布后用域名访问）"
  echo "ServerStatus 探针协议端口：${SS_PANEL_PORT}（仅本机探针使用）"
elif [[ "${INSTALL_SERVERSTATUS:-1}" == "2" ]]; then
  echo "ServerStatus 探针客户端：上报 ${SS_SERVER}:${SS_PANEL_PORT}，状态 ${SS_PROBE_STATE}"
fi
echo ""
echo "下一步：把上面的 vless:// 链接导入 v2rayN（剪贴板导入）或 v2rayNG（扫码）测试连接。"

cat > "$REPORT_FILE" <<EOF
# VPS 一键部署结果报告

生成时间：$(date '+%F %T %Z')

## 基础信息

- 服务器 IP：${DIRECT_IP}
- WARP 出口 IP：${WARP_IP}
- Xray 状态：${XRAY_STATE}
- 监听端口：${LISTEN:-未检测到}
- cloudflared 状态：${CLOUDFLARED_STATE}

## 客户端节点

### 主节点：Reality XHTTP

\`\`\`text
${MAIN_LINK}
\`\`\`

导入方式：v2rayN 使用「从剪贴板导入」；v2rayNG / Shadowrocket 可扫描 ${OUT_DIR}/main-qrcode.png。

### 备用节点：CDN XHTTP

EOF

if [[ -n "$CDN_LINK" ]]; then
  cat >> "$REPORT_FILE" <<EOF
\`\`\`text
${CDN_LINK}
\`\`\`

导入方式：v2rayN 使用「从剪贴板导入」；v2rayNG / Shadowrocket 可扫描 ${OUT_DIR}/cdn-qrcode.png。

EOF
else
  echo "未启用（config.env 中 CDN_DOMAIN 为空）。" >> "$REPORT_FILE"
fi

if [[ "${INSTALL_3XUI:-1}" == "1" ]]; then
  cat >> "$REPORT_FILE" <<EOF
## 3x-ui 管理面板

- 服务状态：${XUI_STATE}
- 本机地址：http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}
- Tunnel 公网地址：${PANEL_PUBLIC_URL}
- 用户名：${PANEL_USER}
- 密码：${PANEL_PASS}
- 路径：/${PANEL_PATH}

本机地址只能在服务器或 SSH 端口转发后访问；日常请使用 Tunnel 公网地址，并保持 Cloudflare Access 保护。

EOF
fi

if [[ "${INSTALL_SERVERSTATUS:-1}" == "1" ]]; then
  cat >> "$REPORT_FILE" <<EOF
## ServerStatus 探针面板

- 数据收集服务：${SS_STATE}
- 静态面板服务：${SS_WEB_STATE}
- 本机探针服务：${SS_PROBE_STATE}
- 本机 Web 地址：http://127.0.0.1:${SS_WEB_PORT}
- Tunnel 公网地址：${STATUS_PUBLIC_URL}
- 探针协议端口：${SS_PANEL_PORT}（仅本机探针使用，不要发布到 Tunnel）
- 探针用户名：${SS_USER}
- 探针密码：${SS_PASS}

\`35601\` 是探针上报协议端口，不是 HTTP 面板端口；Cloudflare Tunnel 应指向静态面板端口 \`35602\`。

EOF
elif [[ "${INSTALL_SERVERSTATUS:-1}" == "2" ]]; then
  cat >> "$REPORT_FILE" <<EOF
## ServerStatus 探针客户端

- 探针服务：${SS_PROBE_STATE}
- 上报地址：${SS_SERVER}:${SS_PANEL_PORT}

EOF
fi

cat >> "$REPORT_FILE" <<EOF
## 需要你完成或确认的 Cloudflare 操作

1. Zero Trust -> Networks -> Tunnels 中确认 Tunnel 为 HEALTHY。
2. Public Hostname 配置：
${CF_PUBLIC_HOSTNAMES}
3. ${CF_ACCESS_TARGETS}分别配置 Cloudflare Access 应用，只允许你的 Google 邮箱登录。
4. DNS/SSL 设置：
   - SSL/TLS 模式使用 `Full` 或 `Full (strict)`。
   - 开启 `Always Use HTTPS`。
5. 浏览器访问时使用 `https://`。Tunnel 服务里的 `http://127.0.0.1` 只是 Cloudflare 到源站的内网回源协议。
EOF

cat >> "$REPORT_FILE" <<'EOF'
## 导入与验证步骤

1. 打开 `client-links.txt`，复制主节点 `vless://` 链接。
2. v2rayN：服务器 -> 从剪贴板导入，然后设为活动节点并测试真实延迟。
3. v2rayNG / Shadowrocket：扫描 `main-qrcode.png`，选择该节点后测试连接。
4. 访问 Claude / Codex / Google，确认代理可用。
EOF

cat >> "$REPORT_FILE" <<EOF
5. ${VERIFY_TARGETS}，确认 Cloudflare Access 登录流程正常。
EOF

cat >> "$REPORT_FILE" <<'EOF'
## 常用自检命令

```bash
systemctl status xray --no-pager
systemctl status warp-svc --no-pager
systemctl status serverstatus serverstatus-web serverstatus-probe --no-pager
systemctl status x-ui cloudflared --no-pager
curl -I http://127.0.0.1:35602/
curl --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

## 文件位置

- 客户端链接：`/opt/vps-oneclick/output/client-links.txt`
- 主节点二维码：`/opt/vps-oneclick/output/main-qrcode.png`
- 备用节点二维码：`/opt/vps-oneclick/output/cdn-qrcode.png`
- 生成密钥：`/etc/vps-oneclick/secrets.env`
- 部署日志：`/opt/vps-oneclick/deploy.log`

> 本报告包含节点链接和账号密码，权限为 600。不要提交到 Git，也不要上传到公开位置。
EOF

chmod 600 "$REPORT_FILE"
echo "部署报告：${REPORT_FILE}（权限 600）"
