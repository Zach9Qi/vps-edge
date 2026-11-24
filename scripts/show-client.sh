#!/usr/bin/env bash
# 输出客户端配置：VLESS 分享链接 + mihomo (Clash Meta) 配置片段；以及链式代理的状态
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env
load_keys

if [ "$EDGE_ROLE" = edge ]; then
    # YAML 双引号字符串：转义 \ 和 "
    NODE_NAME_YAML="${NODE_NAME//\\/\\\\}"
    NODE_NAME_YAML="${NODE_NAME_YAML//\"/\\\"}"
    LINK="$(vless_link "$XRAY_UUID" "$NODE_NAME")"

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
      support-x25519mlkem768: true
============================================
EOF
else
    cat <<'EOF'
================ 内网出口模式 ================
这台机器只给同一内网里的入口机当出口（EDGE_ROLE=exit），没有给手机直接用的链接。
入口机要用的链接通过"通行证"发放：
  edge relay add <名字>     发一张通行证，打印链接
  edge relay list           查看已发的通行证
==============================================
EOF
fi

# ---------- 链式代理状态（只在用到时显示）----------
relays_load
if [ -n "$UPSTREAM" ] || [ "${#RELAY_NAMES[@]}" -gt 0 ] || [ -n "$EXIT_LISTEN" ]; then
    echo
    echo "---- 链式代理 ----"
    if [ -n "$UPSTREAM" ]; then
        if upstream_parse "$UPSTREAM" 2>/dev/null; then
            echo "出口      : 经上游 $UP_DESC（本机不直连任何网站）"
        else
            echo "出口      : UPSTREAM 链接有问题，运行 edge upstream 查看"
        fi
    else
        echo "出口      : 本机直接出网"
    fi
    if [ -n "$EXIT_LISTEN" ]; then echo "内网入口  : $EXIT_LISTEN"; fi
    echo "通行证    : ${#RELAY_NAMES[@]} 张（edge relay list 查看，edge relay show <名字> 显示链接）"
fi
