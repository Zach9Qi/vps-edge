# 由 scripts/01-host-setup.sh 安装到 /etc/logrotate.d/edge-nginx
# 每天轮转一次，保留 14 天，旧日志 gzip 压缩
__EDGE_DIR__/logs/nginx/*.log {
    su root root
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        # 让 nginx 重新打开日志文件，继续往新文件里写
        docker exec nginx nginx -s reopen >/dev/null 2>&1 || true
    endscript
}
