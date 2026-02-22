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
# 从已有配置中解析出已存在的端口
existing_ports=()
if [ -f "$TARGET_BLOCK_FILE" ]; then
    while read -r line; do
        if [[ "$line" =~ tcp\ dport\ \{\ ([^}]+)\ \} ]]; then
            for p in $(echo "${BASH_REMATCH[1]}" | tr ',' ' '); do
                p=$(echo "$p" | tr -d ' ')
                [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && existing_ports+=("$p")
            done
            break
        fi
    done < "$TARGET_BLOCK_FILE"
fi

# 去重并排序
existing_ports=($(printf '%s\n' "${existing_ports[@]}" | sort -nu))
if [ ${#existing_ports[@]} -gt 0 ]; then
    echo "当前已配置的 block 端口: ${existing_ports[*]}"
fi

while true; do
    read -r -p "请输入需要 block 的端口（多个端口用空格分隔，直接回车则仅使用已有端口）: " input_ports
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
