#!/usr/bin/env bash
# ServerStatus 数据收集 + 本机探针 + 静态面板（同机部署）
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] 40-serverstatus 需要 root"; exit 1; }

SECRETS_FILE="/etc/vps-oneclick/secrets.env"
REPO_DIR="/usr/local/ServerStatus"
SS_PANEL_PORT="${SS_PANEL_PORT:-35601}"
SS_WEB_PORT="${SS_WEB_PORT:-35602}"
export SS_PANEL_PORT SS_WEB_PORT

if [[ -z "${SS_USER:-}" ]]; then
  SS_USER="node_la"
  echo "SS_USER=\"${SS_USER}\"" >> "$SECRETS_FILE"
fi
if [[ -z "${SS_PASS:-}" ]]; then
  SS_PASS="$(openssl rand -hex 8)"
  echo "SS_PASS=\"${SS_PASS}\"" >> "$SECRETS_FILE"
fi
export SS_USER SS_PASS

echo "[40] 获取 ServerStatus..."
if [[ ! -d "$REPO_DIR/.git" ]]; then
  rm -rf "$REPO_DIR"
  SS_MIRRORS=(
    "https://github.com/cokemine/ServerStatus-Hotaru.git"
    "https://gitlab.com/null-anything/ServerStatus.git"
    "https://github.com/ToyoDAdoubiBackup/ServerStatus-Toyo.git"
  )
  CLONED=0
  for _mirror in "${SS_MIRRORS[@]}"; do
    echo "[40] 尝试源：${_mirror}"
    if GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$_mirror" "$REPO_DIR"; then
      CLONED=1
      break
    fi
    rm -rf "$REPO_DIR"
  done
  if [[ $CLONED -ne 1 ]]; then
    echo "[!] ServerStatus 所有源均克隆失败，已跳过（不影响代理主链路）"
    systemctl disable --now serverstatus serverstatus-probe serverstatus-web >/dev/null 2>&1 || true
    exit 0
  fi
fi

echo "[40] 编译 sergate..."
make -C "$REPO_DIR/server" > /dev/null

echo "[40] 写入节点配置..."
cat > "$REPO_DIR/server/config.json" <<EOF
{
  "group": "MyServers",
  "servers": [
    {
      "username": "${SS_USER}",
      "password": "${SS_PASS}",
      "name": "LA-主节点",
      "type": "KVM",
      "host": "VPS",
      "location": "Los Angeles",
      "disabled": false,
      "region": "US"
    }
  ]
}
EOF

echo "[40] 定位探针脚本..."
CLIENT_SCRIPT="$(find "$REPO_DIR" -type f -name '*.py' | grep -Ei 'client' | head -n1 || true)"

# Hotaru 探针不解析命令行参数，凭据和地址是文件内常量，部署时直接注入。
if [[ -n "$CLIENT_SCRIPT" ]]; then
  sed -i -E "s|^SERVER = .*|SERVER = \"127.0.0.1\"|; s|^PORT = .*|PORT = ${SS_PANEL_PORT}|; s|^USER = .*|USER = \"${SS_USER}\"|; s|^PASSWORD = .*|PASSWORD = \"${SS_PASS}\"|" "$CLIENT_SCRIPT"
fi

echo "[40] 定位面板 Web 目录..."
WEB_INDEX="$(find "$REPO_DIR" -type f \( -name 'index.html' -o -name 'index.htm' \) -print -quit 2>/dev/null || true)"
WEB_DIR=""
if [[ -n "$WEB_INDEX" ]]; then
  WEB_DIR="$(dirname "$WEB_INDEX")"
fi

# Hotaru 源码可能不携带 web/ 前端，补拉 Toyo 前端作为兼容来源。
if [[ -z "$WEB_DIR" ]]; then
  echo "[40] 当前源码未找到前端，尝试获取兼容 Web 目录..."
  rm -rf /tmp/ss-web-src /usr/local/ServerStatus-web
  if GIT_TERMINAL_PROMPT=0 git clone --depth 1 https://github.com/ToyoDAdoubiBackup/ServerStatus-Toyo.git /tmp/ss-web-src \
    && [[ -f /tmp/ss-web-src/web/index.html ]]; then
    cp -a /tmp/ss-web-src/web /usr/local/ServerStatus-web
    rm -rf /tmp/ss-web-src
    WEB_DIR="/usr/local/ServerStatus-web"
  else
    rm -rf /tmp/ss-web-src
  fi
fi

if [[ -z "$WEB_DIR" ]] || { [[ ! -f "$WEB_DIR/index.html" ]] && [[ ! -f "$WEB_DIR/index.htm" ]]; }; then
  echo "[!] 未找到可用的 ServerStatus Web 目录，已跳过（不影响代理主链路）"
  systemctl disable --now serverstatus serverstatus-probe serverstatus-web >/dev/null 2>&1 || true
  exit 0
fi
echo "[40] Web 目录：${WEB_DIR}"

echo "[40] 创建 systemd 服务..."
cat > /etc/systemd/system/serverstatus.service <<EOF
[Unit]
Description=ServerStatus Data Collector (sergate)
After=network.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}/server
ExecStart=${REPO_DIR}/server/sergate --config=${REPO_DIR}/server/config.json --web-dir=${WEB_DIR} --port=${SS_PANEL_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/serverstatus-web.service <<EOF
[Unit]
Description=ServerStatus Web (static)
After=network.target serverstatus.service

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/bin/python3 -m http.server ${SS_WEB_PORT} --bind 127.0.0.1 --directory ${WEB_DIR}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

if [[ -n "$CLIENT_SCRIPT" ]]; then
  cat > /etc/systemd/system/serverstatus-probe.service <<EOF
[Unit]
Description=ServerStatus Probe (local)
After=network.target serverstatus.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${CLIENT_SCRIPT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
else
  echo "[!] 未找到探针脚本，先跳过探针（面板正常安装）"
  echo "    仓库 Python 文件如下，把列表发给 Codex 即可精确适配："
  find "$REPO_DIR" -type f -name '*.py' | head -20 | sed 's/^/      /'
fi

systemctl daemon-reload
systemctl enable --now serverstatus serverstatus-web
systemctl restart serverstatus serverstatus-web
if [[ -n "$CLIENT_SCRIPT" ]]; then
  systemctl enable --now serverstatus-probe
  systemctl restart serverstatus-probe
fi
sleep 2
systemctl is-active --quiet serverstatus || { journalctl -u serverstatus -n 20 --no-pager; exit 1; }
systemctl is-active --quiet serverstatus-web || { journalctl -u serverstatus-web -n 20 --no-pager; exit 1; }
curl -fsS "http://127.0.0.1:${SS_WEB_PORT}/" >/dev/null
if [[ -n "$CLIENT_SCRIPT" ]]; then
  echo "[40] ServerStatus 面板 :${SS_WEB_PORT}，探针协议端口 :${SS_PANEL_PORT}，探针已接入本机节点"
else
  echo "[40] ServerStatus 面板 :${SS_WEB_PORT} 已运行（探针待适配）"
fi
