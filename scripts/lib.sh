#!/usr/bin/env bash
# 公共函数，由其他脚本 source，不单独执行
set -euo pipefail

EDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_FILE="$EDGE_DIR/xray/keys.env"
ACME="${ACME:-$HOME/.acme.sh/acme.sh}"
# Xray 官方镜像：:latest 只在正式版发布时更新（Pre-release 不会动它），即最新稳定版
# 与 docker-compose.yml、.env.example 里的默认值保持一致
XRAY_IMAGE_DEFAULT="ghcr.io/xtls/xray-core:latest"
# 官方镜像里 xray 进程的 UID/GID（distroless nonroot）
XRAY_UID=65532

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo -i 后再执行）"
}

# 读取 .env（顺手去掉 Windows 换行符，防止值里混进 \r）
load_env() {
    [ -f "$EDGE_DIR/.env" ] || die "找不到 $EDGE_DIR/.env，请先执行：cp .env.example .env 并修改"
    set -a
    # shellcheck disable=SC1090
    . <(sed 's/\r$//' "$EDGE_DIR/.env")
    set +a
    # 本机角色：edge = 完整节点（默认，旧版 .env 没有这一项）；exit = 只做内网出口
    EDGE_ROLE="${EDGE_ROLE:-edge}"
    case "$EDGE_ROLE" in
        edge|exit) ;;
        *) die ".env 里 EDGE_ROLE=$EDGE_ROLE 不对：填 edge（完整节点）或 exit（只做内网出口）" ;;
    esac
    if [ "$EDGE_ROLE" = edge ]; then
        : "${REALITY_SNI:?.env 缺少 REALITY_SNI}"
        : "${REALITY_CERT_DOMAIN:?.env 缺少 REALITY_CERT_DOMAIN}"
    fi
    REALITY_SNI="${REALITY_SNI:-}"
    REALITY_CERT_DOMAIN="${REALITY_CERT_DOMAIN:-}"
    EXIT_LISTEN="${EXIT_LISTEN:-}"
    NODE_NAME="${NODE_NAME:-edge-reality}"
    # 伪装站端口；兼容旧版 .env 里的 DECOY_UPSTREAM（3000 或 127.0.0.1:3000）
    DECOY_PORT="${DECOY_PORT:-${DECOY_UPSTREAM:-}}"
    DECOY_PORT="${DECOY_PORT##*:}"
    # 伪装站主题：apps/decoy/themes/ 下的目录名（旧版 .env 没有这一项，用 forma）
    DECOY_THEME="${DECOY_THEME:-forma}"
    ENABLE_IPV6="${ENABLE_IPV6:-auto}"
    NGINX_IMAGE="${NGINX_IMAGE:-nginx:stable-alpine}"
    XRAY_IMAGE="${XRAY_IMAGE:-$XRAY_IMAGE_DEFAULT}"
    CF_Token="${CF_Token:-}"
    ACME_EMAIL="${ACME_EMAIL:-}"
}

load_keys() {
    [ -f "$KEYS_FILE" ] || die "找不到 $KEYS_FILE，请先运行 scripts/02-init.sh"
    # shellcheck disable=SC1090
    . <(sed 's/\r$//' "$KEYS_FILE")
}

# render_text <模板> <变量名...>：把模板里的 __变量名__ 替换为变量值，输出结果
render_text() {
    local tpl="$1" content v
    shift
    # $(<文件) 读不到文件时只打印错误、不算失败，会悄悄渲染出空内容，所以先检查
    [ -f "$tpl" ] || die "找不到模板 $tpl（项目文件不完整？）"
    content="$(<"$tpl")"
    for v in "$@"; do
        content="${content//"__${v}__"/"${!v}"}"
    done
    if grep -qE '__[A-Z0-9_]+__' <<<"$content"; then
        die "渲染 $tpl 后仍有未替换的占位符：$(grep -oE '__[A-Z0-9_]+__' <<<"$content" | sort -u | tr '\n' ' ')"
    fi
    printf '%s\n' "$content"
}

# render <模板> <输出文件> <变量名...>：同上，写入文件
render() {
    local tpl="$1" out="$2" content
    shift 2
    content="$(render_text "$tpl" "$@")"
    # 用重定向覆盖写入（保持 inode 不变，对容器的单文件挂载友好）
    printf '%s\n' "$content" >"$out"
}

# domain 是否被 cert_domain 的证书（cert_domain + *.cert_domain）覆盖
cert_covers() {
    local domain="$1" cert="$2" rest
    [ "$domain" = "$cert" ] && return 0
    case "$domain" in
        *".$cert") rest="${domain%".$cert"}" ;;
        *) return 1 ;;
    esac
    # 泛域名证书只覆盖一级子域名
    [[ "$rest" != *.* ]]
}

# find_cert <域名>：从域名本身逐级向上，在 certs/ 下找一张能覆盖它的证书，打印证书根域名
find_cert() {
    local d="$1"
    while [[ "$d" == *.* ]]; do
        if [ -s "$EDGE_DIR/certs/$d/fullchain.pem" ] && cert_covers "$1" "$d"; then
            echo "$d"
            return 0
        fi
        d="${d#*.}"
    done
    return 1
}

# 单独运行脚本时提示下一步；由 edge.sh 一键执行时（EDGE_ONECLICK=1）不提示
next_step() {
    [ "${EDGE_ONECLICK:-0}" = 1 ] || log "下一步：$*"
}

# port_ok <端口>：端口是否可用（1-65535，且不是 edge 自己占用的端口）
port_ok() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] \
        && [ "$1" != 443 ] && [ "$1" != 8443 ] && [ "$1" != 10443 ]
}

# ---------------------------------------------------------------- Cloudflare DNS（只支持灰云 proxied=false）
# cf_zone_lookup <域名>：从域名本身逐级向上查 Cloudflare zone，打印 "<zone_id> <zone_name>"
# 返回 0 找到；1 Token 有效但看不到这个域名；2 网络或 jq 问题；3 Token 无效
cf_zone_lookup() {
    local d="$1" resp zid zname
    command -v jq >/dev/null || return 2
    while [[ "$d" == *.* ]]; do
        resp="$(curl -sS --max-time 15 -H "Authorization: Bearer $CF_Token" \
                "https://api.cloudflare.com/client/v4/zones?name=$d" 2>/dev/null)" || return 2
        jq -e '.success == true' >/dev/null 2>&1 <<<"$resp" || return 3
        zid="$(jq -r '.result[0].id // empty' <<<"$resp")"
        zname="$(jq -r '.result[0].name // empty' <<<"$resp")"
        if [ -n "$zid" ] && [ "$zname" = "$d" ]; then
            echo "$zid $zname"
            return 0
        fi
        d="${d#*.}"
    done
    return 1
}

# cf_zone_of <域名>：只打印 zone 名（供 edge.sh 选证书根域名、校验 Token）
cf_zone_of() {
    local out rc
    out="$(cf_zone_lookup "$1")" && rc=0 || rc=$?
    [ "$rc" -eq 0 ] && echo "${out#* }"
    return "$rc"
}

# public_ipv4 / public_ipv6：获取本机公网出口 IP（缓存到进程内变量，批量补齐时只查一次）
_PUB_IPV4_DONE=0 _PUB_IPV4=""
_PUB_IPV6_DONE=0 _PUB_IPV6=""
public_ipv4() {
    if [ "$_PUB_IPV4_DONE" -eq 0 ]; then
        _PUB_IPV4_DONE=1
        _PUB_IPV4="$(curl -4 -sS --max-time 8 "$TRACE_URL" 2>/dev/null | sed -n 's/^ip=//p')" || true
        [[ "$_PUB_IPV4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || _PUB_IPV4=""
    fi
    [ -n "$_PUB_IPV4" ] && echo "$_PUB_IPV4"
}

public_ipv6() {
    if [ "$_PUB_IPV6_DONE" -eq 0 ]; then
        _PUB_IPV6_DONE=1
        _PUB_IPV6="$(curl -6 -sS --max-time 8 "$TRACE_URL" 2>/dev/null | sed -n 's/^ip=//p')" || true
        [[ "$_PUB_IPV6" == *:* ]] || _PUB_IPV6=""
    fi
    [ -n "$_PUB_IPV6" ] && echo "$_PUB_IPV6"
}

# _cf_ensure_one <zone_id> <域名> <A|AAAA> <本机IP>：单条灰云记录幂等检查与创建
_cf_ensure_one() {
    local zid="$1" domain="$2" rtype="$3" ip="$4" resp count cur proxied payload msg
    resp="$(curl -sS --max-time 15 -H "Authorization: Bearer $CF_Token" \
            "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?name=$domain&type=$rtype" 2>/dev/null)" || {
        warn "查询 Cloudflare DNS（$domain $rtype）失败：网络超时"
        return 1
    }
    if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$resp"; then
        msg="$(jq -r '.errors[0].message // "未知错误"' 2>/dev/null <<<"$resp")"
        warn "查询 Cloudflare DNS（$domain $rtype）失败：$msg"
        return 1
    fi
    count="$(jq -r '.result | length' <<<"$resp")"
    if [ "$count" -gt 0 ]; then
        cur="$(jq -r '.result[0].content // empty' <<<"$resp")"
        proxied="$(jq -r '.result[0].proxied // false' <<<"$resp")"
        if [ "$proxied" = "true" ]; then
            warn "DNS $rtype 记录 $domain 已存在，但开了橙云（代理）！本方案只支持灰云（仅 DNS），请到 Cloudflare 关掉小云朵"
        elif [ "$cur" != "$ip" ]; then
            warn "DNS $rtype 记录 $domain 已存在（当前指向 $cur，本机公网 IP 为 $ip），未覆盖"
        else
            log "DNS $rtype 记录 $domain → $ip（灰云）已就绪"
        fi
        return 0
    fi

    # 不存在同名 CNAME 时才可直接建 A/AAAA；若已有 CNAME，Cloudflare 会返回明确报错，下面直接打印原因
    payload="$(jq -nc --arg t "$rtype" --arg n "$domain" --arg c "$ip" \
        '{type: $t, name: $n, content: $c, ttl: 1, proxied: false}')"
    resp="$(curl -sS --max-time 15 -X POST \
            -H "Authorization: Bearer $CF_Token" \
            -H "Content-Type: application/json" \
            --data "$payload" \
            "https://api.cloudflare.com/client/v4/zones/$zid/dns_records" 2>/dev/null)" || {
        warn "创建 Cloudflare DNS（$domain $rtype）失败：网络超时"
        return 1
    }
    if jq -e '.success == true' >/dev/null 2>&1 <<<"$resp"; then
        log "已在 Cloudflare 自动创建 DNS $rtype 记录：$domain → $ip（灰云）"
        return 0
    fi
    msg="$(jq -r '.errors[0].message // "未知错误"' 2>/dev/null <<<"$resp")"
    warn "创建 DNS $rtype 记录 $domain 失败：$msg（请检查 Token 是否有 Zone → DNS → Edit 权限，或手动添加灰云记录）"
    return 1
}

# ensure_dns_record <域名>：确保该域名在 Cloudflare 上有指向本机的灰云 A（及按 ENABLE_IPV6 决定的 AAAA）记录
# 失败只打印 warn 不退出，避免网络抖动或外部独立管理的域名卡死站点创建/重载
ensure_dns_record() {
    local domain="$1" out zid rc ip4="" ip6="" want_v6=0
    if [ -z "${CF_Token:-}" ]; then
        warn ".env 未填写 CF_Token，跳过自动创建 $domain 的 DNS 记录"
        return 1
    fi
    if ! command -v jq >/dev/null; then
        warn "未安装 jq（运行 edge install 会自动补装），跳过自动创建 $domain 的 DNS 记录"
        return 1
    fi
    out="$(cf_zone_lookup "$domain")" && rc=0 || rc=$?
    case "$rc" in
        0) zid="${out%% *}" ;;
        1) warn "Cloudflare Token 看不到 $domain 所在的根域名，跳过自动创建 DNS 记录（请手动添加灰云记录或检查 Zone Resources）"; return 1 ;;
        3) warn "Cloudflare Token 无效或缺少 Zone → Zone → Read 权限，跳过自动创建 $domain 的 DNS 记录"; return 1 ;;
        *) warn "连接 Cloudflare API 失败，跳过自动创建 $domain 的 DNS 记录"; return 1 ;;
    esac

    ip4="$(public_ipv4 || true)"
    case "${ENABLE_IPV6:-auto}" in
        true)  want_v6=1 ;;
        false) want_v6=0 ;;
        *)     [ -s /proc/net/if_inet6 ] && want_v6=1 ;;
    esac
    [ "$want_v6" -eq 1 ] && ip6="$(public_ipv6 || true)"

    if [ -z "$ip4" ] && [ -z "$ip6" ]; then
        warn "无法获取本机公网 IP，跳过自动创建 $domain 的 DNS 记录"
        return 1
    fi
    [ -n "$ip4" ] && _cf_ensure_one "$zid" "$domain" A "$ip4" || true
    [ -n "$ip6" ] && _cf_ensure_one "$zid" "$domain" AAAA "$ip6" || true
    return 0
}

# ensure_all_sites_dns：为伪装站 + 所有已发布业务站点补齐灰云 DNS 记录（edge install / edge apply 时自动调用）
ensure_all_sites_dns() {
    local f d
    [ -n "${REALITY_SNI:-}" ] && ensure_dns_record "$REALITY_SNI" || true
    for f in "$CONF_DIR"/*.conf; do
        [ -e "$f" ] || continue
        d="$(basename "$f" .conf)"
        [ "$d" = "00-decoy" ] && continue
        ensure_dns_record "$d" || true
    done
}

# ---------------------------------------------------------------- apps/ 下的应用
# 约定：每个应用一个目录 apps/<名字>/，里面有 compose.yaml，端口写成
#   "127.0.0.1:${APP_PORT}:容器端口"
# APP_PORT 由 edge 分配并传进去：伪装站 decoy 用 .env 的 DECOY_PORT，业务应用由 edge add 自动分配
# 应用和端口的对应关系记在站点配置 nginx/conf.d/<域名>.conf 第一行的 "# app=<名字>" 和 proxy_pass 里
APPS_DIR="$EDGE_DIR/apps"
CONF_DIR="$EDGE_DIR/nginx/conf.d"

app_exists() {  # app_exists <名字>：apps/<名字>/ 下有 compose 文件
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    local f
    for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        if [ -f "$APPS_DIR/$1/$f" ]; then return 0; fi
    done
    return 1
}

# app_up <名字> <端口> [pull]：构建并启动应用；带 pull 时先拉取最新的基础镜像
app_up() {
    local name="$1" port="$2"
    app_exists "$name" || { warn "apps/$name/ 下没有 compose.yaml"; return 1; }
    log "构建并启动 apps/$name（127.0.0.1:$port）"
    (
        cd "$APPS_DIR/$name"
        export APP_PORT="$port"
        if [ "${3:-}" = pull ]; then docker compose build --pull; fi
        docker compose up -d --build
    )
}

app_down() {  # app_down <名字>：停止并删除应用容器（目录和镜像保留）
    app_exists "$1" || return 0
    (cd "$APPS_DIR/$1" && APP_PORT=1 docker compose down)
}

# decoy_up [pull]：按 DECOY_PORT 和 DECOY_THEME 构建并启动伪装站（主题变了会自动重新构建）
decoy_up() {
    decoy_theme_ok "${DECOY_THEME:-}" \
        || { warn "伪装站主题 DECOY_THEME=${DECOY_THEME:-（空）} 不存在，可选：$(decoy_themes | tr '\n' ' ')"; return 1; }
    log "伪装站主题：$DECOY_THEME"
    DECOY_THEME="$DECOY_THEME" app_up decoy "$DECOY_PORT" "${1:-}"
}

# 伪装站主题：apps/decoy/themes/<名字>/ 是网站根目录（必须有 index.html）
# 同目录下的 .about 第一行是给菜单看的说明（构建时被 .dockerignore 排除，不会出现在网站里）
DECOY_THEMES_DIR="$APPS_DIR/decoy/themes"

decoy_themes() {  # 列出所有主题
    local d
    for d in "$DECOY_THEMES_DIR"/*/; do
        if [ -f "$d/index.html" ]; then basename "$d"; fi
    done
}

decoy_theme_ok() {  # decoy_theme_ok <名字>：主题存在
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [ -f "$DECOY_THEMES_DIR/$1/index.html" ]
}

decoy_theme_desc() {  # decoy_theme_desc <名字>：主题说明（没有就输出空）
    local f="$DECOY_THEMES_DIR/$1/.about"
    if [ -f "$f" ]; then sed -n '1{s/\r$//;p;}' "$f"; fi
}

site_app() {   # site_app <conf>：这个站点对应的应用名（没有就输出空）
    sed -n '1s/^# app=//p' "$1"
}

site_port() {  # site_port <conf>：proxy_pass 里的端口
    { grep -oE 'proxy_pass[[:space:]]+http://[^;]+' "$1" || true; } | head -n 1 | sed -E 's#.*:([0-9]+)/?$#\1#'
}

app_port() {   # app_port <名字>：应用已分配的端口；还没发布返回 1
    local f
    if [ "$1" = decoy ]; then
        if [ -n "${DECOY_PORT:-}" ]; then echo "$DECOY_PORT"; return 0; fi
        return 1
    fi
    for f in "$CONF_DIR"/*.conf; do
        [ -e "$f" ] || continue
        if [ "$(site_app "$f")" = "$1" ]; then site_port "$f"; return 0; fi
    done
    return 1
}

published_apps() {  # 已发布（有站点配置）的业务应用名，去重
    local f
    for f in "$CONF_DIR"/*.conf; do
        if [ -e "$f" ]; then site_app "$f"; fi
    done | sort -u
}

alloc_port() {  # 从 3001 开始找一个没被站点配置、伪装站、本机进程占用的端口
    local p=3001 used f
    used=" ${DECOY_PORT:-} "
    for f in "$CONF_DIR"/*.conf; do
        if [ -e "$f" ]; then used+="$(site_port "$f") "; fi
    done
    used+="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | tr '\n' ' ') "
    while [[ "$used" == *" $p "* ]] || ! port_ok "$p"; do p=$((p + 1)); done
    echo "$p"
}

nginx_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx
}

xray_exists() {  # xray 容器存在（不管是否在运行）
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx xray
}

# ================================================================ 账号 / 出口 / 内网入口
# 术语：
#   账号      一个独立凭据 = 一条链接。手机用、发给别的设备用、给入口机当上游用，都是账号
#             每个账号指定一个出口，各走各的，互不影响
#   出口      账号的流量从哪出去：direct = 本机直接出网；其他 = 一条链接（另一台机器、第三方代理）
#   内网入口  给同一内网里的入口机用的 Shadowsocks 2022 入口，只监听内网 IP
#
# 账号（xray/users.env）：每行 "名字 UUID SS密钥 创建日期 出口"
#   UUID 给公网入口（VLESS + REALITY）用，SS密钥 给内网入口（Shadowsocks 2022 多用户）用
#   完整节点自带账号 default（手机用的那条链接，edge client 显示的就是它），不能删除，也不进内网入口
# 出口（xray/exits.env）：每行 "名字 链接"，支持的链接见 upstream_parse
USERS_FILE="$EDGE_DIR/xray/users.env"
EXITS_FILE="$EDGE_DIR/xray/exits.env"
NAME_RE='^[A-Za-z0-9_-]{1,32}$'
SS_METHOD="2022-blake3-aes-128-gcm"
# 测出口 IP 用：Cloudflare 的 trace 页面，返回内容里有一行 ip=<访问者 IP>
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"

# urlencode <文本>：按 UTF-8 字节做百分号编码（中文、空格、emoji 都可以放进分享链接）
urlencode() {
    local b c out=""
    for b in $(printf '%s' "$1" | od -An -v -tx1); do
        case "$b" in
            3[0-9]|4[1-9a-f]|5[0-9a]|6[1-9a-f]|7[0-9a]|2d|2e|5f|7e)
                printf -v c "\\x$b"; out+="$c" ;;       # 字母、数字、- . _ ~ 原样保留
            *)  out+="%${b^^}" ;;
        esac
    done
    printf '%s' "$out"
}

urldecode() {  # urldecode <文本>：解开 %XX
    local s="${1//\\/\\\\}"
    printf '%b' "${s//%/\\x}"
}

b64dec() {  # b64dec <文本>：base64 / base64url 解码，自动补齐 =
    local s="${1//-/+}"
    s="${s//_//}"
    case $(( ${#s} % 4 )) in
        2) s+="==" ;;
        3) s+="=" ;;
    esac
    printf '%s' "$s" | base64 -d 2>/dev/null
}

json_str() {  # json_str <文本>：输出 JSON 字符串（带引号），去掉控制字符
    local s="${1//[[:cntrl:]]/}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# UUID v4：优先读内核，否则用 openssl 随机数拼出来
gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi
    local h
    h="$(openssl rand -hex 16)"
    printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" \
        $(( (0x${h:16:1} & 3) | 8 )) "${h:17:3}" "${h:20:12}"
}

gen_ss_key() { openssl rand -base64 16; }   # Shadowsocks 2022（aes-128-gcm）密钥：16 字节

# is_private_ipv4 <IP>：10.x / 172.16-31.x / 192.168.x / 100.64-127.x（CGNAT，Tailscale 用这段）
is_private_ipv4() {
    local a b c d
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]})) c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
    [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ] || return 1
    [ "$a" -eq 10 ] && return 0
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
    return 1
}

# local_private_ips：本机网卡上的内网 IPv4，每行 "IP 网卡名"
local_private_ips() {
    local ip dev
    command -v ip >/dev/null || return 0
    while read -r ip dev; do
        if is_private_ipv4 "$ip"; then echo "$ip $dev"; fi
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1], $2}')
}

# exit_listen_check <IP:端口>：内网入口地址能不能用；能用时设置 EXIT_IP / EXIT_PORT，不能用时打印原因、返回 1
exit_listen_check() {
    local v="$1"
    if ! [[ "$v" =~ ^([0-9.]+):([0-9]+)$ ]]; then
        warn "内网入口地址格式不对：${v:-（空）}（应为 内网IP:端口，例如 10.0.0.2:23456）"
        return 1
    fi
    EXIT_IP="${BASH_REMATCH[1]}" EXIT_PORT="${BASH_REMATCH[2]}"
    if ! is_private_ipv4 "$EXIT_IP"; then
        warn "$EXIT_IP 不是内网地址：内网入口只能监听 10.x / 172.16-31.x / 192.168.x / 100.64-127.x，防止代理端口暴露到公网"
        return 1
    fi
    if ! port_ok "$EXIT_PORT" || [ "$EXIT_PORT" = "${DECOY_PORT:-}" ]; then
        warn "端口 $EXIT_PORT 不能用：填 1-65535，不能用 443 / 8443 / 10443 和伪装站端口"
        return 1
    fi
    # 先存进变量再 grep：直接 ip | grep -q 时，grep 匹配到就退出，ip 再写管道会被 SIGPIPE 杀掉，
    # 在 pipefail 下整条管道算失败，导致明明有这个 IP 也报"没有"
    local addrs
    addrs="$(ip -4 -o addr show 2>/dev/null || true)"
    if command -v ip >/dev/null && ! grep -qF " inet $EXIT_IP/" <<<"$addrs"; then
        warn "本机网卡上没有 $EXIT_IP：确认这是本机的内网 IP（ip -4 addr 查看）"
        return 1
    fi
}

# ---------------------------------------------------------------- 账号（xray/users.env）
users_load() {  # 读到数组 USER_NAMES / USER_UUIDS / USER_SSKEYS / USER_DATES / USER_EXITS
    local n u k d e rest
    USER_NAMES=() USER_UUIDS=() USER_SSKEYS=() USER_DATES=() USER_EXITS=()
    [ -f "$USERS_FILE" ] || return 0
    while read -r n u k d e rest; do
        if [ -z "$n" ] || [[ "$n" == \#* ]]; then continue; fi
        [[ "$n" =~ $NAME_RE && "$u" =~ ^[0-9a-fA-F-]{36}$ && "$k" =~ ^[A-Za-z0-9+/=]{24}$ && "$e" =~ $NAME_RE ]] \
            || die "$USERS_FILE 里这一行格式不对：$n（应为：名字 UUID SS密钥 日期 出口）"
        if user_index "$n" >/dev/null; then die "$USERS_FILE 里有重名的账号：$n"; fi
        USER_NAMES+=("$n") USER_UUIDS+=("$u") USER_SSKEYS+=("$k") USER_DATES+=("$d") USER_EXITS+=("$e")
    done < <(sed 's/\r$//' "$USERS_FILE")
}

user_index() {  # user_index <名字>：输出它在数组里的下标；没有返回 1（先 users_load）
    local i
    for i in "${!USER_NAMES[@]}"; do
        if [ "${USER_NAMES[$i]}" = "$1" ]; then echo "$i"; return 0; fi
    done
    return 1
}

users_save() {  # 把数组写回 users.env（先写临时文件再改名，写到一半出错不会留下半个文件）
    local i tmp
    tmp="$(mktemp "$USERS_FILE.XXXXXX")"
    {
        echo "# 账号，由 edge user 维护，不要改格式"
        echo "# 名字 UUID SS密钥 创建日期 出口（direct = 本机直接出网，其他 = exits.env 里的出口名）"
        for i in "${!USER_NAMES[@]}"; do
            printf '%s %s %s %s %s\n' "${USER_NAMES[$i]}" "${USER_UUIDS[$i]}" "${USER_SSKEYS[$i]}" \
                "${USER_DATES[$i]}" "${USER_EXITS[$i]}"
        done
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$USERS_FILE"
}

user_email() { printf '%s@edge' "$1"; }   # Xray 里账号的标识：日志、路由规则都用它

users_of() {  # users_of <出口>：走这个出口的账号，输出 JSON 数组的内容 "a@edge", "b@edge"；没有输出空
    local i out=""
    for i in "${!USER_NAMES[@]}"; do
        if [ "${USER_EXITS[$i]}" = "$1" ]; then out+="${out:+, }\"$(user_email "${USER_NAMES[$i]}")\""; fi
    done
    printf '%s' "$out"
}

internal_users() {  # 能用内网入口的账号数（default 不进内网入口）
    local n i
    n=0
    for i in "${!USER_NAMES[@]}"; do
        if [ "${USER_NAMES[$i]}" != default ]; then n=$((n + 1)); fi
    done
    echo "$n"
}

# ---------------------------------------------------------------- 出口（xray/exits.env）
exits_load() {  # 读到数组 OUT_NAMES / OUT_LINKS
    local n l rest
    OUT_NAMES=() OUT_LINKS=()
    [ -f "$EXITS_FILE" ] || return 0
    while read -r n l rest; do
        if [ -z "$n" ] || [[ "$n" == \#* ]]; then continue; fi
        [[ "$n" =~ $NAME_RE ]] && [ -n "$l" ] && [ -z "$rest" ] \
            || die "$EXITS_FILE 里这一行格式不对：$n（应为：名字 链接）"
        case "$n" in direct|block) die "$EXITS_FILE 里的出口不能叫 $n（保留名字）" ;; esac
        if out_index "$n" >/dev/null; then die "$EXITS_FILE 里有重名的出口：$n"; fi
        OUT_NAMES+=("$n") OUT_LINKS+=("$l")
    done < <(sed 's/\r$//' "$EXITS_FILE")
}

out_index() {  # out_index <名字>：输出出口在数组里的下标；没有返回 1（先 exits_load）
    local i
    for i in "${!OUT_NAMES[@]}"; do
        if [ "${OUT_NAMES[$i]}" = "$1" ]; then echo "$i"; return 0; fi
    done
    return 1
}

exit_known() {  # exit_known <名字>：direct 或者 exits.env 里有这个出口
    [ "$1" = direct ] || out_index "$1" >/dev/null
}

exits_save() {
    local i tmp
    tmp="$(mktemp "$EXITS_FILE.XXXXXX")"
    {
        echo "# 出口，由 edge exit 维护，不要改格式"
        echo "# 名字 链接"
        for i in "${!OUT_NAMES[@]}"; do
            printf '%s %s\n' "${OUT_NAMES[$i]}" "${OUT_LINKS[$i]}"
        done
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$EXITS_FILE"
}

exit_desc() {  # exit_desc <出口>：给人看的简介（不含密码；先 exits_load）
    local i
    if [ "$1" = direct ]; then echo "本机直接出网"; return 0; fi
    if ! i="$(out_index "$1")"; then echo "（出口不存在）"; return 0; fi
    if upstream_parse "${OUT_LINKS[$i]}" 2>/dev/null; then echo "$UP_DESC"; else echo "（链接有问题）"; fi
}

# ---------------------------------------------------------------- 按账号生成出口和路由
# xray_egress：根据账号和出口生成 Xray 的 outbounds 和 routing（先 users_load、exits_load）
# 设置 EGRESS_OUTBOUNDS / EGRESS_RULES / EGRESS_DOMAIN_STRATEGY，填进 templates/xray/egress.json.tpl
#
# 严格按账号走，没有任何回落：
#   - 第一个出口是 block：没匹配到任何规则的连接（Xray 默认用第一个出口）一律丢弃，不会掉进 direct
#   - 至少有一个账号走 direct 时才生成 freedom；所有账号都走出口时，配置里根本没有直连这条路
#   - 账号指向的出口不存在、链接看不懂、指向本机 → 报错，不生成
#   - 不生成 balancer / observatory：出口连不上就是连不上，Xray 不会换别的出口
# 拦截规则：
#   - bittorrent：所有账号都拦（只看协议嗅探的结果，不查 DNS）
#   - geoip:private：只拦走 direct 的账号，防止经本机访问 127.0.0.1 上的服务、所在内网、云厂商元数据接口
#     走出口的账号不加 IP 规则：Xray 判断一条规则时 user 条件在 ip 条件之前，不满足就不再往下看；
#     IPOnDemand 只在真正判断 ip 条件时才查 DNS。所以走出口的账号不会在本机查 DNS，
#     内网地址交给真正出网的那一跳去拦
xray_egress() {
    local i users tag directs
    for i in "${!USER_NAMES[@]}"; do
        exit_known "${USER_EXITS[$i]}" \
            || die "账号 ${USER_NAMES[$i]} 的出口 ${USER_EXITS[$i]} 不存在（edge exit list 查看；edge user set-exit ${USER_NAMES[$i]} <出口> 修改）"
    done

    EGRESS_OUTBOUNDS="    { \"tag\": \"block\", \"protocol\": \"blackhole\" }"
    EGRESS_RULES="      { \"type\": \"field\", \"protocol\": [\"bittorrent\"], \"outboundTag\": \"block\" }"
    EGRESS_DOMAIN_STRATEGY=AsIs

    directs="$(users_of direct)"
    if [ -n "$directs" ]; then
        EGRESS_OUTBOUNDS+=$',\n'"    { \"tag\": \"direct\", \"protocol\": \"freedom\" }"
        EGRESS_RULES+=$',\n'"      { \"type\": \"field\", \"user\": [ $directs ], \"ip\": [\"geoip:private\"], \"outboundTag\": \"block\" }"
        EGRESS_RULES+=$',\n'"      { \"type\": \"field\", \"user\": [ $directs ], \"outboundTag\": \"direct\" }"
        EGRESS_DOMAIN_STRATEGY=IPOnDemand
    fi

    for i in "${!OUT_NAMES[@]}"; do
        users="$(users_of "${OUT_NAMES[$i]}")"
        [ -n "$users" ] || continue          # 没有账号用的出口不放进配置
        tag="exit-${OUT_NAMES[$i]}"
        upstream_parse "${OUT_LINKS[$i]}" "$tag" \
            || die "出口 ${OUT_NAMES[$i]} 的链接看不懂（原因见上）：edge exit update ${OUT_NAMES[$i]} '<链接>' 重新设置"
        if { [ -n "${REALITY_SNI:-}" ] && [ "$UP_HOST" = "$REALITY_SNI" ]; } \
           || { [ -n "${EXIT_IP:-}" ] && [ "$UP_HOST" = "$EXIT_IP" ]; }; then
            die "出口 ${OUT_NAMES[$i]} 指向的是本机（$UP_HOST）：出口必须是另一台机器"
        fi
        [ -z "$UP_WARN" ] || [ "${EDGE_EXIT_WARNED:-0}" = 1 ] || warn "出口 ${OUT_NAMES[$i]}：$UP_WARN"
        EGRESS_OUTBOUNDS+=$',\n'"$UP_OUTBOUND"
        EGRESS_RULES+=$',\n'"      { \"type\": \"field\", \"user\": [ $users ], \"outboundTag\": \"$tag\" }"
    done
}

# ---------------------------------------------------------------- 分享链接
link_name() {  # link_name <账号>：分享链接里显示的节点名（需要 load_env）
    if [ "$1" = default ]; then printf '%s' "$NODE_NAME"; else printf '%s-%s' "$NODE_NAME" "$1"; fi
}

# vless_link <UUID> <节点名>：本机公网入口（REALITY）的分享链接（需要 load_keys）
vless_link() {
    printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none&support-x25519mlkem768=1#%s' \
        "$1" "$REALITY_SNI" "$REALITY_SNI" "$XRAY_PUBLIC_KEY" "$XRAY_SHORT_ID" "$(urlencode "$2")"
}

# ss_link <SS用户密钥> <节点名>：本机内网入口的分享链接（需要 load_keys 和 exit_listen_check）
# Shadowsocks 2022 多用户：客户端密码是 "服务端密钥:用户密钥"；按 SIP022 用百分号编码的明文
ss_link() {
    printf 'ss://%s:%s@%s:%s#%s' "$SS_METHOD" "$(urlencode "$SS_SERVER_KEY:$1")" \
        "$EXIT_IP" "$EXIT_PORT" "$(urlencode "$2")"
}

# ---------------------------------------------------------------- 上游链接解析
_qp() {  # _qp <查询串> <参数名>：取查询参数（已解码），没有输出空
    local kv parts
    IFS='&' read -ra parts <<<"$1"
    for kv in "${parts[@]}"; do
        if [ "${kv%%=*}" = "$2" ]; then urldecode "${kv#*=}"; return 0; fi
    done
}

_hostport() {  # _hostport <host:port>：设置 UP_HOST / UP_PORT / UP_ADDR（IPv6 写成 [::1]:443）
    if [[ "$1" =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]{1,5})$ ]] || [[ "$1" =~ ^([A-Za-z0-9.-]+):([0-9]{1,5})$ ]]; then
        UP_HOST="${BASH_REMATCH[1]}" UP_PORT="$((10#${BASH_REMATCH[2]}))" UP_ADDR="$1"
        [ "$UP_PORT" -ge 1 ] && [ "$UP_PORT" -le 65535 ] && return 0
    fi
    warn "链接里的地址不对：${1:-（空）}（应为 主机:端口）"
    return 1
}

_userpass() {  # _userpass <userinfo>：设置 UP_USER / UP_PASS；支持 user:pass（百分号编码）和 base64(user:pass)
    local ui
    UP_USER="" UP_PASS=""
    [ -n "$1" ] || return 0
    ui="$(urldecode "$1")"
    [[ "$ui" == *:* ]] || ui="$(b64dec "$1")"
    [[ "$ui" == *:* ]] || { warn "链接里的用户名密码看不懂（应为 用户名:密码）"; return 1; }
    UP_USER="${ui%%:*}" UP_PASS="${ui#*:}"
}

_plain_warn() {  # 明文协议、上游又不在内网：提醒
    if ! is_private_ipv4 "$UP_HOST"; then
        UP_WARN="$1 不加密：本机到上游这一段，密码和访问的域名都是明文（网页内容大多是 HTTPS，仍然是加密的）"
    fi
}

_json_list() {  # _json_list <逗号分隔的值>：输出 JSON 数组的内容 "a", "b"
    local a out="" parts
    IFS=',' read -ra parts <<<"$1"
    for a in "${parts[@]}"; do out+="${out:+, }$(json_str "$a")"; done
    printf '%s' "$out"
}

# upstream_parse <链接> [tag]：解析出口（上游）链接。成功时设置：
#   UP_OUTBOUND  Xray 出口配置（JSON，tag 默认为 upstream）
#   UP_HOST / UP_PORT 上游地址；UP_DESC 简介（不含密码）；UP_WARN 需要提醒的事（可能为空）
# 支持：vless://（reality / tls / none；raw、ws、grpc、xhttp、httpupgrade）、ss://、socks5://、http://、https://
# 看不懂时打印原因、返回 1
upstream_parse() {
    local link="$1" tag="${2:-upstream}" scheme rest query userinfo hostport
    local id enc flow sec net sni fp pbk sid spx pqv alpn host path svc mode users stream tls trans ui method pw dec
    UP_OUTBOUND="" UP_HOST="" UP_PORT="" UP_DESC="" UP_WARN=""

    if [ -z "$link" ]; then warn "上游链接为空"; return 1; fi
    if [[ "$link" =~ [[:space:][:cntrl:]] || "$link" == *[\'\"\\\`]* ]]; then
        warn "上游链接里不能有空格、引号、反斜杠：确认复制完整，没有多余字符"
        return 1
    fi
    if [[ "$link" != *://* ]]; then warn "看不懂这个链接：应以 vless:// ss:// socks5:// http:// https:// 开头"; return 1; fi
    scheme="${link%%://*}"
    scheme="${scheme,,}"
    rest="${link#*://}"
    rest="${rest%%#*}"                       # 去掉 #节点名
    query=""
    if [[ "$rest" == *\?* ]]; then query="${rest#*\?}"; rest="${rest%%\?*}"; fi
    rest="${rest%/}"
    if [[ "$rest" == *@* ]]; then userinfo="${rest%@*}" hostport="${rest##*@}"; else userinfo="" hostport="$rest"; fi

    case "$scheme" in
    vless)
        _hostport "$hostport" || return 1
        id="$(urldecode "$userinfo")"
        [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { warn "vless 链接里的 UUID 不对：${id:-（空）}"; return 1; }
        enc="$(_qp "$query" encryption)"; enc="${enc:-none}"
        flow="$(_qp "$query" flow)"
        sec="$(_qp "$query" security)"; sec="${sec:-none}"
        net="$(_qp "$query" type)"; net="${net:-raw}"; [ "$net" != tcp ] || net=raw
        sni="$(_qp "$query" sni)"; fp="$(_qp "$query" fp)"
        host="$(_qp "$query" host)"; path="$(_qp "$query" path)"

        users="{ \"id\": $(json_str "$id"), \"encryption\": $(json_str "$enc")"
        [ -z "$flow" ] || users+=", \"flow\": $(json_str "$flow")"
        users+=" }"

        case "$sec" in
        reality)
            pbk="$(_qp "$query" pbk)"; sid="$(_qp "$query" sid)"; spx="$(_qp "$query" spx)"; pqv="$(_qp "$query" pqv)"
            [ -n "$pbk" ] || { warn "REALITY 链接缺少公钥（pbk）"; return 1; }
            [ -n "$sni" ] || { warn "REALITY 链接缺少 sni"; return 1; }
            tls="\"realitySettings\": { \"serverName\": $(json_str "$sni"), \"fingerprint\": $(json_str "${fp:-chrome}"), \"publicKey\": $(json_str "$pbk"), \"shortId\": $(json_str "$sid")"
            [ -z "$spx" ] || tls+=", \"spiderX\": $(json_str "$spx")"
            [ -z "$pqv" ] || tls+=", \"mldsa65Verify\": $(json_str "$pqv")"
            tls+=" }"
            ;;
        tls)
            alpn="$(_qp "$query" alpn)"
            tls="\"tlsSettings\": { \"serverName\": $(json_str "${sni:-${host:-$UP_HOST}}")"
            [ -z "$fp" ] || tls+=", \"fingerprint\": $(json_str "$fp")"
            [ -z "$alpn" ] || tls+=", \"alpn\": [ $(_json_list "$alpn") ]"
            tls+=" }"
            ;;
        none)
            tls=""
            if ! is_private_ipv4 "$UP_HOST"; then UP_WARN="这条 vless 链接没有加密（security=none）：本机到上游这一段是明文"; fi
            ;;
        *) warn "不支持的 security=$sec（支持 reality / tls / none）"; return 1 ;;
        esac

        case "$net" in
        raw)
            if [ "$(_qp "$query" headerType)" = http ]; then warn "不支持 tcp + http 伪装（headerType=http）"; return 1; fi
            trans="" ;;
        ws)          trans="\"wsSettings\": { \"path\": $(json_str "${path:-/}")${host:+, \"host\": $(json_str "$host")} }" ;;
        httpupgrade) trans="\"httpupgradeSettings\": { \"path\": $(json_str "${path:-/}")${host:+, \"host\": $(json_str "$host")} }" ;;
        grpc)
            svc="$(_qp "$query" serviceName)"; mode="$(_qp "$query" mode)"
            trans="\"grpcSettings\": { \"serviceName\": $(json_str "$svc")"
            [ "$mode" != multi ] || trans+=", \"multiMode\": true"
            trans+=" }" ;;
        xhttp)
            mode="$(_qp "$query" mode)"
            trans="\"xhttpSettings\": { \"path\": $(json_str "${path:-/}")${host:+, \"host\": $(json_str "$host")}${mode:+, \"mode\": $(json_str "$mode")} }" ;;
        *) warn "不支持的传输方式 type=$net（支持 tcp/raw、ws、grpc、xhttp、httpupgrade）"; return 1 ;;
        esac

        stream="\"network\": $(json_str "$net"), \"security\": $(json_str "$sec")"
        [ -z "$tls" ] || stream+=", $tls"
        [ -z "$trans" ] || stream+=", $trans"
        UP_OUTBOUND="    {
      \"tag\": $(json_str "$tag"),
      \"protocol\": \"vless\",
      \"settings\": {
        \"vnext\": [ { \"address\": $(json_str "$UP_HOST"), \"port\": $UP_PORT, \"users\": [ $users ] } ]
      },
      \"streamSettings\": { $stream }
    }"
        UP_DESC="vless + $sec（$net）→ $UP_ADDR"
        ;;

    ss)
        if [ -n "$(_qp "$query" plugin)" ]; then warn "不支持带插件（plugin）的 ss 链接"; return 1; fi
        if [ -z "$userinfo" ]; then                  # 老格式：ss://base64(method:password@host:port)
            dec="$(b64dec "$hostport")"
            [[ "$dec" == *@* ]] || { warn "ss 链接看不懂"; return 1; }
            ui="${dec%@*}" hostport="${dec##*@}"
        else
            ui="$(urldecode "$userinfo")"
            [[ "$ui" == *:* ]] || ui="$(b64dec "$userinfo")"   # SIP002：base64url(method:password)
        fi
        [[ "$ui" == *:* ]] || { warn "ss 链接里的加密方式和密码看不懂"; return 1; }
        method="${ui%%:*}" pw="${ui#*:}"
        _hostport "$hostport" || return 1
        case "$method" in
            2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|\
            aes-128-gcm|aes-256-gcm|chacha20-poly1305|chacha20-ietf-poly1305|xchacha20-poly1305|xchacha20-ietf-poly1305) ;;
            *) warn "不支持的 ss 加密方式：$method"; return 1 ;;
        esac
        [ -n "$pw" ] || { warn "ss 链接里没有密码"; return 1; }
        UP_OUTBOUND="    {
      \"tag\": $(json_str "$tag"),
      \"protocol\": \"shadowsocks\",
      \"settings\": {
        \"servers\": [ { \"address\": $(json_str "$UP_HOST"), \"port\": $UP_PORT, \"method\": $(json_str "$method"), \"password\": $(json_str "$pw") } ]
      }
    }"
        UP_DESC="shadowsocks（$method）→ $UP_ADDR"
        ;;

    socks|socks5|socks5h|http|https)
        _hostport "$hostport" || return 1
        _userpass "$userinfo" || return 1
        if [ -n "$UP_USER" ]; then
            users=", \"users\": [ { \"user\": $(json_str "$UP_USER"), \"pass\": $(json_str "$UP_PASS") } ]"
        else
            users=""
        fi
        case "$scheme" in
            socks*) method=socks; UP_DESC="socks5 → $UP_ADDR"; _plain_warn "socks5" ;;
            http)   method=http;  UP_DESC="http → $UP_ADDR";   _plain_warn "http 代理" ;;
            https)  method=http;  UP_DESC="https → $UP_ADDR" ;;
        esac
        [ -z "$UP_USER" ] || UP_DESC+="（有认证）"
        stream=""
        if [ "$scheme" = https ]; then
            sni="$(_qp "$query" sni)"
            stream=",
      \"streamSettings\": { \"security\": \"tls\", \"tlsSettings\": { \"serverName\": $(json_str "${sni:-$UP_HOST}") } }"
        fi
        UP_OUTBOUND="    {
      \"tag\": $(json_str "$tag"),
      \"protocol\": \"$method\",
      \"settings\": {
        \"servers\": [ { \"address\": $(json_str "$UP_HOST"), \"port\": $UP_PORT$users } ]
      }$stream
    }"
        ;;

    *)
        warn "不支持的链接类型 $scheme://（支持 vless ss socks5 http https）"
        return 1 ;;
    esac
}

# upstream_mask <链接>：给人看的链接，隐藏 UUID / 密码 / 公钥
upstream_mask() {
    local l="$1"
    if [[ "$l" == *@* ]]; then l="${l%%://*}://******@${l##*@}"; fi
    printf '%s' "$l" | sed -E 's/((pbk|sid|pqv)=)[^&#]*/\1******/g'
}

# upstream_probe <链接> [local]：临时起一个 Xray 容器，经这条链接访问外网，不影响正在运行的 xray
# 确认：能连上、能出网，并且出口 IP 符合预期：
#   默认   出口 IP 不是本机（测出口 / 上游：流量确实从另一台机器出去）
#   local  出口 IP 就是本机（测本机走 direct 的账号）
# 通过返回 0
upstream_probe() {
    local link="$1" expect="${2:-remote}" dir name port i direct4="" direct6="" via="" rc=0 logs=""
    upstream_parse "$link" || return 1

    # shellcheck disable=SC2016
    if timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$UP_HOST" "$UP_PORT" 2>/dev/null; then
        log "能连上 $UP_HOST:$UP_PORT"
    else
        warn "连不上 $UP_HOST:$UP_PORT：对方没启动、地址或端口写错，或者被对方的防火墙 / 安全组挡住了"
        return 1
    fi

    port=$(( 20000 + RANDOM % 20000 ))
    name="edge-uptest-$$"
    dir="$(mktemp -d)"
    printf '{\n  "log": { "loglevel": "warning" },\n  "inbounds": [ { "listen": "127.0.0.1", "port": %s, "protocol": "socks", "settings": { "udp": false } } ],\n  "outbounds": [\n%s\n  ]\n}\n' \
        "$port" "$UP_OUTBOUND" >"$dir/config.json"
    chown "0:$XRAY_UID" "$dir/config.json" 2>/dev/null || true
    chmod 640 "$dir/config.json"
    if ! docker run -d --rm --name "$name" --network host \
            -v "$dir/config.json:/etc/xray/config.json:ro" \
            "$XRAY_IMAGE" run -c /etc/xray/config.json >/dev/null 2>&1; then
        rm -rf "$dir"
        warn "测试用的 Xray 容器启动失败（docker run $XRAY_IMAGE）"
        return 1
    fi
    for i in $(seq 1 20); do
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qx "127.0.0.1:$port"; then break; fi
        sleep 0.25
    done

    direct4="$(curl -4 -s --max-time 8 "$TRACE_URL" 2>/dev/null | sed -n 's/^ip=//p')" || true
    direct6="$(curl -6 -s --max-time 8 "$TRACE_URL" 2>/dev/null | sed -n 's/^ip=//p')" || true
    via="$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$port" "$TRACE_URL" 2>/dev/null | sed -n 's/^ip=//p')" || true
    if [ -z "$via" ]; then logs="$(docker logs "$name" 2>&1 | tail -n 5)" || true; fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$dir"

    if [ -z "$via" ]; then
        warn "经 $UP_HOST:$UP_PORT 访问外网失败：链接里的密码 / UUID / 公钥不对，或者它后面的出口不通"
        if [ -n "$logs" ]; then printf '%s\n' "$logs" | sed 's/^/      xray: /' >&2; fi
        rc=1
    elif [ "$expect" = local ]; then
        if [ "$via" = "$direct4" ] || [ "$via" = "$direct6" ]; then
            log "出口 IP：$via，就是本机，符合预期（direct）"
        else
            warn "出口 IP（$via）不是本机（${direct4:-${direct6:-未知}}），和预期的 direct 不一致"
            rc=1
        fi
    elif [ "$via" = "$direct4" ] || [ "$via" = "$direct6" ]; then
        warn "出口 IP（$via）和本机一样：流量没有走到另一台机器"
        rc=1
    else
        log "出口 IP：$via（本机：${direct4:-${direct6:-未知}}），流量确实从另一台机器出去"
    fi
    return "$rc"
}
