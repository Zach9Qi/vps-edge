#!/usr/bin/env bash
# 检查配置并平滑重载 nginx。acme.sh 续期成功后也会调用这个脚本
# nginx 容器没在运行时直接跳过（首次签发证书时容器可能还没启动）
set -u
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx; then
    echo "nginx 容器未运行，跳过 reload"
    exit 0
fi
if ! docker exec nginx nginx -t -q; then
    echo "nginx 配置检查失败，未重载" >&2
    exit 1
fi
docker exec nginx nginx -s reload && echo "nginx 已重载"
