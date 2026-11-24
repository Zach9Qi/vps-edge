    {
      "tag": "internal",
      "listen": "__EXIT_IP__",
      "port": __EXIT_PORT__,
      "protocol": "shadowsocks",
      "settings": {
        "network": "tcp,udp",
        "method": "__SS_METHOD__",
        "password": "__SS_SERVER_KEY__",
        "clients": [
__SS_CLIENTS__
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
