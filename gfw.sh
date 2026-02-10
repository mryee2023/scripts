sudo cat << 'EOF' > /usr/local/bin/gfw
#!/bin/bash

# --- 核心配置 ---
CN_IP_URL="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
IPSET_CONF="/etc/ipset.conf"
IPTABLES_DIR="/etc/iptables"
IPTABLES_RULES="$IPTABLES_DIR/rules.v4"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
  echo "错误: 请以 root 权限运行此脚本。"
  exit 1
fi

# 获取 ipset 的绝对路径，防止 command not found
get_ipset_path() {
    local p=$(which ipset)
    if [ -z "$p" ]; then
        echo "/sbin/ipset" # 默认兜底路径
    else
        echo "$p"
    fi
}
IPSET_BIN=$(get_ipset_path)

prepare_env() {
    # 确保目录存在
    [ ! -d "$IPTABLES_DIR" ] && mkdir -p "$IPTABLES_DIR"

    if ! command -v ipset &> /dev/null; then
        echo "正在安装必要组件 (ipset, curl, iptables-persistent)..."
        apt update && apt install -y ipset curl iptables-persistent
        IPSET_BIN=$(get_ipset_path)
    fi
}

update_ip_list() {
    echo "正在同步最新中国 IP 库 (gaoyifan/china-operator-ip)..."
    
    TEMP_FILE=$(mktemp)
    if curl -s -L -o "$TEMP_FILE" "$CN_IP_URL"; then
        sed -i 's/\r//g' "$TEMP_FILE"
        
        {
            echo "create china_list hash:net family inet hashsize 4096 maxelem 131072 -exist"
            echo "flush china_list"
            awk '{print "add china_list " $1}' "$TEMP_FILE"
        } | $IPSET_BIN restore

        rm "$TEMP_FILE"
        $IPSET_BIN save > "$IPSET_CONF"
        echo "IP 库更新成功！时间: $(date)"
    else
        echo "错误: 下载 IP 库失败。"
        [ -f "$TEMP_FILE" ] && rm "$TEMP_FILE"
        return 1
    fi
}

save_rules() {
    $IPSET_BIN save > "$IPSET_CONF"
    iptables-save > "$IPTABLES_RULES"
    echo "配置已持久化到 $IPTABLES_RULES"
}

add_port() {
    $IPSET_BIN create china_list hash:net family inet hashsize 4096 maxelem 131072 -exist 2>/dev/null
    local port=$1
    if ! iptables -C INPUT -p tcp --dport "$port" -m set --match-set china_list src -j DROP 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -m set --match-set china_list src -j DROP
        iptables -I INPUT -p udp --dport "$port" -m set --match-set china_list src -j DROP
        save_rules
        echo "Done! 端口 $port 已封锁中国 IP。"
    else
        echo "跳过: 规则已存在。"
    fi
}

del_port() {
    local port=$1
    iptables -D INPUT -p tcp --dport "$port" -m set --match-set china_list src -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -m set --match-set china_list src -j DROP 2>/dev/null
    save_rules
    echo "Done! 端口 $port 封锁已解除。"
}

usage() {
    echo "GFW 端口黑名单管理器"
    echo "用法: gfw -a [端口]  <- 封锁"
    echo "      gfw -d [端口]  <- 解封"
    echo "      gfw -u         <- 手动更新 IP 库"
    echo "      gfw -l         <- 查看列表"
    exit 1
}

prepare_env

if [ $# -eq 0 ]; then usage; fi

while getopts "a:d:lu" opt; do
    case "$opt" in
        a) add_port "$OPTARG" ;;
        d) del_port "$OPTARG" ;;
        u) update_ip_list && save_rules ;;
        l) 
            echo "当前被封锁的端口："
            iptables -L INPUT -vn --line-numbers | grep "DROP.*match-set china_list src" | sed -E 's/.*dpt:([0-9]+).*/端口: \1/' | sort -u
            ;;
        *) usage ;;
    esac
done
EOF

# 授权并执行初始化
sudo chmod +x /usr/local/bin/gfw
sudo gfw -u