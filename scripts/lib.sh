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
    : "${REALITY_SNI:?.env 缺少 REALITY_SNI}"
    : "${REALITY_CERT_DOMAIN:?.env 缺少 REALITY_CERT_DOMAIN}"
    NODE_NAME="${NODE_NAME:-edge-reality}"
    # 伪装站端口；兼容旧版 .env 里的 DECOY_UPSTREAM（3000 或 127.0.0.1:3000）
    DECOY_PORT="${DECOY_PORT:-${DECOY_UPSTREAM:-}}"
    DECOY_PORT="${DECOY_PORT##*:}"
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

# render <模板> <输出文件> <变量名...>：把模板里的 __变量名__ 替换为变量值
render() {
    local tpl="$1" out="$2" content v
    shift 2
    content="$(<"$tpl")"
    for v in "$@"; do
        content="${content//"__${v}__"/"${!v}"}"
    done
    if grep -qE '__[A-Z0-9_]+__' <<<"$content"; then
        die "渲染 $tpl 后仍有未替换的占位符：$(grep -oE '__[A-Z0-9_]+__' <<<"$content" | sort -u | tr '\n' ' ')"
    fi
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

decoy_up() { app_up decoy "$DECOY_PORT" "${1:-}"; }  # decoy_up [pull]

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
