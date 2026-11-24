    {
      "tag": "vless-reality",
      "listen": "127.0.0.1",
      "port": 10443,
      "protocol": "vless",
      "settings": {
        "clients": [
__REALITY_CLIENTS__
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "sockopt": {
          "acceptProxyProtocol": true
        },
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:8443",
          "xver": 1,
          "serverNames": [
            "__REALITY_SNI__"
          ],
          "privateKey": "__XRAY_PRIVATE_KEY__",
          "shortIds": [
            "__XRAY_SHORT_ID__"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
