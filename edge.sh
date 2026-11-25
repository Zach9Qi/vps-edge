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
#   edge theme [主题名]       切换伪装站主题（不带参数会列出来让你选）
#   edge remove [域名]        删除网站，并停止对应的应用（不带参数会列出来让你选）
#   edge sites               查看已有网站
#   edge check               健康检查
#   edge client              显示客户端配置 / 分享链接
#   edge apply               改了 .env 或模板之后，重新生成配置并生效
#   edge update              更新所有镜像并重启（包括 apps/ 下的应用）
#   edge rotate-keys         轮换 Xray 密钥（旧客户端需要重新导入）
#   edge logs [nginx|xray]   查看日志
#   edge xray [--raw]        查看 Xray 实际配置（私钥默认隐藏，--raw 显示完整）
#
#   ---- 链式代理（多台机器串联，详见 README 第 8 节）----
#   edge chain                       打开链式代理菜单
#   edge upstream                    查看本机的上游
#   edge upstream '<链接>' [--force]  设置上游：先测试，通过后才启用；本机流量全部经上游出去
#   edge upstream test               测试当前上游（能否连通、出口 IP 是不是上游的）
#   edge upstream off                取消上游，恢复直接出网
#   edge relay add <名字>            给入口机发一张通行证，打印链接（入口机拿去 edge upstream）
#   edge relay list                  查看已发的通行证
#   edge relay show <名字>           再次显示某张通行证的链接
#   edge relay remove <名字>         吊销通行证（对应入口机立刻连不上，其他不受影响）
#   edge internal                    查看 / 交互设置内网入口
#   edge internal <内网IP:端口>       开启或修改内网入口（给同一内网的入口机用）
#   edge internal off                关闭内网入口
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
. "$(dirname "$SELF")/scripts/lib.sh"
S="$EDGE_DIR/scripts"
DOMAIN_RE='^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SELF"; }

dc() { (cd "$EDGE_DIR" && docker compose "$@"); }

installed() {
    [ -f "$EDGE_DIR/.env" ] && [ -f "$KEYS_FILE" ] || return 1
    if [ "$(env_get EDGE_ROLE)" = exit ]; then
        [ -f "$EDGE_DIR/xray/config.json" ]
    else
        [ -f "$EDGE_DIR/nginx/nginx.conf" ]
    fi
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

# cf_zone_of / cf_zone_lookup 定义在 scripts/lib.sh，这里不要重复定义（会覆盖掉 lib.sh 的实现）

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

# ask_theme <变量名> [当前主题]：列出 apps/decoy/themes/ 下的主题，按序号选择
ask_theme() {
    local __v="$1" __cur="${2:-forma}" __list __i __def=1 __n __mark
    mapfile -t __list < <(decoy_themes)
    [ ${#__list[@]} -gt 0 ] || die "apps/decoy/themes/ 下没有主题（每个主题一个目录，里面要有 index.html）"
    echo
    echo "  伪装站主题："
    for __i in "${!__list[@]}"; do
        __mark=""
        if [ "${__list[$__i]}" = "$__cur" ]; then __mark="（当前）"; __def=$((__i + 1)); fi
        printf '    %d) %-12s %s%s\n' $((__i + 1)) "${__list[$__i]}" "$(decoy_theme_desc "${__list[$__i]}")" "$__mark"
    done
    while :; do
        read -rp "选择伪装站主题（序号）[$__def]: " __n
        __n="${__n:-$__def}"
        if [[ "$__n" =~ ^[0-9]+$ ]] && [ "$__n" -ge 1 ] && [ "$__n" -le ${#__list[@]} ]; then break; fi
        warn "填 1-${#__list[@]} 之间的序号"
    done
    printf -v "$__v" '%s' "${__list[$((__n - 1))]}"
}

# pick_internal <变量名>：交互选择内网入口地址（列出本机的内网 IP），结果形如 10.0.0.2:23456
pick_internal() {
    local __v="$1" __cur __ip="" __port __ips __n __i __line
    __cur="$(env_get EXIT_LISTEN)"
    __port="${__cur##*:}"
    [[ "$__port" =~ ^[0-9]+$ ]] || __port=23456
    mapfile -t __ips < <(local_private_ips)
    echo
    if [ ${#__ips[@]} -gt 0 ]; then
        echo "  本机的内网 IP："
        for __i in "${!__ips[@]}"; do
            __line="${__ips[$__i]}"
            printf '    %d) %-16s 网卡 %s\n' $((__i + 1)) "${__line%% *}" "${__line#* }"
        done
        echo "    也可以直接输入 IP"
    else
        warn "没找到本机的内网 IP（同一 VPC 内网、WireGuard、Tailscale 的地址都算）：确认两台机器在同一内网，或者手动输入"
    fi
    while :; do
        if [ ${#__ips[@]} -eq 1 ]; then
            ask __n "内网入口监听哪个 IP（序号或 IP）" "1"
        else
            ask __n "内网入口监听哪个 IP（序号或 IP）" "${__cur%%:*}"
        fi
        if [[ "$__n" =~ ^[0-9]+$ ]] && [ "$__n" -ge 1 ] && [ "$__n" -le ${#__ips[@]} ]; then
            __ip="${__ips[$((__n - 1))]%% *}"
        else
            __ip="$__n"
        fi
        ask __port "端口（入口机连这个端口，直接回车用默认值）" "$__port"
        if exit_listen_check "$__ip:$__port"; then break; fi
        __port=23456
    done
    printf -v "$__v" '%s' "$__ip:$__port"
}

# wizard_exit：出口模式的配置（只需要内网入口地址）
wizard_exit() {
    local addr cur
    cur="$(env_get EXIT_LISTEN)"
    if [ -n "$cur" ] && exit_listen_check "$cur" >/dev/null 2>&1; then return 0; fi
    [ -t 0 ] || die "出口模式需要在 .env 填写 EXIT_LISTEN=内网IP:端口（或者在终端里运行 bash edge.sh 按提示选择）"
    cat <<'EOF'

================ 内网出口配置 ================
这台机器只给同一内网里的入口机当出口：
  - 不需要域名、证书、Cloudflare，不对公网开放任何端口
  - 只在内网 IP 上开一个 Shadowsocks 2022 入口，入口机凭"通行证"连进来
EOF
    pick_internal addr
    env_set EXIT_LISTEN "$addr"
    log "内网入口：$addr（已保存到 .env）"
}

# ask_role：首次安装时选择角色，结果写入 .env 的 EDGE_ROLE
ask_role() {
    local c
    cat <<'EOF'

================ 这台机器做什么用？================
  1) 完整节点（默认）：手机直接连（REALITY + 伪装站，需要域名和 Cloudflare）
     以后也可以给别的机器当出口，或者把流量转给上游
  2) 纯内网出口：只给同一内网里的入口机当出口，不需要域名，不对公网提供任何服务
EOF
    while :; do
        read -rp "请选择 [1]: " c
        case "${c:-1}" in
            1) env_set EDGE_ROLE edge; return 0 ;;
            2) env_set EDGE_ROLE exit; return 0 ;;
            *) warn "填 1 或 2" ;;
        esac
    done
}

wizard() {
    local f="$EDGE_DIR/.env" sni token email decoy
    [ -f "$f" ] || cp "$EDGE_DIR/.env.example" "$f"
    chmod 600 "$f"

    if [ "$(env_get EDGE_ROLE)" = exit ]; then wizard_exit; return; fi

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
        if [ -z "$(env_get DECOY_THEME)" ]; then  # 旧版 .env：沿用原来的伪装站 forma
            env_set DECOY_THEME forma
            log "伪装站主题 DECOY_THEME=forma（换主题：edge theme）"
        fi
        return 0    # .env 已经填好，不再询问
    fi
    [ -t 0 ] || die ".env 还没填好：请编辑 $f，或者在终端里运行 bash edge.sh 按提示填写"
    ask_role
    if [ "$(env_get EDGE_ROLE)" = exit ]; then wizard_exit; return; fi
    wizard_ask "$f" "$sni" "$token" "$email" "$decoy"
}

# wizard_ask：完整问答（首次安装时）
wizard_ask() {
    local f="$1" sni="$2" token="$3" email="$4" decoy="$5" zone cert rc theme
    is_example "$sni" && sni=""
    is_example "${email#*@}" && email=""

    cat <<'EOF'

================ 首次配置（只问这一次，答案保存在 .env）================
开始前请在 Cloudflare 准备好：
  1. 给伪装站用的域名（如 www.你的域名.com），A/AAAA 记录指向本机，灰云（仅 DNS）
  2. API Token：My Profile → API Tokens → Create Token → Custom token
     权限 Zone → DNS → Edit 和 Zone → Zone → Read，Zone Resources 选你的域名
伪装站应用放在 apps/decoy/，安装时会按你选的主题和端口自动构建并启动
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
    ask_theme theme "$(env_get DECOY_THEME)"

    env_set REALITY_SNI "$sni"
    env_set REALITY_CERT_DOMAIN "$cert"
    env_set CF_Token "$token"
    env_set ACME_EMAIL "$email"
    env_set DECOY_PORT "$decoy"
    env_set DECOY_THEME "$theme"
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

    if [ "$(env_get EDGE_ROLE)" = exit ]; then install_exit; return; fi

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
    log "要和别的机器串联（链式代理）：edge chain"
}

# install_exit：出口模式的安装后半段（不需要证书、nginx、伪装站）
install_exit() {
    local name
    log "[3/5] 证书：出口模式不需要，跳过"

    log "[4/5] 生成密钥和配置"
    bash "$S/02-init.sh"
    load_env

    log "[5/5] 启动 Xray"
    dc up -d xray
    sleep 3

    echo
    bash "$S/check.sh" || warn "有检查项没通过，按上面的提示处理后再运行 edge check"
    echo
    log "安装完成（内网出口模式）。以后只需要记一个命令：edge（打开菜单）"
    relays_load
    if [ ${#RELAY_NAMES[@]} -eq 0 ] && [ -t 0 ]; then
        echo
        if confirm "现在给入口机发一张通行证吗？"; then
            ask name "通行证名字（字母、数字、- _，比如入口机的名字 A01）" "A01"
            bash "$SELF" relay add "$name" || true
        else
            log "以后需要时运行：edge relay add <名字>"
        fi
    fi
}

need_edge_role() {  # 网站相关的命令：出口模式下没有
    [ "$(env_get EDGE_ROLE)" != exit ] \
        || die "这台机器是内网出口模式（EDGE_ROLE=exit），没有 nginx 和网站功能"
}

list_apps() {  # apps/ 下可以发布的应用（不含伪装站 decoy）
    local d n
    for d in "$APPS_DIR"/*/; do
        n="$(basename "$d")"
        if [ "$n" != decoy ] && app_exists "$n"; then echo "$n"; fi
    done
}

cmd_add() {
    need_edge_role
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
    need_edge_role
    load_env
    local name="${1:-}" port fails=0
    if [ "$name" = decoy ]; then
        decoy_up pull
        return
    elif [ -n "$name" ]; then
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

# cmd_theme [主题名]：切换伪装站主题；不带参数时列出主题按序号选择
cmd_theme() {
    need_edge_role
    load_env
    local t="${1:-}" old="$DECOY_THEME"
    if [ -z "$t" ]; then
        if [ ! -t 0 ]; then
            log "伪装站主题：$DECOY_THEME（可选：$(decoy_themes | tr '\n' ' ')；切换：edge theme <主题名>）"
            return 0
        fi
        ask_theme t "$DECOY_THEME"
    fi
    decoy_theme_ok "$t" || die "没有这个主题：$t（可选：$(decoy_themes | tr '\n' ' ')）"
    if [ "$t" = "$old" ]; then
        log "伪装站已经是 $t 主题，不用切换（改了页面后重新构建：edge up decoy）"
        return 0
    fi
    env_set DECOY_THEME "$t"
    DECOY_THEME="$t"
    if ! decoy_up; then
        env_set DECOY_THEME "$old"
        DECOY_THEME="$old"
        decoy_up || true
        die "切换失败，已恢复为 $old（原因见上）"
    fi
    log "伪装站已切换为 $t：https://$REALITY_SNI（浏览器有缓存的话强制刷新一下）"
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
    need_edge_role
    load_env
    local d up app n=0
    printf '  %-36s → 127.0.0.1:%s（伪装站 apps/decoy，主题 %s）\n' "$REALITY_SNI" "$DECOY_PORT" "$DECOY_THEME"
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
    need_edge_role
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
    if [ "$(env_get EDGE_ROLE)" = exit ]; then
        dc pull xray
        dc up -d xray
    else
        dc pull
        dc up -d
        (cmd_up) || true     # 伪装站和所有已发布的应用：拉最新基础镜像并重新构建
    fi
    sleep 3
    bash "$S/check.sh" || true
}

cmd_rotate() {
    load_env
    relays_load
    if [ -t 0 ]; then
        if [ ${#RELAY_NAMES[@]} -gt 0 ]; then
            warn "已发出 ${#RELAY_NAMES[@]} 张通行证（${RELAY_NAMES[*]}）：轮换后它们的链接也会失效，要在每台入口机上重新 edge upstream"
        fi
        confirm "轮换后所有客户端都要重新导入，确定？" || { log "已取消"; return 0; }
    fi
    bash "$S/02-init.sh" --rotate-keys
    if [ ${#RELAY_NAMES[@]} -gt 0 ]; then
        log "通行证的新链接：edge relay show <名字>（${RELAY_NAMES[*]}），再到对应的入口机上 edge upstream '<新链接>'"
    fi
}

# cmd_xray [--raw]：查看 Xray 正在用的配置（容器挂载的就是这个文件），私钥和密码默认打码
cmd_xray() {
    local f="$EDGE_DIR/xray/config.json" started
    [ -f "$f" ] || die "还没有 $f：先运行 edge install"
    echo "== $f =="
    if [ "${1:-}" = --raw ]; then
        cat "$f"
    else
        sed -E -e 's/("privateKey"[[:space:]]*:[[:space:]]*")[^"]*/\1******（已隐藏，edge xray --raw 显示完整）/' \
               -e 's/("(password|pass)"[[:space:]]*:[[:space:]]*")[^"]*/\1******/g' "$f"
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
        nginx) need_edge_role
               tail -n 50 -f "$EDGE_DIR/logs/nginx/access.log" "$EDGE_DIR/logs/nginx/error.log" ;;
        xray)  docker logs -f --tail 100 xray ;;
        *)     die "用法：edge logs [nginx|xray]" ;;
    esac
}

# ================================================================ 链式代理
# 重新生成配置并生效（不打印客户端配置）
apply_quiet() { EDGE_ONECLICK=1 bash "$S/02-init.sh"; }

need_installed() {
    [ -f "$KEYS_FILE" ] || die "还没有安装：先运行 edge install"
}

# ---------------------------------------------------------------- 上游
upstream_status() {
    if [ -z "$UPSTREAM" ]; then
        log "本机没有设置上游：代理流量直接从本机出网"
        echo "  设置上游：edge upstream '<链接>'"
        return 0
    fi
    if upstream_parse "$UPSTREAM"; then
        log "上游：$UP_DESC（本机的代理流量全部经它出去）"
        echo "  链接：$(upstream_mask "$UPSTREAM")"
        [ -z "$UP_WARN" ] || warn "$UP_WARN"
        echo "  测试：edge upstream test    取消：edge upstream off"
    else
        warn ".env 里的 UPSTREAM 看不懂（原因见上）：edge upstream '<链接>' 重新设置，或 edge upstream off 取消"
    fi
}

upstream_set() {  # upstream_set <链接> <force 0|1>
    local link="$1" force="$2" old
    upstream_parse "$link" || die "这个链接用不了（原因见上）"
    if [ "$EDGE_ROLE" = edge ] && [ "$UP_HOST" = "$REALITY_SNI" ]; then
        die "这是本机自己的链接：上游必须是另一台机器"
    fi
    log "上游：$UP_DESC"
    [ -z "$UP_WARN" ] || warn "$UP_WARN"
    log "先测试一下（临时启动一个测试用的 Xray，不影响正在运行的服务）"
    if ! upstream_probe "$link"; then
        if [ "$force" = 1 ]; then
            warn "测试没通过，按 --force 仍然启用"
        elif [ -t 0 ]; then
            confirm "测试没通过，仍然保存并启用吗？（启用后代理流量全部走这个上游，上游不通就上不了网）" \
                || die "已取消，配置没有改动"
        else
            die "测试没通过，配置没有改动（确定要启用：edge upstream '<链接>' --force）"
        fi
    fi
    old="$(env_get UPSTREAM)"
    env_set UPSTREAM "'$link'"
    if ! EDGE_UPSTREAM_WARNED=1 apply_quiet; then
        if [ -n "$old" ]; then env_set UPSTREAM "'$old'"; else env_set UPSTREAM ""; fi
        die "启用失败，已恢复原来的设置（原因见上）"
    fi
    log "已启用上游：本机的代理流量全部经 $UP_ADDR 出去，本机不再直连任何网站"
    echo "  手机等客户端的配置不用改，照常连本机"
}

cmd_upstream() {
    load_env
    need_installed
    local a link="" force=0 old
    for a in "$@"; do
        if [ "$a" = --force ]; then force=1; else link="$a"; fi
    done
    case "$link" in
        "")
            upstream_status ;;
        test)
            [ -n "$UPSTREAM" ] || die "本机没有设置上游"
            log "测试上游（临时启动一个测试用的 Xray，不影响正在运行的服务）"
            upstream_probe "$UPSTREAM" || die "上游测试没通过（原因见上）"
            log "上游测试通过" ;;
        off)
            if [ -z "$UPSTREAM" ]; then log "本机本来就没有设置上游"; return 0; fi
            old="$UPSTREAM"
            env_set UPSTREAM ""
            if ! apply_quiet; then env_set UPSTREAM "'$old'"; die "取消失败，已恢复原来的设置（原因见上）"; fi
            log "已取消上游：代理流量恢复直接从本机出网" ;;
        *)
            upstream_set "$link" "$force" ;;
    esac
}

# ---------------------------------------------------------------- 通行证
relays_backup() {
    RELAYS_BAK="$(mktemp)" RELAYS_HAD=0
    if [ -f "$RELAYS_FILE" ]; then cp -p "$RELAYS_FILE" "$RELAYS_BAK"; RELAYS_HAD=1; fi
}

relays_restore() {
    if [ "$RELAYS_HAD" = 1 ]; then cat "$RELAYS_BAK" >"$RELAYS_FILE"; else rm -f "$RELAYS_FILE"; fi
    rm -f "$RELAYS_BAK"
}

relay_print() {  # relay_print <名字>：打印这张通行证的链接
    local name="$1" i
    relays_load
    i="$(relay_index "$name")" || die "没有叫 $name 的通行证（edge relay list 查看）"
    load_keys
    echo
    echo "================ 通行证：$name ================"
    if [ -n "$EXIT_LISTEN" ] && exit_listen_check "$EXIT_LISTEN"; then
        echo "【和本机在同一内网的入口机用这条】走内网：更快，通常也不计公网流量"
        ss_link "${RELAY_SSKEYS[$i]}" "relay-$name"; echo
        echo
    fi
    if [ "$EDGE_ROLE" = edge ]; then
        echo "【公网上的入口机用这条】"
        vless_link "${RELAY_UUIDS[$i]}" "relay-$name"; echo
        echo
    fi
    echo "到入口机上运行（链接两边要加单引号）："
    echo "  edge upstream '<上面的链接>'"
    echo "================================================"
    echo "链接相当于密码，只发给对应的入口机；不用了在本机运行 edge relay remove $name"
    if [ "$EDGE_ROLE" = edge ] && [ -z "$EXIT_LISTEN" ]; then
        echo "入口机和本机在同一内网？开启内网入口会更快：edge internal"
    fi
}

relay_add() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge relay add <名字>"
        ask name "通行证名字（字母、数字、- _，比如入口机的名字 A01）"
    fi
    [[ "$name" =~ $RELAY_NAME_RE ]] || die "名字只能用字母、数字、- 和 _，最长 32 个字符：$name"
    relays_load
    if relay_index "$name" >/dev/null; then
        die "已经有叫 $name 的通行证了（edge relay show $name 再次显示链接）"
    fi
    relays_backup
    if [ ! -f "$RELAYS_FILE" ]; then
        printf '# 中转通行证，由 edge relay add / remove 维护，不要改格式\n# 名字 UUID SS密钥 发放日期\n' >"$RELAYS_FILE"
    fi
    chmod 600 "$RELAYS_FILE"
    printf '%s %s %s %s\n' "$name" "$(gen_uuid)" "$(gen_ss_key)" "$(date +%F)" >>"$RELAYS_FILE"
    log "已生成通行证 $name，重新生成配置"
    if ! apply_quiet; then
        relays_restore
        die "发放失败，已撤销（原因见上）"
    fi
    rm -f "$RELAYS_BAK"
    relay_print "$name"
}

relay_list() {
    local i kinds=""
    relays_load
    if [ ${#RELAY_NAMES[@]} -eq 0 ]; then
        log "还没有发过通行证"
        echo "  发一张：edge relay add <名字>"
        return 0
    fi
    if [ -n "$EXIT_LISTEN" ]; then kinds="内网"; fi
    if [ "$EDGE_ROLE" = edge ]; then kinds="${kinds:+$kinds + }公网"; fi
    log "已发出 ${#RELAY_NAMES[@]} 张通行证（每张都有：${kinds:-无可用入口} 链接）"
    for i in "${!RELAY_NAMES[@]}"; do
        printf '  %-24s 发放于 %s\n' "${RELAY_NAMES[$i]}" "${RELAY_DATES[$i]}"
    done
    echo "  显示链接：edge relay show <名字>    吊销：edge relay remove <名字>"
}

relay_remove() {
    local name="${1:-}" n i tmp
    relays_load
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge relay remove <名字>"
        [ ${#RELAY_NAMES[@]} -gt 0 ] || { log "还没有发过通行证"; return 0; }
        for i in "${!RELAY_NAMES[@]}"; do printf '  %d) %s\n' $((i + 1)) "${RELAY_NAMES[$i]}"; done
        read -rp "吊销哪张（序号）: " n
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#RELAY_NAMES[@]} ] || die "序号不对"
        name="${RELAY_NAMES[$((n - 1))]}"
        confirm "确认吊销 $name？用它的入口机会立刻连不上" || { log "已取消"; return 0; }
    fi
    relay_index "$name" >/dev/null || die "没有叫 $name 的通行证（edge relay list 查看）"
    relays_backup
    tmp="$(mktemp)"
    awk -v n="$name" '$1 != n' "$RELAYS_FILE" >"$tmp"
    cat "$tmp" >"$RELAYS_FILE"
    rm -f "$tmp"
    if ! apply_quiet; then
        relays_restore
        die "吊销失败，已恢复（原因见上）"
    fi
    rm -f "$RELAYS_BAK"
    log "已吊销 $name：用它的入口机现在连不上本机了，其他客户端不受影响"
}

cmd_relay() {
    load_env
    need_installed
    local sub="${1:-list}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        add)       relay_add "$@" ;;
        list|ls)   relay_list ;;
        show)      [ -n "${1:-}" ] || die "用法：edge relay show <名字>"; relay_print "$1" ;;
        remove|rm) relay_remove "$@" ;;
        *)         die "用法：edge relay add|list|show|remove [名字]" ;;
    esac
}

# ---------------------------------------------------------------- 内网入口
cmd_internal() {
    load_env
    need_installed
    local v="${1:-}" old
    if [ "$v" = set ] || { [ -z "$v" ] && [ -t 0 ]; }; then
        if [ -z "$v" ]; then
            if [ -n "$EXIT_LISTEN" ]; then log "内网入口：$EXIT_LISTEN"; else log "内网入口：未开启"; fi
            confirm "要开启 / 修改内网入口吗？" || return 0
        fi
        pick_internal v
    elif [ -z "$v" ]; then
        if [ -n "$EXIT_LISTEN" ]; then log "内网入口：$EXIT_LISTEN"; else log "内网入口：未开启"; fi
        return 0
    fi

    old="$EXIT_LISTEN"
    if [ "$v" = off ]; then
        [ "$EDGE_ROLE" != exit ] || die "出口模式（EDGE_ROLE=exit）必须有内网入口：只能修改，不能关闭"
        if [ -z "$old" ]; then log "内网入口本来就没开"; return 0; fi
        env_set EXIT_LISTEN ""
    else
        exit_listen_check "$v" || die "这个地址不能用（原因见上）"
        env_set EXIT_LISTEN "$v"
    fi
    if ! apply_quiet; then
        env_set EXIT_LISTEN "$old"
        die "设置失败，已恢复原来的设置（原因见上）"
    fi
    if [ "$v" = off ]; then
        log "已关闭内网入口：通行证的内网链接失效，公网链接不受影响"
        return 0
    fi
    log "内网入口：$v"
    warn "记得在云厂商的安全组 / 防火墙里放行 ${v##*:}/tcp 和 ${v##*:}/udp，来源只填入口机的内网 IP 或内网网段"
    relays_load
    if [ ${#RELAY_NAMES[@]} -eq 0 ]; then
        log "下一步：给入口机发通行证 edge relay add <名字>"
    else
        log "已有的 ${#RELAY_NAMES[@]} 张通行证也能走内网了：edge relay show <名字> 显示内网链接"
    fi
}

# ---------------------------------------------------------------- 链式代理菜单
chain_header() {
    local role up="本机直接出网" internal="未开启"
    load_env
    relays_load
    if [ "$EDGE_ROLE" = exit ]; then role="纯内网出口"; else role="完整节点"; fi
    if [ -n "$UPSTREAM" ]; then
        if upstream_parse "$UPSTREAM" 2>/dev/null; then up="经上游 $UP_DESC"; else up="UPSTREAM 链接有问题"; fi
    fi
    [ -z "$EXIT_LISTEN" ] || internal="$EXIT_LISTEN"
    cat <<EOF

================ 链式代理 ================
  本机角色 : $role
  出口     : $up
  内网入口 : $internal
  通行证   : ${#RELAY_NAMES[@]} 张
EOF
}

menu_chain() {
    local c link name
    while :; do
        (chain_header) || true
        cat <<'EOF'
  ---- 本机当入口：把流量转给另一台机器出去 ----
  1) 设置上游（粘贴链接，先测试再启用）
  2) 测试上游
  3) 取消上游，恢复直接出网
  ---- 本机当出口：让别的机器把流量转过来 ----
  4) 发通行证（给入口机用）
  5) 查看通行证 / 再次显示链接
  6) 吊销通行证
  7) 开启 / 修改内网入口（同一内网的入口机用）
  8) 关闭内网入口
  0) 返回
EOF
        read -rp "请选择: " c || return 0
        echo
        case "$c" in
            1) echo "支持 vless:// ss:// socks5:// http:// https:// 链接"
               echo "上游也是本项目搭的：在那台机器上运行 edge relay add <名字>，复制它打印的链接"
               read -rp "粘贴上游链接: " link
               [ -n "$link" ] && bash "$SELF" upstream "$link" ;;
            2) bash "$SELF" upstream test ;;
            3) confirm "取消后代理流量直接从本机出网，确定？" && bash "$SELF" upstream off ;;
            4) read -rp "通行证名字（字母、数字、- _，比如入口机的名字 A01）: " name
               [ -n "$name" ] && bash "$SELF" relay add "$name" ;;
            5) bash "$SELF" relay list
               read -rp "显示哪张的链接（输入名字，留空跳过）: " name
               [ -n "$name" ] && bash "$SELF" relay show "$name" ;;
            6) bash "$SELF" relay remove ;;
            7) bash "$SELF" internal set ;;
            8) confirm "关闭后入口机就不能走内网连本机了，确定？" && bash "$SELF" internal off ;;
            0|q|"") return 0 ;;
            *) warn "没有这个选项" ;;
        esac || true
    done
}

# ---------------------------------------------------------------- 主菜单
menu_edge() {
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
  7) 切换伪装站主题
  8) 改了 .env 后重新生成配置
  9) 更新所有镜像
 10) 重新安装 / 修复
 11) 轮换 Xray 密钥
 12) 查看 Xray 配置
 13) 链式代理（上游 / 通行证 / 内网入口）
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
            7) bash "$SELF" theme ;;
            8) bash "$SELF" apply ;;
            9) bash "$SELF" update ;;
            10) bash "$SELF" install ;;
            11) bash "$SELF" rotate-keys ;;
            12) bash "$SELF" xray ;;
            13) menu_chain ;;
            0|q|"") exit 0 ;;
            *) warn "没有这个选项" ;;
        esac || true
    done
}

menu_exit() {
    local c name
    while :; do
        cat <<'EOF'

================ vps-edge（内网出口）================
  1) 健康检查
  2) 链式代理（通行证 / 内网入口 / 上游）
  3) 发通行证（给入口机用）
  4) 查看通行证 / 再次显示链接
  5) 改了 .env 后重新生成配置
  6) 更新 Xray 镜像
  7) 重新安装 / 修复
  8) 轮换密钥（所有通行证链接都会失效）
  9) 查看 Xray 配置
 10) 查看 Xray 日志
  0) 退出
EOF
        read -rp "请选择: " c || exit 0
        echo
        case "$c" in
            1) bash "$SELF" check ;;
            2) menu_chain ;;
            3) read -rp "通行证名字（字母、数字、- _，比如入口机的名字 A01）: " name
               [ -n "$name" ] && bash "$SELF" relay add "$name" ;;
            4) bash "$SELF" relay list
               read -rp "显示哪张的链接（输入名字，留空跳过）: " name
               [ -n "$name" ] && bash "$SELF" relay show "$name" ;;
            5) bash "$SELF" apply ;;
            6) bash "$SELF" update ;;
            7) bash "$SELF" install ;;
            8) bash "$SELF" rotate-keys ;;
            9) bash "$SELF" xray ;;
            10) bash "$SELF" logs xray ;;
            0|q|"") exit 0 ;;
            *) warn "没有这个选项" ;;
        esac || true
    done
}

menu() {
    if [ "$(env_get EDGE_ROLE)" = exit ]; then menu_exit; else menu_edge; fi
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
    theme)       cmd_theme "$@" ;;
    remove|rm)   cmd_remove "$@" ;;
    sites|ls)    cmd_sites ;;
    check)       bash "$S/check.sh" ;;
    client)      bash "$S/show-client.sh" ;;
    apply)       bash "$S/02-init.sh" ;;
    update)      cmd_update ;;
    rotate-keys) cmd_rotate ;;
    logs)        cmd_logs "$@" ;;
    xray)        cmd_xray "$@" ;;
    chain)       menu_chain ;;
    upstream)    cmd_upstream "$@" ;;
    relay)       cmd_relay "$@" ;;
    internal)    cmd_internal "$@" ;;
    *)           usage; exit 1 ;;
esac
