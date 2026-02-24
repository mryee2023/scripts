#!/usr/bin/env bash
# GFW 端口黑名单管理器 - nftables 版本
# 功能与 gfw.sh (iptables/ipset) 一致：按端口封锁中国 IP（TCP/UDP）
#
# 持久化：规则保存在 /etc/nftables/gfw.nft。开机自动加载可：
#   - 在 /etc/nftables.conf 中加入: include "/etc/nftables/gfw.nft"
#   - 或确保系统先加载 nftables 再执行: nft -f /etc/nftables/gfw.nft

set -e

# --- 核心配置 ---
CN_IP_URL="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
NFTABLES_DIR="${NFTABLES_DIR:-/etc/nftables}"
NFTABLES_GFW_FILE="${NFTABLES_GFW_FILE:-$NFTABLES_DIR/gfw.nft}"
TABLE_NAME="gfw"
SET_NAME="china_list"
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
    elif command -v yum &>/dev/null; then
      yum install -y nftables curl
    else
      echo "错误: 请先安装 nftables 和 curl。"
      exit 1
    fi
  fi

  # 若已有持久化配置则先加载，否则创建空表结构
  if [ -f "$NFTABLES_GFW_FILE" ]; then
    nft list table inet "$TABLE_NAME" &>/dev/null || nft -f "$NFTABLES_GFW_FILE"
  else
    ensure_table
  fi
}

# 确保 inet gfw 表、集合、链存在
ensure_table() {
  if ! nft list table inet "$TABLE_NAME" &>/dev/null; then
    nft add table inet "$TABLE_NAME"
    nft add set inet "$TABLE_NAME" "$SET_NAME" '{ type ipv4_addr; flags interval; }'
    nft add chain inet "$TABLE_NAME" "$CHAIN_NAME" '{ type filter hook input priority -100; policy accept; }'
  fi
}

update_ip_list() {
  echo "正在同步最新中国 IP 库 (gaoyifan/china-operator-ip)..."
  ensure_table

  TEMP_FILE=$(mktemp)
  if curl -sSfL -o "$TEMP_FILE" "$CN_IP_URL"; then
    sed 's/\r//g' "$TEMP_FILE" > "${TEMP_FILE}.tmp" && mv "${TEMP_FILE}.tmp" "$TEMP_FILE"
    ELEM_FILE=$(mktemp)
    nft flush set inet "$TABLE_NAME" "$SET_NAME" 2>/dev/null || true
    while IFS= read -r cidr; do
      [ -z "$cidr" ] && continue
      echo "add element inet $TABLE_NAME $SET_NAME { $cidr }" >> "$ELEM_FILE"
    done < "$TEMP_FILE"
    nft -f "$ELEM_FILE"
    rm -f "$TEMP_FILE" "$ELEM_FILE"
    echo "IP 库更新成功！时间: $(date)"
  else
    echo "错误: 下载 IP 库失败。"
    rm -f "$TEMP_FILE"
    return 1
  fi
}

save_rules() {
  ensure_table
  nft list table inet "$TABLE_NAME" > "$NFTABLES_GFW_FILE"
  echo "配置已持久化到 $NFTABLES_GFW_FILE"
}

add_port() {
  ensure_table
  local port="$1"
  if ! nft list chain inet "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null | grep -q "tcp dport $port "; then
    nft add rule inet "$TABLE_NAME" "$CHAIN_NAME" ip saddr @$SET_NAME tcp dport "$port" drop
    nft add rule inet "$TABLE_NAME" "$CHAIN_NAME" ip saddr @$SET_NAME udp dport "$port" drop
    save_rules
    echo "Done! 端口 $port 已封锁中国 IP。"
  else
    echo "跳过: 规则已存在。"
  fi
}

del_port() {
  local port="$1"
  nft delete rule inet "$TABLE_NAME" "$CHAIN_NAME" ip saddr @$SET_NAME tcp dport "$port" drop 2>/dev/null || true
  nft delete rule inet "$TABLE_NAME" "$CHAIN_NAME" ip saddr @$SET_NAME udp dport "$port" drop 2>/dev/null || true
  save_rules
  echo "Done! 端口 $port 封锁已解除。"
}

list_ports() {
  echo "当前被封锁的端口："
  nft list chain inet "$TABLE_NAME" "$CHAIN_NAME" 2>/dev/null | grep -E "dport [0-9]+.*drop" | sed -nE 's/.*dport ([0-9]+).*/端口: \1/p' | sort -u
}

usage() {
  echo "GFW 端口黑名单管理器 (nftables 版)"
  echo "用法: gfw-nft -a [端口]  <- 封锁"
  echo "      gfw-nft -d [端口]  <- 解封"
  echo "      gfw-nft -u         <- 手动更新 IP 库"
  echo "      gfw-nft -l         <- 查看列表"
  exit 1
}

prepare_env

if [ $# -eq 0 ]; then usage; fi

while getopts "a:d:lu" opt; do
  case "$opt" in
    a) add_port "$OPTARG" ;;
    d) del_port "$OPTARG" ;;
    u) update_ip_list && save_rules ;;
    l) list_ports ;;
    *) usage ;;
  esac
done
