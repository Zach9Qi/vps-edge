#!/usr/bin/env bash
# 输出客户端配置：default 账号的 VLESS 分享链接 + mihomo (Clash Meta) 配置片段；以及账号 / 出口的情况
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env
load_keys
users_load
exits_load

if [ "$EDGE_ROLE" = edge ]; then
    i="$(user_index default)" || die "没有账号 default（手机用的那条链接）：运行 edge user add default 重新创建"
    DEFAULT_UUID="${USER_UUIDS[$i]}"
    # YAML 双引号字符串：转义 \ 和 "
    NODE_NAME_YAML="${NODE_NAME//\/\\}"
    NODE_NAME_YAML="${NODE_NAME_YAML//\"/\\\"}"
    LINK="$(vless_link "$DEFAULT_UUID" "$NODE_NAME")"

    cat <<EOT
================ 客户端配置（账号 default）================
地址 (address)     : ${REALITY_SNI}
端口 (port)        : 443
UUID (id)          : ${DEFAULT_UUID}
流控 (flow)        : xtls-rprx-vision
传输 (network)     : tcp
安全 (security)    : reality
SNI (serverName)   : ${REALITY_SNI}
指纹 (fingerprint) : chrome
公钥 (publicKey)   : ${XRAY_PUBLIC_KEY}
shortId            : ${XRAY_SHORT_ID}
出口               : ${USER_EXITS[$i]}（$(exit_desc "${USER_EXITS[$i]}")）

---- 分享链接 ----
${LINK}

---- mihomo / Clash Meta ----
proxies:
  - name: "${NODE_NAME_YAML}"
    type: vless
    server: ${REALITY_SNI}
    port: 443
    uuid: ${DEFAULT_UUID}
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
EOT
else
    cat <<'EOT'
================ 内网出口模式 ================
这台机器只给同一内网里的入口机当出口（EDGE_ROLE=exit），没有给手机直接用的链接。
入口机用的链接，给每台入口机建一个账号：
  edge user add <名字>      新建账号，打印内网链接
  edge user list            查看账号
==============================================
EOT
fi

# ---------- 账号 / 出口（只有一个 default 账号、没有出口和内网入口时不显示）----------
if [ ${#OUT_NAMES[@]} -gt 0 ] || [ ${#USER_NAMES[@]} -gt 1 ] || [ -n "$EXIT_LISTEN" ] \
   || { [ "$EDGE_ROLE" = exit ] && [ ${#USER_NAMES[@]} -gt 0 ]; }; then
    echo
    echo "---- 账号 / 出口 ----"
    for i in "${!USER_NAMES[@]}"; do
        printf '  %-20s → %s（%s）\n' "${USER_NAMES[$i]}" "${USER_EXITS[$i]}" "$(exit_desc "${USER_EXITS[$i]}")"
    done
    if [ -n "$EXIT_LISTEN" ]; then echo "  内网入口：$EXIT_LISTEN"; fi
    echo "  其他账号的链接：edge user show <名字>    管理账号和出口：edge chain"
fi
