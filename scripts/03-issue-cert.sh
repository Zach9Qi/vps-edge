#!/usr/bin/env bash
# 用 Cloudflare DNS-01 为根域名签发泛域名证书（domain + *.domain），并登记自动续期
# 全程只有出站请求，不需要 80 端口
# 用法：
#   bash scripts/03-issue-cert.sh               # 签发 .env 里的 REALITY_CERT_DOMAIN
#   bash scripts/03-issue-cert.sh foo.com       # 再签发另一个根域名（需托管在 Cloudflare 且 Token 有权限）
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_root
load_env

DOMAIN="${1:-$REALITY_CERT_DOMAIN}"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "域名格式不对：$DOMAIN"
[ -n "$CF_Token" ] || die ".env 里 CF_Token 为空"
[ -n "$ACME_EMAIL" ] || die ".env 里 ACME_EMAIL 为空"

# ---------- 安装 acme.sh ----------
if [ ! -x "$ACME" ]; then
    log "安装 acme.sh"
    command -v crontab >/dev/null || die "未检测到 cron，请先运行 scripts/01-host-setup.sh"
    curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL"
    [ -x "$ACME" ] || die "acme.sh 安装失败"
fi
"$ACME" --set-default-ca --server letsencrypt >/dev/null

# ---------- 签发 ----------
# CF_Token 会被 acme.sh 保存到 ~/.acme.sh/account.conf，之后续期自动使用
export CF_Token
log "签发 $DOMAIN 和 *.$DOMAIN（DNS-01 / Cloudflare）"
set +e
"$ACME" --issue --dns dns_cf -d "$DOMAIN" -d "*.$DOMAIN" --keylength ec-256
rc=$?
set -e
case "$rc" in
    0) log "签发成功" ;;
    2) log "证书已存在且未到续期时间，跳过签发" ;;
    *) die "签发失败（rc=$rc）。常见原因：Token 权限不足、域名不在 Cloudflare、Zone Resources 未包含该域名" ;;
esac

# ---------- 安装到 nginx 目录，并登记续期后的 reload 命令 ----------
CERT_DIR="$EDGE_DIR/certs/$DOMAIN"
mkdir -p "$CERT_DIR"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
    --key-file       "$CERT_DIR/key.pem" \
    --fullchain-file "$CERT_DIR/fullchain.pem" \
    --reloadcmd      "bash $EDGE_DIR/scripts/reload-nginx.sh"
chmod 600 "$CERT_DIR/key.pem"

# 确保续期 cron 存在
"$ACME" --install-cronjob >/dev/null 2>&1 || true
crontab -l 2>/dev/null | grep -q acme.sh && log "acme.sh 续期 cron 已就绪" || warn "未找到 acme.sh 的 cron，请检查 crontab -l"

log "证书位置：$CERT_DIR"
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -enddate
if ! nginx_running; then
    next_step "docker compose up -d"
fi
