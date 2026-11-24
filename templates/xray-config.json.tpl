{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "127.0.0.1",
      "port": 10443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "__XRAY_UUID__",
            "flow": "xtls-rprx-vision",
            "email": "default@edge"
          }
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
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
