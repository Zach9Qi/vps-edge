#!/usr/bin/env bash
# 删除一个站点配置并重载 nginx（直接删除，不留副本）；对应的 apps/ 应用没有其他站点在用时一并停止（应用目录、证书保留）
# 用法：bash scripts/remove-site.sh app1.example.com
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ $# -eq 1 ] || die "用法：remove-site.sh <域名>"
[[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || die "域名格式不对：$1"
CONF="$CONF_DIR/$1.conf"
[ -f "$CONF" ] || die "不存在：$CONF"
[ "$(basename "$CONF")" != "00-decoy.conf" ] || die "不能删除伪装站配置"
APP="$(site_app "$CONF")"

rm -f "$CONF"
log "已删除 $CONF"
nginx_running && bash "$EDGE_DIR/scripts/reload-nginx.sh" || true

if [ -n "$APP" ] && ! app_port "$APP" >/dev/null; then
    app_down "$APP" && log "已停止 apps/$APP（目录保留，重新 edge add 即可恢复）" \
        || warn "停止 apps/$APP 失败：cd apps/$APP && APP_PORT=1 docker compose down"
fi
