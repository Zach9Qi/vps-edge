# 反向代理站点：__SITE_DOMAIN__ → __UPSTREAM__
# 由 scripts/add-site.sh 生成（业务站点），或由 02-init.sh 生成（伪装站 00-decoy.conf，上游是 127.0.0.1:DECOY_PORT）
# 业务站点可以按需手动修改（改完执行 bash scripts/reload-nginx.sh）；伪装站请改模板后重跑 02-init.sh

server {
    listen 127.0.0.1:8443 ssl proxy_protocol;
    http2 on;
    server_name __SITE_DOMAIN__;

    ssl_certificate     /etc/nginx/certs/__CERT_DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/__CERT_DOMAIN__/key.pem;

    include /etc/nginx/snippets/security-headers.conf;

    location / {
        include /etc/nginx/snippets/proxy-headers.conf;
        proxy_pass http://__UPSTREAM__;
    }
}
