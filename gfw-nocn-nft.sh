#!/usr/bin/env bash
# GFW 白名单模式管理器 - nftables 版本
# 功能：只允许中国大陆 IP 访问，屏蔽所有非大陆 IP（与 gfw-nft.sh 互补）
#
# 持久化：规则保存在 /etc/nftables/gfw-nocn.nft。开机自动加载可：
#   - 在 /etc/nftables.conf 中加入: include "/etc/nftables/gfw-nocn.nft"
#   - 或确保系统先加载 nftables 再执行: nft -f /etc/nftables/gfw-nocn.nft

set -e

# --- 核心配置 ---
CN_IP_URL="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
NFTABLES_DIR="${NFTABLES_DIR:-/etc/nftables}"
NFTABLES_WL_FILE="${NFTABLES_WL_FILE:-$NFTABLES_DIR/gfw-nocn.nft}"
TABLE_NAME="gfw_whitelist"
SET_CN="china_list"
SET_EXEMPT="exempt_ips"
CHAIN_NAME="input"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "错误: 请以 root 权限运行此脚本。"
  exit 1
fi

prepare_env() {
  [ ! -d "$NFTABLES_DIR" ] && mkdir -p "$NFTABLES_DIR"

  if ! command -v nft &>/dev/null; then
    echo "正在安装必要组件 (nftables, curl)..."
    if command -v apt-get &>/dev/null; then
      apt-get update && apt-get install -y nftables curl
    elif command -v dnf &>/dev/null; then
      dnf install -y nftables curl
    elif command -v yum &>/dev/null; then
      yum install -y nftables curl
    elif command -v apk &>/dev/null; then
      apk add nftables curl
    elif command -v zypper &>/dev/null; then
      zypper install -y nftables curl
    else
      echo "错误: 无法识别包管理器，请手动安装 nftables 和 curl 后重试。"
      exit 1
    fi
  fi

  # 若已有持久化配置则先加载，否则创建空表结构
  if [ -f "$NFTABLES_WL_FILE" ]; then
    nft list table inet "$TABLE_NAME" &>/dev/null || nft -f "$NFTABLES_WL_FILE"
  else
    ensure_table
  fi
}

# 确保 inet gfw_whitelist 表、集合、链存在（完全幂等：逐级检查表→集合→链）
ensure_table() {
  # 1. 确保表和集合存在
  if ! nft list table inet "$TABLE_NAME" &>/dev/null; then
    nft add table inet "$TABLE_NAME"
    nft add set inet "$TABLE_NAME" "$SET_CN"     '{ type ipv4_addr; flags interval; }'
    nft add set inet "$TABLE_NAME" "$SET_EXEMPT" '{ type ipv4_addr; flags interval; }'
  fi

  # 2. 确保 input 链存在（过滤直连本机的流量）
  if ! nft list chain inet "$TABLE_NAME" "$CHAIN_NAME" &>/dev/null; then
    nft add chain inet "$TABLE_NAME" "$CHAIN_NAME" '{ type filter hook input priority -100; policy accept; }'
    nft add rule inet "$TABLE_NAME" "$CHAIN_NAME" ct state established,related accept
    nft add rule inet "$TABLE_NAME" "$CHAIN_NAME" iif lo accept
    nft add rule inet "$TABLE_NAME" "$CHAIN_NAME" ip saddr '{ 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16 }' accept
    nft add rule inet "$TABLE_NAME" "$CHAIN_NAME" ip saddr @$SET_EXEMPT accept
    nft add rule inet "$TABLE_NAME" "$CHAIN_NAME" ip saddr @$SET_CN accept
    nft add rule inet "$TABLE_NAME" "$CHAIN_NAME" drop
  fi

  # 3. 确保 forward 链存在（过滤 DNAT 转发流量，防止海外 IP 经由本机中转）
  #    forward 链与 input 链规则相同，但不需要放行 lo（转发包不走回环）
  if ! nft list chain inet "$TABLE_NAME" forward &>/dev/null; then
    nft add chain inet "$TABLE_NAME" forward '{ type filter hook forward priority -100; policy accept; }'
    nft add rule inet "$TABLE_NAME" forward ct state established,related accept
    nft add rule inet "$TABLE_NAME" forward ip saddr '{ 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16 }' accept
    nft add rule inet "$TABLE_NAME" forward ip saddr @$SET_EXEMPT accept
    nft add rule inet "$TABLE_NAME" forward ip saddr @$SET_CN accept
    nft add rule inet "$TABLE_NAME" forward drop
  fi
}

update_ip_list() {
  echo "正在同步最新中国 IP 库 (gaoyifan/china-operator-ip)..."
  ensure_table

  local TEMP_FILE ELEM_FILE
  TEMP_FILE=$(mktemp)
  ELEM_FILE=$(mktemp)
  trap 'rm -f "$TEMP_FILE" "$ELEM_FILE"' RETURN

  if ! curl -sSfL -o "$TEMP_FILE" "$CN_IP_URL"; then
    echo "错误: 下载 IP 库失败。"
    return 1
  fi

  if [ ! -s "$TEMP_FILE" ]; then
    echo "错误: 下载文件为空，已中止更新。"
    return 1
  fi

  sed 's/\r//g' "$TEMP_FILE" > "${TEMP_FILE}.tmp" && mv "${TEMP_FILE}.tmp" "$TEMP_FILE"

  while IFS= read -r cidr; do
    [ -z "$cidr" ] && continue
    echo "add element inet $TABLE_NAME $SET_CN { $cidr }" >> "$ELEM_FILE"
  done < "$TEMP_FILE"

  nft flush set inet "$TABLE_NAME" "$SET_CN" 2>/dev/null || true
  nft -f "$ELEM_FILE"
  echo "IP 库更新成功！时间: $(date)"
}

save_rules() {
  ensure_table
  nft list table inet "$TABLE_NAME" > "$NFTABLES_WL_FILE"
  echo "配置已持久化到 $NFTABLES_WL_FILE"
}

validate_ip() {
  local ip="$1"
  # 支持单 IP 或 CIDR 格式
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    echo "错误: 无效 IP '$ip'（支持 1.2.3.4 或 1.2.3.0/24 格式）。"
    exit 1
  fi
}

# 添加豁免 IP（允许该 IP 绕过白名单限制）
add_exempt() {
  validate_ip "$1"
  local ip="$1"
  ensure_table

  if nft list set inet "$TABLE_NAME" "$SET_EXEMPT" 2>/dev/null | grep -qF "$ip"; then
    echo "跳过: $ip 已在豁免列表中。"
    return 0
  fi

  nft add element inet "$TABLE_NAME" "$SET_EXEMPT" "{ $ip }"
  save_rules
  echo "Done! $ip 已豁免（允许访问所有端口）。"
}

# 删除豁免 IP
del_exempt() {
  validate_ip "$1"
  local ip="$1"

  if ! nft list set inet "$TABLE_NAME" "$SET_EXEMPT" 2>/dev/null | grep -qF "$ip"; then
    echo "跳过: $ip 不在豁免列表中。"
    return 0
  fi

  nft delete element inet "$TABLE_NAME" "$SET_EXEMPT" "{ $ip }"
  save_rules
  echo "Done! $ip 豁免已取消。"
}

list_exempt() {
  echo "当前豁免 IP（允许绕过白名单）："
  nft list set inet "$TABLE_NAME" "$SET_EXEMPT" 2>/dev/null | grep -oE 'elements = \{[^}]*\}' | sed 's/elements = {//;s/}//' | tr ',' '\n' | sed 's/^ */  /'
}

# 启用/禁用白名单
toggle() {
  case "$1" in
    on)
      if nft list table inet "$TABLE_NAME" &>/dev/null; then
        echo "白名单已经处于启用状态。"
      else
        if [ -f "$NFTABLES_WL_FILE" ]; then
          nft -f "$NFTABLES_WL_FILE"
          echo "白名单已启用。"
        else
          echo "错误: 未找到持久化文件，请先运行 -u 更新 IP 库。"
          return 1
        fi
      fi
      ;;
    off)
      if nft list table inet "$TABLE_NAME" &>/dev/null; then
        nft delete table inet "$TABLE_NAME"
        echo "白名单已禁用（表已从内核移除，持久化文件保留）。"
      else
        echo "白名单已经处于禁用状态。"
      fi
      ;;
    *)
      echo "错误: 参数须为 on 或 off。"
      return 1
      ;;
  esac
}

status() {
  if nft list table inet "$TABLE_NAME" &>/dev/null; then
    echo "白名单状态: 启用"
    local cn_count
    cn_count=$(nft list set inet "$TABLE_NAME" "$SET_CN" 2>/dev/null | grep -c "element" || echo "0")
    echo "大陆 IP 段数: 约 $cn_count 条"
    list_exempt
  else
    echo "白名单状态: 禁用"
  fi
}

usage() {
  echo "GFW 白名单管理器 (nftables 版)"
  echo "功能: 只允许大陆 IP 访问，屏蔽所有海外 IP"
  echo ""
  echo "用法: gfw-nocn-nft -u              <- 更新大陆 IP 库"
  echo "      gfw-nocn-nft -a [IP/CIDR]   <- 添加豁免 IP（允许绕过白名单）"
  echo "      gfw-nocn-nft -d [IP/CIDR]   <- 删除豁免 IP"
  echo "      gfw-nocn-nft -l              <- 查看豁免 IP 列表"
  echo "      gfw-nocn-nft -s on|off       <- 启用/禁用白名单"
  echo "      gfw-nocn-nft -i              <- 查看当前状态"
  exit 1
}

prepare_env

if [ $# -eq 0 ]; then usage; fi

while getopts "a:d:lus:i" opt; do
  case "$opt" in
    a) add_exempt "$OPTARG" ;;
    d) del_exempt "$OPTARG" ;;
    u) update_ip_list && save_rules ;;
    l) list_exempt ;;
    s) toggle "$OPTARG" ;;
    i) status ;;
    *) usage ;;
  esac
done
