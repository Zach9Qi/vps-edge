#!/usr/bin/env bash
# 生成 Xray 密钥（只在第一次生成，之后复用）并渲染 nginx / xray 配置
# 用法：
#   bash scripts/02-init.sh                 # 首次初始化，或修改 .env / 模板 / 通行证后重新渲染
#   bash scripts/02-init.sh --rotate-keys   # 重新生成 UUID、密钥、shortId（旧客户端会失效）
#
# Xray 配置由几块拼成（都在 templates/ 下）：
#   xray-config.json.tpl            外框
#   xray/inbound-reality.json.tpl   公网入口（完整节点才有）
#   xray/inbound-internal.json.tpl  内网入口（.env 填了 EXIT_LISTEN 且发过通行证才有）
#   xray/egress-direct.json.tpl     直接出网 + 拦截规则（没填 UPSTREAM 时）
#   xray/egress-upstream.json.tpl   全部转给上游（填了 UPSTREAM 时）
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

ROTATE=0
[ "${1:-}" = "--rotate-keys" ] && ROTATE=1

command -v docker >/dev/null || die "未检测到 docker"
command -v openssl >/dev/null || die "未检测到 openssl"

# ---------- 检查 .env ----------
if [ "$EDGE_ROLE" = edge ]; then
    case "$REALITY_SNI" in
        example.com|*.example.com) die ".env 里还是示例域名：运行 bash edge.sh 按提示填写，或手动修改 REALITY_SNI / REALITY_CERT_DOMAIN" ;;
    esac
    cert_covers "$REALITY_SNI" "$REALITY_CERT_DOMAIN" \
        || die "REALITY_SNI=$REALITY_SNI 不在 $REALITY_CERT_DOMAIN 泛域名证书的覆盖范围内（只覆盖根域名和一级子域名）"
    [ "$REALITY_SNI" != "$REALITY_CERT_DOMAIN" ] \
        || warn "REALITY_SNI 用的是根域名，建议改用专用子域名（如 www.$REALITY_CERT_DOMAIN）"
    port_ok "$DECOY_PORT" \
        || die ".env 里 DECOY_PORT=${DECOY_PORT:-（空）} 不对：填 1-65535 之间的端口（如 3000），不能用 443 / 8443 / 10443"
    decoy_theme_ok "$DECOY_THEME" \
        || die ".env 里 DECOY_THEME=$DECOY_THEME 不对：apps/decoy/themes/ 下没有这个主题，可选：$(decoy_themes | tr '\n' ' ')（或者运行 edge theme 选择）"
else
    [ -n "$EXIT_LISTEN" ] || die "出口模式（EDGE_ROLE=exit）必须在 .env 填写 EXIT_LISTEN=内网IP:端口，或者运行 edge internal 设置"
    DECOY_PORT=""
fi
if [ -n "$EXIT_LISTEN" ]; then
    exit_listen_check "$EXIT_LISTEN" || die ".env 里 EXIT_LISTEN 不对（原因见上）：运行 edge internal 重新设置"
fi
if [ -n "$UPSTREAM" ]; then
    upstream_parse "$UPSTREAM" || die ".env 里 UPSTREAM 的链接不对（原因见上）：运行 edge upstream '<链接>' 重新设置，或 edge upstream off 取消"
    if [ "$UP_HOST" = "$REALITY_SNI" ] || [ "$UP_HOST" = "${EXIT_IP:-}" ]; then
        die "UPSTREAM 指向的是本机（$UP_HOST）：上游必须是另一台机器"
    fi
    # edge upstream 设置时已经提醒过一次，这里不再重复
    [ -z "$UP_WARN" ] || [ "${EDGE_UPSTREAM_WARNED:-0}" = 1 ] || warn "$UP_WARN"
fi

# 旧版本用的是 teddysun/xray：它的启动方式和官方镜像不同，跟现在的 docker-compose.yml 不兼容，自动切换
if [[ "$XRAY_IMAGE" == teddysun/* ]]; then
    warn "XRAY_IMAGE=$XRAY_IMAGE 已不再支持，.env 改为官方镜像 $XRAY_IMAGE_DEFAULT"
    sed -i -E "s#^XRAY_IMAGE=.*#XRAY_IMAGE=$XRAY_IMAGE_DEFAULT#" "$EDGE_DIR/.env"
    XRAY_IMAGE="$XRAY_IMAGE_DEFAULT"
fi

mkdir -p "$EDGE_DIR"/{nginx/conf.d,certs,xray,logs/nginx}
chmod 600 "$EDGE_DIR/.env"
chmod +x "$EDGE_DIR"/scripts/*.sh

# ---------- 证书必须先就位（只有完整节点需要）----------
# 伪装站配置会引用 certs/$REALITY_CERT_DOMAIN/：证书不存在时先签发，签不下来就不渲染，
# 否则 nginx -t 会一直失败，nginx 容器重启后也起不来（网站和代理一起中断）
if [ "$EDGE_ROLE" = edge ] && [ ! -s "$EDGE_DIR/certs/$REALITY_CERT_DOMAIN/fullchain.pem" ]; then
    log "还没有 $REALITY_CERT_DOMAIN 的证书，先签发"
    bash "$EDGE_DIR/scripts/03-issue-cert.sh" "$REALITY_CERT_DOMAIN" \
        || die "证书签发失败，未改动现有配置；处理好后重新运行本脚本"
fi

# ---------- Xray 密钥 ----------
b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }

gen_x25519() {
    local out tmp
    XRAY_PRIVATE_KEY="" XRAY_PUBLIC_KEY=""
    # 优先用 xray 自带命令（官方镜像入口就是 xray）
    # 新版输出 "PrivateKey: …" / "Password (PublicKey): …"，旧版 "Private key: …" / "Public key: …"，均取前两行冒号后的值
    log "拉取 $XRAY_IMAGE 并生成密钥（第一次需要下载镜像，请稍等）"
    if out="$(docker run --rm "$XRAY_IMAGE" x25519 2>/dev/null)"; then
        out="$(tr -d '\r' <<<"$out")"
        XRAY_PRIVATE_KEY="$(sed -n '1p' <<<"$out" | awk -F': *' '{print $2}')"
        XRAY_PUBLIC_KEY="$(sed -n '2p' <<<"$out" | awk -F': *' '{print $2}')"
    fi
    # 兜底：用 openssl 生成 X25519 密钥对（格式与 xray 相同：32 字节 base64url 无填充）
    if ! [[ "$XRAY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ && "$XRAY_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
        warn "xray x25519 不可用，改用 openssl 生成密钥"
        tmp="$(mktemp)"
        openssl genpkey -algorithm X25519 -out "$tmp" 2>/dev/null
        XRAY_PRIVATE_KEY="$(openssl pkey -in "$tmp" -outform DER | tail -c 32 | b64url)"
        XRAY_PUBLIC_KEY="$(openssl pkey -in "$tmp" -pubout -outform DER | tail -c 32 | b64url)"
        rm -f "$tmp"
    fi
    # 两种方式都失败时绝不能写出空密钥：否则之后每次都会复用它，xray 一直起不来
    [[ "$XRAY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ && "$XRAY_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] \
        || die "生成 X25519 密钥失败：xray 镜像 $XRAY_IMAGE 拉取失败，且本机 openssl 不支持 X25519（需要 1.1.1 以上）"
}

# ---------- 备份当前配置：后面任何一步失败都恢复原样 ----------
# 否则坏配置会留在磁盘上：nginx 暂时还用着内存里的旧配置，
# 但下次容器重启（VPS 重启、edge update）就起不来，网站和代理一起中断
GENERATED=("$EDGE_DIR/nginx/nginx.conf" "$EDGE_DIR/nginx/conf.d/00-decoy.conf"
           "$EDGE_DIR/xray/config.json" "$KEYS_FILE")
BACKUP_DIR="$(mktemp -d)"
COMMITTED=0
for f in "${GENERATED[@]}"; do
    [ -f "$f" ] && cp -p "$f" "$BACKUP_DIR/$(basename "$f")"
done

restore_configs() {
    local f b
    for f in "${GENERATED[@]}"; do
        b="$BACKUP_DIR/$(basename "$f")"
        # 用 cat 覆盖写回：保持 inode 不变，容器里的单文件挂载能看到
        if [ -f "$b" ]; then cat "$b" >"$f"; else rm -f "$f"; fi
    done
}

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$COMMITTED" -eq 0 ]; then
        restore_configs
        warn "已恢复成修改前的配置（包括密钥），正在运行的服务不受影响；处理好上面的问题后重新运行"
    fi
    rm -rf "$BACKUP_DIR"
}
trap on_exit EXIT

if [ "$ROTATE" -eq 1 ] && [ -f "$KEYS_FILE" ]; then
    cp "$KEYS_FILE" "$KEYS_FILE.bak.$(date +%Y%m%d%H%M%S)"
    rm -f "$KEYS_FILE"
    warn "已备份并删除旧密钥，将重新生成"
fi

if [ -f "$KEYS_FILE" ]; then
    log "复用已有密钥 $KEYS_FILE"
    load_keys
    # 旧版本的 keys.env 没有内网入口的服务端密钥：补上（不影响已有的 UUID / REALITY 密钥）
    if [ -z "${SS_SERVER_KEY:-}" ]; then
        SS_SERVER_KEY="$(gen_ss_key)"
        printf 'SS_SERVER_KEY=%s\n' "$SS_SERVER_KEY" >>"$KEYS_FILE"
        log "已补充内网入口用的服务端密钥（SS_SERVER_KEY）"
    fi
else
    log "生成 Xray UUID / X25519 密钥 / shortId"
    XRAY_UUID="$(gen_uuid)"
    gen_x25519
    XRAY_SHORT_ID="$(openssl rand -hex 8)"
    SS_SERVER_KEY="$(gen_ss_key)"
    umask 077
    cat >"$KEYS_FILE" <<EOF
# 由 02-init.sh 生成，请妥善备份；泄露后用 --rotate-keys 轮换
XRAY_UUID=$XRAY_UUID
XRAY_PRIVATE_KEY=$XRAY_PRIVATE_KEY
XRAY_PUBLIC_KEY=$XRAY_PUBLIC_KEY
XRAY_SHORT_ID=$XRAY_SHORT_ID
SS_SERVER_KEY=$SS_SERVER_KEY
EOF
    umask 022
fi

# ---------- nginx（只有完整节点需要）----------
if [ "$EDGE_ROLE" = edge ]; then
    case "$ENABLE_IPV6" in
        true)  USE_V6=1 ;;
        false) USE_V6=0 ;;
        *)     if [ -s /proc/net/if_inet6 ]; then USE_V6=1; else USE_V6=0; fi ;;
    esac
    if [ "$USE_V6" -eq 1 ]; then
        STREAM_LISTEN_V6="listen [::]:443 reuseport;"
        log "nginx 将同时监听 IPv6 443"
    else
        STREAM_LISTEN_V6="# IPv6 未启用（.env 中 ENABLE_IPV6）"
        log "nginx 只监听 IPv4 443"
    fi

    render "$EDGE_DIR/templates/nginx.conf.tpl" "$EDGE_DIR/nginx/nginx.conf" \
        REALITY_SNI STREAM_LISTEN_V6
    # 伪装站：反向代理到 apps/decoy（和业务站点用同一个模板）
    SITE_DOMAIN="$REALITY_SNI"
    UPSTREAM_ADDR="127.0.0.1:$DECOY_PORT"
    CERT_DOMAIN="$REALITY_CERT_DOMAIN"
    UPSTREAM_SAVED="$UPSTREAM" UPSTREAM="$UPSTREAM_ADDR"    # site.conf.tpl 用的是 __UPSTREAM__（反代后端）
    render "$EDGE_DIR/templates/site.conf.tpl" "$EDGE_DIR/nginx/conf.d/00-decoy.conf" \
        SITE_DOMAIN UPSTREAM CERT_DOMAIN
    UPSTREAM="$UPSTREAM_SAVED"
    log "伪装站：反向代理到 $UPSTREAM_ADDR"
fi

# ---------- Xray ----------
T="$EDGE_DIR/templates/xray"
relays_load
NRELAY=${#RELAY_NAMES[@]}

# ---------- DNS 自动记录 ----------
if [ "$EDGE_ROLE" = edge ]; then
    log "同步所有站点的 Cloudflare DNS 记录"
    ensure_all_sites_dns
fi

# 公网入口的用户：主 UUID（给手机等客户端）+ 每张通行证一个 UUID
REALITY_CLIENTS="          { \"id\": \"$XRAY_UUID\", \"flow\": \"xtls-rprx-vision\", \"email\": \"default@edge\" }"
SS_CLIENTS=""
for i in "${!RELAY_NAMES[@]}"; do
    REALITY_CLIENTS+=$',\n'"          { \"id\": \"${RELAY_UUIDS[$i]}\", \"flow\": \"xtls-rprx-vision\", \"email\": \"relay-${RELAY_NAMES[$i]}@edge\" }"
    SS_CLIENTS+="${SS_CLIENTS:+$',\n'}          { \"password\": \"${RELAY_SSKEYS[$i]}\", \"email\": \"relay-${RELAY_NAMES[$i]}@edge\" }"
done

XRAY_INBOUNDS=""
if [ "$EDGE_ROLE" = edge ]; then
    XRAY_INBOUNDS="$(render_text "$T/inbound-reality.json.tpl" \
        REALITY_CLIENTS REALITY_SNI XRAY_PRIVATE_KEY XRAY_SHORT_ID)"
fi
if [ -n "$EXIT_LISTEN" ]; then
    # 一张通行证都没有时不开内网入口：Shadowsocks 2022 没有用户时会退化成单用户模式，
    # 只凭服务端密钥就能连，已吊销的入口机手里正好有这个密钥
    if [ "$NRELAY" -gt 0 ]; then
        frag="$(render_text "$T/inbound-internal.json.tpl" EXIT_IP EXIT_PORT SS_METHOD SS_SERVER_KEY SS_CLIENTS)"
        XRAY_INBOUNDS+="${XRAY_INBOUNDS:+$',\n'}$frag"
        log "内网入口：$EXIT_IP:$EXIT_PORT（$NRELAY 张通行证）"
    else
        warn "内网入口 $EXIT_IP:$EXIT_PORT 还没有发过通行证，暂不监听：运行 edge relay add <名字>"
    fi
fi

if [ -n "$UPSTREAM" ]; then
    UPSTREAM_OUTBOUND="$UP_OUTBOUND"
    XRAY_EGRESS="$(render_text "$T/egress-upstream.json.tpl" UPSTREAM_OUTBOUND)"
    log "出口：全部经上游 $UP_DESC（本机不直连）"
else
    XRAY_EGRESS="$(render_text "$T/egress-direct.json.tpl")"
fi

render "$EDGE_DIR/templates/xray-config.json.tpl" "$EDGE_DIR/xray/config.json" \
    XRAY_INBOUNDS XRAY_EGRESS
# 官方镜像以 UID 65532 运行：属主 root、属组 65532、640，容器能读，宿主机其他用户读不到
chown "0:$XRAY_UID" "$EDGE_DIR/xray/config.json"
chmod 640 "$EDGE_DIR/xray/config.json"
if [ "$EDGE_ROLE" = edge ]; then
    log "已生成 nginx/nginx.conf、nginx/conf.d/00-decoy.conf、xray/config.json"
else
    log "已生成 xray/config.json（出口模式：不需要 nginx）"
fi

# ---------- 检查新配置：不通过就恢复旧配置（见上面的 on_exit）----------
if [ "$EDGE_ROLE" = edge ] && nginx_running; then
    docker exec nginx nginx -t -q || die "新生成的 nginx 配置检查不通过（报错见上）"
    log "nginx 配置检查通过"
fi
if docker image inspect "$XRAY_IMAGE" >/dev/null 2>&1; then
    if ! out="$(docker run --rm -v "$EDGE_DIR/xray/config.json:/etc/xray/config.json:ro" \
                "$XRAY_IMAGE" run -test -c /etc/xray/config.json 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "新生成的 Xray 配置检查不通过（报错见上）"
    fi
    log "Xray 配置检查通过"
else
    warn "本机还没有 $XRAY_IMAGE 镜像，跳过 Xray 配置检查"
fi
COMMITTED=1

# ---------- 生效 / 下一步 ----------
if [ "$EDGE_ROLE" = edge ]; then
    # 伪装站应用：按 DECOY_PORT 构建并启动（端口改了会自动重建）
    # 失败只提醒：应用没起来不影响代理，只是访问伪装站会看到 502
    decoy_up || warn "伪装站应用启动失败（代理不受影响）：cd apps/decoy && docker compose logs 查看原因，处理后运行 edge apply"

    if nginx_running; then
        log "容器在运行：重载配置"
        # 重建而不是 restart：.env 里换了 XRAY_IMAGE 或 compose 有改动时也能生效
        (cd "$EDGE_DIR" && docker compose up -d --force-recreate xray) \
            || warn "xray 容器重建失败：docker compose logs xray 查看原因"
        # .env 里换了 NGINX_IMAGE 时重建 nginx（新配置上面已检查过）；没变化时这一步什么都不做
        (cd "$EDGE_DIR" && docker compose up -d nginx) \
            || warn "nginx 容器更新失败：docker compose logs nginx 查看原因"
        bash "$EDGE_DIR/scripts/reload-nginx.sh"
    else
        next_step "docker compose up -d"
    fi
else
    if xray_exists; then
        log "重建 xray 容器，让新配置生效"
        (cd "$EDGE_DIR" && docker compose up -d --force-recreate xray) \
            || warn "xray 容器重建失败：docker compose logs xray 查看原因"
    else
        next_step "docker compose up -d xray"
    fi
    if nginx_running; then
        warn "出口模式不需要 nginx，但它还在运行：确认不再需要网站后，运行 docker compose stop nginx"
    fi
fi

# 一键安装时，客户端配置在最后统一打印一次
if [ "${EDGE_ONECLICK:-0}" != 1 ]; then
    echo
    bash "$EDGE_DIR/scripts/show-client.sh"
fi
