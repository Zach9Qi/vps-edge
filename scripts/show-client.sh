#!/usr/bin/env bash
# 输出客户端配置：VLESS 分享链接 + mihomo (Clash Meta) 配置片段
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env
load_keys

# urlencode <文本>：按 UTF-8 字节做百分号编码（中文、空格、emoji 都可以放进分享链接的 #节点名）
urlencode() {
    local b c out=""
    for b in $(printf '%s' "$1" | od -An -v -tx1); do
        case "$b" in
            3[0-9]|4[1-9a-f]|5[0-9a]|6[1-9a-f]|7[0-9a]|2d|2e|5f|7e)
                printf -v c "\\x$b"; out+="$c" ;;       # 字母、数字、- . _ ~ 原样保留
            *)  out+="%${b^^}" ;;
        esac
    done
    printf '%s' "$out"
}

# YAML 双引号字符串：转义 \ 和 "
NODE_NAME_YAML="${NODE_NAME//\\/\\\\}"
NODE_NAME_YAML="${NODE_NAME_YAML//\"/\\\"}"

LINK="vless://${XRAY_UUID}@${REALITY_SNI}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp&headerType=none#$(urlencode "$NODE_NAME")"

cat <<EOF
================ 客户端配置 ================
地址 (address)     : ${REALITY_SNI}
端口 (port)        : 443
UUID (id)          : ${XRAY_UUID}
流控 (flow)        : xtls-rprx-vision
传输 (network)     : tcp
安全 (security)    : reality
SNI (serverName)   : ${REALITY_SNI}
指纹 (fingerprint) : chrome
公钥 (publicKey)   : ${XRAY_PUBLIC_KEY}
shortId            : ${XRAY_SHORT_ID}

---- 分享链接 ----
${LINK}

---- mihomo / Clash Meta ----
proxies:
  - name: "${NODE_NAME_YAML}"
    type: vless
    server: ${REALITY_SNI}
    port: 443
    uuid: ${XRAY_UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${XRAY_PUBLIC_KEY}
      short-id: ${XRAY_SHORT_ID}
============================================
EOF
