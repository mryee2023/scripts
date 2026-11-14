#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then echo '请使用 sudo bash install-sub-proxy.sh 运行'; exit 1; fi
if [[ $(uname -m) != x86_64 ]]; then echo '仅支持 Linux AMD64 (x86_64)'; exit 1; fi
if ! command -v systemctl >/dev/null; then echo '需要 systemd'; exit 1; fi

read -rp '你的代理域名（例如 sub.example.com）: ' PROXY_DOMAIN
# 不再固定单一上游。调用方把目标写进路径：/https://目标域名/原路径
# 只转发允许列表中的域名；只填一个域名时，也按允许列表处理。
read -rp '允许转发的目标域名（逗号或空格分隔，例如 a.example.net,b.example.net）: ' ALLOW_RAW
read -rp '访问密钥（调用方需在请求头 X-Proxy-Key 中携带；留空则不校验，任何人都可通过本机访问上游）: ' PROXY_KEY

# 与 Caddy 路径正则一致：小写、至少一个点、标签不以连字符开头或结尾
valid_domain() {
  local d=$1
  [[ ${#d} -le 253 ]] || return 1
  [[ $d =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || return 1
  local IFS=.
  local -a labels=($d)
  local label
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
  done
}
# IP 字面量（含 127.1 这类缩写）和特殊用途后缀不能作为转发目标
is_disallowed_target() {
  local d=$1
  [[ $d =~ ^[0-9]+(\.[0-9]+)+$ ]] && return 0
  [[ $d =~ (^|\.)(localhost|local|internal|localdomain|lan|home|intranet|arpa|alt|svc)$ ]] && return 0
  return 1
}

PROXY_DOMAIN=${PROXY_DOMAIN,,}
if ! valid_domain "$PROXY_DOMAIN"; then echo "代理域名格式不正确：${PROXY_DOMAIN}"; exit 1; fi
if is_disallowed_target "$PROXY_DOMAIN"; then echo "代理域名不能是 IP 或内网/保留域名：${PROXY_DOMAIN}"; exit 1; fi

ALLOW_RAW=${ALLOW_RAW//，/,}
ALLOW_RAW=${ALLOW_RAW//,/ }
read -r -a ALLOW_PARTS <<< "${ALLOW_RAW}"
declare -a ALLOW_DOMAINS=()
declare -A ALLOW_SEEN=()
for raw in "${ALLOW_PARTS[@]+"${ALLOW_PARTS[@]}"}"; do
  [[ -z ${raw//[[:space:]]/} ]] && continue
  if [[ $raw == *"://"* || $raw == */* || $raw == *:* ]]; then
    echo "请只填写域名，不要带协议、端口或路径：${raw}"
    exit 1
  fi
  d=${raw,,}
  if ! valid_domain "$d"; then echo "域名格式不正确：${d}"; exit 1; fi
  if [[ $d == "$PROXY_DOMAIN" ]]; then echo "不能将代理域名加入目标列表（防止循环代理）：${d}"; exit 1; fi
  if is_disallowed_target "$d"; then echo "拒绝 IP 或内网/保留域名：${d}"; exit 1; fi
  if [[ -n ${ALLOW_SEEN[$d]+x} ]]; then continue; fi
  ALLOW_SEEN[$d]=1
  ALLOW_DOMAINS+=("$d")
done
if [[ ${#ALLOW_DOMAINS[@]} -eq 0 ]]; then echo '至少填写一个目标域名'; exit 1; fi
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
AUTH_ROUTE=''
if [[ -n "$PROXY_KEY" ]]; then
  AUTH_ROUTE=$(cat <<AUTH
		@denied {
			not header X-Proxy-Key "${PROXY_KEY}"
		}
		handle @denied {
			respond 403
		}
AUTH
)
fi

# 代理域名写入 map 正则时转义点，避免 example.com 匹配 exampleXcom
PROXY_DOMAIN_RE=${PROXY_DOMAIN//./\\.}

install -d -m 0755 /etc/caddy
if [[ -f /etc/caddy/Caddyfile ]]; then
  cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
fi
if [[ -f /etc/caddy/allowed-hosts.caddy ]]; then
  cp -a /etc/caddy/allowed-hosts.caddy "/etc/caddy/allowed-hosts.caddy.bak.$(date +%Y%m%d%H%M%S)"
fi

# 允许列表单独成文件，便于以后追加域名而无需改转发逻辑。
# 内网后缀、IP 形态和本机代理域名的拒绝规则写在主 Caddyfile 里，且排在本文件之前。
{
  cat << 'ALLOW'
# 允许转发的目标域名。每行一个：小写域名 + 空格 + yes
# 例：target.host.com yes
# 不要写 https://、端口、路径、IP、localhost，或本机代理域名。
# .local .internal .localhost .lan .home .arpa .svc 等即使写在这里也不会转发。
# 修改后执行：
#   caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
ALLOW
  for d in "${ALLOW_DOMAINS[@]}"; do
    printf '%s yes\n' "$d"
  done
} > /etc/caddy/allowed-hosts.caddy

cat > /etc/caddy/Caddyfile <<CADDY
${PROXY_DOMAIN} {
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
	# 调用方请求 /https://目标域名/原路径。Caddy 会先合并连续斜杠，匹配时看到的是 /https:/目标域名/原路径。
	# 拨号、Host 和 TLS SNI 只用正则捕获的域名，且必须命中允许列表；畸形目标直接 403，不会连接上游。
	route {
		@banned method CONNECT TRACE
		handle @banned {
			respond 403
		}
${AUTH_ROUTE}
		@embed path_regexp embed ^/https:/(?P<host>[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+)(?P<path>/[^{}\\\\]*)?\$
		handle @embed {
			route {
				map {re.embed.host} {host_allowed} {
					~^${PROXY_DOMAIN_RE}\$ no
					~^[0-9]+(\\.[0-9]+)+\$ no
					~(\\.|^)(localhost|local|internal|localdomain|lan|home|intranet|arpa|alt|svc)\$ no
					import /etc/caddy/allowed-hosts.caddy
					default no
				}
				map {re.embed.path} {upstream_path} {
					"" /
					default "{re.embed.path}"
				}
				@allow expression \`{host_allowed} == "yes"\`
				handle @allow {
					rewrite * {upstream_path}
					reverse_proxy {re.embed.host}:443 {
						header_up Host {re.embed.host}
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
							tls
							tls_server_name {re.embed.host}
						}
					}
				}
				handle {
					respond 403
				}
			}
		}
		handle {
			respond 403
		}
	}
}
CADDY

chown root:"${CADDY_GROUP}" /etc/caddy/Caddyfile /etc/caddy/allowed-hosts.caddy
chmod 0640 /etc/caddy/Caddyfile /etc/caddy/allowed-hosts.caddy

caddy fmt --overwrite /etc/caddy/Caddyfile
chown root:"${CADDY_GROUP}" /etc/caddy/Caddyfile /etc/caddy/allowed-hosts.caddy
chmod 0640 /etc/caddy/Caddyfile /etc/caddy/allowed-hosts.caddy
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

# IPv6 检测：本机有公网 IPv6 且某个允许的目标有 AAAA 记录时，可能经 IPv6 出网
IPV6_WARN=''
IPV6_HITS=()
if [[ -n "$(ip -6 addr show scope global 2>/dev/null)" ]]; then
  for d in "${ALLOW_DOMAINS[@]}"; do
    if getent ahostsv6 "$d" >/dev/null 2>&1; then
      IPV6_HITS+=("$d")
    fi
  done
fi
if [[ ${#IPV6_HITS[@]} -gt 0 ]]; then
  IPV6_LIST=$(IFS='、'; echo "${IPV6_HITS[*]}")
  IPV6_WARN=$(cat <<WARN

警告：本机有公网 IPv6，且这些目标域名存在 IPv6 地址：${IPV6_LIST}。
      转发可能经 IPv6 出网。请将本机 IPv6 出口地址一并加入上游白名单（curl -6 ifconfig.me 查看），
      或关闭本机 IPv6：sysctl -w net.ipv6.conf.all.disable_ipv6=1（并写入 /etc/sysctl.conf 持久化）。
WARN
)
fi

if [[ -n "$PROXY_KEY" ]]; then
  AUTH_TIP="调用方须在请求头中携带：X-Proxy-Key: ${PROXY_KEY}（缺失或错误返回 403）"
else
  AUTH_TIP='未设置访问密钥：任何知道代理域名的人都可经本机访问上游资源，请确认上游另有鉴权。'
fi

ALLOW_LIST_DISPLAY=$(IFS='、'; echo "${ALLOW_DOMAINS[*]}")
FIRST_TARGET=${ALLOW_DOMAINS[0]}

cat <<DONE

安装和配置已完成！
代理域名：https://${PROXY_DOMAIN}
允许转发的目标：${ALLOW_LIST_DISPLAY}
本机出口 IPv4（请将此 IP 加入各上游白名单）：${EGRESS_IPV4}
${AUTH_TIP}${IPV6_WARN}

请求格式：https://${PROXY_DOMAIN}/https://目标域名/原路径?原查询
例如：https://${PROXY_DOMAIN}/https://${FIRST_TARGET}/aaa/bbb?token=...
只有允许列表中的 https 目标会转发。IP、内网或保留域名、非 https、带端口、用户信息或其他未列出的域名一律返回 403，不会连接上游。
原路径和查询参数（包括 token）会转发给目标；访问日志里会去掉 token，并保留 User-Agent。
转发时已去除 X-Forwarded-For / X-Real-IP 等请求头，上游只能看到本机出口 IP。

允许列表：/etc/caddy/allowed-hosts.caddy
追加目标时新增一行「小写域名 yes」（不要写 https://、端口或路径），然后执行：
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy

查看状态：systemctl status caddy
查看日志：journalctl -u caddy -n 100 --no-pager
访问日志：/var/log/caddy/access.log（超过 10MiB 自动轮转，保留 5 个文件；已去掉 X-Proxy-Key 和 URI 中的 token，User-Agent 会保留）
查看时间、客户端 IP、User-Agent 与 URI：sudo jq -r '[.ts, .request.client_ip, (.request.headers["User-Agent"][0] // ""), .request.uri] | @tsv' /var/log/caddy/access.log
配置文件：/etc/caddy/Caddyfile

注意：首次 HTTPS 证书申请可能需要一点时间；确保 DNS 已解析到本机且 TCP 80/443 已放通。
DONE
