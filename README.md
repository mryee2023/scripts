### mihomo 安装/升级/卸载脚本

安装

```

curl -fsSL https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/install_mihomo.sh | bash

```

卸载

```

curl -fsSL https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/install_mihomo.sh | bash -s uninstall

```

---

### nftables 端口转发管理脚本（交互式）

在 VPS 上管理 `/etc/nftables.conf` 中的端口转发：列出、添加、删除转发规则，以及语法检测后加载并重启 nftables。

**功能：**

1. **列出当前所有转发** — 表格显示：本地端口 | 目标IP:端口 | 注释
2. **添加转发** — 输入本地端口（限 50000–60000）、目标 IP:端口、注释；本地端口不可重复
3. **删除转发** — 按本地端口删除，确认后从配置中移除规则及对应注释
4. **加载配置并重启** — 先做配置文件语法检测，通过后加载并（如有）重启 nftables 服务

**使用：**

```bash
# 下载并运行（需 root，因会写 /etc/nftables.conf）
curl -sSL "https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/nftables-forward-manager.sh" -o nftmgr.sh
chmod +x nftmgr.sh
sudo ./nftmgr.sh
```

指定配置文件（例如本地测试）：

```bash
# 使用当前目录的 nftables.conf 测试
NFTABLES_CONFIG=./nftables.conf sudo ./nftmgr.sh
```

默认配置文件路径：`/etc/nftables.conf`。修改配置需 root；测试时可设置 `NFTABLES_CONFIG` 指向本地文件。

---



### gfw-nft.sh


通过 nftables 对指定端口封锁大陆 IP（TCP/UDP）。

**使用：**

```bash
# 下载并安装为系统命令
curl -sSL "https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/gfw-nft.sh" -o gfw-nft.sh
chmod +x gfw-nft.sh
```

```bash
sudo ./gfw-nft.sh -u              # 初始化/更新大陆 IP 库（首次必须执行）
sudo ./gfw-nft.sh -a 8388         # 封锁端口 8388
sudo ./gfw-nft.sh -d 8388         # 解封端口 8388
sudo ./gfw-nft.sh -l              # 查看当前封锁端口列表
```

**持久化：** 规则保存在 `/etc/nftables/gfw.nft`，需在 `/etc/nftables.conf` 末尾添加以下内容才能开机自动生效：

```
include "/etc/nftables/gfw.nft"
```

---

### gfw-nocn-nft.sh

与 `gfw-nft.sh` 互补：**只允许大陆 IP 访问，屏蔽所有海外 IP**（白名单模式）。同时放行回环、内网、已建立连接，支持端口豁免。

**使用：**

```bash
# 下载并安装
curl -sSL "https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/gfw-nocn-nft.sh" -o gfw-nocn-nft.sh
chmod +x gfw-nocn-nft.sh
```

```bash
sudo ./gfw-nocn-nft.sh -u              # 初始化/更新大陆 IP 库（首次必须执行）
sudo ./gfw-nocn-nft.sh -a 1.2.3.4      # 豁免 IP（允许绕过白名单）
sudo ./gfw-nocn-nft.sh -a 5.6.0.0/16   # 豁免 CIDR 段
sudo ./gfw-nocn-nft.sh -d 1.2.3.4      # 取消豁免 IP
sudo ./gfw-nocn-nft.sh -l              # 查看豁免 IP 列表
sudo ./gfw-nocn-nft.sh -s on|off       # 启用/禁用白名单
sudo ./gfw-nocn-nft.sh -i              # 查看当前状态
```

**持久化：** 规则保存在 `/etc/nftables/gfw-nocn.nft`，需在 `/etc/nftables.conf` 末尾添加：

```
include "/etc/nftables/gfw-nocn.nft"
```
