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
#   ---- 账号和出口（多账号、链式代理，详见 README 第 8 节）----
#   每个账号一条链接，各走各的出口：direct = 本机直接出网，或者另一台机器 / 第三方代理
#   edge chain                                  打开账号 / 出口菜单
#   edge user add <名字> [--exit <出口>]         新建账号，打印链接（手机用，或者给入口机当出口）
#   edge user list                              查看账号和各自的出口
#   edge user show <名字>                        再次显示链接
#   edge user set-exit <名字> <出口>              修改账号的出口（链接不变）
#   edge user test <名字>                        测试：流量是不是从该走的出口出去
#   edge user remove <名字>                      删除账号（用它的设备立刻连不上，其他不受影响）
#   edge exit add <名字> '<链接>' [--force]       添加出口：先测试，通过才保存
#   edge exit update <名字> '<链接>' [--force]    更换出口的链接
#   edge exit list | test <名字> | remove <名字>   查看 / 测试 / 删除出口（还有账号在用时不能删）
#   edge upstream '<链接>' | test | off          旧命令：所有账号都走出口 upstream / 测试 / 取消
#   edge relay ...                              旧命令：同 edge user
#   edge internal                               查看 / 交互设置内网入口
#   edge internal <内网IP:端口>                  开启或修改内网入口（给同一内网的入口机用）
#   edge internal off                           关闭内网入口
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
  - 只在内网 IP 上开一个 Shadowsocks 2022 入口，入口机凭本机发的账号连进来
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
    log "多账号、和别的机器串联（链式代理）：edge chain"
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
    users_load
    if [ ${#USER_NAMES[@]} -eq 0 ] && [ -t 0 ]; then
        echo
        if confirm "现在给入口机建一个账号吗？"; then
            ask name "账号名字（字母、数字、- _，比如入口机的名字 A01）" "A01"
            bash "$SELF" user add "$name" || true
        else
            log "以后需要时运行：edge user add <名字>"
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
    need_installed
    users_load
    if [ -t 0 ]; then
        warn "轮换会换掉 REALITY 密钥、内网入口密钥和所有账号的 UUID：${#USER_NAMES[@]} 个账号（${USER_NAMES[*]}）的链接全部失效"
        warn "给入口机当出口的账号，要到对应的入口机上 edge exit update <出口名> '<新链接>'"
        confirm "轮换后所有客户端都要重新导入，确定？" || { log "已取消"; return 0; }
    fi
    bash "$S/02-init.sh" --rotate-keys
    log "新链接：edge client（default），其他账号 edge user show <名字>"
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

# ================================================================ 账号 / 出口 / 内网入口
# 数据和路由规则见 scripts/lib.sh 的"账号 / 出口 / 内网入口"一节和 xray_egress
#
# 重新生成配置并生效（不打印客户端配置；出口的明文提醒在添加出口时已经说过）
apply_quiet() { EDGE_ONECLICK=1 EDGE_EXIT_WARNED=1 bash "$S/02-init.sh"; }

need_installed() {
    [ -f "$KEYS_FILE" ] || die "还没有安装：先运行 edge install"
}

# 改账号 / 出口之前先备份；重新生成配置失败时恢复原样（02-init.sh 自己会恢复 config.json）
chain_backup() {
    local f
    CHAIN_BAK="$(mktemp -d)"
    for f in "$USERS_FILE" "$EXITS_FILE"; do
        if [ -f "$f" ]; then cp -p "$f" "$CHAIN_BAK/"; fi
    done
}

chain_restore() {
    local f b
    for f in "$USERS_FILE" "$EXITS_FILE"; do
        b="$CHAIN_BAK/$(basename "$f")"
        if [ -f "$b" ]; then cat "$b" >"$f"; else rm -f "$f"; fi
    done
    rm -rf "$CHAIN_BAK"
}

chain_apply() {  # chain_apply <失败时的说明>：重新生成配置并生效；失败就恢复账号和出口，然后退出
    if ! apply_quiet; then
        chain_restore
        die "$1，已恢复原来的设置（原因见上）"
    fi
    rm -rf "$CHAIN_BAK"
}

link_name() {  # link_name <账号>：分享链接里显示的节点名
    if [ "$1" = default ]; then printf '%s' "$NODE_NAME"; else printf '%s-%s' "$NODE_NAME" "$1"; fi
}

users_using() {  # users_using <出口>：走这个出口的账号名，空格分隔（先 users_load）
    local i out=""
    for i in "${!USER_NAMES[@]}"; do
        if [ "${USER_EXITS[$i]}" = "$1" ]; then out+="${out:+ }${USER_NAMES[$i]}"; fi
    done
    printf '%s' "$out"
}

suggest_exit() {  # 新账号默认的出口：和 default 一样；没有 default 时和第一个账号一样；都没有就 direct
    local i
    if i="$(user_index default)"; then
        echo "${USER_EXITS[$i]}"
    elif [ ${#USER_EXITS[@]} -gt 0 ]; then
        echo "${USER_EXITS[0]}"
    else
        echo direct
    fi
}

# pick_user <变量名> <提示>：列出账号，按序号选
pick_user() {
    local __v="$1" __p="$2" __i __n
    [ ${#USER_NAMES[@]} -gt 0 ] || die "还没有账号：edge user add <名字>"
    for __i in "${!USER_NAMES[@]}"; do
        printf '  %d) %-20s → %s\n' $((__i + 1)) "${USER_NAMES[$__i]}" "${USER_EXITS[$__i]}"
    done
    read -rp "$__p（序号）: " __n
    [[ "$__n" =~ ^[0-9]+$ ]] && [ "$__n" -ge 1 ] && [ "$__n" -le ${#USER_NAMES[@]} ] || die "序号不对"
    printf -v "$__v" '%s' "${USER_NAMES[$((__n - 1))]}"
}

# pick_exit_name <变量名> <提示>：列出出口（不含 direct），按序号选
pick_exit_name() {
    local __v="$1" __p="$2" __i __n
    [ ${#OUT_NAMES[@]} -gt 0 ] || die "还没有出口：edge exit add <名字> '<链接>'"
    for __i in "${!OUT_NAMES[@]}"; do
        printf '  %d) %-16s %s\n' $((__i + 1)) "${OUT_NAMES[$__i]}" "$(exit_desc "${OUT_NAMES[$__i]}")"
    done
    read -rp "$__p（序号）: " __n
    [[ "$__n" =~ ^[0-9]+$ ]] && [ "$__n" -ge 1 ] && [ "$__n" -le ${#OUT_NAMES[@]} ] || die "序号不对"
    printf -v "$__v" '%s' "${OUT_NAMES[$((__n - 1))]}"
}

# pick_out <变量名> <提示> [默认]：列出 direct 和所有出口，按序号选
pick_out() {
    local __v="$1" __p="$2" __def="${3:-direct}" __list __i __n __d=1 __mark
    __list=(direct "${OUT_NAMES[@]}")
    for __i in "${!__list[@]}"; do
        __mark=""
        if [ "${__list[$__i]}" = "$__def" ]; then __mark="（默认）"; __d=$((__i + 1)); fi
        printf '  %d) %-16s %s%s\n' $((__i + 1)) "${__list[$__i]}" "$(exit_desc "${__list[$__i]}")" "$__mark"
    done
    while :; do
        read -rp "$__p（序号）[$__d]: " __n
        __n="${__n:-$__d}"
        if [[ "$__n" =~ ^[0-9]+$ ]] && [ "$__n" -ge 1 ] && [ "$__n" -le ${#__list[@]} ]; then break; fi
        warn "填 1-${#__list[@]} 之间的序号"
    done
    printf -v "$__v" '%s' "${__list[$((__n - 1))]}"
}

# ---------------------------------------------------------------- 账号
user_print() {  # user_print <名字>：打印账号的链接
    local name="$1" i out
    users_load
    exits_load
    i="$(user_index "$name")" || die "没有叫 $name 的账号（edge user list 查看）"
    load_keys
    out="${USER_EXITS[$i]}"
    echo
    echo "================ 账号：$name ================"
    echo "出口：$out（$(exit_desc "$out")）"
    if [ "$EDGE_ROLE" = edge ]; then
        echo
        echo "【公网链接】导入手机、电脑的客户端；或者给公网上的入口机当出口"
        vless_link "${USER_UUIDS[$i]}" "$(link_name "$name")"; echo
    fi
    if [ "$name" != default ] && [ -n "$EXIT_LISTEN" ] && exit_listen_check "$EXIT_LISTEN"; then
        echo
        echo "【内网链接】给和本机在同一内网的入口机当出口：更快，通常也不计公网流量"
        ss_link "${USER_SSKEYS[$i]}" "$(link_name "$name")"; echo
    fi
    if [ "$name" != default ]; then
        echo
        echo "给入口机当出口时，到入口机上运行（链接两边要加单引号）："
        echo "  edge exit add <出口名> '<上面的链接>'"
    fi
    echo "================================================"
    echo "链接相当于密码，只发给要用的人或机器；不用了：edge user remove $name"
    if [ "$EDGE_ROLE" = edge ] && [ -z "$EXIT_LISTEN" ] && [ "$name" != default ]; then
        echo "入口机和本机在同一内网？开启内网入口会更快：edge internal"
    fi
}

user_add() {  # user_add <名字> [--exit <出口>]
    local name="" out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --exit)   [ $# -ge 2 ] || die "--exit 后面要跟出口名（direct 或 edge exit list 里的名字）"
                      out="$2"; shift 2 ;;
            --exit=*) out="${1#--exit=}"; shift ;;
            -*)       die "不认识的参数：$1（用法：edge user add <名字> [--exit <出口>]）" ;;
            *)        name="$1"; shift ;;
        esac
    done
    users_load
    exits_load
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge user add <名字> [--exit <出口>]"
        ask name "账号名字（字母、数字、- _；比如 phone2、work，给入口机用就写入口机的名字）"
    fi
    [[ "$name" =~ $NAME_RE ]] || die "名字只能用字母、数字、- 和 _，最长 32 个字符：$name"
    if [ "$name" = default ] && [ "$EDGE_ROLE" = exit ]; then
        die "default 是完整节点给手机用的保留名字，换一个"
    fi
    if user_index "$name" >/dev/null; then die "已经有叫 $name 的账号了（edge user show $name 显示链接）"; fi
    if [ -z "$out" ]; then
        if [ -t 0 ]; then
            echo
            echo "  $name 的流量从哪个出口出去："
            pick_out out "选择出口" "$(suggest_exit)"
        elif [ ${#OUT_NAMES[@]} -eq 0 ]; then
            out=direct
        else
            die "本机有出口（${OUT_NAMES[*]}）：请用 --exit 指定 $name 走哪个出口（direct 或出口名），免得走错"
        fi
    fi
    exit_known "$out" || die "没有叫 $out 的出口（edge exit list 查看；本机直接出网填 direct）"
    chain_backup
    USER_NAMES+=("$name") USER_UUIDS+=("$(gen_uuid)") USER_SSKEYS+=("$(gen_ss_key)")
    USER_DATES+=("$(date +%F)") USER_EXITS+=("$out")
    users_save
    log "已创建账号 $name（出口：$out），重新生成配置"
    chain_apply "创建失败"
    user_print "$name"
}

user_list() {
    local i
    users_load
    exits_load
    if [ ${#USER_NAMES[@]} -eq 0 ]; then
        log "还没有账号"
        echo "  创建：edge user add <名字>"
        return 0
    fi
    log "共 ${#USER_NAMES[@]} 个账号（名字 → 出口）"
    for i in "${!USER_NAMES[@]}"; do
        printf '  %-20s → %-14s %s（创建于 %s）\n' "${USER_NAMES[$i]}" "${USER_EXITS[$i]}" \
            "$(exit_desc "${USER_EXITS[$i]}")" "${USER_DATES[$i]}"
    done
    echo "  显示链接：edge user show <名字>    改出口：edge user set-exit <名字> <出口>"
    echo "  测试：    edge user test <名字>    删除：  edge user remove <名字>"
}

user_set_exit() {  # user_set_exit <名字> <出口>
    local name="${1:-}" out="${2:-}" i cur
    users_load
    exits_load
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge user set-exit <名字> <出口>"
        pick_user name "修改哪个账号"
    fi
    i="$(user_index "$name")" || die "没有叫 $name 的账号（edge user list 查看）"
    cur="${USER_EXITS[$i]}"
    if [ -z "$out" ]; then
        [ -t 0 ] || die "用法：edge user set-exit <名字> <出口>"
        echo
        echo "  $name 现在走：$cur（$(exit_desc "$cur")）"
        pick_out out "改成哪个出口" "$cur"
    fi
    exit_known "$out" || die "没有叫 $out 的出口（edge exit list 查看；本机直接出网填 direct）"
    if [ "$out" = "$cur" ]; then log "$name 已经走 $out，不用改"; return 0; fi
    if [ "$out" = direct ] && [ -t 0 ]; then
        confirm "改成 direct 后，$name 的流量从本机直接出网，确定？" || { log "已取消"; return 0; }
    fi
    chain_backup
    USER_EXITS[$i]="$out"
    users_save
    chain_apply "修改失败"
    log "账号 $name 的出口：$cur → $out（$(exit_desc "$out")）"
    echo "  链接不变，客户端不用重新导入；验证：edge user test $name"
}

user_test() {  # user_test <名字>：模拟客户端用这个账号连本机，看流量是不是从该走的出口出去
    local name="${1:-}" i out link
    users_load
    exits_load
    load_keys
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge user test <名字>"
        pick_user name "测试哪个账号"
    fi
    i="$(user_index "$name")" || die "没有叫 $name 的账号（edge user list 查看）"
    out="${USER_EXITS[$i]}"
    if [ "$EDGE_ROLE" = edge ]; then
        link="$(vless_link "${USER_UUIDS[$i]}" test)"
    elif [ "$name" != default ] && [ -n "$EXIT_LISTEN" ] && exit_listen_check "$EXIT_LISTEN"; then
        link="$(ss_link "${USER_SSKEYS[$i]}" test)"
    else
        die "$name 没有可以测试的入口"
    fi
    log "测试账号 $name：临时起一个客户端用它的链接连本机，看流量从哪出去（应该走 $out：$(exit_desc "$out")）"
    if [ "$out" = direct ]; then upstream_probe "$link" local; else upstream_probe "$link"; fi \
        || die "账号 $name 测试没通过（原因见上）"
    log "账号 $name 测试通过"
}

user_remove() {  # user_remove <名字>
    local name="${1:-}" i
    users_load
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge user remove <名字>"
        [ ${#USER_NAMES[@]} -gt 0 ] || { log "还没有账号"; return 0; }
        pick_user name "删除哪个账号"
        confirm "确认删除 $name？用它的设备、入口机会立刻连不上" || { log "已取消"; return 0; }
    fi
    i="$(user_index "$name")" || die "没有叫 $name 的账号（edge user list 查看）"
    if [ "$name" = default ] && [ "$EDGE_ROLE" = edge ]; then
        die "default 是本机自带的账号（edge client 显示的就是它），不能删除；想让旧链接失效用 edge rotate-keys（所有账号的链接都会换）"
    fi
    chain_backup
    unset "USER_NAMES[$i]" "USER_UUIDS[$i]" "USER_SSKEYS[$i]" "USER_DATES[$i]" "USER_EXITS[$i]"
    users_save
    chain_apply "删除失败"
    log "已删除账号 $name：用它的设备 / 入口机现在连不上本机了，其他账号不受影响"
}

cmd_user() {
    load_env
    need_installed
    local sub="${1:-list}" name
    [ $# -gt 0 ] && shift
    case "$sub" in
        add)       user_add "$@" ;;
        list|ls)   user_list ;;
        show)      name="${1:-}"
                   if [ -z "$name" ]; then
                       [ -t 0 ] || die "用法：edge user show <名字>"
                       users_load
                       pick_user name "显示哪个账号的链接"
                   fi
                   user_print "$name" ;;
        set-exit)  user_set_exit "$@" ;;
        test)      user_test "$@" ;;
        remove|rm) user_remove "$@" ;;
        *)         die "用法：edge user add|list|show|set-exit|test|remove [名字]" ;;
    esac
}

# ---------------------------------------------------------------- 出口
# exit_check <名字> <链接> <force 0|1>：添加 / 更换出口前检查链接，并实际测试一次
exit_check() {
    local name="$1" link="$2" force="$3"
    [[ "$name" =~ $NAME_RE ]] || die "出口名只能用字母、数字、- 和 _，最长 32 个字符：$name"
    case "$name" in direct|block) die "$name 是保留名字，换一个" ;; esac
    upstream_parse "$link" || die "这个链接用不了（原因见上）"
    if [ "$EDGE_ROLE" = edge ] && [ "$UP_HOST" = "$REALITY_SNI" ]; then
        die "这是本机自己的链接：出口必须是另一台机器"
    fi
    if [ -n "$EXIT_LISTEN" ] && exit_listen_check "$EXIT_LISTEN" 2>/dev/null && [ "$UP_HOST" = "$EXIT_IP" ]; then
        die "这是本机内网入口的链接：出口必须是另一台机器"
    fi
    log "出口 $name：$UP_DESC"
    [ -z "$UP_WARN" ] || warn "$UP_WARN"
    log "先测试一下（临时启动一个测试用的 Xray，不影响正在运行的服务）"
    if ! upstream_probe "$link"; then
        if [ "$force" = 1 ]; then
            warn "测试没通过，按 --force 仍然保存"
        elif [ -t 0 ]; then
            confirm "测试没通过，仍然保存吗？（走这个出口的账号在它恢复之前都上不了网）" \
                || die "已取消，配置没有改动"
        else
            die "测试没通过，配置没有改动（确定要保存：加上 --force）"
        fi
    fi
}

# exit_args <参数...>：解析 "<名字> '<链接>' [--force]"，结果放在 EA_NAME / EA_LINK / EA_FORCE
exit_args() {
    local a
    EA_NAME="" EA_LINK="" EA_FORCE=0
    for a in "$@"; do
        if [ "$a" = --force ]; then EA_FORCE=1
        elif [ -z "$EA_NAME" ]; then EA_NAME="$a"
        elif [ -z "$EA_LINK" ]; then EA_LINK="$a"
        else die "参数太多：链接两边要加单引号"
        fi
    done
}

ask_link() {  # ask_link <变量名>
    echo "支持 vless:// ss:// socks5:// http:// https:// 链接"
    echo "另一台机器也是本项目搭的：在那台机器上运行 edge user add <名字>，复制它打印的链接"
    ask "$1" "粘贴链接"
}

exit_add() {  # exit_add <名字> '<链接>' [--force]
    local name link
    exit_args "$@"
    name="$EA_NAME" link="$EA_LINK"
    exits_load
    if [ -z "$name" ] || [ -z "$link" ]; then
        [ -t 0 ] || die "用法：edge exit add <名字> '<链接>' [--force]"
        [ -n "$name" ] || ask name "出口名字（字母、数字、- _，比如 us-b、jp-c）"
        [ -n "$link" ] || ask_link link
    fi
    if out_index "$name" >/dev/null; then die "已经有叫 $name 的出口了（换链接：edge exit update $name '<链接>'）"; fi
    exit_check "$name" "$link" "$EA_FORCE"
    # 还没有账号走它，Xray 配置不变，不用重启
    OUT_NAMES+=("$name") OUT_LINKS+=("$link")
    exits_save
    log "已添加出口 $name：$UP_DESC"
    echo "  让账号走它：edge user add <名字> --exit $name，或者 edge user set-exit <账号> $name"
}

exit_update() {  # exit_update <名字> '<链接>' [--force]：更换出口的链接，账号不用改
    local name link i
    exit_args "$@"
    name="$EA_NAME" link="$EA_LINK"
    exits_load
    users_load
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge exit update <名字> '<链接>' [--force]"
        pick_exit_name name "更换哪个出口的链接"
    fi
    i="$(out_index "$name")" || die "没有叫 $name 的出口（edge exit list 查看）"
    if [ -z "$link" ]; then
        [ -t 0 ] || die "用法：edge exit update <名字> '<链接>' [--force]"
        ask_link link
    fi
    exit_check "$name" "$link" "$EA_FORCE"
    chain_backup
    OUT_LINKS[$i]="$link"
    exits_save
    if [ -n "$(users_using "$name")" ]; then
        chain_apply "更换失败"
    else
        rm -rf "$CHAIN_BAK"
    fi
    log "出口 $name 已更换为：$UP_DESC"
    echo "  走它的账号：$(users_using "$name")"
}

exit_list() {
    local i users
    exits_load
    users_load
    users="$(users_using direct)"
    log "出口"
    echo "  direct：本机直接出网（内置）"
    echo "      账号：${users:-（没有）}"
    for i in "${!OUT_NAMES[@]}"; do
        users="$(users_using "${OUT_NAMES[$i]}")"
        echo "  ${OUT_NAMES[$i]}：$(exit_desc "${OUT_NAMES[$i]}")"
        echo "      链接：$(upstream_mask "${OUT_LINKS[$i]}")"
        echo "      账号：${users:-（没有账号在用，不会放进 Xray 配置）}"
    done
    if [ ${#OUT_NAMES[@]} -eq 0 ]; then
        echo "  还没有别的出口：edge exit add <名字> '<链接>'"
    else
        echo "  测试：edge exit test <名字>    换链接：edge exit update <名字> '<链接>'    删除：edge exit remove <名字>"
    fi
}

exit_test() {  # exit_test <名字>
    local name="${1:-}" i
    exits_load
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge exit test <名字>"
        pick_exit_name name "测试哪个出口"
    fi
    [ "$name" != direct ] || die "direct 就是本机直接出网；想测某个账号用 edge user test <名字>"
    i="$(out_index "$name")" || die "没有叫 $name 的出口（edge exit list 查看）"
    log "测试出口 $name（临时启动一个测试用的 Xray，不影响正在运行的服务）"
    upstream_probe "${OUT_LINKS[$i]}" || die "出口 $name 测试没通过（原因见上）"
    log "出口 $name 测试通过"
}

exit_remove() {  # exit_remove <名字>：还有账号在用时拒绝删除
    local name="${1:-}" i users
    exits_load
    users_load
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge exit remove <名字>"
        [ ${#OUT_NAMES[@]} -gt 0 ] || { log "还没有出口"; return 0; }
        pick_exit_name name "删除哪个出口"
    fi
    [ "$name" != direct ] || die "direct 是内置出口，不能删除"
    i="$(out_index "$name")" || die "没有叫 $name 的出口（edge exit list 查看）"
    users="$(users_using "$name")"
    if [ -n "$users" ]; then
        die "还有账号在用出口 $name：$users。先用 edge user set-exit 把它们改到别的出口，或者 edge user remove 删掉"
    fi
    if [ -t 0 ]; then confirm "确认删除出口 $name？" || { log "已取消"; return 0; }; fi
    # 没有账号走它，它本来就不在 Xray 配置里，不用重启
    unset "OUT_NAMES[$i]" "OUT_LINKS[$i]"
    exits_save
    log "已删除出口 $name"
}

cmd_exit() {
    load_env
    need_installed
    local sub="${1:-list}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        add)       exit_add "$@" ;;
        update)    exit_update "$@" ;;
        list|ls)   exit_list ;;
        test)      exit_test "$@" ;;
        remove|rm) exit_remove "$@" ;;
        *)         die "用法：edge exit add|update|list|test|remove [名字] ['<链接>']" ;;
    esac
}

# ---------------------------------------------------------------- 旧命令：edge upstream / edge relay
# edge upstream 保留旧版的意思："本机所有账号都走这个上游"。出口名固定叫 upstream
cmd_upstream() {
    load_env
    need_installed
    local a link="" force=0 i moved others=""
    for a in "$@"; do
        if [ "$a" = --force ]; then force=1; else link="$a"; fi
    done
    users_load
    exits_load
    case "$link" in
        "")
            if i="$(out_index upstream)"; then
                log "出口 upstream：$(exit_desc upstream)"
                echo "  链接：$(upstream_mask "${OUT_LINKS[$i]}")"
                echo "  走它的账号：$(users_using upstream)"
                echo "  测试：edge upstream test    取消：edge upstream off"
            else
                log "没有出口 upstream：edge upstream '<链接>' 设置后，所有账号都走它"
            fi
            echo "  每个账号单独指定出口：edge exit / edge user（或者 edge chain 打开菜单）" ;;
        test)
            out_index upstream >/dev/null || die "没有出口 upstream"
            exit_test upstream ;;
        off)
            out_index upstream >/dev/null || { log "没有出口 upstream，不用取消"; return 0; }
            moved="$(users_using upstream)"
            if [ -n "$moved" ] && [ -t 0 ]; then
                confirm "取消后这些账号改为本机直接出网：$moved，确定？" || { log "已取消"; return 0; }
            fi
            chain_backup
            for i in "${!USER_NAMES[@]}"; do
                if [ "${USER_EXITS[$i]}" = upstream ]; then USER_EXITS[$i]=direct; fi
            done
            i="$(out_index upstream)"
            unset "OUT_NAMES[$i]" "OUT_LINKS[$i]"
            users_save
            exits_save
            chain_apply "取消失败"
            log "已删除出口 upstream${moved:+；这些账号改为本机直接出网：$moved}" ;;
        *)
            for i in "${!USER_NAMES[@]}"; do
                case "${USER_EXITS[$i]}" in
                    direct|upstream) ;;
                    *) others+="${others:+ }${USER_NAMES[$i]}→${USER_EXITS[$i]}" ;;
                esac
            done
            if [ -n "$others" ]; then
                [ -t 0 ] || die "有账号走别的出口（$others）：edge upstream 会把所有账号都改走 upstream。只改某个账号请用 edge user set-exit"
                confirm "所有账号都会改走 upstream，包括走别的出口的：$others，确定？" || die "已取消，配置没有改动"
            fi
            exit_check upstream "$link" "$force"
            chain_backup
            if i="$(out_index upstream)"; then OUT_LINKS[$i]="$link"; else OUT_NAMES+=(upstream) OUT_LINKS+=("$link"); fi
            for i in "${!USER_NAMES[@]}"; do USER_EXITS[$i]=upstream; done
            exits_save
            users_save
            chain_apply "启用失败"
            if [ ${#USER_NAMES[@]} -gt 0 ]; then
                log "已启用上游：所有账号（${USER_NAMES[*]}）都经 $UP_ADDR 出去，本机不再直连任何网站"
            else
                log "已保存出口 upstream（$UP_ADDR）：还没有账号，创建时选它（edge user add <名字> --exit upstream）"
            fi
            echo "  客户端的配置不用改，照常连本机" ;;
    esac
}

# edge relay：旧版的"通行证"，现在就是账号
cmd_relay() { cmd_user "$@"; }

# ---------------------------------------------------------------- 内网入口
cmd_internal() {
    load_env
    need_installed
    local v="${1:-}" old n
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
        log "已关闭内网入口：账号的内网链接失效，公网链接不受影响"
        return 0
    fi
    log "内网入口：$v"
    warn "记得在云厂商的安全组 / 防火墙里放行 ${v##*:}/tcp 和 ${v##*:}/udp，来源只填入口机的内网 IP 或内网网段"
    users_load
    n="$(internal_users)"
    if [ "$n" -eq 0 ]; then
        log "下一步：给入口机建一个账号 edge user add <名字>"
    else
        log "已有的 $n 个账号也能走内网了：edge user show <名字> 显示内网链接（default 不进内网入口）"
    fi
}

# ---------------------------------------------------------------- 账号 / 出口菜单
chain_header() {
    local role i
    load_env
    users_load
    exits_load
    if [ "$EDGE_ROLE" = exit ]; then role="纯内网出口"; else role="完整节点"; fi
    cat <<EOF

================ 账号 / 出口 ================
  本机角色 : $role
  内网入口 : ${EXIT_LISTEN:-未开启}
  出口     : direct（本机直接出网）${OUT_NAMES[*]:+ ${OUT_NAMES[*]}}
EOF
    if [ ${#USER_NAMES[@]} -eq 0 ]; then
        echo "  账号     : 还没有"
    else
        echo "  账号     : ${#USER_NAMES[@]} 个（名字 → 出口）"
        for i in "${!USER_NAMES[@]}"; do
            printf '    %-20s → %s\n' "${USER_NAMES[$i]}" "${USER_EXITS[$i]}"
        done
    fi
}

menu_chain() {
    local c name
    while :; do
        (chain_header) || true
        cat <<'EOF'
  ---- 出口：账号的流量从哪出去（另一台机器、第三方代理）----
  1) 添加出口（粘贴链接，先测试再保存）
  2) 查看 / 测试出口
  3) 更换出口的链接
  4) 删除出口
  ---- 账号：每个账号一条链接，各走各的出口 ----
  5) 添加账号（选出口）
  6) 查看账号 / 显示链接
  7) 修改账号的出口
  8) 测试账号（流量是不是从该走的出口出去）
  9) 删除账号
  ---- 内网入口：给同一内网里的入口机用 ----
 10) 开启 / 修改内网入口
 11) 关闭内网入口
  0) 返回
EOF
        read -rp "请选择: " c || return 0
        echo
        case "$c" in
            1) bash "$SELF" exit add ;;
            2) bash "$SELF" exit list
               read -rp "测试哪个出口（输入名字，留空跳过）: " name
               [ -z "$name" ] || bash "$SELF" exit test "$name" ;;
            3) bash "$SELF" exit update ;;
            4) bash "$SELF" exit remove ;;
            5) bash "$SELF" user add ;;
            6) bash "$SELF" user list
               read -rp "显示哪个账号的链接（输入名字，留空跳过）: " name
               [ -z "$name" ] || bash "$SELF" user show "$name" ;;
            7) bash "$SELF" user set-exit ;;
            8) bash "$SELF" user test ;;
            9) bash "$SELF" user remove ;;
            10) bash "$SELF" internal set ;;
            11) confirm "关闭后入口机就不能走内网连本机了，确定？" && bash "$SELF" internal off ;;
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
 13) 账号 / 出口 / 内网入口（多账号、链式代理）
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
  2) 账号 / 出口 / 内网入口
  3) 添加账号（给入口机用）
  4) 查看账号 / 显示链接
  5) 改了 .env 后重新生成配置
  6) 更新 Xray 镜像
  7) 重新安装 / 修复
  8) 轮换密钥（所有账号的链接都会失效）
  9) 查看 Xray 配置
 10) 查看 Xray 日志
  0) 退出
EOF
        read -rp "请选择: " c || exit 0
        echo
        case "$c" in
            1) bash "$SELF" check ;;
            2) menu_chain ;;
            3) bash "$SELF" user add ;;
            4) bash "$SELF" user list
               read -rp "显示哪个账号的链接（输入名字，留空跳过）: " name
               [ -z "$name" ] || bash "$SELF" user show "$name" ;;
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
    user)        cmd_user "$@" ;;
    exit)        cmd_exit "$@" ;;
    upstream)    cmd_upstream "$@" ;;
    relay)       cmd_relay "$@" ;;
    internal)    cmd_internal "$@" ;;
    *)           usage; exit 1 ;;
esac
