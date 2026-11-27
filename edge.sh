#!/usr/bin/env bash
# vps-edge 唯一入口：所有操作都从这里开始，不用记 scripts/ 里的各个脚本
#
#   bash edge.sh             第一次：一键安装（会问几个问题）；之后：打开菜单
#   安装完成后，任何目录下直接输入 edge 即可（已链接到 /usr/local/bin/edge）
#
#   edge install             一键安装 / 修复（可重复执行，不会重复生成密钥）
#   edge add <域名> <应用名>  发布 apps/<应用名>：自动分配端口、构建启动、签证书、配好 HTTPS
#   edge add <域名> <端口>    或者反代到一个已经在运行的服务
#                            新的根域名（和 .env 不一样）会问你要它的 Token；不在终端里时加 --token <Token>
#   edge up [应用名]          改了应用代码后重新构建、重启（不带参数 = 全部应用）
#   edge theme [主题名]       切换伪装站主题（不带参数会列出来让你选）
#   edge remove [域名]        删除网站，并停止对应的应用（不带参数会列出来让你选）
#   edge rename [旧域名] [新域名]  网站或节点（伪装站）换域名：先上线新域名、确认能访问，再删旧的
#   edge sites               查看已有网站
#   edge check               健康检查
#   edge client [--all]      显示客户端配置 / 分享链接（--all 连同其他账号的链接一起显示）
#   edge apply               改了 .env 或模板之后，重新生成配置并生效（先检查 Token，再更新续签 Token、清理旧证书）
#   edge update              更新所有镜像并重启（包括 apps/ 下的应用）
#   edge rotate-keys         轮换 Xray 密钥（旧客户端需要重新导入）
#   edge logs [nginx|xray]   查看日志
#   edge xray [--raw]        查看 Xray 实际配置（私钥默认隐藏，--raw 显示完整）
#
#   ---- 证书（每张证书续签用自己存的 Token；.env 里的 CF_Token 管和 REALITY_CERT_DOMAIN 同一个根域名的）----
#   edge apply 先检查 .env 的 Token 能管理它的域名（不能就拒绝），续签 Token 不一样才改；没人用的旧证书会问你要不要删
#   edge certs                          查看每张证书：谁在用、剩余天数、续签用哪个 Token
#   edge certs prune [根域名...] [--revoke]  停止续签并删除没人用的证书（先演练，确认不影响网站才删）
#
#   ---- 账号和出口（多账号、链式代理，详见 README 第 8 节）----
#   每个账号一条链接，各走各的出口：direct = 本机直接出网，或者另一台机器 / 第三方代理
#   edge chain                                  打开账号 / 出口菜单
#   edge user add <名字> [--exit <出口>]         新建账号，打印链接（手机用，或者给入口机当出口）
#   edge user list                              查看账号和各自的出口
#   edge user show <名字>                        再次显示链接
#   edge user set-exit <名字> <出口>              修改账号的出口（链接不变）
#   edge user rename <旧名字> <新名字>            给账号改名（链接照常能用）
#   edge user test <名字>                        测试：流量是不是从该走的出口出去
#   edge user remove <名字>                      删除账号（用它的设备立刻连不上，其他不受影响）
#   edge exit add <名字> '<链接>' [--force]       添加出口：先测试，通过才保存
#   edge exit update <名字> '<链接>' [--force]    更换出口的链接
#   edge exit list | test <名字> | remove <名字>   查看 / 测试 / 删除出口（还有账号在用时不能删）
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
    load_env
    env_token_check
    bash "$S/03-issue-cert.sh"

    log "[4/5] 生成密钥和配置、启动应用"
    bash "$S/02-init.sh"          # 里面会启动伪装站 apps/decoy
    load_env
    env_token_sync                # 伪装站证书续签用 .env 里的 Token
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
    local domain="" target="" given="" cert up app="" port="" new_app=0 issue=0 apps
    while [ $# -gt 0 ]; do
        case "$1" in
            --token)   [ $# -ge 2 ] || die "--token 后面要跟 Token"; given="$2"; shift ;;
            --token=*) given="${1#--token=}" ;;
            -*)        die "不认识的参数：$1" ;;
            *)         if [ -z "$domain" ]; then domain="$1"; elif [ -z "$target" ]; then target="$1"; else die "多余的参数：$1"; fi ;;
        esac
        shift
    done
    if [ -z "$domain" ] || [ -z "$target" ]; then
        [ -t 0 ] || die "用法：edge add <域名> <应用名|端口> [--token <Token>]"
        ask domain "网站域名（如 app.你的域名.com）" "$domain"
        apps="$(list_apps | tr '\n' ' ')"
        echo "  apps/ 下的应用：${apps:-（没有）}"
        ask target "填应用名（自动构建、启动），或已经在运行的服务的端口" "$target"
    fi
    [[ "$domain" =~ $DOMAIN_RE ]] || die "域名格式不对：$domain"
    [ "$domain" != "$REALITY_SNI" ] \
        || die "$domain 是伪装站域名，由 apps/decoy 提供，不需要再添加"
    [ ! -e "$CONF_DIR/$domain.conf" ] || die "$domain 已经添加过了（edge sites 查看；要重建先 edge remove $domain）"

    # 还没有覆盖它的证书：先定好用哪个 Token、签哪张证书（不行就在这里停，应用还没启动）
    if ! cert="$(find_cert "$domain")"; then
        add_pick_token "$domain" "$given"
        cert="$(pick_cert_domain "$domain" "$ADD_ZONE")"
        issue=1
    fi

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
        if [ "$issue" = 1 ]; then
            log "还没有覆盖 $domain 的证书，自动签发 $cert 和 *.$cert"
            ISSUE_CF_TOKEN="$ADD_TOKEN" bash "$S/03-issue-cert.sh" "$cert"
        fi &&
        bash "$S/add-site.sh" "$domain" "$up" "$cert" "$app"
    }; then
        [ "$new_app" -eq 0 ] || app_down "$app" || true
        die "添加 $domain 失败（见上面的报错）"
    fi
}

# add_pick_token <域名> [Token]：edge add 签证书用哪个 Token，结果放在 ADD_TOKEN / ADD_ZONE（zone 名）
#   命令行给了 --token                            → 用它
#   和 .env 的 REALITY_CERT_DOMAIN 同一个根域名    → .env 的 CF_Token
#   已经有这个根域名的证书（a.b.shop.org 之于 shop.org）→ 那张证书自己存的 Token
#   都不是（新的根域名）                          → 让你粘贴一个，签证书后存在这张证书里，不写进 .env
# 选出来的 Token 先查一次 Cloudflare，确认能管理这个域名才用
ADD_TOKEN="" ADD_ZONE=""
add_pick_token() {
    local d="$1" tok="${2:-}" from="" root out rc
    if [ -n "$tok" ]; then
        from="命令行给的 Token"
    elif same_root_as_env "$d"; then
        tok="$CF_Token"; from=".env 的 CF_Token（和伪装站同一个根域名 $REALITY_CERT_DOMAIN）"
    elif root="$(cert_root_of "$d")"; then
        tok="$(acme_conf_get "$(acme_conf "$root")" CF_Token)"; from="$root 证书存的 Token"
    fi
    if [ -n "$tok" ]; then
        out="$(cf_token_zone "$tok" "$d")" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
            ADD_TOKEN="$tok"; ADD_ZONE="${out#* }"
            log "$d 用 $from（$(mask_token "$tok")）"
            return 0
        fi
        # .env 和命令行的 Token 是你明确指定的，不能用就停；证书里存的可能过期了，可以重新给一个
        case "$from" in
            .env*|命令行*) die "$from 不能用来签 $d：$(cf_token_err "$rc" "$d")。什么都没改" ;;
        esac
        warn "$from 不能用了：$(cf_token_err "$rc" "$d")"
    else
        warn "$d 的根域名和 .env 里的 $REALITY_CERT_DOMAIN 不一样，也还没有它的证书，要用能管理它的 Cloudflare Token"
    fi
    [ -t 0 ] || die "不在终端里运行时，在命令最后加 --token <能管理 $d 的 Token>"
    while :; do
        tok=""
        read -rsp "粘贴能管理 $d 的 Cloudflare Token（Zone → DNS → Edit、Zone → Zone → Read；直接回车取消）: " tok; echo
        [ -n "$tok" ] || die "已取消，什么都没改"
        out="$(cf_token_zone "$tok" "$d")" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
            ADD_TOKEN="$tok"; ADD_ZONE="${out#* }"
            log "Token 能管理 $d（Cloudflare 上的 $ADD_ZONE），签证书后存在这张证书里，以后续签就用它"
            return 0
        fi
        warn "$(cf_token_err "$rc" "$d")，请重新粘贴"
    done
}

# ================================================================ 换域名
# edge rename <旧域名> <新域名> [--token <Token>]
#   网站：复制旧的站点配置，只改 server_name 和证书路径（手动改过的内容原样保留）→ 新域名上线 →
#         本机确认 https://新域名 能访问 → 删除旧域名的站点。任何一步失败都撤回，旧域名照常
#   节点（伪装站，REALITY_SNI）：改 .env 的 REALITY_SNI / REALITY_CERT_DOMAIN（新根域名还会换 CF_Token）
#         → 走一遍 edge apply；失败就恢复 .env，节点照常
#   最后：旧域名指向本机的 DNS 记录、没人用的旧证书，都问你要不要删
#   新域名用哪个 Token 和 edge add 一样（add_pick_token）
cmd_rename() {
    need_edge_role
    load_env
    local old="" new="" given="" sites n i
    while [ $# -gt 0 ]; do
        case "$1" in
            --token)   [ $# -ge 2 ] || die "--token 后面要跟 Token"; given="$2"; shift ;;
            --token=*) given="${1#--token=}" ;;
            -*)        die "不认识的参数：$1" ;;
            *)         if [ -z "$old" ]; then old="$1"; elif [ -z "$new" ]; then new="$1"; else die "多余的参数：$1"; fi ;;
        esac
        shift
    done
    if [ -z "$old" ]; then
        [ -t 0 ] || die "用法：edge rename <旧域名> <新域名> [--token <Token>]"
        mapfile -t sites < <(echo "$REALITY_SNI"; list_sites)
        for i in "${!sites[@]}"; do
            if [ "$i" -eq 0 ]; then printf '  %d) %s（节点 / 伪装站）\n' 1 "${sites[0]}"
            else printf '  %d) %s\n' $((i + 1)) "${sites[$i]}"; fi
        done
        read -rp "改哪个（序号）: " n
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#sites[@]} ] || die "序号不对"
        old="${sites[$((n - 1))]}"
    fi
    if [ -z "$new" ]; then
        [ -t 0 ] || die "用法：edge rename <旧域名> <新域名> [--token <Token>]"
        ask new "$old 改成什么域名"
    fi
    [[ "$new" =~ $DOMAIN_RE ]] || die "域名格式不对：$new"
    [ "$new" != "$old" ] || die "新旧域名一样"
    [ "$new" != "$REALITY_SNI" ] || die "$new 是节点（伪装站）现在的域名"
    [ ! -e "$CONF_DIR/$new.conf" ] || die "$new 已经是一个网站了（edge sites 查看）"
    if [ "$old" = "$REALITY_SNI" ]; then
        rename_decoy "$old" "$new" "$given"
    else
        rename_site "$old" "$new" "$given"
    fi
}

rename_site() {  # rename_site <旧域名> <新域名> [Token]
    local old="$1" new="$2" given="${3:-}" conf newconf oldcert cert issue=0 oldtok code
    conf="$CONF_DIR/$old.conf"
    [ -f "$conf" ] || die "没有 $old 这个网站（edge sites 查看）"
    oldtok="$(token_for_domain "$old")"   # 删旧域名的 DNS 记录要用，旧证书删掉之前先记下
    oldcert="$({ grep -oE '/etc/nginx/certs/[^/]+/' "$conf" || true; } | head -n 1 | cut -d/ -f5)"
    if ! cert="$(find_cert "$new")"; then
        add_pick_token "$new" "$given"
        cert="$(pick_cert_domain "$new" "$ADD_ZONE")"
        issue=1
    fi
    if [ -t 0 ]; then
        confirm "把网站 $old 改成 $new？（先上线新域名，确认能访问后再删旧的）" || { log "已取消"; return 0; }
    fi
    if [ "$issue" = 1 ]; then
        log "还没有覆盖 $new 的证书，自动签发 $cert 和 *.$cert"
        ISSUE_CF_TOKEN="$ADD_TOKEN" bash "$S/03-issue-cert.sh" "$cert"
    fi

    # 1. 新域名上线：复制旧配置，只改域名和证书路径
    newconf="$CONF_DIR/$new.conf"
    site_conf_rename "$conf" "$old" "$new" "$oldcert" "$cert" >"$newconf"
    if ! grep -qF "/etc/nginx/certs/$cert/" "$newconf" || ! grep -qE "server_name[^;]*[[:space:]]$new[[:space:];]" "$newconf"; then
        rm -f "$newconf"
        die "$old 的站点配置不是 edge 生成的格式（找不到 server_name $old 或证书路径），没法自动改名：手动 edge add $new 再 edge remove $old"
    fi
    log "已生成 $newconf（从 $old 复制，证书：$cert）"
    if nginx_running; then
        if ! bash "$S/reload-nginx.sh"; then
            rm -f "$newconf"
            die "nginx 配置检查不通过，已撤销，$old 照常"
        fi
    else
        warn "nginx 没在运行，没法确认新域名能访问"
    fi
    ensure_dns_record "$new" || true

    # 2. 确认新域名能访问：本机直连（不用等 DNS 生效），同时验证证书
    if nginx_running; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$new:443:127.0.0.1" "https://$new/" 2>/dev/null)" || true
        if [ -z "$code" ] || [ "$code" = 000 ]; then
            rm -f "$newconf"
            bash "$S/reload-nginx.sh" >/dev/null || true
            die "https://$new 在本机访问不通（证书或配置有问题），已撤销，$old 照常"
        fi
        log "https://$new 本机访问正常（HTTP $code）"
    fi

    # 3. 删掉旧域名（对应的应用新域名还在用，不会停）
    bash "$S/remove-site.sh" "$old"
    log "网站已从 $old 改成 $new"
    dns_offer_cleanup "$old" "$oldtok"
    certs_offer_prune
}

# 节点改名中途失败或被中断时，把 .env 改回原来的三个值（记在变量里，不生成备份文件）
RD_PENDING=0 RD_SNI="" RD_CERT="" RD_TOK=""
rename_decoy_undo() {
    [ "$RD_PENDING" = 1 ] || return 0
    RD_PENDING=0
    env_set REALITY_SNI "$RD_SNI"
    env_set REALITY_CERT_DOMAIN "$RD_CERT"
    env_set CF_Token "$RD_TOK"
    warn "没改成功，.env 已恢复，节点还是 $RD_SNI"
}

rename_decoy() {  # rename_decoy <旧域名> <新域名> [Token]
    local old="$1" new="$2" given="${3:-}" cert oldtok
    if [ -t 0 ]; then
        warn "$old 是节点（伪装站）的域名：改完以后所有客户端链接里的 SNI 都会变，要重新导入（UUID、公钥、shortId 不变）"
        confirm "把节点域名 $old 改成 $new？" || { log "已取消"; return 0; }
    fi
    oldtok="$CF_Token"
    # .env 的 Token 永远跟着节点域名走：新根域名用你给的 Token，同根域名还用 .env 的
    add_pick_token "$new" "$given"
    cert="$(pick_cert_domain "$new" "$ADD_ZONE")"

    RD_SNI="$(env_get REALITY_SNI)" RD_CERT="$(env_get REALITY_CERT_DOMAIN)" RD_TOK="$(env_get CF_Token)"
    RD_PENDING=1
    trap rename_decoy_undo EXIT
    trap 'exit 130' INT TERM
    env_set REALITY_SNI "$new"
    env_set REALITY_CERT_DOMAIN "$cert"
    env_set CF_Token "$ADD_TOKEN"
    log ".env 已改成 REALITY_SNI=$new、REALITY_CERT_DOMAIN=$cert，开始生成配置"
    (apply_core) || die "节点域名没改成（原因见上面）"
    RD_PENDING=0
    trap - EXIT INT TERM
    load_env
    log "节点域名已从 $old 改成 $new。新的分享链接："
    bash "$S/show-client.sh" || true
    dns_offer_cleanup "$old" "$oldtok"
    certs_offer_prune
}

# site_conf_rename <conf> <旧域名> <新域名> <旧证书> <新证书>：输出改好域名的站点配置
#   只改 server_name 行和注释里的旧域名（整词匹配），以及证书路径；其他手动改过的内容原样保留
site_conf_rename() {
    OLD="$2" NEW="$3" OC="/etc/nginx/certs/$4/" NC="/etc/nginx/certs/$5/" awk '
        function swap(s, a, b,    out, i, pre, post) {
            out = ""
            while ((i = index(s, a)) > 0) {
                pre = (i > 1) ? substr(s, i - 1, 1) : ""
                post = substr(s, i + length(a), 1)
                if (pre !~ /[A-Za-z0-9.-]/ && post !~ /[A-Za-z0-9.-]/) out = out substr(s, 1, i - 1) b
                else out = out substr(s, 1, i - 1 + length(a))
                s = substr(s, i + length(a))
            }
            return out s
        }
        BEGIN { o = ENVIRON["OLD"]; n = ENVIRON["NEW"]; oc = ENVIRON["OC"]; nc = ENVIRON["NC"] }
        /^[ \t]*server_name[ \t]/ || (/^[ \t]*#/ && !/^# app=/) { $0 = swap($0, o, n) }
        { if (oc != nc && oc != "/etc/nginx/certs//") while ((i = index($0, oc)) > 0) $0 = substr($0, 1, i - 1) nc substr($0, i + length(oc)); print }
    ' "$1"
}

# dns_offer_cleanup <旧域名> <Token>：旧域名已经不用了，问要不要删掉它指向本机的 DNS 记录
dns_offer_cleanup() {
    local d="$1" tok="$2"
    [ ! -e "$CONF_DIR/$d.conf" ] && [ "$d" != "$REALITY_SNI" ] || return 0   # 还在用就不问
    echo
    if [ -z "$tok" ]; then
        log "旧域名 $d 的 DNS 记录请到 Cloudflare 上自己删（不知道它用哪个 Token）"
    elif [ -t 0 ] && confirm "删除 Cloudflare 上 $d 指向本机的 DNS 记录（指向别处的不动）？"; then
        cf_delete_records "$d" "$tok" || warn "DNS 记录没删干净，到 Cloudflare 上看一下"
    else
        log "暂不删除。旧域名 $d 的 DNS 记录以后到 Cloudflare 上删"
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
    load_env
    certs_offer_prune
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

# ================================================================ 证书
# 证书按根域名签，每张证书续签用自己存的 Cloudflare Token（见 scripts/lib.sh 的"证书清单"一节）。
# .env 里的 CF_Token 和 REALITY_CERT_DOMAIN 永远是最新的，edge apply 会：
#   1. 先检查这个 Token 能不能管理这个域名，不能就拒绝，什么都不改（env_token_check）
#   2. 能就看这个域名的证书现在续签用的 Token 是不是它，不是才改（env_token_sync）；其他证书不动
#   3. 换了域名以后没人用的旧证书，先检查不影响现有网站，再问你要不要删（certs_offer_prune）
cmd_certs() {
    need_edge_role
    load_env
    case "${1:-list}" in
        list|ls)  certs_list; [ ! -t 0 ] || certs_offer_prune ;;
        prune|rm) shift; certs_prune "$@" ;;
        *)        die "用法：edge certs [list] | edge certs prune [根域名...] [--revoke]" ;;
    esac
}

# cmd_apply：检查 .env 的 Token 和域名 → 重新生成配置并生效 → 更新续签 Token → 问要不要清理没人用的证书
cmd_apply() {
    if [ "$(env_get EDGE_ROLE)" = exit ]; then bash "$S/02-init.sh"; return; fi
    apply_core
    certs_offer_prune
}

apply_core() {  # 检查 Token → 生成配置并生效 → 更新续签 Token（失败直接退出）
    load_env
    env_token_check
    # 在 if / 子 shell 里调用时 set -e 不生效，这里明确退出
    bash "$S/02-init.sh" || die "生成配置失败（原因见上面）"
    load_env
    env_token_sync
}

# env_token_check：.env 里的 CF_Token 能不能管理 REALITY_CERT_DOMAIN；能就记下 zone id（ENV_ZONE_ID），不能直接退出
ENV_ZONE_ID=""
env_token_check() {
    local d="$REALITY_CERT_DOMAIN" out rc
    is_example "$REALITY_SNI" && die ".env 里还是示例域名，请先改 REALITY_SNI / REALITY_CERT_DOMAIN。未做任何改动"
    cert_covers "$REALITY_SNI" "$d" \
        || die "REALITY_SNI=$REALITY_SNI 不在 $d 泛域名证书的覆盖范围内，REALITY_CERT_DOMAIN 是不是忘了改？未做任何改动"
    [ -n "$CF_Token" ] || die ".env 里 CF_Token 为空。未做任何改动"
    out="$(cf_token_zone "$CF_Token" "$d")" && rc=0 || rc=$?
    case "$rc" in
        0) ENV_ZONE_ID="${out%% *}"
           log ".env 里的 Token（$(mask_token "$CF_Token")）能管理 $d（Cloudflare 上的 ${out#* }）" ;;
        1) die ".env 里的 Token 看不到 $d：确认域名托管在 Cloudflare，且 Token 的 Zone Resources 包含它。未做任何改动" ;;
        3) die ".env 里的 Token 无效或缺少 Zone → Zone → Read 权限。未做任何改动" ;;
        4) die ".env 里的 Token 能看到 $d，但没有 Zone → DNS → Edit 权限。未做任何改动" ;;
        *) die "连不上 Cloudflare API（或者没装 jq），没法确认 .env 里的 Token。未做任何改动，稍后再试" ;;
    esac
}

# env_token_sync：和 .env 同一个根域名的证书（伪装站的，还有 a.b.<根域名> 这类单独签的），续签 Token
# 和 .env 不一样才改（先 env_token_check）。其他根域名的证书用它们自己存的，不动
env_token_sync() {
    local d conf cur curzid
    [ -n "$ENV_ZONE_ID" ] || return 0
    while read -r d; do
        [ -n "$d" ] && same_root_as_env "$d" || continue
        if ! acme_managed "$d"; then
            warn "$d 的证书不归 acme.sh 管，不会自动续签：bash $S/03-issue-cert.sh $d 重新签一次"
            continue
        fi
        conf="$(acme_conf "$d")"
        cur="$(acme_conf_get "$conf" CF_Token)"
        curzid="$(acme_conf_get "$conf" CF_Zone_ID)"
        if [ "$cur" = "$CF_Token" ] && [ "$curzid" = "$ENV_ZONE_ID" ]; then
            log "$d 续签用的 Token 和 .env 一致，不用改"
        else
            [ -n "$cur" ] || cur="$(cert_token "$d")"
            cert_set_token "$d" "$CF_Token" "$ENV_ZONE_ID"
            log "$d 续签 Token 已更新为 .env 里的（$(mask_token "$CF_Token")），原来是 $(mask_token "$cur")"
        fi
    done < <(cert_all)
}

certs_list() {
    local d days users tok renew other
    echo "== 证书（按根域名，每张覆盖 X 和 *.X）=="
    while read -r d; do
        [ -n "$d" ] || continue
        days="$(cert_days "$d")"
        if acme_managed "$d"; then
            tok="$(cert_token "$d")"
            renew="自动续签，Token $(mask_token "$tok")"
            if same_root_as_env "$d"; then
                if [ "$(acme_conf_get "$(acme_conf "$d")" CF_Token)" = "$CF_Token" ]; then
                    renew="$renew（和 .env 一致）"
                else
                    renew="$renew（≠ .env，edge apply 检查通过后会更新）"
                fi
            else
                renew="$renew（自己的根域名，用它自己存的）"
            fi
        else
            renew="acme.sh 没在续签，到期就失效"
        fi
        printf '  %-28s 剩余 %s 天  %s\n' "$d" "${days:-?}" "$renew"
        users="$(cert_users "$d")"
        if [ -n "$users" ]; then sed 's/^/      在用：/' <<<"$users"; else echo "      没有站点在用"; fi
    done < <(cert_all)

    other="$(acme_only)"
    if [ -n "$other" ]; then
        echo
        echo "== acme.sh 还在续签、但不在 certs/ 下的 =="
        sed 's/^/  /' <<<"$other"
        echo "  （你自己另外签的就别管；是 edge 以前签的可以 edge certs prune <根域名> 停掉）"
    fi
    echo
    echo "  .env：$REALITY_CERT_DOMAIN，Token $(mask_token "$CF_Token")"
}

# certs_offer_prune：有没人用的证书就问一次：同意 → 检查后直接删；不同意 → 告诉你以后用什么命令
certs_offer_prune() {
    local list=()
    mapfile -t list < <(cert_unused)
    [ ${#list[@]} -gt 0 ] || return 0
    echo
    warn "这些证书已经没有站点在用，acme.sh 还在续签它们：${list[*]}"
    if [ -t 0 ] && confirm "先确认不影响现有网站，再停止续签并删除？"; then
        (certs_prune --yes "${list[@]}") || warn "没有删除（原因见上面）"
    else
        log "暂不删除。以后要删：edge certs prune ${list[*]}（加 --revoke 同时注销）"
    fi
}

# certs_prune [根域名...] [--revoke] [--yes]：不带域名 = 所有没人用的证书；--yes 不再问（调用方已经问过）
certs_prune() {
    local revoke=0 yes=0 a d u list=()
    for a in "$@"; do
        case "$a" in
            --revoke) revoke=1 ;;
            --yes)    yes=1 ;;
            -*)       die "不认识的参数：$a" ;;
            *)        list+=("$a") ;;
        esac
    done
    if [ ${#list[@]} -eq 0 ]; then
        mapfile -t list < <(cert_unused)
        [ ${#list[@]} -gt 0 ] || { log "每张证书都有站点在用，没有要清理的"; return 0; }
        echo "这些证书已经没有站点在用："
        printf '  %s\n' "${list[@]}"
        [ -t 0 ] || [ "$yes" = 1 ] || die "不在终端里运行时要写明删哪些：edge certs prune ${list[*]}"
    fi
    # 第一道检查：配置文件里没有任何地方引用它；有一个不能删就一个都不动
    for d in "${list[@]}"; do
        [[ "$d" =~ $DOMAIN_RE ]] || die "域名格式不对：$d"
        u="$(cert_users "$d" | paste -sd' ')"
        [ -z "$u" ] || die "$d 的证书还在用：$u（先把这些网站换成新域名或 edge remove，伪装站改 .env 后 edge apply）"
        [ -d "$EDGE_DIR/certs/$d" ] || acme_managed "$d" || die "没有 $d 的证书（edge certs 查看）"
    done
    if [ "$yes" = 0 ] && [ -t 0 ]; then
        if [ "$revoke" = 1 ]; then
            confirm "注销并删除 ${list[*]} 的证书（停止自动续签）？" || { log "已取消"; return 0; }
        else
            confirm "停止自动续签并删除 ${list[*]} 的证书？" || { log "已取消"; return 0; }
        fi
    fi
    # 第二道检查：真的把证书挪走，让 nginx 检查一遍配置，通过了才删
    certs_dry_run "${list[@]}"
    for d in "${list[@]}"; do cert_drop "$d" "$revoke"; done
    log "完成：edge certs 查看剩下的证书。旧域名的 DNS 记录、不再用的 Token 要到 Cloudflare 上自己删"
}

# certs_dry_run <根域名...>：把这些证书目录临时挪走，跑 nginx -t，然后马上挪回来。
# 检查通过 = 没有这些证书 nginx 照样能加载配置，删掉不影响网站；不通过就退出，什么都不删
DRY_TMP="" DRY_MOVED=()
certs_dry_undo() {  # 把演练时挪走的证书目录挪回原处（可以重复调用）
    local d
    for d in "${DRY_MOVED[@]}"; do
        if [ -d "$EDGE_DIR/certs/$DRY_TMP-$d" ]; then mv "$EDGE_DIR/certs/$DRY_TMP-$d" "$EDGE_DIR/certs/$d"; fi
    done
    DRY_MOVED=()
}

certs_dry_run() {
    local d err rc
    if ! nginx_running; then
        warn "nginx 没在运行，没法实际演练，只按配置文件检查过"
        return 0
    fi
    err="$(docker exec nginx nginx -t -q 2>&1)" \
        || die "nginx 现在的配置本身就检查不通过，先修好再清理证书：$err"
    DRY_TMP=".prune-check-$$" DRY_MOVED=()
    trap certs_dry_undo EXIT
    trap 'exit 130' INT TERM
    for d in "$@"; do
        if [ -d "$EDGE_DIR/certs/$d" ]; then
            mv "$EDGE_DIR/certs/$d" "$EDGE_DIR/certs/$DRY_TMP-$d"
            DRY_MOVED+=("$d")
        fi
    done
    err="$(docker exec nginx nginx -t -q 2>&1)" && rc=0 || rc=$?
    certs_dry_undo
    trap - EXIT INT TERM
    [ "$rc" -eq 0 ] || die "把 $* 的证书挪走后 nginx 配置检查不通过，说明还有地方在用，一个都没删：$err"
    log "演练通过：没有这些证书 nginx 配置照样正常，删除不影响现有网站"
}

cert_drop() {  # cert_drop <根域名> <注销 0|1>
    local d="$1"
    if acme_managed "$d"; then
        if [ "$2" = 1 ]; then
            # 注销要用 acme.sh 目录里的证书文件，所以必须在 --remove / 删除之前
            if "$ACME" --revoke -d "$d" --ecc; then log "$d 的证书已注销"
            else warn "注销 $d 失败，继续删除（不注销的话 90 天内到期自然失效）"; fi
        fi
        if "$ACME" --remove -d "$d" --ecc >/dev/null; then log "$d 已停止自动续签"
        else warn "acme.sh --remove $d 失败，仍然删除它的目录（续签任务就找不到它了）"; fi
        rm -rf "${ACME_HOME:?}/${d}_ecc"
    elif [ "$2" = 1 ]; then
        warn "$d 不归 acme.sh 管理，没法注销，只删除文件"
    fi
    if [ -d "$EDGE_DIR/certs/$d" ]; then
        rm -rf "${EDGE_DIR:?}/certs/$d"
        log "已删除 certs/$d"
    fi
}

# ================================================================ 账号 / 出口 / 内网入口
# 数据和路由规则见 scripts/lib.sh 的"账号 / 出口 / 内网入口"一节和 xray_egress
#
# 重新生成配置并生效（不打印客户端配置；出口的明文提醒在添加出口时已经说过）
apply_quiet() { EDGE_ONECLICK=1 EDGE_EXIT_WARNED=1 bash "$S/02-init.sh"; }

need_installed() {
    [ -f "$KEYS_FILE" ] || die "还没有安装：先运行 edge install"
}

# 改账号 / 出口之前先在临时目录留一份；重新生成配置失败时恢复原样（02-init.sh 自己会恢复 config.json）
# 临时目录在脚本退出时总会删掉，不会留在磁盘上
chain_backup() {
    local f
    CHAIN_BAK="$(mktemp -d)"
    trap 'rm -rf "$CHAIN_BAK"' EXIT
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
    echo "  改名：    edge user rename <旧名字> <新名字>"
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

user_rename() {  # user_rename <旧名字> <新名字>：只改名字，UUID / 密钥 / 出口都不变，已发出的链接继续能用
    local name="${1:-}" new="${2:-}" i
    users_load
    if [ -z "$name" ]; then
        [ -t 0 ] || die "用法：edge user rename <旧名字> <新名字>"
        pick_user name "改哪个账号的名字"
    fi
    i="$(user_index "$name")" || die "没有叫 $name 的账号（edge user list 查看）"
    # default 是本机自带的账号（edge client 显示它，不进内网入口），配置生成按这个名字认它
    [ "$name" != default ] || die "default 是本机自带的账号，不能改名"
    if [ -z "$new" ]; then
        [ -t 0 ] || die "用法：edge user rename <旧名字> <新名字>"
        ask new "新名字（字母、数字、- _）"
    fi
    [[ "$new" =~ $NAME_RE ]] || die "名字只能用字母、数字、- 和 _，最长 32 个字符：$new"
    [ "$new" != default ] || die "default 是保留名字，换一个"
    if [ "$new" = "$name" ]; then log "名字没变，不用改"; return 0; fi
    if user_index "$new" >/dev/null; then die "已经有叫 $new 的账号了"; fi
    chain_backup
    USER_NAMES[$i]="$new"
    users_save
    chain_apply "改名失败"
    log "账号 $name 已改名为 $new"
    echo "  UUID 和密钥不变，用旧链接的设备、入口机照常能连；"
    echo "  客户端里显示的节点名还是旧的（$(link_name "$name")），想跟着改就重新导入：edge user show $new"
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
        rename|mv) user_rename "$@" ;;
        test)      user_test "$@" ;;
        remove|rm) user_remove "$@" ;;
        *)         die "用法：edge user add|list|show|set-exit|rename|test|remove [名字]" ;;
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
 10) 修改账号的名字
  ---- 内网入口：给同一内网里的入口机用 ----
 11) 开启 / 修改内网入口
 12) 关闭内网入口
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
            10) bash "$SELF" user rename ;;
            11) bash "$SELF" internal set ;;
            12) confirm "关闭后入口机就不能走内网连本机了，确定？" && bash "$SELF" internal off ;;
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
 14) 证书（谁在用、续签 Token、清理旧证书）
 15) 网站 / 节点换域名
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
            14) bash "$SELF" certs ;;
            15) bash "$SELF" rename ;;
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
    rename|mv)   cmd_rename "$@" ;;
    sites|ls)    cmd_sites ;;
    check)       bash "$S/check.sh" ;;
    client)      bash "$S/show-client.sh" "$@" ;;
    apply)       cmd_apply ;;
    update)      cmd_update ;;
    rotate-keys) cmd_rotate ;;
    logs)        cmd_logs "$@" ;;
    xray)        cmd_xray "$@" ;;
    certs|cert)  cmd_certs "$@" ;;
    chain)       menu_chain ;;
    user)        cmd_user "$@" ;;
    exit)        cmd_exit "$@" ;;
    internal)    cmd_internal "$@" ;;
    *)           usage; exit 1 ;;
esac
