#!/usr/bin/env bash
# vps-oneclick 在线安装引导
# 用法：curl -fsSL https://raw.githubusercontent.com/wwddcc/vps-oneclick/master/install.sh | sudo bash -s -- --minimal
set -euo pipefail

REPO="${VPS_ONECLICK_REPO:-wwddcc/vps-oneclick}"
REF="${VPS_ONECLICK_REF:-master}"
REF_TYPE="${VPS_ONECLICK_REF_TYPE:-branch}"
INSTALL_DIR="${VPS_ONECLICK_DIR:-/opt/vps-oneclick}"
SHA256="${VPS_ONECLICK_SHA256:-}"
MIRROR="${VPS_ONECLICK_MIRROR:-}"
RUN_DEPLOY=1
MINIMAL=0
TIMEZONE=""

usage() {
  cat <<'EOF'
vps-oneclick 在线安装引导

用法：
  curl -fsSL https://raw.githubusercontent.com/wwddcc/vps-oneclick/master/install.sh | sudo bash -s -- [参数]

参数：
  --repo OWNER/REPO        使用其他 GitHub 仓库，默认 wwddcc/vps-oneclick
  --branch NAME            使用指定分支，默认 master
  --version TAG            使用指定 tag；生产环境推荐固定版本
  --dir PATH               安装目录，默认 /opt/vps-oneclick
  --minimal                首次安装时生成最小配置：不启用 CDN、Tunnel、3x-ui、ServerStatus
  --timezone NAME          首次创建配置时设置 IANA 时区，例如 Asia/Shanghai
  --run                    下载后执行 deploy.sh，默认行为
  --no-run                 只下载并准备配置，不自动部署
  --mirror PREFIX          使用可信 GitHub 加速镜像前缀；第三方镜像有供应链风险
  --sha256 HEX             校验源码包 SHA-256；固定版本部署推荐开启
  -h, --help               显示帮助
EOF
}

die() {
  echo "[!] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ -n "${2:-}" ]] || die "--repo 需要参数"
      REPO="$2"
      shift 2
      ;;
    --branch)
      [[ -n "${2:-}" ]] || die "--branch 需要参数"
      REF="$2"
      REF_TYPE="branch"
      shift 2
      ;;
    --version)
      [[ -n "${2:-}" ]] || die "--version 需要参数"
      REF="$2"
      REF_TYPE="tag"
      shift 2
      ;;
    --dir)
      [[ -n "${2:-}" ]] || die "--dir 需要参数"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --minimal)
      MINIMAL=1
      shift
      ;;
    --timezone)
      [[ -n "${2:-}" ]] || die "--timezone 需要参数"
      TIMEZONE="$2"
      shift 2
      ;;
    --run)
      RUN_DEPLOY=1
      shift
      ;;
    --no-run)
      RUN_DEPLOY=0
      shift
      ;;
    --mirror)
      [[ -n "${2:-}" ]] || die "--mirror 需要参数"
      MIRROR="$2"
      shift 2
      ;;
    --sha256)
      [[ -n "${2:-}" ]] || die "--sha256 需要参数"
      SHA256="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1（使用 --help 查看帮助）"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "请用 root 运行：curl ... | sudo bash -s -- ..."
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "REPO 格式应为 OWNER/REPO"
case "$REF_TYPE" in
  branch|tag) ;;
  *) die "不支持的源码引用类型：$REF_TYPE" ;;
esac
[[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "branch/tag 名称包含不受支持的字符"
[[ "$INSTALL_DIR" = /* ]] || die "安装目录必须使用绝对路径"
[[ "$INSTALL_DIR" != "/" ]] || die "安装目录不能是根目录"
[[ -z "$SHA256" || "$SHA256" =~ ^[A-Fa-f0-9]{64}$ ]] || die "SHA-256 应为 64 位十六进制值"
[[ -z "$MIRROR" || "$MIRROR" =~ ^https?:// ]] || die "镜像前缀必须以 http:// 或 https:// 开头"

if [[ ! -r /etc/os-release ]]; then
  die "未识别到 /etc/os-release，仅支持 Ubuntu 20.04+ / Debian 11+"
fi
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "当前系统 ${ID:-unknown} 不受支持，请用 Ubuntu 20.04+ / Debian 11+" ;;
esac
VER_MAJOR="${VERSION_ID%%.*}"
if [[ "${ID}" == "ubuntu" && "${VER_MAJOR}" -lt 20 ]] || \
   [[ "${ID}" == "debian" && "${VER_MAJOR}" -lt 11 ]]; then
  die "系统版本过低：${PRETTY_NAME:-$ID $VERSION_ID}"
fi

ensure_download_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  ((${#missing[@]})) || return 0

  command -v apt-get >/dev/null 2>&1 || die "缺少命令：${missing[*]}"
  echo "[*] 安装下载依赖：${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y </dev/null
  apt-get install -y "${missing[@]}" </dev/null
}

download_source() {
  local output="$1"
  local ref_path
  case "$REF_TYPE" in
    branch) ref_path="heads" ;;
    tag) ref_path="tags" ;;
  esac
  local direct="https://codeload.github.com/${REPO}/tar.gz/refs/${ref_path}/${REF}"
  local -a urls=()
  local url

  if [[ -n "$MIRROR" ]]; then
    echo "[!] 使用第三方 GitHub 镜像存在供应链风险；固定版本时建议同时提供 --sha256"
    urls+=("${MIRROR%/}/${direct}")
  fi
  urls+=("$direct")

  for url in "${urls[@]}"; do
    echo "[*] 下载源码：$url"
    rm -f "$output"
    if curl -fL --retry 3 --connect-timeout 15 --max-time 300 -o "$output" "$url" && \
       [[ -s "$output" ]]; then
      return 0
    fi
    echo "[*] 下载失败，尝试下一个源"
  done

  die "无法下载 vps-oneclick 源码"
}

verify_source() {
  local archive="$1"
  [[ -z "$SHA256" ]] && return 0
  echo "[*] 校验源码包 SHA-256"
  echo "${SHA256}  ${archive}" | sha256sum --check --status || \
    die "源码包 SHA-256 校验失败"
}

extract_source() {
  local archive="$1" workdir="$2"
  local extract_dir
  extract_dir="$(mktemp -d "${workdir}/source.XXXXXX")"
  tar -xzf "$archive" -C "$extract_dir"

  local -a dirs=()
  local item
  for item in "$extract_dir"/*; do
    [[ -d "$item" ]] && dirs+=("$item")
  done
  ((${#dirs[@]} == 1)) || die "源码包目录结构异常"
  printf '%s\n' "${dirs[0]}"
}

create_config() {
  local target="$1"
  local config="$target/config.env"

  if [[ -f "$config" ]]; then
    echo "[*] 保留已有配置：$config"
    return 0
  fi

  cp "$target/config.env.example" "$config"
  if [[ "$MINIMAL" == "1" ]]; then
    sed -i \
      -e 's|^INSTALL_SERVERSTATUS=.*|INSTALL_SERVERSTATUS="0"|' \
      -e 's|^INSTALL_3XUI=.*|INSTALL_3XUI="0"|' \
      -e 's|^INSTALL_TUNNEL=.*|INSTALL_TUNNEL="0"|' \
      -e 's|^CDN_DOMAIN=.*|CDN_DOMAIN=""|' \
      -e 's|^TUNNEL_TOKEN=.*|TUNNEL_TOKEN=""|' \
      "$config"
  fi
  if [[ -n "$TIMEZONE" ]]; then
    sed -i "s|^TIMEZONE=.*|TIMEZONE=\"${TIMEZONE}\"|" "$config"
  fi
  chmod 600 "$config"
  echo "[*] 已创建配置：$config"
}

ensure_download_tools

echo "[*] 安装目录：$INSTALL_DIR"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/vps-oneclick-install.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

archive="$workdir/source.tar.gz"
download_source "$archive"
verify_source "$archive"
source_dir="$(extract_source "$archive" "$workdir")"

for required_file in \
  deploy.sh \
  config.env.example \
  scripts/70-links.sh \
  templates/xray-server.json.tmpl; do
  [[ -f "$source_dir/$required_file" ]] || die "源码包缺少必要文件：$required_file"
done

if [[ -e "$INSTALL_DIR" ]]; then
  [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] || die "安装目录已存在但不是普通目录：$INSTALL_DIR"
  backup="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
  echo "[*] 备份旧目录到：$backup"
  mkdir -p "$backup"
  cp -a "$INSTALL_DIR"/. "$backup"/
else
  mkdir -p "$INSTALL_DIR"
fi

cp -a "$source_dir"/. "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR/deploy.sh" "$INSTALL_DIR"/scripts/*.sh
create_config "$INSTALL_DIR"

echo "[*] 安装完成：$INSTALL_DIR"
if [[ "$RUN_DEPLOY" == "1" ]]; then
  echo "[*] 开始一键部署..."
  cd "$INSTALL_DIR"
  bash deploy.sh </dev/null
else
  echo "[*] 已按要求跳过部署。"
  echo "    后续可执行：cd $INSTALL_DIR && sudo bash deploy.sh"
fi
