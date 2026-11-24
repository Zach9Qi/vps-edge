#!/usr/bin/env bash
# 健康检查：容器、端口、证书有效期、续期任务、REALITY 回落链路、链式代理、对外暴露的端口
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
set +e
load_env

FAILS=0
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
bad()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }

EXIT_ADDR=""
if [ -n "$EXIT_LISTEN" ] && exit_listen_check "$EXIT_LISTEN" 2>/dev/null; then EXIT_ADDR="$EXIT_IP:$EXIT_PORT"; fi

echo "== 容器 =="
if [ "$EDGE_ROLE" = edge ]; then CONTAINERS="nginx xray"; else CONTAINERS="xray"; fi
for c in $CONTAINERS; do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then ok "$c 运行中"; else bad "$c 未运行（docker compose ps / docker logs $c）"; fi
done
if [ "$EDGE_ROLE" = edge ] && nginx_running; then
    docker exec nginx nginx -t -q 2>/dev/null && ok "nginx 配置检查通过" || bad "nginx -t 失败"
fi

echo "== 端口 =="
LISTEN="$(ss -tlnH | awk '{print $4}')"
if [ "$EDGE_ROLE" = edge ]; then
    grep -qE '^(0\.0\.0\.0|\*|\[::\]):443$' <<<"$LISTEN" && ok "443 对外监听" || bad "443 未对外监听"
    grep -qx '127.0.0.1:8443'  <<<"$LISTEN" && ok "127.0.0.1:8443 (HTTPS 站点层)" || bad "127.0.0.1:8443 未监听"
    grep -qx '127.0.0.1:10443' <<<"$LISTEN" && ok "127.0.0.1:10443 (Xray)"        || bad "127.0.0.1:10443 未监听"
    grep -qE '[:.]80$'         <<<"$LISTEN" && bad "检测到有进程监听 80 端口：$(grep -E '[:.]80$' <<<"$LISTEN" | tr '\n' ' ')" || ok "80 端口未监听"
    grep -qE '^(0\.0\.0\.0|\*|\[::\]):(8443|10443)$' <<<"$LISTEN" && bad "8443/10443 暴露在公网地址上"
fi
if [ -n "$EXIT_LISTEN" ]; then
    relays_load
    if [ -z "$EXIT_ADDR" ]; then
        bad "EXIT_LISTEN=$EXIT_LISTEN 不对（edge internal 重新设置）"
    elif [ "${#RELAY_NAMES[@]}" -eq 0 ]; then
        info "内网入口 $EXIT_ADDR 还没有发过通行证，暂不监听（edge relay add <名字>）"
    elif grep -qx "$EXIT_ADDR" <<<"$LISTEN"; then
        ok "$EXIT_ADDR (内网入口，${#RELAY_NAMES[@]} 张通行证)"
    else
        bad "内网入口 $EXIT_ADDR 未监听（docker logs xray）"
    fi
fi

if [ "$EDGE_ROLE" = edge ]; then
    echo "== 证书 =="
    shopt -s nullglob
    certs=("$EDGE_DIR"/certs/*/fullchain.pem)
    [ ${#certs[@]} -gt 0 ] || bad "certs/ 下没有证书"
    now="$(date +%s)"
    for f in "${certs[@]}"; do
        d="$(basename "$(dirname "$f")")"
        end="$(openssl x509 -in "$f" -noout -enddate | cut -d= -f2)"
        left=$(( ($(date -d "$end" +%s) - now) / 86400 ))
        if   [ "$left" -lt 3 ];  then bad  "$d 剩余 $left 天（$end）"
        elif [ "$left" -lt 15 ]; then info "$d 剩余 $left 天，续期可能有问题：tail ~/.acme.sh/acme.sh.log"
        else ok "$d 剩余 $left 天"; fi
    done
    crontab -l 2>/dev/null | grep -q acme.sh && ok "acme.sh 续期 cron 存在" || bad "root 的 crontab 里没有 acme.sh 续期任务"

    echo "== 链路 =="
    # 用普通 TLS 客户端连 REALITY SNI：stream → Xray（认证失败）→ 回落 nginx，应拿到真实证书
    subj="$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$REALITY_SNI" 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null)"
    if [ -n "$subj" ]; then ok "REALITY 回落正常，伪装站证书：$subj"; else bad "连接 $REALITY_SNI 拿不到证书（检查 xray 日志：docker logs xray）"; fi

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$REALITY_SNI:443:127.0.0.1" "https://$REALITY_SNI/")"
    case "$code" in
        000)         bad "伪装站连接失败" ;;
        502|503|504) bad "伪装站返回 $code：apps/decoy 没起来（代理不受影响，但外人访问会看到错误页；edge up decoy 重新启动）" ;;
        *)           ok "伪装站返回 HTTP $code" ;;
    esac

    if echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "probe-$RANDOM.invalid" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
        bad "未知 SNI 也返回了证书（default_server 拒绝握手没有生效）"
    else
        ok "未知 SNI 被拒绝握手"
    fi

    for conf in "$EDGE_DIR"/nginx/conf.d/*.conf; do
        name="$(basename "$conf" .conf)"
        [ "$name" = "00-decoy" ] && continue
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$name:443:127.0.0.1" "https://$name/")"
        case "$code" in
            000) bad  "站点 $name 连接失败" ;;
            403) info "站点 $name 返回 403" ;;
            502|504) app="$(site_app "$conf")"
                     if [ -n "$app" ]; then bad "站点 $name 返回 $code：apps/$app 没起来（edge up $app 重新启动，cd apps/$app && docker compose logs 看原因）"
                     else bad "站点 $name 返回 $code（后端没起来？）"; fi ;;
            *) ok "站点 $name 返回 $code" ;;
        esac
    done
fi

if [ -n "$UPSTREAM" ]; then
    echo "== 上游 =="
    if upstream_parse "$UPSTREAM" 2>/dev/null; then
        ok "上游：$UP_DESC"
        [ -z "$UP_WARN" ] || info "$UP_WARN"
        if upstream_probe "$UPSTREAM"; then ok "经上游出网正常"; else bad "经上游出网失败（原因见上；edge upstream test 可以单独重试）"; fi
    else
        bad "UPSTREAM 链接看不懂（edge upstream '<链接>' 重新设置，或 edge upstream off 取消）"
    fi
fi

if [ "$EDGE_ROLE" = edge ]; then
    echo "== 对外监听的端口（安全组入站只需放行 SSH 和 443/tcp）=="
else
    echo "== 对外监听的端口（安全组入站只需放行 SSH，内网入口端口只对内网放行）=="
fi
while read -r addr proc; do
    port="${addr##*:}"
    if [ "$port" = "443" ] && [ "$EDGE_ROLE" = edge ]; then
        ok "$addr  nginx 入口"
    elif [ -n "$EXIT_ADDR" ] && [ "$addr" = "$EXIT_ADDR" ]; then
        ok "$addr  内网入口（安全组只对内网来源放行 $port/tcp+udp）"
    elif [[ "$proc" == *sshd* ]]; then
        ok "$addr  SSH"
    else
        info "$addr  ${proc:-未知进程}：确认安全组没有放行这个端口，或者改成只监听 127.0.0.1"
    fi
done < <(ss -tlnpH | awk '{print $4, $6}' | grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)|%lo' | sort -u)
if [ "$EDGE_ROLE" = edge ] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw status | grep -qE '^443(/tcp)?[[:space:]].*ALLOW' || bad "主机 ufw 已启用，但没有放行 443/tcp"
fi

echo
if [ "$FAILS" -eq 0 ]; then ok "全部检查通过"; else bad "共 $FAILS 项失败"; exit 1; fi
