# VPS 边缘层：nginx + Xray（VLESS / REALITY / Vision，偷自己的域名）

在一台只装了 Docker 的 VPS 上：

- **Xray**：VLESS + REALITY + Vision，偷自己的域名（伪装站是你自己的真实网站）
- **nginx**：统一入口，托管多个 HTTPS 站点 / 多个域名
- **证书**：acme.sh + Cloudflare DNS-01 签泛域名证书，自动续期，**不需要 80 端口**
- **DNS**：所有域名都用 Cloudflare 灰云（仅 DNS）
- **端口**：公网入站由 VPS 安全组控制，只放行 SSH 和 443/tcp
- **依赖**：除 Docker 外只需要 curl、openssl、cron、logrotate（缺哪个才装哪个）
- **链式代理**（可选）：多台机器串联，入口机把流量全部转给出口机，走公网或内网都行，两条命令完成配对（见第 8 节）

**只需要记一个命令**：第一次运行 `bash edge.sh` 一键安装，之后输入 `edge` 打开菜单。

## 快速开始

```bash
# 在 Cloudflare 准备好伪装站域名（灰云）和 API Token 之后（见第 3 节）
cd /opt/edge && bash edge.sh
```

脚本先问这台机器的用途（完整节点 / 纯内网出口，默认完整节点，纯内网出口见 8.4 节），完整节点再问 5 个问题（伪装站域名、Cloudflare Token、邮箱、伪装站端口（默认 3000，回车即可）、伪装站主题（按序号选）），然后自动完成：补装工具、开 BBR → 签证书 → 生成密钥和配置、启动伪装站应用 → 启动容器 → 健康检查 → 打印客户端分享链接。

装完以后：

```
edge                          打开菜单（所有操作都在里面）
edge add blog.example.com blog 发布 apps/blog（自动分配端口、构建启动、签证书）
edge up blog                  改了 apps/blog 的代码后重新构建、重启
edge theme                    切换伪装站主题（列出来按序号选）
edge check                    健康检查
edge client                   再看一次分享链接（--all 连同其他账号的链接一起显示）
edge chain                    账号 / 出口 / 内网入口菜单（多账号、链式代理）
edge help                     所有命令
```

---

## 1. 架构

```
                   VPS（安全组入站只放行 SSH + 443/tcp）
 ┌───────────────────────────────────────────────────────────────┐
 │  :443/tcp  nginx stream（ssl_preread，按 SNI 分流，不解密）       │
 │     ├─ SNI = REALITY_SNI ─► 127.0.0.1:10443  Xray (REALITY)     │
 │     │                          ├ 认证通过 → 代理出站              │
 │     │                          └ 认证失败 → 回落 ↓                │
 │     └─ 其他 SNI ────────────► 127.0.0.1:8443 nginx HTTPS 层      │
 │                                 ├─ REALITY_SNI      → 伪装站应用   │
 │                                 ├─ app1.example.com → :3001      │
 │                                 ├─ blog.foo.com     → :3002      │
 │                                 └─ 未知 SNI / 用 IP 访问 → 拒绝握手 │
 │                                                               │
 │  业务容器：只绑定 127.0.0.1:300x                                  │
 │  acme.sh（宿主机 cron）─出站─► Cloudflare API（写 TXT 记录）        │
 │        └─ 续期成功 → scripts/reload-nginx.sh                     │
 └───────────────────────────────────────────────────────────────┘
```

PROXY protocol 贯穿全链路（stream → Xray → nginx），网站日志和后端服务都能拿到访客的真实 IP。

| 设计 | 原因 |
|---|---|
| nginx 占 443，Xray 在后面 | 多个站点只依赖 nginx；Xray 重启、升级、配置出错都不影响网站 |
| nginx / Xray 用 host 网络 | 不经过 Docker NAT，真实 IP 和 IPv6 不丢 |
| 泛域名证书 + DNS-01 | 一个根域名一张证书，新增子域名站点不用再签；续期不依赖任何入站端口 |
| Xray 不使用证书 | REALITY 不需要证书，证书续期只要 reload nginx |
| nginx 日志写到宿主机文件 | 升级镜像、重建容器都不丢；logrotate 每天轮转，保留 14 天；访问日志和错误日志分开 |

---

## 2. 目录结构

```
vps-edge/                       → 上传到 VPS 的 /opt/edge
├── edge.sh                     ★ 唯一入口：安装、菜单、所有日常操作
├── .env.example                配置模板（edge.sh 首次运行时会自动生成 .env）
├── docker-compose.yml          nginx + xray
├── templates/                  配置模板（由脚本渲染）
│   ├── nginx.conf.tpl          主配置：stream 分流 + http 公共参数
│   ├── site.conf.tpl           反向代理站点（业务站点和伪装站共用）
│   ├── xray-config.json.tpl    Xray 配置外框（下面几块按需拼进来）
│   └── xray/
│       ├── inbound-reality.json.tpl   公网入口：VLESS + REALITY（完整节点）
│       ├── inbound-internal.json.tpl  内网入口：Shadowsocks 2022（开了内网入口且有 default 以外的账号时）
│       └── egress.json.tpl            出口和路由：每个账号走自己的出口（见 8.8 节）
├── nginx/
│   ├── snippets/               公共片段：安全响应头、反代参数
│   ├── nginx.conf              ← 自动生成
│   └── conf.d/                 ← 站点配置（00-decoy.conf 是伪装站，其余每个网站一个文件）
├── xray/
│   ├── config.json             ← 自动生成
│   ├── keys.env                ← REALITY 密钥 / shortId / 内网入口密钥（请备份）
│   ├── users.env               ← 账号：UUID、密钥、各自的出口（edge user 维护，请备份）
│   └── exits.env               ← 出口的链接（edge exit 维护，请备份）
├── certs/<根域名>/             ← acme.sh 安装的证书
├── apps/                       应用，每个一个目录（edge 自动构建、启动，见第 5 节）
│   └── decoy/                  伪装站（见第 6 节）
│       ├── themes/forma/       主题：FORMA Robotics（人形机器人设计工作室）
│       ├── themes/assistant/   主题：Oriel（AI 私人助手产品站）
│       └── nginx.conf          容器内的静态站配置（所有主题共用）
├── logs/nginx/                 ← nginx 的 access.log / error.log
├── host/logrotate-nginx.tpl    日志轮转规则
└── scripts/                    edge.sh 内部调用的步骤脚本，平时不用直接运行
```

### edge 命令一览

| 命令 | 菜单项 | 作用 |
|---|---|---|
| `edge install` | 10 | 一键安装 / 修复。可以重复执行：已有的密钥、证书、配置、应用都会复用，不会让客户端失效 |
| `edge add <域名> <应用名>` | 3 | 发布 `apps/<应用名>`：自动分配端口、构建启动、签证书（需要时）、配好 HTTPS |
| `edge add <域名> <端口>` | 3 | 反代到一个已经在运行的服务 |
| `edge up [应用名]` | 6 | 应用重新构建、重启（会先拉取最新基础镜像）；不带参数 = 全部应用 |
| `edge theme [主题名]` | 7 | 切换伪装站主题：不带参数列出所有主题按序号选，切换后自动重新构建 |
| `edge remove [域名]` | 4 | 删除网站，对应的应用没有其他网站在用时一并停止（目录保留） |
| `edge sites` | 5 | 查看已有网站、各自的后端和应用 |
| `edge check` | 1 | 检查容器、端口、证书剩余天数、伪装站、各站点、对外暴露的端口 |
| `edge client [--all]` | 2 | 打印 `default` 账号的分享链接和 mihomo 配置片段；`--all` 再列出其他每个账号的链接（公网 `vless://`，开了内网入口时还有内网 `ss://`） |
| `edge apply` | 8 | 改了 `.env` 或模板之后重新生成配置，自动重载（密钥不变） |
| `edge update` | 9 | 拉取 nginx / Xray 新镜像并重启，再 `edge up` 全部应用 |
| `edge rotate-keys` | 11 | 轮换 Xray 密钥和所有账号的 UUID（所有链接都失效，需要重新导入） |
| `edge logs [nginx\|xray]` | | 实时查看日志 |
| `edge xray [--raw]` | 12 | 查看 Xray 实际配置（私钥、密码默认隐藏，`--raw` 显示完整），并提示配置是否已生效 |
| `edge chain` | 13 | 账号 / 出口 / 内网入口菜单 |
| `edge exit ...` | 13 → 1~4 | 添加 / 查看测试 / 更换 / 删除出口（另一台机器、第三方代理），见 8.6 节 |
| `edge user ...` | 13 → 5~10 | 添加 / 查看链接 / 改出口 / 测试 / 删除 / 改名账号，每个账号走自己的出口，见 8.6 节 |
| `edge internal ...` | 13 → 11~12 | 开启 / 修改 / 关闭内网入口（给同一内网的入口机用），见 8.6 节 |

内网出口模式（`EDGE_ROLE=exit`）的菜单只有和 Xray、链式代理有关的项，网站相关的命令（`add` / `up` / `remove` / `sites` / `logs nginx`）不可用。

`scripts/` 里的脚本是 edge 背后的分步实现（`01-host-setup` / `02-init` / `03-issue-cert` / `add-site` …），想单独调试某一步时仍然可以直接运行。`reload-nginx.sh` 会在证书续期后被 acme.sh 自动调用，不要改名或移动。

---

## 3. 准备工作

### 3.1 Cloudflare

1. **DNS 记录**：伪装站域名（如 `www.example.com`）和所有业务子域名，A/AAAA 都指向 VPS，**全部灰云（仅 DNS）**
2. **API Token**：My Profile → API Tokens → Create Token → Custom token
   - 权限：`Zone → DNS → Edit`、`Zone → Zone → Read`
   - Zone Resources：只选你要用的域名
   - 可选：Client IP Address Filtering 填 VPS 的出口 IP

安装时脚本会用这个 Token 查询一次 Cloudflare，确认 Token 有效、能看到你的域名，填错了会让你当场重填。

### 3.2 VPS

- Debian / Ubuntu，已安装 Docker 和 docker compose 插件
- **安全组**：入站只保留 SSH 端口（TCP）和 443（TCP），80 不放行；出站全部放行（签证书要访问 Cloudflare API 和 Let's Encrypt）
- 所有命令都以 root 身份执行
- **伪装站页面**：自带两套主题（`apps/decoy/themes/`），安装时按序号选一套，自动构建并启动（见第 6 节）

---

## 4. 部署

### 4.1 上传

在 Windows 上执行（或者用 WinSCP 之类的工具上传整个目录）：

```powershell
scp -r .\vps-edge root@<VPS_IP>:/opt/edge
```

> 如果文件被转换成了 Windows 换行符（CRLF），脚本会报 `$'\r': command not found`。
> 在 VPS 上执行 `sed -i 's/\r$//' /opt/edge/edge.sh /opt/edge/scripts/*.sh /opt/edge/templates/* /opt/edge/nginx/snippets/*` 即可修复。

### 4.2 一键安装

```bash
cd /opt/edge && bash edge.sh
```

按提示回答问题即可，答案保存在 `/opt/edge/.env`（权限 600）。安装结束时会打印健康检查结果和客户端分享链接，并把 `edge` 命令链接到 `/usr/local/bin/edge`。

想跳过问答（比如自动化部署）：先 `cp .env.example .env` 并填好，再运行 `bash edge.sh install`，脚本发现 `.env` 已填写就不会再问。

中途出错（比如 Token 权限不够、签证书失败）：按提示处理后重新运行 `edge install`，已经完成的部分会直接复用。

### 4.3 验证

- `edge check` 全部显示 OK
- 浏览器打开 `https://<伪装站域名>`：能看到你的伪装站应用，证书有效
- 用客户端导入分享链接，能正常连接
- `https://<VPS_IP>`：握手失败（符合预期）

---

## 5. 新增站点（发布应用）

### 5.1 把应用放进 apps/，edge 全自动发布（推荐）

每个应用一个目录 `apps/<应用名>/`，里面放代码和 `compose.yaml`。**端口不用自己定**，写成 `${APP_PORT}`，由 edge 分配：

```yaml
# apps/blog/compose.yaml
services:
  web:
    build: .                  # 或者 image: <现成的镜像>
    restart: unless-stopped
    ports:
      - "127.0.0.1:${APP_PORT:?请用 edge add / edge up 启动}:8080"   # 冒号后面是容器里的端口
```

```bash
# Cloudflare 加一条灰云 A 记录，然后：
edge add blog.example.com blog
```

edge 会依次：从 3001 开始找一个空闲端口 → 按这个端口构建并启动 `apps/blog` → 证书没有就签 → 生成 nginx 配置并重载。中途失败会把刚启动的应用停掉。

| 想做的事 | 操作 |
|---|---|
| 改了代码 / 页面 | `edge up blog`（拉取最新基础镜像、重新构建、重启；端口不变） |
| 一次更新全部应用 | `edge up` |
| 同一个应用再绑一个域名 | `edge add www.blog.com blog`（复用同一个容器和端口） |
| 下线 | `edge remove blog.example.com`：删掉网站，并停止 `apps/blog` 的容器（目录保留，再 `edge add` 即可恢复） |

应用和端口的对应关系记在 `nginx/conf.d/<域名>.conf` 的第一行（`# app=blog`）和 `proxy_pass` 里，不要删这一行。`apps/` 下的 compose 不要手动 `docker compose up`（拿不到 `APP_PORT`），统一用 `edge up`。

**每个应用单独用 git 管理**：主仓库的 `.gitignore` 忽略了 `apps/` 下除 `decoy` 以外的所有目录，业务应用各自一个仓库，直接 clone 到 `apps/` 下即可：

```bash
cd /opt/edge/apps && git clone <blog 仓库地址> blog
edge add blog.example.com blog           # 首次发布
cd /opt/edge/apps/blog && git pull && edge up blog   # 以后更新
```

迁移机器时如果只 clone 了主仓库，记得把这些应用也重新 clone 回 `apps/`（直接拷贝整个 `/opt/edge` 则不受影响）。

### 5.2 反代到已经在运行的服务

```bash
edge add app.example.com 3001     # 服务自己管理，端口要写成 127.0.0.1:3001:容器端口，不要写成 "3001:容器端口"（会暴露在公网）
```

### 说明

- 证书自动处理：已有能覆盖它的泛域名证书就直接用；没有（比如另一个根域名 `app.foo.com`，或二级子域名 `a.b.example.com`）就自动签一张新的。新根域名需要托管在 Cloudflare，且 Token 的 Zone Resources 包含它
- nginx 配置检查不通过会自动撤销，不会把 nginx 弄坏
- 需要特殊配置（大文件上传、多个 location、静态目录等）的站点，生成后直接编辑 `nginx/conf.d/<域名>.conf`，然后执行 `bash scripts/reload-nginx.sh`
- 删除站点：`edge remove`

stream 分流规则和 Xray 配置都不用改：不是伪装站域名的流量都会进入 HTTPS 层，由 `server_name` 匹配。

---

## 6. 伪装站

伪装站就是访问伪装站域名（`REALITY_SNI`）时看到的网站，REALITY 认证失败的流量（浏览器访问、主动探测）都会落到这里。它就是 `apps/decoy/` 这个应用，和第 5 节的应用写法一样，区别只是端口固定用 `.env` 的 `DECOY_PORT`（默认 3000），由 `edge install` / `edge apply` 自动构建、启动，并生成 `nginx/conf.d/00-decoy.conf`。

### 6.1 主题

`apps/decoy/themes/` 下每个目录是一套完整的网站，同一时间只用一套，由 `.env` 的 `DECOY_THEME` 决定：

| 主题 | 内容 |
|---|---|
| `forma` | FORMA Robotics：人形机器人设计工作室。产品页、设计日志（3 篇文章）、关于我们 / 团队 / 招聘、隐私说明 |
| `assistant` | Oriel：AI 私人助手（邀请制内测）。首页对话演示、价格与常见问题、更新日志、隐私政策 |

两套都是纯静态页面：没有登录、注册、表单这类点了没反应的功能，联系方式一律是邮件，邮箱域名由页面脚本按访问的域名自动生成（`hello@你的域名`），换域名不用改页面。另外都带 404 页面、`robots.txt` 和干净的网址（`/pricing`、`/journal/visor`）。

**多台机器建议用不同的主题**：几台 VPS 显示一模一样的网站，本身就是一个可以把它们关联起来的特征。

### 6.2 常用操作

| 想做的事 | 操作 |
|---|---|
| 换主题 | `edge theme`（或菜单 7）：列出所有主题，按序号选，自动重新构建；也可以直接 `edge theme assistant` |
| 改页面内容 | 改 `apps/decoy/themes/<主题>/` 里的文件，然后 `edge up decoy` |
| 新增页面 | 在主题目录里放 `xxx.html`，访问地址就是 `/xxx`；不用改 Dockerfile |
| 加一套自己的主题 | 新建 `apps/decoy/themes/<名字>/`，至少要有 `index.html`（建议再放一个 `404.html`）；再建一个 `.about` 文件，第一行写一句说明，会显示在 `edge theme` 的列表里（构建时会被排除，不会出现在网站上） |
| 换端口 | 改 `.env` 的 `DECOY_PORT`，然后 `edge apply` |

注意：
- **应用挂了不影响代理**。REALITY 只需要 nginx 在 8443 完成 TLS 握手，后面的应用没起来时，代理照常能用，只是外人访问会看到 502。`edge check` 会检查这种情况
- 页面要像一个**看起来正常、能公开访问**的网站，不要放敏感内容
- 不要直接改 `nginx/conf.d/00-decoy.conf`，下次 `edge apply` 会覆盖

---

## 7. 证书自动续期

| 环节 | 说明 |
|---|---|
| 定时任务 | acme.sh 安装时会在 root 的 crontab 里加一条每日任务（`crontab -l` 可以看到） |
| 验证方式 | DNS-01：通过 Cloudflare API 写 `_acme-challenge` TXT 记录，验证完自动删除，只有出站请求 |
| 凭据 | `CF_Token` 第一次签发时保存在 `~/.acme.sh/account.conf` |
| 安装 | 新证书写到 `certs/<根域名>/`，nginx 以只读方式挂载 |
| 生效 | 执行 `scripts/reload-nginx.sh`：先 `nginx -t` 检查，再平滑 reload |

常用命令：

```bash
~/.acme.sh/acme.sh --list                                   # 证书列表和下次续期时间
~/.acme.sh/acme.sh --renew -d example.com --ecc --force     # 手动强制续期一次，验证整条链路
tail -n 100 ~/.acme.sh/acme.sh.log                          # 续期日志
```

**建议配置失败通知**（acme.sh 支持邮件、Telegram、Bark 等，详见 acme.sh 文档的 notify 章节），例如 Telegram：

```bash
export TELEGRAM_BOT_APITOKEN="..." TELEGRAM_BOT_CHATID="..."
~/.acme.sh/acme.sh --set-notify --notify-hook telegram --notify-level 2
```

Token 被删除或权限被修改都会导致续期失败；`edge check` 会在证书剩余不足 15 天时报警。

---

## 8. 多账号与链式代理

### 8.1 是什么

三个概念：

| 术语 | 是什么 | 命令 |
|---|---|---|
| **账号** | 一个独立凭据 = 一条链接。自己的手机、家人的设备、给另一台机器（入口机）当出口，都是账号。**每个账号指定一个出口** | `edge user` |
| **出口** | 账号的流量从哪出去。`direct` 是内置的：本机直接出网；其他出口都是一条链接：另一台本项目的机器、第三方节点或代理 | `edge exit` |
| **内网入口** | 本机在内网 IP 上开的 Shadowsocks 2022 入口，给同一内网里的入口机用；只监听内网 IP，不对公网开放 | `edge internal` |

完整节点自带账号 `default`，就是 `edge client` 显示的那条链接，不能删除。其他账号的链接用 `edge user show <名字>` 单独看，或者 `edge client --all` 一次全部列出来。

一个例子：A 在香港，B 是美国的完整节点，C 是和 A 在同一个 VPC 里的纯内网出口。手机导入 A 的三条链接，想走哪条路就选哪个节点：

```
链接 default → A ──────────────► 目标网站     网站看到的是 A 的 IP
链接 work    → A ──► B ────────► 目标网站     网站看到的是 B 的 IP
链接 jp      → A ─(内网)─► C ──► 目标网站     网站看到的是 C 的 IP
```

**每台机器只管自己这一跳**（账号 → 出口），整条链自然串起来。比如 B 上给 A 用的账号如果指向 B 的另一个出口 D，就成了 A → B → D，A 不需要知道 B 后面还有什么。

### 8.2 严格按配置走

- **每个账号只走它的出口。出口挂了就是连不上，不会改走本机直连**：Xray 选定出口后不会自动换别的出口（生成的配置里没有 balancer / observatory）
- 第一个出口是 `block`：没匹配到任何规则的连接（Xray 默认用第一个出口）一律丢弃，不会掉进直连
- 至少有一个账号走 `direct` 时，配置里才有直连（freedom）出口；所有账号都走别的出口时，配置里根本没有直连这条路
- 账号指向的出口不存在：生成配置时直接报错；还有账号在用的出口：不能删除；生成或检查不通过：恢复原来的配置，正在运行的服务不受影响
- **走出口的账号，本机连 DNS 都不查**：域名原样交给下一跳解析
- 改账号的出口只能明确地操作（`edge user set-exit`），交互模式下改成 `direct` 还要再确认一次
- 只影响代理流量：本机自己的 `apt`、证书续期、`docker pull` 仍然直连

拦截规则：

| 规则 | 作用于 | 为什么 |
|---|---|---|
| BT（`bittorrent`） | 所有账号 | 版权投诉会发到出网那台机器的商家；在入口就拦掉，也省下到下一跳的带宽。只能识别没加密的 BT |
| 内网地址（`geoip:private`） | 走 `direct` 的账号 | 防止有人把本机当跳板，访问本机 `127.0.0.1` 上的服务（`edge add` 发布的应用、伪装站）、所在内网的其他机器、云厂商的元数据接口（`169.254.169.254`）。解析到内网 IP 的域名也会拦 |

走出口的账号不加内网地址这条：加了的话本机就要先查 DNS 才能判断，等于在本机留下 DNS 记录。内网地址交给真正出网的那一跳去拦（下一跳也是本项目时，它的 `direct` 默认就拦）。

### 8.3 例子：一台入口机，三条路

按 8.1 的例子，三台机器都按第 4 节装好（C 装成纯内网出口，见 8.4）。

**在 B 上给 A 建一个账号**（名字随意，建议用入口机的名字；出口默认 `direct`）：

```bash
edge user add hk-a
```

```
================ 账号：hk-a ================
出口：direct（本机直接出网）

【公网链接】导入手机、电脑的客户端；或者给公网上的入口机当出口
vless://2222bbbb-...@www.b-site.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&...#US01-hk-a

给入口机当出口时，到入口机上运行（链接两边要加单引号）：
  edge exit add <出口名> '<上面的链接>'
================================================
```

**在 C 上同样建一个**，C 是纯内网出口，只打印内网链接：

```bash
edge user add hk-a
# → ss://2022-blake3-aes-128-gcm:...@10.0.0.3:23456#JP01-hk-a
```

**在 A 上添加两个出口**（会先测试，确认出口 IP 确实是对方的，通过才保存；这一步不改 Xray 配置，不会断线）：

```bash
edge exit add us-b 'vless://2222bbbb-...#US01-hk-a'
edge exit add jp-c 'ss://2022-blake3-aes-128-gcm:...@10.0.0.3:23456#JP01-hk-a'
```

**在 A 上建两个账号，各自指定出口**：

```bash
edge user add work --exit us-b      # → 打印 A 的链接（work）
edge user add jp   --exit jp-c      # → 打印 A 的链接（jp）
```

完成。手机导入 A 的 `default`、`work`、`jp` 三条链接。`edge user list` 查看：

```
[+] 共 3 个账号（名字 → 出口）
  default              → direct         本机直接出网
  work                 → us-b           vless + reality（raw）→ www.b-site.com:443
  jp                   → jp-c           shadowsocks（2022-blake3-aes-128-gcm）→ 10.0.0.3:23456
```

出故障时：

| 情况 | default | work | jp |
|---|---|---|---|
| B 挂了 | 正常 | **连不上**，不会改走 A 直出 | 正常 |
| C 挂了 | 正常 | 正常 | **连不上** |
| 想删出口 `us-b` | 拒绝，提示 work 还在用 | | |
| 想让 work 改走直连 | 只能明确执行 `edge user set-exit work direct` | | |

> 链接里有 `&`、`#` 等字符，命令行里**一定要用单引号括起来**，否则会被 shell 截断。用菜单（`edge chain`）粘贴就不用管引号。

### 8.4 下一跳怎么部署

| 场景 | 下一跳（B）怎么部署 | 入口机（A）用哪条链接 |
|---|---|---|
| **A、B 都用本项目，走公网** | 完整节点，默认安装即可 | B 上 `edge user add` 打印的 `vless://` |
| **A、B 在同一内网**（同一云厂商 VPC、WireGuard、Tailscale） | 完整节点 + 内网入口，或者纯内网出口 | B 上 `edge user add` 打印的 `ss://`（内网链接） |
| **B 是第三方节点、买来的代理** | 不归本项目管 | 对方给的链接（见 8.5） |

一台 B 可以同时服务多台 A（每台 A 一个账号），也可以同时是完整节点（手机直连）和内网出口。

#### 走内网：B 是完整节点

前提：A 和 B 互相能 `ping` 通对方的内网 IP。下面假设 B 的内网 IP 是 `10.0.0.2`，A 是 `10.0.0.3`。走内网延迟更低，很多云厂商的内网流量不计费，A 和 B 之间的代理流量也不经过公网。

**第 1 步，在 B 上开启内网入口**（只需要做一次）：

```bash
edge internal                      # 交互：列出本机的内网 IP 让你选，再填端口（默认 23456）
edge internal 10.0.0.2:23456       # 或者直接指定
```

脚本会检查这个 IP 确实是内网地址、确实在本机网卡上，不是就拒绝（防止代理端口暴露到公网）。

**第 2 步，在云厂商的安全组 / 防火墙里放行这个端口**：

| 方向 | 协议 | 端口 | 来源 |
|---|---|---|---|
| 入站 | TCP 和 UDP | 23456 | A 的内网 IP（`10.0.0.3/32`），或者整个内网网段 |

UDP 也要放行，否则经过 A 的 UDP 流量（QUIC、游戏、语音）过不去。

**第 3 步，在 B 上建账号**：`edge user add A01`。开了内网入口后，除了 `default` 以外的账号都会多一条内网链接（`ss://...@10.0.0.2:23456`）。已有的账号不用重建，`edge user show <名字>` 重新显示即可。

**第 4 步，在 A 上用内网那条**：`edge exit add b-lan 'ss://...'`，再让账号走它。

#### 走内网：B 是纯内网出口

适合 B 只当出口、不想买域名或不想暴露任何服务的情况。B 上不装 nginx、证书、伪装站，只跑一个 Xray，没有 `default` 账号。

**安装 B**：上传项目后运行 `bash edge.sh`，第一个问题选 `2) 纯内网出口`，然后从列出的内网 IP 里选一个、填端口。装完会问是否马上建一个账号。

想跳过问答：先写好 `.env` 再运行 `bash edge.sh install`：

```bash
EDGE_ROLE=exit
EXIT_LISTEN=10.0.0.2:23456
```

之后和上面一样：放行安全组 → `edge user add A01`（只打印内网链接）→ 在 A 上 `edge exit add`。

纯内网出口的安全组**入站只需要 SSH**（加上对内网放行的入口端口），443 也不用开。

### 8.5 第三方节点或代理当出口

直接把对方给的链接交给 `edge exit add`：

```bash
edge exit add vendor1 'vless://...'
edge exit add vendor2 'ss://...'
edge exit add home    'socks5://用户名:密码@1.2.3.4:1080'
edge exit add office  'https://用户名:密码@proxy.example.com:443'
```

支持的链接：

| 链接 | 支持的写法 | 说明 |
|---|---|---|
| `vless://` | `security=reality / tls / none`；`type=tcp(raw) / ws / grpc / xhttp / httpupgrade` | 不支持 `headerType=http` |
| `ss://` | SIP002 base64 写法、SIP022 明文写法、老式整段 base64 | 加密方式只支持 AEAD 和 2022 系列；不支持插件（`plugin=`） |
| `socks5://`（也认 `socks://`） | 有无认证都行；用户名密码可以是百分号编码，也可以是 base64 | **明文**，见下 |
| `http://` | 有无认证都行 | **明文**，只能走 TCP |
| `https://` | 套了 TLS 的 HTTP 代理 | 加密，只能走 TCP |

暂不支持 `trojan://`、`vmess://`。

注意：

- **http / socks5 不加密**：本机到出口这一段，用户名密码和访问的域名都是明文（网页内容大多是 HTTPS，仍然加密）。出口不在内网时脚本会提醒。能用 `https://` 就别用 `http://`
- **UDP**：http / https 代理不支持 UDP，socks5 要看对方有没有开 UDP（很多住宅代理不开）。UDP 不通时就是不通，不会改走直连；浏览器的 QUIC 会自动退回 TCP，基本不影响上网，但游戏、语音通话这类只走 UDP 的应用用不了
- 内网地址的拦截由对方负责；BT 在本机就拦了

### 8.6 命令详解

所有操作都可以在菜单里完成：`edge` → `13) 账号 / 出口 / 内网入口`（内网出口模式是 `2)`），或者直接 `edge chain`。菜单顶部会显示本机的角色、内网入口、出口，以及每个账号走哪个出口。

#### `edge user`：账号

| 命令 | 作用 |
|---|---|
| `edge user add <名字> [--exit <出口>]` | 新建账号，打印链接。名字只能用字母、数字、`-`、`_`，最长 32 个字符。交互运行时不带 `--exit` 会列出出口让你选；**非交互运行、本机又有出口时必须带 `--exit`**，免得走错 |
| `edge user list` | 列出账号、各自的出口、创建日期（不显示链接） |
| `edge user show <名字>` | 再次显示链接（忘了链接、开了内网入口、轮换密钥之后用） |
| `edge user set-exit <名字> <出口>` | 修改账号的出口。**链接不变，客户端不用重新导入** |
| `edge user rename <旧名字> <新名字>` | 给账号改名。UUID、密钥、出口都不变，**用旧链接的设备 / 入口机照常能连**；只是客户端里显示的节点名还是旧的，想跟着改就 `edge user show <新名字>` 重新导入。`default` 不能改名，也不能改成 `default` |
| `edge user test <名字>` | 临时起一个客户端，用这个账号的链接连本机，看流量是不是从该走的出口出去（见 8.7） |
| `edge user remove <名字>` | 删除：用它的设备 / 入口机立刻连不上，其他账号不受影响。`default` 不能删 |

细节：

- 账号记在 `xray/users.env`，一行一个：`名字 UUID SS密钥 创建日期 出口`。不要手动改格式
- 新建、修改、改名、删除账号都会重新生成配置并重启 Xray，正在使用的连接会断开几秒后自动重连
- 完整节点上每个账号都有公网链接（`vless://`，大家走同一个 443 入口，只是 UUID 不同）；开了内网入口时，`default` 以外的账号再加一条内网链接（`ss://`）
- Xray 日志里，账号的流量显示为 `<名字>@edge`

#### `edge exit`：出口

| 命令 | 作用 |
|---|---|
| `edge exit add <名字> '<链接>'` | 添加出口：解析 → 测试 → 通过才保存。名字规则同账号，`direct`、`block` 是保留名字 |
| `edge exit add ... --force` | 测试不通过也保存（比如对方暂时挂了，但你确定链接是对的）。交互运行时不加 `--force` 也会问你 |
| `edge exit update <名字> '<链接>'` | 更换出口的链接（对方轮换了密钥、换了地址），走它的账号不用改 |
| `edge exit list` | 列出出口、打码后的链接、哪些账号在用 |
| `edge exit test <名字>` | 只测试，不改任何配置 |
| `edge exit remove <名字>` | 删除；还有账号在用时拒绝，并列出是哪些账号 |

细节：

- 出口记在 `xray/exits.env`，一行一个：`名字 链接`（权限 600，不进 git）
- 没有账号在用的出口不会放进 Xray 配置，所以添加、删除这种出口不用重启 Xray
- 不能把本机自己的链接设成出口

#### `edge internal`：内网入口

| 命令 | 作用 |
|---|---|
| `edge internal` | 查看内网入口；在终端里运行时会问要不要开启 / 修改 |
| `edge internal set` | 直接进入交互设置：列出本机的内网 IP 供选择，再填端口 |
| `edge internal <内网IP:端口>` | 开启或修改，例如 `edge internal 10.0.0.2:23456` |
| `edge internal off` | 关闭内网入口：账号的内网链接失效，公网链接不受影响。纯内网出口模式不能关闭 |

细节：

- 只接受内网地址：`10.x`、`172.16-31.x`、`192.168.x`、`100.64-127.x`（Tailscale 用这一段），并且必须是本机网卡上的 IP；不接受 `0.0.0.0` 和公网 IP
- 目前只支持 IPv4；端口不能用 443 / 8443 / 10443 和伪装站端口
- `default` 不进内网入口。**除了 `default` 一个账号都没有时，内网入口不监听**：Shadowsocks 2022 在没有用户时会退化成单用户模式，只凭服务端密钥就能连，而被删除账号的入口机手里正好有这个密钥
- 地址保存在 `.env` 的 `EXIT_LISTEN`；改了 IP 或端口后，已发出的内网链接都要重新导入

### 8.7 验证：流量真的从该走的出口出去了吗

`edge exit add`、`edge exit test` 和 `edge check` 测出口；`edge user test` 测账号。做法一样：

1. 用 TCP 连一下对方的地址和端口，确认网络是通的
2. 临时启动一个测试用的 Xray 容器（只监听 `127.0.0.1` 的随机端口），**不影响正在运行的 xray**
3. 分别直接访问、经测试容器访问 `https://www.cloudflare.com/cdn-cgi/trace`，取出返回的 IP
4. 测出口：拿到的 IP 和本机**不一样**才算通过；测账号：走出口的账号要和本机不一样，走 `direct` 的账号要和本机**一样**

`edge user test` 的测试容器是用这个账号的链接连本机自己的 443，走的是和手机一模一样的路径，所以它验证的是**实际生效的路由**。想确认"B 挂了也不会回落"：在 B 上 `docker stop xray`，再在 A 上 `edge user test work`，结果应该是失败，而不是显示 A 的 IP。

```
[+] 测试账号 work：临时起一个客户端用它的链接连本机，看流量从哪出去（应该走 us-b：vless + reality（raw）→ www.b-site.com:443）
[+] 能连上 www.a-site.com:443
[+] 出口 IP：203.0.113.20（本机：198.51.100.10），流量确实从另一台机器出去
[+] 账号 work 测试通过
```

### 8.8 生成的配置长什么样

想看实际配置运行 `edge xray`（密码打码）或 `edge xray --raw`。下面是 8.3 例子里 A 的出口和路由部分：

```json
"outbounds": [
  { "tag": "block", "protocol": "blackhole" },
  { "tag": "direct", "protocol": "freedom" },
  { "tag": "exit-us-b", "protocol": "vless", ... },
  { "tag": "exit-jp-c", "protocol": "shadowsocks", ... }
],
"routing": {
  "domainStrategy": "IPOnDemand",
  "rules": [
    { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" },
    { "type": "field", "user": [ "default@edge" ], "ip": ["geoip:private"], "outboundTag": "block" },
    { "type": "field", "user": [ "default@edge" ], "outboundTag": "direct" },
    { "type": "field", "user": [ "work@edge" ], "outboundTag": "exit-us-b" },
    { "type": "field", "user": [ "jp@edge" ], "outboundTag": "exit-jp-c" }
  ]
}
```

- `IPOnDemand` 只在判断 `ip` 条件时才查 DNS；同一条规则里 `user` 条件先判断，不满足就不再往下看。所以只有走 `direct` 的账号会在本机查 DNS，work 和 jp 不会
- 没有账号走 `direct` 时，不会生成 `direct` 出口和那两条规则，`domainStrategy` 是 `AsIs`
- 没有账号在用的出口不会出现在这里

出口和路由由 `scripts/lib.sh` 的 `xray_egress` 生成，填进 `templates/xray/egress.json.tpl`。想加自定义规则可以改这个模板，但注意不要破坏上面"严格按账号走"的几条（第一个出口是 `block`、不要加回落）。

### 8.9 安全建议

- **一台入口机、一个人一个账号**：某台入口机被攻破或链接泄露，只删它那一个账号，不用轮换密钥，其他设备也不用重新导入
- **链接就是密码**：只发给对应的人或机器，不要贴到公开的地方
- **内网入口只对内网放行**：脚本保证 Xray 只监听内网 IP；安全组再限制来源为入口机的内网 IP，多一层保险
- **轮换密钥（`edge rotate-keys`）会换掉所有账号的 UUID**，连同 REALITY 公钥和内网入口的服务端密钥，所有链接都失效。轮换后用 `edge user show <名字>` 拿新链接；给入口机当出口的，到入口机上 `edge exit update`
- **http / socks5 出口是明文**，走公网时尽量换成 `https://` 或加密协议
- 出口不在你手里（第三方）时，它能看到你访问了哪些域名；HTTPS 网页的内容它看不到

### 8.10 常见问题

| 现象 | 排查 |
|---|---|
| 测试提示"连不上 …" | 对方的 Xray 没在运行（在对方上 `edge check`）；地址或端口不对；对方的安全组 / 防火墙没放行（内网入口要放行 TCP 和 UDP，来源包含入口机的内网 IP） |
| 测试提示"经 … 访问外网失败" | 链接不对或已失效：对方删了账号、轮换过密钥、内网入口的 IP / 端口改过。在对方上 `edge user show <名字>` 拿最新链接，再 `edge exit update`；也可能是对方自己出不了网 |
| 测试提示"出口 IP 和本机一样" | 出口其实就是本机，或者对方又把流量转回了本机 |
| 某个账号上不了网，其他正常 | 它的出口挂了或链接失效：`edge user test <名字>` 看原因，`edge exit test <出口>` 单独测出口；急用时 `edge user set-exit <名字> <别的出口>` |
| `edge user add` 提示"请用 --exit 指定" | 非交互运行、本机又有出口时，必须明确写出账号走哪个出口 |
| `edge exit remove` 被拒绝 | 还有账号在用它：先 `edge user set-exit` 改到别的出口，或者删掉这些账号 |
| 内网入口没有监听 | 除了 `default` 还没有账号（故意不监听，见 8.6）；或者 `EXIT_LISTEN` 的 IP 不在本机网卡上（`ip -4 addr` 查看，WireGuard / Tailscale 的网卡要先起来） |
| 经入口机打游戏、语音通话不通，网页正常 | UDP 不通：出口是 http / https 代理（不支持 UDP），或 socks5 出口没开 UDP，或内网入口的安全组没放行 UDP |

---

## 9. 日常运维

日常操作直接运行 `edge` 打开菜单即可，下面是对应的命令和少数菜单外的操作：

| 操作 | 命令 |
|---|---|
| 查看状态 | `edge check` |
| 查看日志 | `edge logs`（nginx）/ `edge logs xray`；历史日志是 `logs/nginx/access.log.2.gz` 这类文件，用 `zcat` 查看 |
| 改了 `.env` 或 `templates/*.tpl` | `edge apply` |
| 改了 `apps/<应用名>/` 的代码 | `edge up <应用名>` |
| 只改了某个站点配置 `nginx/conf.d/*.conf` | `bash scripts/reload-nginx.sh` |
| 升级镜像 | `edge update`：nginx 跟随 `stable-alpine`，Xray 跟随官方 `ghcr.io/xtls/xray-core:latest`（只含正式版，不含 Pre-release） |
| Xray 升级后出问题 | 回退到上一个正式版：`.env` 里改 `XRAY_IMAGE=ghcr.io/xtls/xray-core:<版本号，不带 v>`（版本见 [Releases](https://github.com/XTLS/Xray-core/releases)），然后 `edge apply`。配置模板用的是新版写法（`raw` / `target`），只回退到最近的正式版，不要退到很老的版本 |
| 轮换 Xray 密钥 | `edge rotate-keys` |
| 手动测试日志轮转 | `logrotate -f /etc/logrotate.d/edge-nginx` |

**增加 Xray 用户**：运行 `edge user add <名字>`，打印出来的链接可以导入任何客户端，比如发给另一台手机或家人用，还可以给它单独指定出口；不用了 `edge user remove <名字>` 单独删除。用户列表由脚本生成，不要再手动改模板里的 `clients`。

**备份**：`/opt/edge`（可以排除 `logs/`）加上 `/root/.acme.sh/`。`xray/keys.env`、`xray/users.env`、`xray/exits.env` 都在里面，恢复后已发出的链接继续有效。换机器时拷到同样的路径，再运行 `bash /opt/edge/edge.sh install` 即可（密钥、证书、站点都会复用，`apps/` 下已发布的应用会按原来的端口自动构建、启动）。应用自己的数据如果用了 Docker 卷，要单独备份。

---

## 10. 常见问题

| 现象 | 排查 |
|---|---|
| 安装时提示 Token 无效 / 看不到域名 | Token 权限要有 `Zone → Zone → Read` 和 `Zone → DNS → Edit`，Zone Resources 要包含该域名 |
| nginx 启动失败 `cannot load certificate` | 证书没签下来，看签发失败的提示，处理后重新运行 `edge install` |
| nginx 报 `bind() to [::]:443 failed` | 主机没有 IPv6，在 `.env` 里设 `ENABLE_IPV6=false`，然后 `edge apply` |
| 外部完全连不上 443 | 检查安全组是否放行了 443/tcp；主机如果启用了 ufw，也要放行 443 |
| 客户端连不上 | `edge logs xray`；确认客户端填的 SNI、公钥(pbk)、shortId 和 `edge client` 输出的一致；确认伪装站域名是灰云 |
| 浏览器访问伪装站报证书错误 | 看 `certs/<根域名>/` 有没有证书，以及伪装站域名是否在证书覆盖范围内 |
| 网站日志里的 IP 全是 127.0.0.1 | 某个 `listen` 少写了 `proxy_protocol`，或者 realip 配置被改动过 |
| 后端 502 | 后端容器没起来，或者端口没有绑定在 `127.0.0.1:<端口>` |
| 签发失败 | Token 权限、Zone Resources 是否包含该域名；`tail ~/.acme.sh/acme.sh.log` |

多账号、链式代理相关的问题见 8.10 节。

---

## 11. 安全注意事项

- 业务容器的端口**必须**写成 `127.0.0.1:端口:容器端口`：即使安全组以后配错，业务端口也不会绕过 nginx 直接暴露在公网。`edge check` 会列出所有对外监听的端口，方便和安全组规则对照
- 走 `direct` 的账号屏蔽了 `geoip:private`，防止通过代理访问本机的 127.0.0.1 服务、所在内网和云厂商元数据接口，不要删除。走别的出口的账号这条规则由真正出网的那一跳负责（见 8.2 节）
- 每个账号严格走自己的出口，出口挂了不会回落到本机直连（见 8.2 节）
- `.env`、`xray/keys.env`、`xray/users.env`、`xray/exits.env`、`xray/config.json`、`certs/*/key.pem` 都是敏感文件（权限 600）
- 多账号和链式代理的安全要点（账号、内网入口、明文出口）见 8.9 节
- 伪装站要像一个真实网站：`apps/decoy/` 里放有正常内容的页面
- 不开 80 端口：现代浏览器默认优先尝试 https，访问过一次后 HSTS 会让浏览器一直走 https；只有极少数手动输入 `http://` 的首次访问会连不上
