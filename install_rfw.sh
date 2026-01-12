#!/bin/bash

# 1. 环境检查与 iptables 安装
if ! command -v iptables &> /dev/null; then
    echo "正在安装缺失的 iptables..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install iptables -y
    elif command -v yum &> /dev/null; then
        sudo yum install iptables iptables-services -y
    fi
fi

# 2. 获取并下载最新版本
LATEST_VERSION=$(curl -s https://api.github.com/repos/narwhal-cloud/rfw/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "$LATEST_VERSION" ] && { echo "版本获取失败"; exit 1; }

FILENAME="rfw-x86_64-unknown-linux-musl"
wget -q --show-progress "https://github.com/narwhal-cloud/rfw/releases/download/${LATEST_VERSION}/${FILENAME}" -O $FILENAME
chmod +x $FILENAME
sudo mv $FILENAME /usr/local/bin/rfw

# 3. 处理 Systemd 服务文件 (带冲突检查)
SERVICE_FILE="/etc/systemd/system/rfw.service"
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
[ -z "$IFACE" ] && IFACE="eth0"

if [ -f "$SERVICE_FILE" ]; then
    echo "检测到 $SERVICE_FILE 已存在，正在更新..."
    sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.bak"
fi

sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=Remote Firewall (rfw) Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rfw --iface $IFACE --countries CN --block-fet-strict --log-port-access
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF


# 检查并挂载 BPF 文件系统（rfw --log-port-access 必须）
if ! mountpoint -q /sys/fs/bpf; then
    echo "正在挂载 BPF 文件系统..."
    sudo mkdir -p /sys/fs/bpf
    sudo mount -t bpf bpf /sys/fs/bpf
    # 写入 fstab 确保重启不失效
    if ! grep -q "bpf" /etc/fstab; then
        echo 'bpffs /sys/fs/bpf bpf defaults 0 0' | sudo tee -a /etc/fstab
    fi
fi

# 4. 设置 Crontab (确保唯一性)
CRON_JOB="0 3 * * 1 /usr/bin/systemctl restart rfw"
# 只有在 crontab 里搜不到这行时才添加
(sudo crontab -l 2>/dev/null | grep -Fq "$CRON_JOB") || ( (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab - )

# 5. 重新加载并重启
echo "重新加载配置并重启服务..."
sudo systemctl daemon-reload
sudo systemctl enable rfw
sudo systemctl restart rfw

echo "处理完成！"