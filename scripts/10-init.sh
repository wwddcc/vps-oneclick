#!/usr/bin/env bash
# 系统初始化：依赖、BBR、防火墙、fail2ban
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "[!] 10-init 需要 root"; exit 1; }

SSH_PORT="${SSH_PORT:-22}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
REALITY_PORT="${REALITY_PORT:-443}"
CDN_PORT="${CDN_PORT:-2053}"

echo "[10] 安装系统依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget socat ufw fail2ban qrencode jq unzip \
  git build-essential python3 python3-psutil openssl gnupg ca-certificates

timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true

echo "[10] 开启 BBR..."
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system > /dev/null

echo "[10] 配置防火墙（放行 SSH / ${REALITY_PORT} / ${CDN_PORT}）..."
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow "${SSH_PORT}/tcp" > /dev/null
ufw allow "${REALITY_PORT}/tcp" > /dev/null
ufw allow "${CDN_PORT}/tcp" > /dev/null
ufw --force enable > /dev/null

echo "[10] 配置 fail2ban..."
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban > /dev/null 2>&1
systemctl restart fail2ban

echo "[10] 系统初始化完成"

