sudo cat << 'EOF' > /usr/local/bin/pm
#!/bin/bash

# --- 核心配置 ---
CN_IP_URL="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
IPSET_CONF="/etc/ipset.conf"
IPTABLES_RULES="/etc/iptables/rules.v4"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
  echo "错误: 请以 root 权限运行此脚本。"
  exit 1
fi

prepare_env() {
    if ! command -v ipset &> /dev/null; then
        echo "正在安装必要组件..."
        apt update && apt install -y ipset curl iptables-persistent
    fi
    if ! ipset list china_list &> /dev/null; then
        update_ip_list
    fi
}

update_ip_list() {
    echo "正在同步最新中国 IP 库 (gaoyifan/china-operator-ip)..."
    TEMP_FILE=$(mktemp)
    if curl -s -o "$TEMP_FILE" "$CN_IP_URL"; then
        ipset create china_list hash:net -hashsize 4096 -maxelem 131072 2>/dev/null
        ipset flush china_list
        sed -e "s/^/add china_list /" "$TEMP_FILE" | ipset restore
        rm "$TEMP_FILE"
        ipset save > "$IPSET_CONF"
        echo "IP 库更新成功时间: $(date)"
    else
        echo "错误: 下载 IP 库失败。"
        [ -f "$TEMP_FILE" ] && rm "$TEMP_FILE"
        return 1
    fi
}

save_rules() {
    ipset save > "$IPSET_CONF"
    iptables-save > "$IPTABLES_RULES"
}

add_port() {
    local port=$1
    if ! iptables -C INPUT -p tcp --dport "$port" -m set --match-set china_list src -j DROP 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -m set --match-set china_list src -j DROP
        iptables -I INPUT -p udp --dport "$port" -m set --match-set china_list src -j DROP
        save_rules
        echo "Done! 端口 $port 已成功封锁中国 IP。"
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
    echo "端口管理器 (中国 IP 黑名单版)"
    echo "用法: pm -a [端口]  <- 封锁"
    echo "      pm -d [端口]  <- 解封"
    echo "      pm -u         <- 手动更新 IP 库"
    echo "      pm -l         <- 查看列表"
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
            iptables -L INPUT -vn --line-numbers | grep "DROP.*match-set china_list src" | awk '{print "端口:",$12}' | sort -u
            ;;
        *) usage ;;
    esac
done
EOF

# 1. 赋予执行权限
sudo chmod +x /usr/local/bin/pm

# 2. 写入 Crontab 定时任务 (每天凌晨 3:00)
# 先删除可能存在的重复任务，再添加新的
(crontab -l 2>/dev/null | grep -v "/usr/local/bin/pm -u"; echo "0 3 * * * /usr/local/bin/pm -u > /dev/null 2>&1") | crontab -

echo "------------------------------------------------"
echo "pm 工具安装成功！"
echo "1. 输入 'pm -a 端口' 即可封锁中国 IP。"
echo "2. 定时任务已添加：每天凌晨 3:00 自动同步最新 IP 库。"
echo "------------------------------------------------"
