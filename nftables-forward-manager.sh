#!/usr/bin/env bash
# nftables 端口转发管理脚本（交互式）

set -e
CONFIG="${NFTABLES_CONFIG:-/etc/nftables.conf}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
title() { echo -e "\n${CYAN}=== $* ===${NC}\n"; }

# 检查权限和文件
if [[ $EUID -ne 0 ]]; then
   err "此脚本必须以 root 权限运行"
   exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
    err "未找到配置文件: $CONFIG"
    exit 1
fi

# 解析规则函数 (保持原样，逻辑正确)
parse_forward_rules() {
    local in_prerouting=0
    local last_comment=""
    while IFS= read -r line; do
        if [[ "$line" =~ chain[[:space:]]prerouting ]]; then
            in_prerouting=1
            last_comment=""
            continue
        fi
        if [[ $in_prerouting -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]] || [[ "$line" =~ chain[[:space:]] ]]; then
                in_prerouting=0
                continue
            fi
            # 修改点：解析注释时，去掉开头的 # 和前导/后缀空格
            if [[ "$line" =~ ^[[:space:]]*# ]]; then
                if [[ ! "$line" =~ (转发清单|通用 SNAT|📝|🛡) ]] && [[ ! "$line" =~ meta[[:space:]]l4proto.*dnat ]]; then
                    # 提取 # 之后的内容并去除空格
                    last_comment=$(echo "${line}" | sed 's/^[[:space:]]*#[[:space:]]*//;s/[[:space:]]*$//')
                fi
                continue
            fi
            if [[ "$line" =~ meta\ l4proto.*th\ dport[[:space:]]+([0-9]+).*dnat\ to[[:space:]]+([0-9.]+):([0-9]+) ]]; then
                printf "%s\t%s:%s\t%s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$last_comment"
                last_comment=""
            fi
        fi
    done < "$CONFIG"
}

list_forwards() {
    title "当前转发清单"
    # 调整了表头宽度以适应更长的注释
    printf "%-10s | %-25s | %s\n" "本地端口" "目标IP:端口" "注释"
    printf "%-10s-+-%-25s-+-%s\n" "----------" "-------------------------" "----------------"
    parse_forward_rules | while IFS=$'\t' read -r lport target comment; do
        # 如果注释为空，显示“-”
        local display_comment="${comment:-}"
        printf "%-10s | %-25s | %s\n" "$lport" "$target" "$display_comment"
    done
    echo
}

port_exists() {
    local port="$1"
    parse_forward_rules | awk -v p="$port" '$1==p {print 1; exit}' | grep -q 1 && echo 1 || echo 0
}

add_forward() {
    title "添加端口转发"
    read -rp "本地端口 (50000-60000): " lport
    lport=$(echo "$lport" | tr -d '[:space:]')
    [[ ! "$lport" =~ ^[0-9]+$ ]] && { err "端口必须是数字"; return 1; }
    [[ "$lport" -lt 50000 || "$lport" -gt 60000 ]] && { err "本地端口须在 50000-60000 范围内"; return 1; }
    [[ $(port_exists "$lport") -eq 1 ]] && { err "端口 $lport 已存在"; return 1; }

    read -rp "目标 IP:端口 (例 1.2.3.4:8080): " target
    target=$(echo "$target" | tr -d '[:space:]')
    # 校验格式：合法 IPv4（每段 0-255）+ 冒号 + 合法端口（1-65535）
    local tip tport
    tip="${target%%:*}"
    tport="${target##*:}"
    if [[ ! "$tip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
       [[ ! "$tport" =~ ^[0-9]+$ ]] || \
       [[ "$tport" -lt 1 || "$tport" -gt 65535 ]]; then
        err "目标格式错误，须为合法 IPv4:端口（如 1.2.3.4:8080）"
        return 1
    fi
    # 逐段验证 IP 每个字节 0-255
    local IFS='.' seg
    for seg in $tip; do
        [[ "$seg" -gt 255 ]] && { err "目标 IP 地址不合法"; return 1; }
    done
    local IFS=' '

    read -rp "注释: " comment

    local tmp
    tmp=$(mktemp)
    local bak="${CONFIG}.bak"
    cp "$CONFIG" "$bak"

    local in_prerouting=0
    local inserted=0
    while IFS= read -r line; do
        if [[ "$line" =~ chain[[:space:]]prerouting ]]; then in_prerouting=1; fi
        if [[ $in_prerouting -eq 1 ]] && [[ $inserted -eq 0 ]] && [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
            [[ -n "$comment" ]] && echo "        # $comment" >> "$tmp"
            echo "        meta l4proto { tcp, udp } th dport $lport counter dnat to $target" >> "$tmp"
            echo "" >> "$tmp"
            inserted=1
        fi
        [[ "$line" =~ chain[[:space:]]postrouting ]] && in_prerouting=0
        echo "$line" >> "$tmp"
    done < "$CONFIG"

    if [[ $inserted -eq 0 ]]; then
        rm -f "$tmp" "$bak"
        err "未找到 prerouting 链，规则未写入，请检查配置文件格式"
        return 1
    fi

    mv "$tmp" "$CONFIG"
    rm -f "$bak"
    info "已写入配置 (尚未生效，请执行选项 4 加载)"
}

delete_forward() {
    title "删除端口转发"
    list_forwards
    read -rp "输入要删除的本地端口: " lport
    lport=$(echo "$lport" | tr -d '[:space:]')
    [[ ! "$lport" =~ ^[0-9]+$ ]] && { err "端口必须是数字"; return 1; }
    [[ "$lport" -lt 50000 || "$lport" -gt 60000 ]] && { err "本地端口须在 50000-60000 范围内"; return 1; }

    if [[ $(port_exists "$lport") -eq 0 ]]; then
        err "未找到端口 $lport 的转发规则"
        return 1
    fi

    read -rp "确认删除端口 $lport 及其注释? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY](es)?$ ]] && { info "已取消删除"; return 0; }

    local tmp=$(mktemp)
    local in_prerouting=0
    local last_comment_line=""
    local found_and_deleted=0

    # 逐行读取并逻辑过滤
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 识别进入 prerouting 链
        if [[ "$line" =~ chain[[:space:]]prerouting ]]; then
            in_prerouting=1
        fi
        
        if [[ $in_prerouting -eq 1 ]]; then
            # 1. 记录可能的注释行（排除掉大标题和保留字）
            if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*[^[:space:]] ]]; then
                if [[ ! "$line" =~ (转发清单|通用 SNAT|📝|🛡) ]]; then
                    last_comment_line="$line"
                    continue
                fi
            fi

            # 2. 匹配规则行（与 parse_forward_rules 保持一致的模式）
            if [[ "$line" =~ meta[[:space:]]l4proto.*th[[:space:]]dport[[:space:]]+$lport[[:space:]].*dnat[[:space:]]to ]]; then
                # 匹配到了！丢弃之前记录的注释行，也不写入当前行
                last_comment_line=""
                found_and_deleted=1
                continue
            fi

            # 3. 如果到了链末尾，重置状态
            if [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
                in_prerouting=0
            fi
        fi

        # 如果有缓存的注释行，先输出它
        if [[ -n "$last_comment_line" ]]; then
            echo "$last_comment_line" >> "$tmp"
            last_comment_line=""
        fi
        # 输出当前行
        echo "$line" >> "$tmp"
    done < "$CONFIG"

    mv "$tmp" "$CONFIG"
    
    if [[ $found_and_deleted -eq 1 ]]; then
        info "已成功删除端口 $lport 的规则及其关联注释"
        warn "提示：别忘了执行选项 4 让修改生效"
    else
        err "执行删除时遇到异常，请检查配置文件格式"
    fi
}

load_and_restart() {
    title "加载配置并重启 nftables"
    
    if [[ ! -f "$CONFIG" ]]; then
        err "配置文件 $CONFIG 不存在！"
        return 1
    fi

    info "正在检测配置文件语法..."
    # 使用 if 包裹命令，即使失败也不会触发 set -e (如果没删的话)
    # 且直接输出错误信息到屏幕
    if ! nft -c -f "$CONFIG"; then
        echo "-------------------------------------------"
        err "语法检测失败！请检查上方报错信息修改配置文件。"
        echo "-------------------------------------------"
        return 1
    fi

    info "语法检测通过，正在加载配置..."
    # 优先通过 systemctl restart 加载（服务内部执行 nft -f，避免双重加载）
    # 仅在 systemctl 不可用时才直接调用 nft -f
    if command -v systemctl &>/dev/null && systemctl is-active --quiet nftables; then
        if ! systemctl restart nftables; then
            err "nftables 服务重启失败！"
            return 1
        fi
        info "nftables 服务已重启，配置生效。"
    else
        if ! nft -f "$CONFIG"; then
            err "加载配置到内核失败！"
            return 1
        fi
        info "配置已通过 nft -f 临时加载（nftables 服务未运行，重启后需手动重新加载）。"
    fi
}

main_menu() {
    echo -e "\n  nftables 端口转发管理 (配置文件: $CONFIG)"
    echo "  1) 列出当前所有转发"
    echo "  2) 添加转发"
    echo "  3) 删除转发"
    echo "  4) 加载配置并重启"
    echo "  0) 退出"
    read -rp "请选择 [0-4]: " choice
    case "$choice" in
        1) list_forwards ;;
        2) add_forward ;;
        3) delete_forward ;;
        4) load_and_restart ;;
        0) exit 0 ;;
        *) err "无效选项" ;;
    esac
}

case "${1:-}" in
    *) while true; do main_menu || true; read -rp "按回车继续..." _; done ;;
esac