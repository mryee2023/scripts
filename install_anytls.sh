#!/bin/bash
set -euo pipefail

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: please run as root (e.g. sudo bash $0)"
    exit 1
  fi
}

prompt_yes_no_default_yes() {
  # usage: prompt_yes_no_default_yes "Question?"
  # returns 0 for yes, 1 for no
  local prompt="$1"
  local ans=""

  if [ -t 0 ]; then
    read -r -p "${prompt} [Y/n]: " ans || true
  else
    # 非交互环境：默认 yes
    echo "${prompt} [Y/n]: (non-interactive, defaulting to Y)"
    ans=""
  fi

  case "${ans}" in
    ""|y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    *) return 0 ;; # 其他输入按默认 yes
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
    echo "Error: could not detect package manager. Please install required packages manually: $*"
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
    echo "Missing dependency: $cmd (installing package: $pkg)"
    install_packages "$pkg"
  fi
}

get_latest_anytls_version() {
  # returns version like "0.0.8" (without leading v)
  local api="https://api.github.com/repos/anytls/anytls-go/releases/latest"
  local tag
  tag="$(curl -fsSL "$api" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$tag" ]; then
    echo "Error: failed to fetch latest AnyTLS release tag from GitHub API."
    exit 1
  fi
  echo "${tag#v}"
}

get_installed_anytls_path() {
  if [ -x /root/anytls/anytls-server ]; then
    echo "/root/anytls/anytls-server"
    return 0
  fi
  if command -v anytls-server >/dev/null 2>&1; then
    command -v anytls-server
    return 0
  fi
  return 1
}

extract_semver() {
  # usage: extract_semver "some text" -> "0.0.8" or empty
  echo "$1" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | sed 's/^v//'
}

get_installed_anytls_version() {
  local p out v
  p="$(get_installed_anytls_path)" || return 1

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

  out="$("$p" version 2>/dev/null || true)"
  v="$(extract_semver "$out")"
  if [ -n "$v" ]; then
    echo "$v"
    return 0
  fi

  echo "unknown"
  return 0
}

detect_arch() {
  # returns: amd64 / arm64
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      echo "Error: unsupported architecture: $m"
      exit 1
      ;;
  esac
}

require_root
echo "Preparing AnyTLS..."

# 依赖检查：升级/安装都需要 curl/wget/unzip；安装需要 openssl/netstat
ensure_command curl curl
ensure_command wget wget
ensure_command unzip unzip

LATEST_VERSION="$(get_latest_anytls_version)"

if get_installed_anytls_path >/dev/null 2>&1; then
  INSTALLED_PATH="$(get_installed_anytls_path)"
  INSTALLED_VERSION="$(get_installed_anytls_version || echo "unknown")"
  echo "AnyTLS already installed."
  echo "Installed path   : ${INSTALLED_PATH}"
  echo "Installed version: v${INSTALLED_VERSION}"
  echo "Latest version   : v${LATEST_VERSION}"

  if ! prompt_yes_no_default_yes "Upgrade AnyTLS to latest?"; then
    echo "User chose not to upgrade. Exiting."
    exit 0
  fi

  echo "Upgrading AnyTLS (will NOT modify existing systemd config)..."
  mkdir -p /root/anytls

  ANYTLS_ARCH="$(detect_arch)"
  ANYTLS_ZIP="anytls_${LATEST_VERSION}_linux_${ANYTLS_ARCH}.zip"
  ANYTLS_URL="https://github.com/anytls/anytls-go/releases/download/v${LATEST_VERSION}/${ANYTLS_ZIP}"

  TMP_DIR="$(mktemp -d)"
  cleanup() { rm -rf "$TMP_DIR"; }
  trap cleanup EXIT

  echo "Downloading: ${ANYTLS_URL}"
  wget -O "${TMP_DIR}/${ANYTLS_ZIP}" "$ANYTLS_URL"
  unzip -o "${TMP_DIR}/${ANYTLS_ZIP}" -d "$TMP_DIR" >/dev/null

  if [ ! -f "${TMP_DIR}/anytls-server" ]; then
    echo "Error: anytls-server not found in the downloaded package."
    exit 1
  fi

  if [ -f /root/anytls/anytls-server ]; then
    cp -f /root/anytls/anytls-server "/root/anytls/anytls-server.bak.$(date +%Y%m%d%H%M%S)" || true
  fi

  mv -f "${TMP_DIR}/anytls-server" /root/anytls/anytls-server
  chmod +x /root/anytls/anytls-server

  echo "Upgrade completed. Restarting service..."
  if systemctl list-unit-files | grep -q '^anytls\.service'; then
    systemctl restart anytls.service
    systemctl --no-pager --full status anytls.service || true
    echo "AnyTLS upgraded and service restarted."
  else
    echo "Warning: anytls.service not found. Binary upgraded at /root/anytls/anytls-server."
  fi

  exit 0
fi

echo "AnyTLS not installed. Proceeding with fresh install..."

ensure_command openssl openssl

# netstat 来自 net-tools（Debian/Ubuntu/CentOS 系列通用）
if ! command -v netstat >/dev/null 2>&1; then
  echo "Missing dependency: netstat (installing package: net-tools)"
  install_packages net-tools
fi

mkdir -p /root/anytls
cd /root/anytls

ANYTLS_ARCH="$(detect_arch)"
ANYTLS_ZIP="anytls_${LATEST_VERSION}_linux_${ANYTLS_ARCH}.zip"
ANYTLS_URL="https://github.com/anytls/anytls-go/releases/download/v${LATEST_VERSION}/${ANYTLS_ZIP}"

echo "Downloading AnyTLS server..."
echo "Latest version: v${LATEST_VERSION} (${ANYTLS_ARCH})"
rm -f "$ANYTLS_ZIP"
wget -O "$ANYTLS_ZIP" "$ANYTLS_URL"
echo "Unzipping AnyTLS server..."
unzip -o "$ANYTLS_ZIP"
echo "Making AnyTLS server executable..."
chmod +x anytls-server
echo "Creating systemd service file..."

# 生成随机密码
RANDOM_PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-16)
echo "Generated random password: $RANDOM_PASSWORD"

# 生成随机端口并检查可用性
echo "Finding available port in range 50000-52000..."
RANDOM_PORT=0
for i in {1..100}; do
    PORT=$((50000 + RANDOM % 2001))
    if ! netstat -tuln | grep -q ":$PORT "; then
        RANDOM_PORT=$PORT
        break
    fi
done

if [ $RANDOM_PORT -eq 0 ]; then
    echo "Error: No available port found in range 50000-52000"
    exit 1
fi

echo "Selected available port: $RANDOM_PORT"

# 自动创建systemd服务文件
cat > /etc/systemd/system/anytls.service << EOF
[Unit]
Description=AnyTLS Server Service
After=network.target
[Service]
Type=simple
ExecStart=/root/anytls/anytls-server -l 0.0.0.0:$RANDOM_PORT -p $RANDOM_PASSWORD
Restart=on-failure
User=root
WorkingDirectory=/root/anytls
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd services..."
systemctl daemon-reload
echo "Enabling AnyTLS service..."
systemctl enable anytls.service
echo "Starting AnyTLS service..."
systemctl start anytls.service
echo "AnyTLS server installed and started"
