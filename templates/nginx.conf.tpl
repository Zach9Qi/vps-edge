# 由 scripts/02-init.sh 根据 templates/nginx.conf.tpl 生成
# 不要直接修改 nginx/nginx.conf：改模板后重新运行 02-init.sh

user  nginx;
worker_processes  auto;
worker_rlimit_nofile 65535;
error_log  /var/log/nginx/error.log warn;   # 宿主机 logs/nginx/，由 logrotate 每天轮转

events {
    worker_connections  8192;
}

# ======================================================================
# 443/tcp 统一入口：只读取 ClientHello 里的 SNI，不解密，按 SNI 原样转发
# ======================================================================
stream {
    map $ssl_preread_server_name $edge_backend {
        __REALITY_SNI__    xray;   # REALITY 专用 SNI → Xray
        default            web;    # 其他所有 SNI → nginx HTTPS 站点层
    }

    upstream xray { server 127.0.0.1:10443; }
    upstream web  { server 127.0.0.1:8443; }

    # 排查问题时可以打开下面两行：记录 SNI 和分流去向
    # log_format edge '$remote_addr [$time_local] sni="$ssl_preread_server_name" -> $edge_backend $status $bytes_sent/$bytes_received ${session_time}s';
    # access_log /var/log/nginx/stream.log edge;
    access_log off;

    server {
        listen 443 reuseport;
        __STREAM_LISTEN_V6__

        ssl_preread on;
        preread_timeout 10s;
        proxy_pass $edge_backend;
        proxy_protocol on;          # 向下一跳（Xray 或 HTTPS 层）传递真实客户端 IP
        proxy_connect_timeout 5s;
        proxy_timeout 10m;          # 双向都空闲超过 10 分钟才断开
    }
}

# ======================================================================
# HTTPS 站点层：只监听 127.0.0.1:8443，所有连接都带 PROXY protocol
# ======================================================================
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    tcp_nopush      on;
    server_tokens   off;
    keepalive_timeout 65;
    client_max_body_size 64m;

    # ---- 从 PROXY protocol 还原真实客户端 IP ----
    set_real_ip_from 127.0.0.1;
    real_ip_header   proxy_protocol;

    log_format main '$remote_addr [$time_local] "$host" "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" rt=$request_time';
    access_log /var/log/nginx/access.log main;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript
               application/json application/manifest+json application/xml image/svg+xml;

    # ---- TLS 公共参数（REALITY 要求回落目标支持 TLS1.3 + H2）----
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    # Let's Encrypt 已停止 OCSP 服务，不要开启 ssl_stapling

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    # 本方案不监听 80 端口

    # 未匹配的 SNI / 直接用 IP 访问：直接拒绝 TLS 握手，不暴露任何证书
    # SNI 合法但 Host 头不匹配任何站点的请求也会落到这里：直接断开连接，不返回 nginx 默认页
    server {
        listen 127.0.0.1:8443 ssl proxy_protocol default_server;
        ssl_reject_handshake on;
        return 444;
    }

    include /etc/nginx/conf.d/*.conf;
}
