#!/usr/bin/env bash
# nftables 端口转发管理脚本（交互式）
# 配置文件默认 /etc/nftables.conf
# 修改配置需 root；测试时可: NFTABLES_CONFIG=./nftables.conf ./nftables-forward-manager.sh

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

# 解析配置文件，输出：本地端口\t目标IP:端口\t注释
# 只解析 table ip nat -> chain prerouting 内的 dnat 规则
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
            if [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
                break
            fi
            if [[ "$line" =~ chain[[:space:]] ]]; then
                break
            fi
            if [[ "$line" =~ ^[[:space:]]*# ]]; then
                # 只保留“转发清单”后的注释，且不是大标题、也不是被注释掉的规则行
                if [[ "$line" =~ (转发清单|通用 SNAT|📝) ]] || [[ "$line" == *"🛡"* ]]; then
                    :
                elif [[ "$line" =~ meta[[:space:]]l4proto.*dnat ]]; then
                    :  # 被注释的规则行，不作为下一条的注释
                else
                    last_comment="${line#\#}"
                    last_comment="${last_comment#"${last_comment%%[![:space:]]*}"}"
                fi
                continue
            fi
            if [[ "$line" =~ meta\ l4proto.*th\ dport[[:space:]]+([0-9]+).*dnat\ to[[:space:]]+([0-9.]+):([0-9]+) ]]; then
                local lport="${BASH_REMATCH[1]}"
                local tip="${BASH_REMATCH[2]}"
                local tport="${BASH_REMATCH[3]}"
                printf "%s\t%s:%s\t%s\n" "$lport" "$tip" "$tport" "$last_comment"
                last_comment=""
            fi
        fi
    done < "$CONFIG"
}

# 1. 列出当前所有转发
list_forwards() {
    title "当前转发清单"
    if [[ ! -r "$CONFIG" ]]; then
        err "无法读取配置文件: $CONFIG"
        return 1
    fi
    printf "%-12s | %-24s | %s\n" "本地端口" "目标IP:端口" "注释"
    printf "%-12s-+-%-24s-+-%s\n" "------------" "------------------------" "----------------"
    parse_forward_rules | while IFS=$'\t' read -r lport target comment; do
        # 显示时去掉注释里的前导 # 和空格
        comment="${comment#\#}"; comment="${comment#"${comment%%[![:space:]]*}"}"
        printf "%-12s | %-24s | %s\n" "$lport" "$target" "$comment"
    done
    echo
}

# 检查本地端口是否已存在
port_exists() {
    local port="$1"
    local found=0
    while IFS=$'\t' read -r p _ _; do
        [[ "$p" == "$port" ]] && { found=1; break; }
    done < <(parse_forward_rules)
    echo "$found"
}

# 2. 添加转发
add_forward() {
    title "添加端口转发"
    read -rp "本地端口: " lport
    lport=$(echo "$lport" | tr -d '[:space:]')
    if [[ ! "$lport" =~ ^[0-9]+$ ]]; then
        err "本地端口必须是数字"
        return 1
    fi
    if [[ $(port_exists "$lport") -eq 1 ]]; then
        err "本地端口 $lport 已存在，请勿重复"
        return 1
    fi
    read -rp "目标 IP:端口 (例 198.176.54.165:37500): " target
    target=$(echo "$target" | tr -d '[:space:]')
    if [[ ! "$target" =~ ^[0-9.]+:[0-9]+$ ]]; then
        err "目标格式应为 IP:端口"
        return 1
    fi
    read -rp "注释 (可留空): " comment
    comment=$(echo "$comment" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # 在 prerouting 链的最后一个规则后、闭合 } 前插入
    local tmp
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN
    local in_prerouting=0
    local inserted=0
    while IFS= read -r line; do
        if [[ "$line" =~ chain[[:space:]]prerouting ]]; then
            in_prerouting=1
        fi
        if [[ $in_prerouting -eq 1 ]] && [[ $inserted -eq 0 ]]; then
            if [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
                [[ -n "$comment" ]] && echo "        # $comment" >> "$tmp"
                echo "        meta l4proto { tcp, udp } th dport $lport counter dnat to $target" >> "$tmp"
                echo "" >> "$tmp"
                inserted=1
            fi
        fi
        if [[ "$line" =~ chain[[:space:]]postrouting ]]; then
            in_prerouting=0
        fi
        echo "$line" >> "$tmp"
    done < "$CONFIG"

    if [[ $inserted -eq 0 ]]; then
        err "未找到插入位置，请检查 $CONFIG 结构"
        return 1
    fi
    cp "$tmp" "$CONFIG"
    info "已添加: 本地 $lport -> $target (注释: ${comment:-无})"
}

# 3. 删除指定本地端口转发
delete_forward() {
    title "删除端口转发"
    list_forwards
    read -rp "要删除的本地端口: " lport
    lport=$(echo "$lport" | tr -d '[:space:]')
    if [[ ! "$lport" =~ ^[0-9]+$ ]]; then
        err "请输入数字端口"
        return 1
    fi
    if [[ $(port_exists "$lport") -eq 0 ]]; then
        err "本地端口 $lport 不存在"
        return 1
    fi
    read -rp "确认删除端口 $lport 的转发? [y/N]: " confirm
    case "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" in
        y|yes) ;;
        *) info "已取消"; return 0 ;;
    esac

    local tmp
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN
    local in_prerouting=0
    local skip_next_comment=0
    local prev_was_comment=0
    local prev_line=""
    while IFS= read -r line; do
        if [[ "$line" =~ chain[[:space:]]prerouting ]]; then
            in_prerouting=1
            echo "$line" >> "$tmp"
            prev_was_comment=0
            continue
        fi
        if [[ $in_prerouting -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*# ]]; then
                if [[ "$line" =~ 转发清单|通用\ SNAT|🛡|📝 ]]; then
                    echo "$line" >> "$tmp"
                else
                    prev_line="$line"
                    prev_was_comment=1
                fi
                continue
            fi
            if [[ "$line" =~ meta\ l4proto.*th\ dport[[:space:]]+${lport}[^0-9].*dnat\ to ]]; then
                # 当前行是要删除的规则：不输出上一行的注释（若存在）和当前行
                prev_was_comment=0
                prev_line=""
                continue
            fi
            if [[ $prev_was_comment -eq 1 && -n "$prev_line" ]]; then
                echo "$prev_line" >> "$tmp"
                prev_line=""
                prev_was_comment=0
            fi
        fi
        if [[ "$line" =~ chain[[:space:]] ]]; then
            in_prerouting=0
        fi
        echo "$line" >> "$tmp"
        prev_was_comment=0
    done < "$CONFIG"
    if [[ -n "$prev_line" ]]; then
        echo "$prev_line" >> "$tmp"
    fi
    cp "$tmp" "$CONFIG"
    info "已删除本地端口 $lport 的转发"
}

# 4. 语法检测、加载并重启
load_and_restart() {
    title "加载配置并重启 nftables"
    if [[ ! -r "$CONFIG" ]]; then
        err "无法读取: $CONFIG"
        return 1
    fi
    if ! command -v nft &>/dev/null; then
        err "未找到 nft 命令，请在有 nftables 的环境（如 VPS）中执行加载"
        return 1
    fi
    info "正在检测配置文件语法..."
    if ! nft -c -f "$CONFIG" 2>&1; then
        err "语法检测失败，未加载配置"
        return 1
    fi
    info "语法检测通过，正在加载新配置..."
    if ! nft -f "$CONFIG" 2>&1; then
        err "加载配置失败"
        return 1
    fi
    if command -v systemctl &>/dev/null && systemctl is-active --quiet nftables 2>/dev/null; then
        info "正在重启 nftables 服务..."
        systemctl restart nftables 2>/dev/null || true
    fi
    info "配置已加载并生效"
}

main_menu() {
    echo
    echo "  nftables 端口转发管理 (配置文件: $CONFIG)"
    echo "  1) 列出当前所有转发"
    echo "  2) 添加转发 (本地端口 / 目标IP:端口 / 注释)"
    echo "  3) 删除指定本地端口转发"
    echo "  4) 加载配置并重启 (语法检测后加载)"
    echo "  0) 退出"
    echo
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

# 直接传参时可非交互执行
case "${1:-}" in
    list)   list_forwards ;;
    add)    add_forward ;;
    delete) delete_forward ;;
    load)   load_and_restart ;;
    *)
        while true; do
            main_menu
            read -rp "按回车继续..."
        done
        ;;
esac
