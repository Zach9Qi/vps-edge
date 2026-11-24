#!/usr/bin/env bash
# vps-edge 唯一入口：所有操作都从这里开始，不用记 scripts/ 里的各个脚本
#
#   bash edge.sh             第一次：一键安装（会问几个问题）；之后：打开菜单
#   安装完成后，任何目录下直接输入 edge 即可（已链接到 /usr/local/bin/edge）
#
#   edge install             一键安装 / 修复（可重复执行，不会重复生成密钥）
#   edge add <域名> <应用名>  发布 apps/<应用名>：自动分配端口、构建启动、签证书、配好 HTTPS
#   edge add <域名> <端口>    或者反代到一个已经在运行的服务
#   edge up [应用名]          改了应用代码后重新构建、重启（不带参数 = 全部应用）
#   edge remove [域名]        删除网站，并停止对应的应用（不带参数会列出来让你选）
#   edge sites               查看已有网站
#   edge check               健康检查
#   edge client              显示客户端配置 / 分享链接
#   edge apply               改了 .env 或模板之后，重新生成配置并生效
#   edge update              更新所有镜像并重启（包括 apps/ 下的应用）
#   edge rotate-keys         轮换 Xray 密钥（旧客户端需要重新导入）
#   edge logs [nginx|xray]   查看日志
#   edge xray [--raw]        查看 Xray 实际配置（私钥默认隐藏，--raw 显示完整）
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
. "$(dirname "$SELF")/scripts/lib.sh"
S="$EDGE_DIR/scripts"
DOMAIN_RE='^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'

usage() { sed -n '2,19p' "$SELF" | sed 's/^# \{0,1\}//'; }

dc() { (cd "$EDGE_DIR" && docker compose "$@"); }

installed() {
    [ -f "$EDGE_DIR/.env" ] && [ -f "$KEYS_FILE" ] && [ -f "$EDGE_DIR/nginx/nginx.conf" ]
}

# ---------------------------------------------------------------- 交互小工具
# ask <变量名> <提示> [默认值]：必填
ask() {
    local __v="$1" prompt="$2" def="${3:-}" ans
    while :; do
        if [ -n "$def" ]; then read -rp "$prompt [$def]: " ans; else read -rp "$prompt: " ans; fi
        ans="${ans:-$def}"
        [ -n "$ans" ] && break
        warn "不能为空"
    done
    printf -v "$__v" '%s' "$ans"
}

# ask_secret <变量名> <提示> [已有值]：输入不回显；已有值时直接回车保留
ask_secret() {
    local __v="$1" prompt="$2" cur="${3:-}" ans
    while :; do
        if [ -n "$cur" ]; then read -rsp "$prompt [已填写，回车保留]: " ans; else read -rsp "$prompt: " ans; fi
        echo
        ans="${ans:-$cur}"
        [ -n "$ans" ] && break
        warn "不能为空"
    done
    printf -v "$__v" '%s' "$ans"
}

confirm() {  # confirm <提示>：默认否
    local ans
    read -rp "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- .env 读写
env_get() {  # env_get KEY：读 .env 里的值（去掉引号和 Windows 换行）
    [ -f "$EDGE_DIR/.env" ] || return 0
    sed 's/\r$//' "$EDGE_DIR/.env" | grep -E "^$1=" | tail -n 1 | cut -d= -f2- \
        | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/" || true
}

env_set() {  # env_set KEY VALUE：改写 .env 里的 KEY=，没有就追加
    local f="$EDGE_DIR/.env" tmp
    tmp="$(mktemp)"
    K="$1" V="$2" awk '
        BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
        index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }' "$f" >"$tmp"
    cat "$tmp" >"$f"
    rm -f "$tmp"
}

is_example() { case "$1" in ""|example.com|*.example.com) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------- Cloudflare
# cf_zone_of <域名>：打印该域名所在的 Cloudflare 域名（zone），用 $CF_Token
# 返回 0 找到；1 Token 有效但看不到这个域名；2 网络问题；3 Token 无效
cf_zone_of() {
    local d="$1" resp
    while [[ "$d" == *.* ]]; do
        resp="$(curl -sS --max-time 15 -H "Authorization: Bearer $CF_Token" \
                "https://api.cloudflare.com/client/v4/zones?name=$d" 2>/dev/null)" || return 2
        grep -q '"success":true' <<<"$resp" || return 3
        if grep -q "\"name\":\"$d\"" <<<"$resp"; then echo "$d"; return 0; fi
        d="${d#*.}"
    done
    return 1
}

# pick_cert_domain <域名> [zone]：决定给这个域名签哪张泛域名证书（X + *.X）
#   www.foo.com → foo.com；foo.com → foo.com；a.b.foo.com → b.foo.com
#   知道 zone 时以 zone 为准，能正确处理 foo.co.uk 这类后缀
pick_cert_domain() {
    local d="$1" z="${2:-}"
    if [ -n "$z" ]; then
        if [ "$d" = "$z" ] || cert_covers "$d" "$z"; then echo "$z"; else echo "${d#*.}"; fi
    elif [[ "$d" == *.*.* ]]; then
        echo "${d#*.}"
    else
        echo "$d"
    fi
}

# ---------------------------------------------------------------- 首次配置向导
# fix_cert_domain <SNI> <Token>：.env 是手动填的时候，REALITY_CERT_DOMAIN 可能忘了改
# （还是 example.com）或者和 REALITY_SNI 对不上。在签证书之前自动算好，
# 免得拿你的 Token 去签一个不相干的域名，最后只报一句"签发失败"
fix_cert_domain() {
    local sni="$1" token="$2" cur zone cert
    cur="$(env_get REALITY_CERT_DOMAIN)"
    if [ -n "$cur" ] && ! is_example "$cur" && cert_covers "$sni" "$cur"; then
        return 0
    fi
    zone="$(CF_Token="$token" cf_zone_of "$sni")" || zone=""
    cert="$(pick_cert_domain "$sni" "$zone")"
    env_set REALITY_CERT_DOMAIN "$cert"
    warn "REALITY_CERT_DOMAIN=${cur:-（空）} 不能覆盖 REALITY_SNI=$sni，已自动改为 $cert（证书：$cert 和 *.$cert）"
}

# ask_port <变量名> [默认值]：伪装站应用 apps/decoy 在本机监听的端口
ask_port() {
    # 局部变量用 __ 开头：避免和调用方、ask 里的变量重名（重名时 printf -v 会写到局部变量上）
    local __v="$1" __port="${2:-3000}"
    while :; do
        ask __port "伪装站应用（apps/decoy）用本机哪个端口？直接回车用默认值" "$__port"
        port_ok "$__port" && break
        warn "端口不对：$__port（1-65535，不能用 443 / 8443 / 10443）"; __port=""
    done
    printf -v "$__v" '%s' "$__port"
}

wizard() {
    local f="$EDGE_DIR/.env" sni token email decoy
    [ -f "$f" ] || cp "$EDGE_DIR/.env.example" "$f"
    chmod 600 "$f"

    sni="$(env_get REALITY_SNI)"
    token="$(env_get CF_Token)"
    email="$(env_get ACME_EMAIL)"
    decoy="$(env_get DECOY_PORT)"
    [ -n "$decoy" ] || decoy="$(env_get DECOY_UPSTREAM)"   # 旧版 .env
    decoy="${decoy##*:}"
    if ! is_example "$sni" && [ -n "$token" ] && [ -n "$email" ] && ! is_example "${email#*@}"; then
        fix_cert_domain "$sni" "$token"
        if [ -z "$(env_get DECOY_PORT)" ]; then   # 没填端口（或旧版 .env）：沿用旧值，没有就用 3000
            env_set DECOY_PORT "${decoy:-3000}"
            log "伪装站端口 DECOY_PORT=${decoy:-3000}"
        fi
        return 0    # .env 已经填好，不再询问
    fi
    [ -t 0 ] || die ".env 还没填好：请编辑 $f，或者在终端里运行 bash edge.sh 按提示填写"
    wizard_ask "$f" "$sni" "$token" "$email" "$decoy"
}

# wizard_ask：完整问答（首次安装时）
wizard_ask() {
    local f="$1" sni="$2" token="$3" email="$4" decoy="$5" zone cert rc
    is_example "$sni" && sni=""
    is_example "${email#*@}" && email=""

    cat <<'EOF'

================ 首次配置（只问这一次，答案保存在 .env）================
开始前请在 Cloudflare 准备好：
  1. 给伪装站用的域名（如 www.你的域名.com），A/AAAA 记录指向本机，灰云（仅 DNS）
  2. API Token：My Profile → API Tokens → Create Token → Custom token
     权限 Zone → DNS → Edit 和 Zone → Zone → Read，Zone Resources 选你的域名
伪装站应用放在 apps/decoy/，安装时会按你填的端口自动构建并启动
EOF
    echo
    while :; do
        ask sni "伪装站域名（REALITY_SNI）" "$sni"
        if ! [[ "$sni" =~ $DOMAIN_RE ]] || is_example "$sni"; then
            warn "域名格式不对：$sni"; sni=""; continue
        fi
        ask_secret token "Cloudflare API Token（输入时不显示）" "$token"
        zone="$(CF_Token="$token" cf_zone_of "$sni")" && rc=0 || rc=$?
        case "$rc" in
            0) log "Token 有效，$sni 属于 Cloudflare 上的 $zone"; break ;;
            1) warn "这个 Token 看不到 $sni 所在的域名：确认域名托管在 Cloudflare，且 Token 的 Zone Resources 包含它"; token="" ;;
            3) warn "Token 无效或缺少 Zone → Zone → Read 权限，请重新输入"; token="" ;;
            *) warn "连不上 Cloudflare API，先跳过 Token 校验（签证书时还会再验证）"; zone=""; break ;;
        esac
    done
    cert="$(pick_cert_domain "$sni" "$zone")"
    log "将签发证书：$cert 和 *.$cert"

    ask email "Let's Encrypt 邮箱" "$email"
    ask_port decoy "$decoy"

    env_set REALITY_SNI "$sni"
    env_set REALITY_CERT_DOMAIN "$cert"
    env_set CF_Token "$token"
    env_set ACME_EMAIL "$email"
    env_set DECOY_PORT "$decoy"
    log "已保存到 $f（以后想改，编辑它然后运行 edge apply）"
}

# ---------------------------------------------------------------- 命令
cmd_install() {
    export EDGE_ONECLICK=1
    log "[1/5] 主机准备"
    bash "$S/01-host-setup.sh"
    chmod +x "$SELF"
    ln -sf "$SELF" /usr/local/bin/edge

    log "[2/5] 配置"
    wizard

    log "[3/5] 证书"
    bash "$S/03-issue-cert.sh"

    log "[4/5] 生成密钥和配置、启动应用"
    bash "$S/02-init.sh"          # 里面会启动伪装站 apps/decoy
    load_env
    start_published_apps          # 已经 edge add 过的应用（换机器恢复时用得上）

    log "[5/5] 启动容器"
    dc up -d
    sleep 3

    echo
    bash "$S/check.sh" || warn "有检查项没通过，按上面的提示处理后再运行 edge check"
    echo
    bash "$S/show-client.sh"
    echo
    log "安装完成。以后只需要记一个命令：edge（打开菜单），或 edge help 查看所有用法"
}

list_apps() {  # apps/ 下可以发布的应用（不含伪装站 decoy）
    local d n
    for d in "$APPS_DIR"/*/; do
        n="$(basename "$d")"
        if [ "$n" != decoy ] && app_exists "$n"; then echo "$n"; fi
    done
}

cmd_add() {
    load_env
    local domain="${1:-}" target="${2:-}" cert zone up app="" port="" new_app=0 apps
    if [ -z "$domain" ] || [ -z "$target" ]; then
        [ -t 0 ] || die "用法：edge add <域名> <应用名|端口>"
        ask domain "网站域名（如 app.你的域名.com）" "$domain"
        apps="$(list_apps | tr '\n' ' ')"
        echo "  apps/ 下的应用：${apps:-（没有）}"
        ask target "填应用名（自动构建、启动），或已经在运行的服务的端口" "$target"
    fi
    [[ "$domain" =~ $DOMAIN_RE ]] || die "域名格式不对：$domain"
    [ "$domain" != "$REALITY_SNI" ] \
        || die "$domain 是伪装站域名，由 apps/decoy 提供，不需要再添加"
    [ ! -e "$CONF_DIR/$domain.conf" ] || die "$domain 已经添加过了（edge sites 查看；要重建先 edge remove $domain）"

    # 第二个参数：apps/ 下的应用名 → 自动分配端口并启动；端口或 host:port → 直接反代
    if [ "$target" = decoy ]; then
        die "decoy 是伪装站应用，不能再发布成业务网站"
    elif app_exists "$target"; then
        app="$target"
        if ! port="$(app_port "$app")"; then
            port="$(alloc_port)"
            new_app=1
        fi
        app_up "$app" "$port" || die "apps/$app 启动失败：cd apps/$app && docker compose logs 查看原因"
        up="$port"
    elif [[ "$target" =~ ^[0-9]+$ || "$target" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]]; then
        up="$target"
    else
        die "$target 既不是 apps/ 下的应用（需要 apps/$target/compose.yaml），也不是端口"
    fi

    # 后面任何一步失败：刚为这次新启动的应用一并停掉，不留下没人用的容器
    if ! {
        if ! cert="$(find_cert "$domain")"; then
            zone="$(cf_zone_of "$domain")" || zone=""
            cert="$(pick_cert_domain "$domain" "$zone")"
            log "还没有覆盖 $domain 的证书，自动签发 $cert 和 *.$cert"
            bash "$S/03-issue-cert.sh" "$cert"
        fi &&
        bash "$S/add-site.sh" "$domain" "$up" "$cert" "$app"
    }; then
        [ "$new_app" -eq 0 ] || app_down "$app" || true
        die "添加 $domain 失败（见上面的报错）"
    fi
}

# cmd_up [应用名]：重新构建并重启应用（先拉取最新基础镜像）；不带参数 = 伪装站 + 所有已发布的应用
cmd_up() {
    load_env
    local name="${1:-}" port fails=0
    if [ -n "$name" ]; then
        app_exists "$name" || die "apps/$name/ 下没有 compose.yaml"
        port="$(app_port "$name")" || die "apps/$name 还没有发布：先运行 edge add <域名> $name"
        app_up "$name" "$port" pull
        return
    fi
    decoy_up pull || { warn "apps/decoy 更新失败（代理不受影响）"; fails=$((fails + 1)); }
    while read -r name; do
        [ -n "$name" ] || continue
        port="$(app_port "$name")" || continue
        app_up "$name" "$port" pull || { warn "apps/$name 更新失败"; fails=$((fails + 1)); }
    done < <(published_apps)
    [ "$fails" -eq 0 ] || die "$fails 个应用更新失败，见上面的报错"
}

# 已发布的业务应用全部构建、启动（install 时用：换机器恢复、或容器被删掉之后）
start_published_apps() {
    local name port
    while read -r name; do
        [ -n "$name" ] || continue
        port="$(app_port "$name")" || continue
        app_up "$name" "$port" || warn "apps/$name 启动失败：cd apps/$name && docker compose logs 查看原因"
    done < <(published_apps)
}

list_sites() {
    local f
    shopt -s nullglob
    for f in "$EDGE_DIR"/nginx/conf.d/*.conf; do
        [ "$(basename "$f")" = "00-decoy.conf" ] || basename "$f" .conf
    done
}

cmd_sites() {
    load_env
    local d up app n=0
    printf '  %-36s → 127.0.0.1:%s（伪装站 apps/decoy）\n' "$REALITY_SNI" "$DECOY_PORT"
    while read -r d; do
        [ -n "$d" ] || continue
        up="$({ grep -oE 'proxy_pass[[:space:]]+http://[^;]+' "$CONF_DIR/$d.conf" || true; } \
              | head -n 1 | sed -E 's#.*http://##; s#/$##')"
        app="$(site_app "$CONF_DIR/$d.conf")"
        printf '  %-36s → %s%s\n' "$d" "${up:-（自定义配置）}" "${app:+（apps/$app）}"
        n=$((n + 1))
    done < <(list_sites)
    [ "$n" -gt 0 ] || echo "  （还没有添加业务网站：edge add <域名> <应用名|端口>）"
}

cmd_remove() {
    local domain="${1:-}" sites n i
    if [ -z "$domain" ]; then
        [ -t 0 ] || die "用法：edge remove <域名>"
        mapfile -t sites < <(list_sites)
        [ ${#sites[@]} -gt 0 ] || { log "还没有添加过网站"; return 0; }
        for i in "${!sites[@]}"; do printf '  %d) %s\n' $((i + 1)) "${sites[$i]}"; done
        read -rp "删除哪个（序号）: " n
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#sites[@]} ] || die "序号不对"
        domain="${sites[$((n - 1))]}"
        confirm "确认删除 $domain？" || { log "已取消"; return 0; }
    fi
    bash "$S/remove-site.sh" "$domain"
}

cmd_update() {
    dc pull
    dc up -d
    (cmd_up) || true     # 伪装站和所有已发布的应用：拉最新基础镜像并重新构建
    sleep 3
    bash "$S/check.sh" || true
}

cmd_rotate() {
    if [ -t 0 ]; then
        confirm "轮换后所有客户端都要重新导入，确定？" || { log "已取消"; return 0; }
    fi
    bash "$S/02-init.sh" --rotate-keys
}

# cmd_xray [--raw]：查看 Xray 正在用的配置（容器挂载的就是这个文件），私钥默认打码
cmd_xray() {
    local f="$EDGE_DIR/xray/config.json" started
    [ -f "$f" ] || die "还没有 $f：先运行 edge install"
    echo "== $f =="
    if [ "${1:-}" = --raw ]; then
        cat "$f"
    else
        sed -E 's/("privateKey"[[:space:]]*:[[:space:]]*")[^"]*/\1******（已隐藏，edge xray --raw 显示完整）/' "$f"
    fi
    echo
    if ! started="$(docker inspect -f '{{.State.Running}} {{.State.StartedAt}}' xray 2>/dev/null)"; then
        warn "xray 容器不存在：运行 edge install"
    elif [ "${started%% *}" != true ]; then
        warn "xray 容器没有在运行：docker logs xray 查看原因"
    else
        log "xray 运行中，启动于 $(date -d "${started#* }" '+%F %T')"
        # 配置文件比容器新：说明改过还没生效
        [ "$(stat -c %Y "$f")" -le "$(date -d "${started#* }" +%s)" ] \
            || warn "配置文件在容器启动之后改过，还没生效：运行 edge apply"
    fi
}

cmd_logs() {
    case "${1:-nginx}" in
        nginx) tail -n 50 -f "$EDGE_DIR/logs/nginx/access.log" "$EDGE_DIR/logs/nginx/error.log" ;;
        xray)  docker logs -f --tail 100 xray ;;
        *)     die "用法：edge logs [nginx|xray]" ;;
    esac
}

menu() {
    local c a
    while :; do
        cat <<'EOF'

================ vps-edge ================
  1) 健康检查
  2) 显示客户端配置（分享链接）
  3) 添加网站 / 发布应用
  4) 删除网站
  5) 查看已有网站
  6) 更新应用（改了 apps/ 里的代码后）
  7) 改了 .env 后重新生成配置
  8) 更新所有镜像
  9) 重新安装 / 修复
 10) 轮换 Xray 密钥
 11) 查看 Xray 配置
  0) 退出
EOF
        read -rp "请选择: " c || exit 0
        echo
        # 每个操作在子进程里跑：出错只结束这一项，回到菜单
        case "$c" in
            1) bash "$SELF" check ;;
            2) bash "$SELF" client ;;
            3) bash "$SELF" add ;;
            4) bash "$SELF" remove ;;
            5) bash "$SELF" sites ;;
            6) echo "  已发布的应用：decoy $(published_apps | tr '\n' ' ')"
               read -rp "更新哪个（留空 = 全部）: " a
               bash "$SELF" up ${a:+"$a"} ;;
            7) bash "$SELF" apply ;;
            8) bash "$SELF" update ;;
            9) bash "$SELF" install ;;
            10) bash "$SELF" rotate-keys ;;
            11) bash "$SELF" xray ;;
            0|q|"") exit 0 ;;
            *) warn "没有这个选项" ;;
        esac || true
    done
}

# ---------------------------------------------------------------- 入口
case "${1:-}" in
    help|-h|--help) usage; exit 0 ;;
esac
require_root
cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
    "")          if installed; then menu; else cmd_install; fi ;;
    install)     cmd_install ;;
    add)         cmd_add "$@" ;;
    up)          cmd_up "$@" ;;
    remove|rm)   cmd_remove "$@" ;;
    sites|ls)    cmd_sites ;;
    check)       bash "$S/check.sh" ;;
    client)      bash "$S/show-client.sh" ;;
    apply)       bash "$S/02-init.sh" ;;
    update)      cmd_update ;;
    rotate-keys) cmd_rotate ;;
    logs)        cmd_logs "$@" ;;
    xray)        cmd_xray "$@" ;;
    *)           usage; exit 1 ;;
esac
