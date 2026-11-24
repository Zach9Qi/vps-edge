#!/usr/bin/env bash
# 主机初始化：只补装缺少的工具 + 开启 BBR + 安装 nginx 日志轮转规则
# 端口访问控制交给 VPS 安全组，本脚本不动主机防火墙；可重复执行
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
require_root

command -v docker >/dev/null || die "未检测到 docker"
docker compose version >/dev/null 2>&1 || die "未检测到 docker compose 插件"

# 本方案只依赖这四个，系统里已有的不会重复安装：
#   curl      安装 acme.sh、调用 Cloudflare API
#   openssl   生成 shortId、查看证书有效期
#   cron      acme.sh 每日检查续期
#   logrotate nginx 日志每日轮转
missing=()
command -v curl      >/dev/null || missing+=(curl)
command -v openssl   >/dev/null || missing+=(openssl)
command -v crontab   >/dev/null || missing+=(cron)
command -v logrotate >/dev/null || missing+=(logrotate)
if [ ${#missing[@]} -gt 0 ]; then
    command -v apt-get >/dev/null || die "缺少：${missing[*]}，请用系统的包管理器手动安装"
    log "安装缺少的工具：${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
else
    log "curl / openssl / cron / logrotate 都已存在，不需要安装任何包"
fi
systemctl enable --now cron >/dev/null 2>&1 || true

log "开启 BBR"
cat >/etc/sysctl.d/99-edge.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
# OpenVZ/LXC 等容器型 VPS、没有 tcp_bbr 模块的内核，或其他 sysctl 文件出错时这里会失败：
# BBR 只是优化，失败只提醒，不中止安装
modprobe tcp_bbr >/dev/null 2>&1 || true
sysctl -q --system >/dev/null 2>&1 || true
cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
if [ "$cc" = bbr ]; then
    log "当前拥塞控制：bbr"
else
    warn "BBR 未生效（当前：$cc），不影响使用；容器型 VPS（OpenVZ/LXC）通常无法开启"
fi

log "安装 nginx 日志轮转规则：/etc/logrotate.d/edge-nginx"
mkdir -p "$EDGE_DIR/logs/nginx"
render "$EDGE_DIR/host/logrotate-nginx.tpl" /etc/logrotate.d/edge-nginx EDGE_DIR
chmod 644 /etc/logrotate.d/edge-nginx
logrotate -d /etc/logrotate.d/edge-nginx >/dev/null 2>&1 || warn "logrotate 配置自检失败，请运行 logrotate -d /etc/logrotate.d/edge-nginx 查看原因"

# 系统镜像如果自带并启用了 ufw，它会挡住 443，这里只提醒、不修改
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    warn "检测到主机上的 ufw 处于启用状态：请执行 ufw allow 443/tcp，或者用 ufw disable 关掉它，只靠安全组"
fi

chmod +x "$EDGE_DIR"/scripts/*.sh
log "主机初始化完成"
next_step "bash scripts/02-init.sh"
