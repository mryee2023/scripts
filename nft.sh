#!/bin/bash

IP_URL="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
TARGET_BLOCK_FILE="/etc/nftables.d/china_block.nft"
NFTABLES_CONF="/etc/nftables.conf"
TMP_IP_FILE="/tmp/china_ips.txt"

# 必须 root 运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行此脚本 (例如 sudo $0)"
    exit 1
fi

# 从 TARGET_BLOCK_FILE 解析已配置的端口列表（用于帮助菜单与主流程）
parse_existing_ports() {
    local arr=()
    [[ ! -f "$TARGET_BLOCK_FILE" ]] && echo "${arr[@]}" && return
    while read -r line; do
        if [[ "$line" =~ tcp\ dport\ \{\ ([^}]+)\ \} ]]; then
            for p in $(echo "${BASH_REMATCH[1]}" | tr ',' ' '); do
                p=$(echo "$p" | tr -d ' ')
                [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && arr+=("$p")
            done
            break
        fi
    done < "$TARGET_BLOCK_FILE"
    printf '%s\n' "${arr[@]}" | sort -nu
}

# ---------- 无参数或 -help 时默认显示帮助菜单（推荐：下载到本地后 chmod +x，再运行）----------
RUN_MAIN=""
if [[ $# -eq 0 || "$1" == "-help" || "$1" == "--help" || "$1" == "-h" ]]; then
    echo "=========================================="
    echo "  nft.sh 帮助菜单（中国 IP 端口 block）"
    echo "  推荐用法: 下载到本地 → chmod +x nft.sh → sudo ./nft.sh"
    echo "=========================================="
    echo "  1、查看已 block 的端口列表"
    echo "  2、删除指定端口"
    echo "  3、添加/更新 block 端口（执行主流程）"
    echo "  0、退出"
    echo "=========================================="
    read_help() {
        if [ -r /dev/tty ]; then
            read -r -p "请选择 [0-3]: " choice < /dev/tty
        else
            read -r -p "请选择 [0-3]: " choice
        fi
    }
    read_help
    case "$choice" in
        1)
            ports=($(parse_existing_ports))
            if [ ${#ports[@]} -eq 0 ]; then
                echo "当前没有已配置的 block 端口，或 $TARGET_BLOCK_FILE 不存在。"
            else
                echo "已 block 的端口列表: ${ports[*]}"
            fi
            ;;
        2)
            ports=($(parse_existing_ports))
            if [ ${#ports[@]} -eq 0 ]; then
                echo "当前没有已配置的 block 端口，无需删除。"
                exit 0
            fi
            echo "当前已 block 端口: ${ports[*]}"
            if [ -r /dev/tty ]; then
                read -r -p "请输入要删除的端口号: " del_port < /dev/tty
            else
                read -r -p "请输入要删除的端口号: " del_port
            fi
            [[ -z "$del_port" || ! "$del_port" =~ ^[0-9]+$ ]] && echo "无效端口，已取消。" && exit 1
            new_ports=()
            for p in "${ports[@]}"; do
                [[ "$p" != "$del_port" ]] && new_ports+=("$p")
            done
            if [ ${#new_ports[@]} -eq ${#ports[@]} ]; then
                echo "未找到端口 $del_port，未做修改。"
                exit 0
            fi
            if [ ${#new_ports[@]} -eq 0 ]; then
                echo "至少需保留一个 block 端口，已取消删除。"
                exit 1
            fi
            echo "删除后端口列表: ${new_ports[*]}"
            # 重新下载 IP 并生成配置
            if ! curl -sSL "$IP_URL" -o "$TMP_IP_FILE"; then
                echo "❌ 无法下载 IP 库，删除未生效。"
                exit 1
            fi
            [[ ! -s "$TMP_IP_FILE" ]] && echo "❌ 下载文件为空。" && rm -f "$TMP_IP_FILE" && exit 1
            PORTS_NFT="{ $(IFS=,; echo "${new_ports[*]}") }"
            IP_COUNT=$(wc -l < "$TMP_IP_FILE")
            cat <<EOFX > "$TARGET_BLOCK_FILE"
table inet china_block {
    set china_ips {
        type ipv4_addr
        flags interval
        elements = {
$(sed 's/$/,/g' "$TMP_IP_FILE" | sed 's/^/            /g')
            127.0.0.1/32
        }
    }

    chain input_block {
        type filter hook input priority -10; policy accept;

        tcp dport $PORTS_NFT ip saddr @china_ips counter drop
        udp dport $PORTS_NFT ip saddr @china_ips counter drop
    }
}
EOFX
            rm -f "$TMP_IP_FILE"
            echo "正在检测 nftables 配置语法..."
            if ! nft -c -f "$NFTABLES_CONF" 2>/dev/null; then
                echo "❌ 语法检测失败，删除未生效。"
                exit 1
            fi
            echo "✅ 语法检测通过。"
            echo "正在加载配置并重启 nftables..."
            if command -v systemctl &>/dev/null && systemctl is-active nftables &>/dev/null; then
                systemctl restart nftables
                echo "✅ nftables 已重启，配置已生效。"
            else
                nft -f "$NFTABLES_CONF"
                echo "✅ 已通过 nft -f 加载配置。"
            fi
            echo "✅ 已删除端口 $del_port，当前 block 端口: ${new_ports[*]}。"
            ;;
        3)
            RUN_MAIN=1
            ;;
        0|"")
            echo "已退出。"
            ;;
        *)
            echo "无效选择。"
            ;;
    esac
    if [[ "$RUN_MAIN" != "1" ]]; then
        exit 0
    fi
fi

# ---------- 1. 检测并安装 nftables ----------
install_nftables() {
    if command -v nft &>/dev/null; then
        echo "nftables 已安装: $(command -v nft)"
        return 0
    fi
    echo "未检测到 nftables，正在尝试安装..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y nftables
    elif command -v dnf &>/dev/null; then
        dnf install -y nftables
    elif command -v yum &>/dev/null; then
        yum install -y nftables
    elif command -v zypper &>/dev/null; then
        zypper install -y nftables
    elif command -v apk &>/dev/null; then
        apk add nftables
    else
        echo "❌ 无法识别包管理器，请手动安装 nftables 后重试。"
        exit 1
    fi
    if ! command -v nft &>/dev/null; then
        echo "❌ 安装 nftables 失败。"
        exit 1
    fi
    echo "✅ nftables 安装成功。"
}

install_nftables

# 启用并启动 nftables 服务（若存在 systemd）
if command -v systemctl &>/dev/null; then
    if systemctl is-enabled nftables &>/dev/null; then
        echo "nftables 服务已启用。"
    else
        systemctl enable nftables 2>/dev/null || true
    fi
    if ! systemctl is-active nftables &>/dev/null; then
        systemctl start nftables 2>/dev/null || true
    fi
fi

# ---------- 2. 将 TARGET_BLOCK_FILE 追加到 nftables.conf 末尾 ----------
mkdir -p "$(dirname "$TARGET_BLOCK_FILE")"

# 若主配置不存在则创建空文件，以便后续追加
[ -f "$NFTABLES_CONF" ] || touch "$NFTABLES_CONF"

INCLUDE_LINE="include \"$TARGET_BLOCK_FILE\""
if grep -qF "$INCLUDE_LINE" "$NFTABLES_CONF" 2>/dev/null; then
    echo "nftables.conf 中已包含该 include，跳过追加。"
else
    echo "$INCLUDE_LINE" >> "$NFTABLES_CONF"
    echo "已在 nftables.conf 末尾追加: $INCLUDE_LINE"
fi

# ---------- 3. 交互式询问需要 block 的端口 ----------
existing_ports=($(parse_existing_ports))
if [ ${#existing_ports[@]} -gt 0 ]; then
    echo "当前已配置的 block 端口: ${existing_ports[*]}"
fi

# 管道执行时 stdin 来自管道，从 /dev/tty 读取才能正常交互（如 curl ... | bash）
while true; do
    if [ -r /dev/tty ]; then
        read -r -p "请输入需要 block 的端口（多个端口用空格分隔，直接回车则仅使用已有端口）: " input_ports < /dev/tty
    else
        read -r -p "请输入需要 block 的端口（多个端口用空格分隔，直接回车则仅使用已有端口）: " input_ports
    fi
    # 规范化：逗号、空格均可，只保留数字
    new_ports=()
    for p in $input_ports; do
        p=$(echo "$p" | tr -d ',')
        [[ "$p" =~ ^[0-9]+$ ]] && new_ports+=("$p")
    done
    # 合并：已有 + 新输入，去重（已存在则忽略）
    all_ports=("${existing_ports[@]}")
    for p in "${new_ports[@]}"; do
        if [[ " ${existing_ports[*]} " != *" $p "* ]]; then
            all_ports+=("$p")
        fi
    done
    # 再次去重并排序
    all_ports=($(printf '%s\n' "${all_ports[@]}" | sort -nu))
    if [ ${#all_ports[@]} -eq 0 ]; then
        echo "至少需要指定一个端口，请重新输入。"
        continue
    fi
    echo "将应用以下 block 端口: ${all_ports[*]}"
    break
done

# 格式化为 nft 集合语法：{ 8388, 8443, 443 }
PORTS_NFT="{ $(IFS=,; echo "${all_ports[*]}") }"

# ---------- 下载 IP 并生成独立表 ----------
echo "正在获取最新的中国 IP 库..."

if ! curl -sSL "$IP_URL" -o "$TMP_IP_FILE"; then
    echo "❌ 无法下载 IP 库。"
    exit 1
fi

if [ ! -s "$TMP_IP_FILE" ]; then
    echo "错误: 下载文件为空。"
    rm -f "$TMP_IP_FILE"
    exit 1
fi

IP_COUNT=$(wc -l < "$TMP_IP_FILE")
echo "正在生成独立拦截表: $TARGET_BLOCK_FILE"

cat <<EOF > "$TARGET_BLOCK_FILE"
table inet china_block {
    set china_ips {
        type ipv4_addr
        flags interval
        elements = {
$(sed 's/$/,/g' "$TMP_IP_FILE" | sed 's/^/            /g')
            127.0.0.1/32
        }
    }

    chain input_block {
        type filter hook input priority -10; policy accept;

        tcp dport $PORTS_NFT ip saddr @china_ips counter drop
        udp dport $PORTS_NFT ip saddr @china_ips counter drop
    }
}
EOF

rm -f "$TMP_IP_FILE"

# ---------- 4. 对最终配置文件做语法检测 ----------
echo "正在检测 nftables 配置语法..."
if ! nft -c -f "$NFTABLES_CONF" 2>/dev/null; then
    echo "❌ 语法检测失败，请检查 $NFTABLES_CONF 及 $TARGET_BLOCK_FILE。"
    exit 1
fi
echo "✅ 语法检测通过。"

# ---------- 5. 加载最新配置并重启 nftables ----------
echo "正在加载配置并重启 nftables..."
if command -v systemctl &>/dev/null && systemctl is-active nftables &>/dev/null; then
    systemctl restart nftables
    echo "✅ nftables 已重启，配置已生效。"
else
    nft -f "$NFTABLES_CONF"
    echo "✅ 已通过 nft -f 加载配置。"
fi

echo "目前屏蔽了 ${IP_COUNT} 个 IP 段，block 端口: ${all_ports[*]}。"
