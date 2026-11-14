#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then echo '请使用 sudo bash install-sub-proxy.sh 运行'; exit 1; fi
if [[ $(uname -m) != x86_64 ]]; then echo '仅支持 Linux AMD64 (x86_64)'; exit 1; fi
if ! command -v systemctl >/dev/null; then echo '需要 systemd'; exit 1; fi

read -rp '你的代理域名（例如 sub.example.com）: ' PROXY_DOMAIN
read -rp '原始订阅域名（例如 origin.example.net，不带 https:// 和路径）: ' UPSTREAM_DOMAIN
read -rp '访问密钥（调用方需在请求头 X-Proxy-Key 中携带；留空则不校验，任何人都可通过本机访问上游）: ' PROXY_KEY

valid_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ $1 == *.* ]] && [[ $1 != *..* ]]; }
if ! valid_domain "$PROXY_DOMAIN" || ! valid_domain "$UPSTREAM_DOMAIN"; then echo '域名格式不正确'; exit 1; fi
if [[ "$PROXY_DOMAIN" == "$UPSTREAM_DOMAIN" ]]; then echo '代理域名和上游域名不能相同（防止循环代理）'; exit 1; fi
# 密钥会写入 Caddyfile，限制字符集避免破坏配置语法
if [[ -n "$PROXY_KEY" && ! "$PROXY_KEY" =~ ^[A-Za-z0-9_-]{16,}$ ]]; then
  echo '访问密钥须为至少 16 位的字母、数字、下划线或短横线'; exit 1
fi

. /etc/os-release
case "${ID:-}" in
  ubuntu|debian)
    apt-get update
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg ca-certificates
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
    ;;
  centos|rhel|rocky|almalinux|fedora)
    if command -v dnf >/dev/null; then
      dnf install -y dnf-plugins-core
      dnf copr enable -y @caddy/caddy
      dnf install -y caddy
    else
      echo '该系统缺少 dnf，请先安装 Caddy 后重新执行'; exit 1
    fi
    ;;
  *) echo "暂不支持的系统：${ID:-unknown}"; exit 1 ;;
esac

# 访问日志目录必须事先存在，且 Caddy 服务用户可写。
# Debian/Ubuntu（apt）与 RHEL 系（dnf/COPR）官方包的服务用户均为 caddy，仍以 unit 中的 User/Group 为准。
CADDY_USER=$(systemctl show caddy -p User --value 2>/dev/null || true)
CADDY_GROUP=$(systemctl show caddy -p Group --value 2>/dev/null || true)
if [[ -z "$CADDY_USER" ]]; then
  CADDY_USER=caddy
fi
if [[ -z "$CADDY_GROUP" ]]; then
  CADDY_GROUP=$(id -gn "$CADDY_USER" 2>/dev/null || echo "$CADDY_USER")
fi
if ! id "$CADDY_USER" >/dev/null 2>&1; then
  echo "未找到 Caddy 服务用户 ${CADDY_USER}，无法创建访问日志目录"
  exit 1
fi
if ! getent group "$CADDY_GROUP" >/dev/null 2>&1; then
  CADDY_GROUP=$(id -gn "$CADDY_USER")
fi
if ! install -d -o "$CADDY_USER" -g "$CADDY_GROUP" -m 0750 /var/log/caddy; then
  echo '无法创建访问日志目录 /var/log/caddy（需服务用户可写）'
  exit 1
fi

# 访问密钥校验：未携带正确的 X-Proxy-Key 时直接返回 403，不转发到上游
AUTH_BLOCK=''
if [[ -n "$PROXY_KEY" ]]; then
  AUTH_BLOCK=$(cat <<AUTH
    @denied {
        not header X-Proxy-Key "${PROXY_KEY}"
    }
    respond @denied 403
AUTH
)
fi

if [[ -f /etc/caddy/Caddyfile ]]; then
  cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/caddy/Caddyfile <<CADDY
${PROXY_DOMAIN} {
${AUTH_BLOCK}
    # 访问日志保留 User-Agent；删除 X-Proxy-Key，并从 URI 中去掉 token 查询参数（仅影响日志，不改变转发）
    log {
        output file /var/log/caddy/access.log {
            roll_size 10MiB
            roll_keep 5
        }
        format filter {
            request>headers>X-Proxy-Key delete
            request>uri query {
                delete token
            }
            wrap json
        }
    }
    encode zstd gzip
    reverse_proxy https://${UPSTREAM_DOMAIN} {
        header_up Host ${UPSTREAM_DOMAIN}
        # 去掉所有可能暴露调用方 IP 的请求头，上游只能看到本机出口 IP（Caddy 默认会追加 X-Forwarded-*）
        header_up -X-Forwarded-For
        header_up -X-Forwarded-Proto
        header_up -X-Forwarded-Host
        header_up -X-Real-IP
        header_up -Forwarded
        header_up -True-Client-IP
        header_up -CF-Connecting-IP
        # 访问密钥只在本机校验，不转发给上游
        header_up -X-Proxy-Key
        transport http {
            tls_server_name ${UPSTREAM_DOMAIN}
        }
    }
}
CADDY

caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
# validate 以 root 执行，若因此创建了日志文件，所有权会是 root，服务用户随后无法写入
if [[ -e /var/log/caddy/access.log ]]; then
  chown "$CADDY_USER:$CADDY_GROUP" /var/log/caddy/access.log
fi
# RHEL 系若启用 SELinux，恢复默认标签，避免服务用户仍无法写入
if command -v restorecon >/dev/null 2>&1; then
  restorecon -R /var/log/caddy >/dev/null 2>&1 || true
fi
systemctl enable --now caddy
systemctl restart caddy

# 出口 IP：上游白名单应添加的地址（云主机经 NAT/EIP 出网时可能与网卡 IP 不同）
EGRESS_IPV4=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo '获取失败，请手动执行 curl -4 ifconfig.me')

# IPv6 检测：本机有公网 IPv6 且上游有 AAAA 记录时，可能经 IPv6 出网，导致上游看到的不是白名单中的 IPv4
IPV6_WARN=''
if [[ -n "$(ip -6 addr show scope global 2>/dev/null)" ]] && getent ahostsv6 "$UPSTREAM_DOMAIN" >/dev/null 2>&1; then
  IPV6_WARN=$(cat <<WARN

警告：本机有公网 IPv6，且上游域名存在 IPv6 地址，转发可能经 IPv6 出网。
      请将本机 IPv6 出口地址一并加入白名单（curl -6 ifconfig.me 查看），
      或关闭本机 IPv6：sysctl -w net.ipv6.conf.all.disable_ipv6=1（并写入 /etc/sysctl.conf 持久化）。
WARN
)
fi

if [[ -n "$PROXY_KEY" ]]; then
  AUTH_TIP="调用方须在请求头中携带：X-Proxy-Key: ${PROXY_KEY}（缺失或错误返回 403）"
else
  AUTH_TIP='未设置访问密钥：任何知道代理域名的人都可经本机访问上游资源，请确认上游另有鉴权。'
fi

cat <<DONE

安装和配置已完成！
代理域名：https://${PROXY_DOMAIN}
上游域名：https://${UPSTREAM_DOMAIN}
本机出口 IPv4（请将此 IP 加入上游白名单）：${EGRESS_IPV4}
${AUTH_TIP}${IPV6_WARN}

请将原订阅链接中的 https://${UPSTREAM_DOMAIN} 替换为 https://${PROXY_DOMAIN}
原有路径和 ?token=... 等查询参数保持不变。
转发时已去除 X-Forwarded-For / X-Real-IP 等请求头，上游只能看到本机出口 IP。

查看状态：systemctl status caddy
查看日志：journalctl -u caddy -n 100 --no-pager
访问日志：/var/log/caddy/access.log（超过 10MiB 自动轮转，保留 5 个文件；已去掉 X-Proxy-Key 和 URI 中的 token，User-Agent 会保留）
查看时间、客户端 IP、User-Agent 与 URI：sudo jq -r '[.ts, .request.client_ip, (.request.headers["User-Agent"][0] // ""), .request.uri] | @tsv' /var/log/caddy/access.log
配置文件：/etc/caddy/Caddyfile

注意：首次 HTTPS 证书申请可能需要一点时间；确保 DNS 已解析到本机且 TCP 80/443 已放通。
DONE
