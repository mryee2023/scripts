#!/bin/bash
set -euo pipefail

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "错误：请使用 root 执行（例如 sudo bash $0）"
    exit 1
  fi
}

prompt_yes_no_default_yes() {
  # usage: prompt_yes_no_default_yes "Question?"
  # returns 0 for yes, 1 for no
  local prompt="$1"
  local ans=""

  # 兼容 `curl ... | bash`：stdin 是 pipe 时，优先从 /dev/tty 读取
  if [ -e /dev/tty ] && [ -t 1 ]; then
    # shellcheck disable=SC2162
    read -r -p "${prompt} [Y/n]: " ans < /dev/tty || true
  elif [ -t 0 ]; then
    read -r -p "${prompt} [Y/n]: " ans || true
  else
    echo "${prompt} [Y/n]: (非交互环境，默认选择 Y)"
    ans=""
  fi

  case "${ans}" in
    ""|y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    *) return 0 ;;
  esac
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  else
    echo ""
  fi
}

install_packages() {
  # usage: install_packages pkg1 pkg2 ...
  local pm
  pm="$(detect_pkg_manager)"
  if [ -z "$pm" ]; then
    echo "错误：无法识别包管理器，请手动安装依赖：$*"
    exit 1
  fi

  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    pacman)
      pacman -Sy --noconfirm "$@"
      ;;
  esac
}

ensure_command() {
  # usage: ensure_command <cmd> <pkg_name>
  local cmd="$1"
  local pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "缺少依赖：$cmd（正在安装：$pkg）"
    install_packages "$pkg"
  fi
}

detect_arch() {
  # returns: amd64 / arm64
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      echo "错误：不支持的架构：$m"
      exit 1
      ;;
  esac
}

get_latest_mihomo_version() {
  # returns version like "1.19.0" (without leading v)
  local api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
  local tag
  tag="$(curl -fsSL "$api" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$tag" ]; then
    echo "错误：无法从 GitHub API 获取 mihomo 最新版本"
    exit 1
  fi
  echo "${tag#v}"
}

get_latest_mihomo_download_url() {
  # best-effort choose a linux asset for arch
  local ver="$1"
  local arch="$2"
  local api json urls chosen=""

  api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
  json="$(curl -fsSL "$api")"

  # 提取所有 browser_download_url（无需 jq）
  urls="$(echo "$json" | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p')"

  # 优先：linux + arch + tar.gz / tgz / zip / gz
  # 注：mihomo 有时发布的是单文件 .gz（非 tar.gz）
  chosen="$(echo "$urls" | grep -Ei 'linux' | grep -Ei "${arch}|x86_64|amd64|aarch64|arm64" | grep -E '\.(tar\.gz|tgz|zip|gz)$' | head -n 1 || true)"

  # 兜底：linux + (arch) + 任意压缩格式
  if [ -z "$chosen" ]; then
    chosen="$(echo "$urls" | grep -Ei 'linux' | grep -Ei "${arch}|x86_64|amd64|aarch64|arm64" | head -n 1 || true)"
  fi

  # 再兜底：任何 linux 资源
  if [ -z "$chosen" ]; then
    chosen="$(echo "$urls" | grep -Ei 'linux' | head -n 1 || true)"
  fi

  if [ -z "$chosen" ]; then
    echo "错误：未能在 latest release 中找到可用的 Linux 下载资源（arch=${arch}）"
    exit 1
  fi

  echo "$chosen"
}

get_installed_mihomo_path() {
  if [ -x /root/mihomo/mihomo ]; then
    echo "/root/mihomo/mihomo"
    return 0
  fi
  if command -v mihomo >/dev/null 2>&1; then
    command -v mihomo
    return 0
  fi
  return 1
}

extract_semver() {
  # usage: extract_semver "some text" -> "1.2.3" or empty
  echo "$1" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | sed 's/^v//'
}

get_installed_mihomo_version() {
  local p out v
  p="$(get_installed_mihomo_path)" || return 1

  if [ -f /root/mihomo/.mihomo_version ]; then
    v="$(cat /root/mihomo/.mihomo_version 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$v" ]; then
      echo "$v"
      return 0
    fi
  fi

  out="$("$p" -v 2>/dev/null || true)"
  v="$(extract_semver "$out")"
  if [ -n "$v" ]; then
    echo "$v"
    return 0
  fi

  out="$("$p" --version 2>/dev/null || true)"
  v="$(extract_semver "$out")"
  if [ -n "$v" ]; then
    echo "$v"
    return 0
  fi

  echo "unknown"
  return 0
}

find_mihomo_service_unit() {
  if [ -f /etc/systemd/system/mihomo.service ] || [ -f /lib/systemd/system/mihomo.service ]; then
    echo "mihomo.service"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^mihomo\.service'; then
    echo "mihomo.service"
    return 0
  fi
  return 1
}

random_password_15() {
  # 生成长度 15 的随机密码（尽量只用可见字符）
  openssl rand -base64 24 | tr -d "=+/" | cut -c1-15
}

generate_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
    return 0
  fi
  # 兜底：openssl 生成伪 UUID（足够使用）
  openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*$/\1-\2-\3-\4-\5/'
}

generate_short_id_12() {
  # reality short-id 常用 12 hex（示例：a1b2c3d4e5f6）
  openssl rand -hex 6
}

generate_reality_keypair() {
  # 输出：private_key|public_key
  local bin out priv pub token1 token2
  bin="/root/mihomo/mihomo"
  if [ ! -x "$bin" ]; then
    echo "错误：mihomo 二进制不存在，无法生成 reality keypair"
    exit 1
  fi

  out="$("$bin" generate reality-keypair 2>/dev/null || "$bin" generate reality-keypair 2>&1 || true)"

  # 常见输出格式包含 PrivateKey/PublicKey 字段
  priv="$(echo "$out" | sed -n 's/.*[Pp]rivate[- ]\?[Kk]ey[: ]\+//p' | head -n 1 | tr -d '"')"
  pub="$(echo "$out" | sed -n 's/.*[Pp]ublic[- ]\?[Kk]ey[: ]\+//p' | head -n 1 | tr -d '"')"

  # 兜底：从输出中抓取两个类似 base64url 的长 token
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    token1="$(echo "$out" | grep -Eo '[A-Za-z0-9_-]{40,}' | head -n 1 || true)"
    token2="$(echo "$out" | grep -Eo '[A-Za-z0-9_-]{40,}' | sed -n '2p' || true)"
    priv="${priv:-$token1}"
    pub="${pub:-$token2}"
  fi

  if [ -z "$priv" ] || [ -z "$pub" ]; then
    echo "错误：无法解析 mihomo 生成的 reality keypair 输出："
    echo "$out"
    exit 1
  fi

  echo "${priv}|${pub}"
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln | grep -qE "[:.]${port}[[:space:]]"
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tuln | grep -q ":${port} "
    return $?
  fi
  # 两者都没有：认为不可判断，返回“占用”避免误用
  return 0
}

find_available_port_52000_56000() {
  local p=0
  for _ in {1..200}; do
    p=$((52000 + RANDOM % 4001))
    if ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo "0"
  return 1
}

find_available_port_52000_56000_excluding() {
  local excluded="$1"
  local p
  for _ in {1..200}; do
    p="$(find_available_port_52000_56000 || echo 0)"
    if [ "$p" != "0" ] && [ "$p" != "$excluded" ]; then
      echo "$p"
      return 0
    fi
  done
  echo "0"
  return 1
}

find_available_port_52000_56000_excluding_two() {
  local e1="$1"
  local e2="$2"
  local p
  for _ in {1..200}; do
    p="$(find_available_port_52000_56000 || echo 0)"
    if [ "$p" != "0" ] && [ "$p" != "$e1" ] && [ "$p" != "$e2" ]; then
      echo "$p"
      return 0
    fi
  done
  echo "0"
  return 1
}

download_and_install_mihomo_binary() {
  local url="$1"
  local tmp_dir archive_name ext

  mkdir -p /root/mihomo

  tmp_dir="$(mktemp -d)"
  # 重要：不要用 EXIT（会在脚本退出时触发，但 local 变量已失效，配合 set -u 会报 unbound）
  trap 'rm -rf "$tmp_dir"' RETURN

  archive_name="$(basename "$url")"
  echo "正在下载：$url"
  wget -O "${tmp_dir}/${archive_name}" "$url"

  ext="${archive_name##*.}"
  if echo "$archive_name" | grep -qE '\.tar\.gz$|\.tgz$'; then
    ensure_command tar tar
    tar -xzf "${tmp_dir}/${archive_name}" -C "$tmp_dir"
  elif echo "$archive_name" | grep -qE '\.gz$' && ! echo "$archive_name" | grep -qE '\.tar\.gz$'; then
    # 单文件 gzip：解压得到二进制
    ensure_command gunzip gzip
    gunzip -c "${tmp_dir}/${archive_name}" > "${tmp_dir}/mihomo"
    chmod +x "${tmp_dir}/mihomo" || true
  elif [ "$ext" = "zip" ]; then
    unzip -o "${tmp_dir}/${archive_name}" -d "$tmp_dir" >/dev/null
  else
    # 兜底：尝试 tar
    ensure_command tar tar
    tar -xf "${tmp_dir}/${archive_name}" -C "$tmp_dir" || {
      echo "错误：无法解压下载的文件：${archive_name}"
      exit 1
    }
  fi

  # 在解压目录里找 mihomo 可执行文件
  local bin
  bin="$(find "$tmp_dir" -maxdepth 3 -type f -name 'mihomo' 2>/dev/null | head -n 1 || true)"
  if [ -z "$bin" ]; then
    # 有些包可能叫 clash-meta / mihomo-linux-xxx 等：兜底找一个可执行文件（名字包含 mihomo）
    bin="$(find "$tmp_dir" -maxdepth 3 -type f -iname '*mihomo*' 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "$bin" ]; then
    echo "错误：在解压内容中未找到 mihomo 可执行文件"
    exit 1
  fi

  if [ -f /root/mihomo/mihomo ]; then
    cp -f /root/mihomo/mihomo "/root/mihomo/mihomo.bak.$(date +%Y%m%d%H%M%S)" || true
  fi
  mv -f "$bin" /root/mihomo/mihomo
  chmod +x /root/mihomo/mihomo
}

require_root

echo "准备安装/升级 mihomo..."

# 依赖（下载/解压/生成密码）
ensure_command curl curl
ensure_command wget wget
ensure_command unzip unzip
ensure_command openssl openssl

# 端口占用检测：优先 ss；没有则用 netstat（net-tools）
if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
  echo "缺少端口检测工具 ss/netstat，尝试安装 net-tools（提供 netstat）"
  install_packages net-tools || true
fi

LATEST_VERSION="$(get_latest_mihomo_version)"
ARCH="$(detect_arch)"
DOWNLOAD_URL="$(get_latest_mihomo_download_url "$LATEST_VERSION" "$ARCH")"

if get_installed_mihomo_path >/dev/null 2>&1; then
  INSTALLED_PATH="$(get_installed_mihomo_path)"
  INSTALLED_VERSION="$(get_installed_mihomo_version || echo "unknown")"
  echo "mihomo 已安装。"
  echo "安装路径   : ${INSTALLED_PATH}"
  echo "当前版本   : v${INSTALLED_VERSION}"
  echo "最新版本   : v${LATEST_VERSION}"

  if ! prompt_yes_no_default_yes "是否升级 mihomo 到最新版本？"; then
    echo "已选择不升级，退出。"
    exit 0
  fi

  echo "开始升级（不会覆盖现有 config.yaml 与 service 文件）..."
  download_and_install_mihomo_binary "$DOWNLOAD_URL"
  echo "${LATEST_VERSION}" > /root/mihomo/.mihomo_version

  if command -v systemctl >/dev/null 2>&1; then
    if UNIT_NAME="$(find_mihomo_service_unit)"; then
      systemctl daemon-reload || true
      systemctl restart "$UNIT_NAME"
      systemctl --no-pager --full status "$UNIT_NAME" || true
      echo "升级完成，已重启服务：${UNIT_NAME}"
    else
      echo "提示：未找到 systemd 服务 mihomo.service（仅完成二进制升级：/root/mihomo/mihomo）"
    fi
  else
    echo "提示：系统无 systemctl（仅完成二进制升级：/root/mihomo/mihomo）"
  fi
  exit 0
fi

echo "mihomo 未安装，开始全新安装..."

mkdir -p /root/mihomo
cd /root/mihomo

download_and_install_mihomo_binary "$DOWNLOAD_URL"
echo "${LATEST_VERSION}" > /root/mihomo/.mihomo_version

# 生成随机端口与随机密码
echo "在 52000-56000 范围内寻找未占用端口..."
PORT="$(find_available_port_52000_56000 || echo 0)"
if [ "$PORT" = "0" ]; then
  echo "错误：未能在 52000-56000 范围内找到可用端口"
  exit 1
fi
PASSWORD="$(random_password_15)"

echo "已选择 AnyTLS 端口：$PORT"
echo "已生成 AnyTLS 密码：$PASSWORD"

# vless + reality 参数
REALITY_PORT="$(find_available_port_52000_56000_excluding "$PORT" || echo 0)"
if [ "$REALITY_PORT" = "0" ]; then
  echo "错误：未能为 reality 找到可用端口（52000-56000）"
  exit 1
fi
VLESS_UUID="$(generate_uuid)"
SHORT_ID="$(generate_short_id_12)"
KEYPAIR="$(generate_reality_keypair)"
REALITY_PRIVATE_KEY="${KEYPAIR%%|*}"
REALITY_PUBLIC_KEY="${KEYPAIR#*|}"
REALITY_DEST="www.microsoft.com:443"
REALITY_SERVER_NAME="www.microsoft.com"

echo "已选择 Reality 端口：$REALITY_PORT"

# Shadowsocks 2022 参数（密码与 AnyTLS 同算法：random_password_15，openssl 随机 15 位可见字符）
SS_PORT="$(find_available_port_52000_56000_excluding_two "$PORT" "$REALITY_PORT" || echo 0)"
if [ "$SS_PORT" = "0" ]; then
  echo "错误：未能为 Shadowsocks 找到可用端口（52000-56000）"
  exit 1
fi
SS_PASSWORD="$(random_password_15)"
echo "已选择 Shadowsocks 端口：$SS_PORT"
echo "已生成 Shadowsocks 密码：$SS_PASSWORD"

cat > /root/mihomo/.pub << EOF
# VLESS + Reality 客户端参数（请妥善保存）
address: <your_server_ip_or_domain>
port: ${REALITY_PORT}
uuid: ${VLESS_UUID}
flow: xtls-rprx-vision
sni: ${REALITY_SERVER_NAME}
dest: ${REALITY_DEST}
public-key: ${REALITY_PUBLIC_KEY}
short-id: ${SHORT_ID}

# AnyTLS 客户端参数（请妥善保存）
anytls-address: <your_server_ip_or_domain>
anytls-port: ${PORT}
anytls-user: ${PASSWORD}

# Shadowsocks 2022 客户端参数（请妥善保存）
ss-address: <your_server_ip_or_domain>
ss-port: ${SS_PORT}
ss-password: ${SS_PASSWORD}
ss-cipher: 2022-blake3-aes-128-gcm
EOF
chmod 600 /root/mihomo/.pub || true

# anytls 需要证书/私钥：首次安装时自动生成一对自签证书（避免服务启动时报缺少字段）
CERT_FILE="/root/mihomo/server.cer"
KEY_FILE="/root/mihomo/server.key"
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  echo "正在生成自签证书用于 anytls（${CERT_FILE}, ${KEY_FILE}）..."
  # 避免交互输入
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -subj "/CN=anytls" >/dev/null 2>&1
  chmod 600 "$KEY_FILE" || true
fi

# 生成默认配置（仅在未安装时创建）
cat > /root/mihomo/config.yaml << EOF
rule-anchor:
  ip: &ip {type: http, interval: 86400, behavior: ipcidr, format: mrs}
  domain: &domain {type: http, interval: 86400, behavior: domain, format: mrs}

rule-providers:
  geoip-cn:
    <<: *ip
    url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs"


listeners:
- name: anytls-in
  type: anytls
  port: ${PORT}
  listen: 0.0.0.0
  users:
    user: ${PASSWORD}
  certificate: ${CERT_FILE}
  private-key: ${KEY_FILE}
  padding-scheme: |
    stop=10
    0=30-30
    1=100-400
    2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
    3=9-9,500-1000
    4=500-1000
    5=500-1000
    6=500-1000
    7=500-1000
- name: "入站-reality"
  type: vless
  listen: "0.0.0.0"
  port: "${REALITY_PORT}"
  proxy-protocol: true
  users:
    - name: "default"
      uuid: "${VLESS_UUID}"
      flow: xtls-rprx-vision
  reality-config:
    private-key: "${REALITY_PRIVATE_KEY}"
    short-id: ["${SHORT_ID}"]
    dest: "${REALITY_DEST}"
    server-names:
      - "${REALITY_SERVER_NAME}"
- name: "入站-shadowsocks"
  type: shadowsocks
  listen: "0.0.0.0"
  port: "${SS_PORT}"
  password: "${SS_PASSWORD}"
  cipher: 2022-blake3-aes-128-gcm

rules:
- SRC-GEOIP,geoip-cn,REJECT
- MATCH,DIRECT
EOF

echo "已创建默认配置：/root/mihomo/config.yaml"

# 创建 systemd 服务
cat > /etc/systemd/system/mihomo.service << EOF
[Unit]
Description=Hihomo
After=network.target
[Service]
Type=simple
ExecStart=/root/mihomo/mihomo -d /root/mihomo/
Restart=on-failure
User=root
WorkingDirectory=/root/mihomo
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

echo "已创建 systemd 服务：/etc/systemd/system/mihomo.service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable mihomo.service
  systemctl start mihomo.service
  if systemctl is-active --quiet mihomo.service; then
    systemctl --no-pager --full status mihomo.service || true
    echo "mihomo 安装完成并已启动服务。"
    echo "=== 入站信息（请保存）==="
    echo "AnyTLS 端口: ${PORT}"
    echo "AnyTLS 密码: ${PASSWORD}"
    echo "VLESS Reality 端口: ${REALITY_PORT}"
    echo "VLESS UUID: ${VLESS_UUID}"
    echo "Reality dest/SNI: ${REALITY_DEST}"
    echo "Reality public-key: ${REALITY_PUBLIC_KEY}"
    echo "Reality public-key 文件: /root/mihomo/.pub"
    echo "Reality short-id: ${SHORT_ID}"
    echo "Shadowsocks 端口: ${SS_PORT}"
    echo "Shadowsocks 密码: ${SS_PASSWORD}"
    echo "Shadowsocks 加密: 2022-blake3-aes-128-gcm"
  else
    echo "错误：mihomo 服务启动失败，请检查配置与日志："
    systemctl --no-pager --full status mihomo.service || true
    journalctl -u mihomo.service --no-pager -n 50 || true
    exit 1
  fi
else
  echo "提示：系统无 systemctl，请自行启动 /root/mihomo/mihomo -d /root/mihomo/"
fi


