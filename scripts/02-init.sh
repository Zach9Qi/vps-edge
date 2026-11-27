#!/usr/bin/env bash
# 生成 Xray 密钥（只在第一次生成，之后复用）并渲染 nginx / xray 配置
# 用法：
#   bash scripts/02-init.sh                 # 首次初始化，或修改 .env / 模板 / 账号 / 出口后重新渲染
#   bash scripts/02-init.sh --rotate-keys   # 重新生成密钥、shortId 和所有账号的 UUID（旧客户端会失效）
#
# Xray 配置由几块拼成（都在 templates/ 下）：
#   xray-config.json.tpl            外框
#   xray/inbound-reality.json.tpl   公网入口（完整节点才有）：所有账号
#   xray/inbound-internal.json.tpl  内网入口（.env 填了 EXIT_LISTEN 且有 default 以外的账号才有）
#   xray/egress.json.tpl            出口和路由：每个账号走自己的出口（由 lib.sh 的 xray_egress 生成）
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

# ---------- 当前配置先复制到临时目录：后面任何一步失败都恢复原样，脚本退出时删掉 ----------
# 否则坏配置会留在磁盘上：nginx 暂时还用着内存里的旧配置，
# 但下次容器重启（VPS 重启、edge update）就起不来，网站和代理一起中断
GENERATED=("$EDGE_DIR/nginx/nginx.conf" "$EDGE_DIR/nginx/conf.d/00-decoy.conf"
           "$EDGE_DIR/xray/config.json" "$KEYS_FILE"
           "$USERS_FILE" "$EXITS_FILE")
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

# 轮换：删掉旧密钥重新生成。中途失败会从上面的临时目录恢复，成功后旧密钥不保留
if [ "$ROTATE" -eq 1 ] && [ -f "$KEYS_FILE" ]; then
    rm -f "$KEYS_FILE"
    warn "已删除旧密钥，将重新生成"
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
    log "生成 Xray X25519 密钥 / shortId"
    KEYS_NEW=1
    gen_x25519
    XRAY_SHORT_ID="$(openssl rand -hex 8)"
    SS_SERVER_KEY="$(gen_ss_key)"
    umask 077
    # 账号的 UUID 不在这里：每个账号一个，记在 xray/users.env
    cat >"$KEYS_FILE" <<EOF
# 由 02-init.sh 生成，请妥善备份；泄露后用 --rotate-keys 轮换
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
    UPSTREAM="$UPSTREAM_ADDR"    # site.conf.tpl 用的是 __UPSTREAM__（反代后端）
    render "$EDGE_DIR/templates/site.conf.tpl" "$EDGE_DIR/nginx/conf.d/00-decoy.conf" \
        SITE_DOMAIN UPSTREAM CERT_DOMAIN
    log "伪装站：反向代理到 $UPSTREAM_ADDR"
fi

# ---------- 账号和出口 ----------
T="$EDGE_DIR/templates/xray"
users_load
exits_load

# 完整节点自带账号 default（手机用的那条链接）：只在第一次生成密钥时自动创建
# 已有密钥却没有 default，说明 users.env 丢了或被改过：报错，不悄悄换一个新 UUID（手机会连不上）
if [ "$EDGE_ROLE" = edge ] && ! user_index default >/dev/null; then
    [ "${KEYS_NEW:-0}" = 1 ] \
        || die "$USERS_FILE 里没有账号 default（手机用的那条链接）：从备份恢复 xray/users.env，或者 edge user add default 新建（手机要重新导入）"
    USER_NAMES+=(default) USER_UUIDS+=("$(gen_uuid)") USER_SSKEYS+=("$(gen_ss_key)")
    USER_DATES+=("$(date +%F)") USER_EXITS+=(direct)
    users_save
    log "已创建账号 default（出口 direct）"
fi
if [ "$ROTATE" -eq 1 ]; then
    # REALITY 公钥和内网入口的服务端密钥都换了，所有链接本来就要重新导入，账号凭据一起换掉
    for i in "${!USER_NAMES[@]}"; do
        USER_UUIDS[$i]="$(gen_uuid)"
        USER_SSKEYS[$i]="$(gen_ss_key)"
    done
    users_save
    log "已重新生成 ${#USER_NAMES[@]} 个账号的 UUID 和密钥"
fi

# ---------- DNS 自动记录 ----------
if [ "$EDGE_ROLE" = edge ]; then
    log "同步所有站点的 Cloudflare DNS 记录"
    ensure_all_sites_dns
fi

# ---------- Xray ----------
# 公网入口：所有账号；内网入口：default 以外的账号（default 是手机用的，和以前一样不进内网入口）
REALITY_CLIENTS="" SS_CLIENTS=""
for i in "${!USER_NAMES[@]}"; do
    email="$(user_email "${USER_NAMES[$i]}")"
    REALITY_CLIENTS+="${REALITY_CLIENTS:+$',\n'}          { \"id\": \"${USER_UUIDS[$i]}\", \"flow\": \"xtls-rprx-vision\", \"email\": \"$email\" }"
    if [ "${USER_NAMES[$i]}" != default ]; then
        SS_CLIENTS+="${SS_CLIENTS:+$',\n'}          { \"password\": \"${USER_SSKEYS[$i]}\", \"email\": \"$email\" }"
    fi
done
NINTERNAL="$(internal_users)"

XRAY_INBOUNDS=""
if [ "$EDGE_ROLE" = edge ]; then
    XRAY_INBOUNDS="$(render_text "$T/inbound-reality.json.tpl" \
        REALITY_CLIENTS REALITY_SNI XRAY_PRIVATE_KEY XRAY_SHORT_ID)"
fi
if [ -n "$EXIT_LISTEN" ]; then
    # 没有可用的账号时不开内网入口：Shadowsocks 2022 没有用户时会退化成单用户模式，
    # 只凭服务端密钥就能连，已删除账号的入口机手里正好有这个密钥
    if [ "$NINTERNAL" -gt 0 ]; then
        frag="$(render_text "$T/inbound-internal.json.tpl" EXIT_IP EXIT_PORT SS_METHOD SS_SERVER_KEY SS_CLIENTS)"
        XRAY_INBOUNDS+="${XRAY_INBOUNDS:+$',\n'}$frag"
        log "内网入口：$EXIT_IP:$EXIT_PORT（$NINTERNAL 个账号）"
    else
        warn "内网入口 $EXIT_IP:$EXIT_PORT 还没有可用的账号，暂不监听：运行 edge user add <名字>"
    fi
fi

# 出口和路由：每个账号严格走自己的出口，没有任何回落（规则见 lib.sh 的 xray_egress）
xray_egress
XRAY_OUTBOUNDS="$EGRESS_OUTBOUNDS"
XRAY_RULES="$EGRESS_RULES"
XRAY_DOMAIN_STRATEGY="$EGRESS_DOMAIN_STRATEGY"
XRAY_EGRESS="$(render_text "$T/egress.json.tpl" XRAY_OUTBOUNDS XRAY_DOMAIN_STRATEGY XRAY_RULES)"
for i in "${!USER_NAMES[@]}"; do
    log "账号 ${USER_NAMES[$i]} → ${USER_EXITS[$i]}（$(exit_desc "${USER_EXITS[$i]}")）"
done

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
