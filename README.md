### mihomo 安装/升级/卸载脚本

安装

```

curl -fsSL https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/install_mihomo.sh | bash

```

卸载

```

curl -fsSL https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/install_mihomo.sh | bash -s uninstall

```


nftables 指定端口屏蔽大陆 IP 安装脚本 


```

curl -sSL "https://raw.githubusercontent.com/mryee2023/scripts/refs/heads/main/nft.sh" -o nft.sh && chmod +x nft.sh && sudo ./nft.sh


```