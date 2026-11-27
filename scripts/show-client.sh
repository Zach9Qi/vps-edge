#!/usr/bin/env bash
# 输出客户端配置：default 账号的 VLESS 分享链接 + mihomo (Clash Meta) 配置片段；以及账号 / 出口的情况
#   show-client.sh [--all]：--all 把 default 以外每个账号的链接也打印出来
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
ALL=0
case "${1:-}" in
    "")       ;;
    --all|-a) ALL=1 ;;
    *)        die "用法：edge client [--all]" ;;
esac
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
  edge client --all         显示所有账号的链接
==============================================
EOT
fi

# ---------- --all：default 以外每个账号的链接 ----------
if [ "$ALL" = 1 ]; then
    others=0
    for i in "${!USER_NAMES[@]}"; do
        if [ "${USER_NAMES[$i]}" != default ]; then others=$((others + 1)); fi
    done
    echo
    if [ "$others" -eq 0 ]; then
        if [ "$EDGE_ROLE" = edge ]; then
            echo "---- 其他账号 ----"
            echo "  除了 default 还没有别的账号：edge user add <名字>"
        else
            echo "---- 账号 ----"
            echo "  还没有账号：edge user add <名字>"
        fi
        exit 0
    fi
    # 内网入口能用才打印内网链接；不能用时说一次原因（exit_listen_check 自己会 warn）
    internal=0
    if [ -n "$EXIT_LISTEN" ]; then
        if exit_listen_check "$EXIT_LISTEN"; then internal=1; else warn "内网入口现在不可用，下面不显示内网链接"; fi
    fi
    if [ "$EDGE_ROLE" = edge ]; then echo "---- 其他账号的链接（${others} 个）----"; else echo "---- 账号的链接（${others} 个）----"; fi
    for i in "${!USER_NAMES[@]}"; do
        name="${USER_NAMES[$i]}"
        [ "$name" != default ] || continue
        echo
        echo "【$name】出口：${USER_EXITS[$i]}（$(exit_desc "${USER_EXITS[$i]}")）"
        if [ "$EDGE_ROLE" = edge ]; then
            echo "  公网：$(vless_link "${USER_UUIDS[$i]}" "$(link_name "$name")")"
        fi
        if [ "$internal" = 1 ]; then
            echo "  内网：$(ss_link "${USER_SSKEYS[$i]}" "$(link_name "$name")")"
        elif [ "$EDGE_ROLE" = exit ]; then
            echo "  （没有可用的链接：内网入口没开启或不可用，edge internal 查看）"
        fi
    done
    echo
    echo "链接相当于密码，只发给要用的人或机器。给入口机当出口：入口机上 edge exit add <出口名> '<链接>'"
    exit 0
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
    echo "  所有账号的链接：edge client --all    单个账号：edge user show <名字>    管理：edge chain"
fi
