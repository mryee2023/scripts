### mihomo 安装/升级/卸载脚本

安装

```

curl -fsSL https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/install_mihomo.sh | bash

```

卸载

```

curl -fsSL https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/install_mihomo.sh | bash -s uninstall

```


### nftables 指定端口屏蔽大陆 IP 安装脚本 


```

curl -sSL "https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/nft.sh" -o nft.sh && chmod +x nft.sh && sudo ./nft.sh

```

---

### nftables 端口转发管理脚本（交互式）

在 VPS 上管理 `/etc/nftables.conf` 中的端口转发：列出、添加、删除转发规则，以及语法检测后加载并重启 nftables。

**功能：**

1. **列出当前所有转发** — 表格显示：本地端口 | 目标IP:端口 | 注释  
2. **添加转发** — 输入本地端口、目标 IP:端口、注释；本地端口不可重复  
3. **删除转发** — 按本地端口删除，确认后从配置中移除规则及对应注释  
4. **加载配置并重启** — 先做配置文件语法检测，通过后加载并（如有）重启 nftables 服务  

**使用：**

```bash
# 下载并运行（需 root，因会写 /etc/nftables.conf）
curl -sSL "https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/nftables-forward-manager.sh" -o nftables-forward-manager.sh
chmod +x nftables-forward-manager.sh
sudo ./nftables-forward-manager.sh
```

指定配置文件（例如本地测试）：

```bash
# 使用当前目录的 nftables.conf 测试
NFTABLES_CONFIG=./nftables.conf ./nftables-forward-manager.sh
```

非交互执行（直接传子命令）：

```bash
./nftables-forward-manager.sh list    # 仅列出转发
./nftables-forward-manager.sh add     # 添加（仍从终端读入）
./nftables-forward-manager.sh delete  # 删除指定端口转发
./nftables-forward-manager.sh load     # 语法检测 + 加载 + 重启
```

默认配置文件路径：`/etc/nftables.conf`。修改配置需 root；测试时可设置 `NFTABLES_CONFIG` 指向本地文件。

