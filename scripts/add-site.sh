#!/usr/bin/env bash
# 新增一个 HTTPS 站点（反向代理到本机端口）
# 用法：
#   bash scripts/add-site.sh app1.example.com 3001
#   bash scripts/add-site.sh app1.example.com 127.0.0.1:3001
#   bash scripts/add-site.sh app.foo.co.uk 3003 foo.co.uk        # 手动指定证书所属的根域名
#   bash scripts/add-site.sh blog.foo.com 3001 foo.com blog      # 记录对应的应用 apps/blog（edge add 会这样调用）
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

[ $# -ge 2 ] || die "用法：add-site.sh <域名> <端口|host:port> [证书根域名] [应用名]"

SITE_DOMAIN="$1"
UPSTREAM="$2"
CERT_DOMAIN="${3:-}"
APP="${4:-}"

[[ "$SITE_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "域名格式不对：$SITE_DOMAIN"
[ "$SITE_DOMAIN" != "$REALITY_SNI" ] \
    || die "$SITE_DOMAIN 是 REALITY 域名（伪装站），由 apps/decoy 提供，不需要再添加"
[[ "$UPSTREAM" =~ ^[0-9]+$ ]] && UPSTREAM="127.0.0.1:$UPSTREAM"
[[ "$UPSTREAM" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "上游格式不对：$UPSTREAM（应为端口或 host:port）"

# 自动查找证书：从域名本身开始逐级向上，找 certs/ 下已存在的证书目录
if [ -z "$CERT_DOMAIN" ]; then
    CERT_DOMAIN="$(find_cert "$SITE_DOMAIN")" \
        || die "certs/ 下找不到覆盖 $SITE_DOMAIN 的证书。用 edge add 会自动签发，或先运行：bash scripts/03-issue-cert.sh <根域名>"
fi
[ -s "$EDGE_DIR/certs/$CERT_DOMAIN/fullchain.pem" ] || die "证书不存在：certs/$CERT_DOMAIN/fullchain.pem"
cert_covers "$SITE_DOMAIN" "$CERT_DOMAIN" \
    || die "$SITE_DOMAIN 不在 $CERT_DOMAIN 泛域名证书范围内（泛域名只覆盖一级子域名，如 a.$CERT_DOMAIN）"

CONF="$EDGE_DIR/nginx/conf.d/$SITE_DOMAIN.conf"
[ ! -e "$CONF" ] || die "$CONF 已存在；如需重建请先删除它"

render "$EDGE_DIR/templates/site.conf.tpl" "$CONF" SITE_DOMAIN UPSTREAM CERT_DOMAIN
if [ -n "$APP" ]; then
    # 第一行记下对应的应用：edge up / edge remove / edge sites 靠它找到 apps/<名字>
    printf '# app=%s\n%s\n' "$APP" "$(<"$CONF")" >"$CONF"
fi
log "已生成 $CONF（证书：$CERT_DOMAIN，上游：$UPSTREAM${APP:+，应用：apps/$APP}）"

if nginx_running; then
    if ! bash "$EDGE_DIR/scripts/reload-nginx.sh"; then
        rm -f "$CONF"
        die "nginx 配置检查失败，已撤销 $CONF"
    fi
else
    warn "nginx 未运行，配置会在 docker compose up -d 后生效"
fi

ensure_dns_record "$SITE_DOMAIN" || true

echo
log "检查清单："
echo "  1. DNS：已检查/创建 $SITE_DOMAIN 的 Cloudflare 灰云记录（如未托管在当前 Token 下请手动添加）"
if [ -n "$APP" ]; then
    echo "  2. 应用：apps/$APP 已在 $UPSTREAM 运行；以后改了代码运行 edge up $APP"
else
    echo "  2. 后端：$UPSTREAM 可访问（Docker 端口必须写成 127.0.0.1:端口:容器端口）"
fi
echo "  3. 测试：curl -I https://$SITE_DOMAIN"
