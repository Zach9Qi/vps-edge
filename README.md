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
edge client                   再看一次分享链接
edge chain                    链式代理菜单（上游 / 通行证 / 内网入口）
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
│       ├── inbound-internal.json.tpl  内网入口：Shadowsocks 2022（开了内网入口且发过通行证时）
│       ├── egress-direct.json.tpl     直接出网 + 拦截规则（没设上游时）
│       └── egress-upstream.json.tpl   全部转给上游（设了上游时）
├── nginx/
│   ├── snippets/               公共片段：安全响应头、反代参数
│   ├── nginx.conf              ← 自动生成
│   └── conf.d/                 ← 站点配置（00-decoy.conf 是伪装站，其余每个网站一个文件）
├── xray/
│   ├── config.json             ← 自动生成
│   ├── keys.env                ← UUID / 密钥 / shortId / 内网入口密钥（请备份）
│   └── relays.env              ← 已发出的通行证（edge relay 维护，请备份）
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
| `edge client` | 2 | 打印分享链接和 mihomo 配置片段 |
| `edge apply` | 8 | 改了 `.env` 或模板之后重新生成配置，自动重载（密钥不变） |
| `edge update` | 9 | 拉取 nginx / Xray 新镜像并重启，再 `edge up` 全部应用 |
| `edge rotate-keys` | 11 | 轮换 Xray 密钥（旧客户端和所有通行证的链接都失效，需要重新导入） |
| `edge logs [nginx\|xray]` | | 实时查看日志 |
| `edge xray [--raw]` | 12 | 查看 Xray 实际配置（私钥、密码默认隐藏，`--raw` 显示完整），并提示配置是否已生效 |
| `edge chain` | 13 | 链式代理菜单：上游、通行证、内网入口都在里面 |
| `edge upstream ...` | 13 → 1~3 | 设置 / 测试 / 取消上游（本机流量全部转给另一台机器出去），见 8.6 节 |
| `edge relay ...` | 13 → 4~6 | 发放 / 查看 / 吊销通行证（让别的机器把本机当上游），见 8.6 节 |
| `edge internal ...` | 13 → 7~8 | 开启 / 修改 / 关闭内网入口（给同一内网的入口机用），见 8.6 节 |

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

## 8. 链式代理（多台机器串联）

### 8.1 是什么

```
手机 ──► A（入口机）──► B（出口机）──► 目标网站
         只转发，不直连      真正出网，网站看到的是 B 的 IP
```

- 手机照常连 A。A 设置了**上游**以后，把代理流量原样转给 B，自己**不直连任何目标网站**，连 DNS 都不查
- A 上不做任何分流和拦截；拦截内网地址、拦截 BT 这些规则在真正出网的 B 上生效（B 用本项目部署时默认就有）
- 只影响**代理流量**：A 本机自己的 `apt`、证书续期、`docker pull` 仍然直连
- B 挂了，经过 A 的代理流量就上不了网，不会悄悄改成从 A 直连

三个术语：

| 术语 | 是什么 | 在哪台机器上操作 |
|---|---|---|
| **上游** | A 把流量转给谁。一条链接，存在 A 的 `.env` 的 `UPSTREAM` 里 | A：`edge upstream` |
| **通行证** | B 发给 A 的独立凭据，A 拿它把 B 当上游。每张通行证包含一个 UUID（走公网用）和一个 SS 密钥（走内网用），和手机用的主 UUID 互不相干 | B：`edge relay` |
| **内网入口** | B 在内网 IP 上开的 Shadowsocks 2022 入口，给同一内网里的 A 用；只监听内网 IP，不对公网开放 | B：`edge internal` |

### 8.2 选哪种场景

| 场景 | B 怎么部署 | A 用哪条链接 |
|---|---|---|
| **A、B 都用本项目，走公网**（见 8.3） | 完整节点，默认安装即可，什么都不用改 | B 上 `edge relay add` 打印的 `vless://` |
| **A、B 在同一内网**（同一云厂商 VPC、WireGuard、Tailscale；见 8.4） | 完整节点 + 内网入口，或者纯内网出口 | B 上 `edge relay add` 打印的 `ss://`（内网链接） |
| **B 是第三方节点、买来的代理**（见 8.5） | 不归本项目管 | 对方给的链接 |

一台 B 可以同时服务多台 A，也可以同时是完整节点（手机直连）和内网出口。一台机器也可以既是别人的上游、自己又有上游（A → B → C），各自配置互不影响。

### 8.3 场景一：A、B 都用本项目，走公网

两台机器都按第 4 节正常安装成完整节点。然后：

**第 1 步，在 B 上发通行证**（名字随意，建议用入口机的名字）：

```bash
edge relay add A01
```

输出类似：

```
================ 通行证：A01 ================
【公网上的入口机用这条】
vless://2222bbbb-...@www.b-domain.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&...#relay-A01

到入口机上运行（链接两边要加单引号）：
  edge upstream '<上面的链接>'
================================================
```

**第 2 步，在 A 上粘贴链接**：

```bash
edge upstream 'vless://2222bbbb-...#relay-A01'
```

A 会依次：解析链接 → 临时起一个测试用的 Xray，经 B 访问外网，确认出口 IP 是 B 的（见 8.7 节）→ 测试通过才写入 `.env`、重新生成配置、重启 Xray。输出类似：

```
[+] 上游：vless + reality（raw）→ www.b-domain.com:443
[+] 先测试一下（临时启动一个测试用的 Xray，不影响正在运行的服务）
[+] 能连上上游 www.b-domain.com:443
[+] 出口 IP：203.0.113.20（本机：198.51.100.10），流量确实从上游出去
...
[+] 已启用上游：本机的代理流量全部经 www.b-domain.com:443 出去，本机不再直连任何网站
```

完成。手机上的配置不用改，照常连 A。

> 链接里有 `&`、`#` 等字符，命令行里**一定要用单引号括起来**，否则会被 shell 截断。用菜单（`edge chain` → 1）粘贴就不用管引号。

### 8.4 场景二：A、B 在同一内网

前提：A 和 B 在同一个内网里，互相能 `ping` 通对方的内网 IP。下面假设 B 的内网 IP 是 `10.0.0.2`，A 是 `10.0.0.3`。

走内网的好处：延迟更低；很多云厂商的内网流量不计费、不占公网带宽；A 和 B 之间的代理流量不经过公网。

#### B 是完整节点（手机也直连 B）

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

**第 3 步，在 B 上发通行证**：

```bash
edge relay add A01
```

开了内网入口后，每张通行证会打印两条链接：

```
【和本机在同一内网的入口机用这条】走内网：更快，通常也不计公网流量
ss://2022-blake3-aes-128-gcm:...@10.0.0.2:23456#relay-A01

【公网上的入口机用这条】
vless://...@www.b-domain.com:443?...#relay-A01
```

**第 4 步，在 A 上用内网那条**：

```bash
edge upstream 'ss://2022-blake3-aes-128-gcm:...@10.0.0.2:23456#relay-A01'
```

已经发过的通行证在开启内网入口后也自动有了内网链接，`edge relay show <名字>` 重新显示即可，不用重新发。

#### B 是纯内网出口（不需要域名，不对公网提供任何服务）

适合 B 只当出口、不想买域名或不想暴露任何服务的情况。B 上不装 nginx、证书、伪装站，只跑一个 Xray。

**安装 B**：上传项目后运行 `bash edge.sh`，第一个问题选 `2) 纯内网出口`，然后从列出的内网 IP 里选一个、填端口。装完会问是否马上发一张通行证。

想跳过问答：先写好 `.env` 再运行 `bash edge.sh install`：

```bash
EDGE_ROLE=exit
EXIT_LISTEN=10.0.0.2:23456
```

之后和上面一样：放行安全组 → `edge relay add A01`（只打印内网链接）→ 在 A 上 `edge upstream 'ss://...'`。

纯内网出口的安全组**入站只需要 SSH**（加上对内网放行的入口端口），443 也不用开。

### 8.5 场景三：上游是第三方节点或代理

直接把对方给的链接交给 `edge upstream`：

```bash
edge upstream 'vless://...'
edge upstream 'ss://...'
edge upstream 'socks5://用户名:密码@1.2.3.4:1080'
edge upstream 'http://用户名:密码@1.2.3.4:3128'
edge upstream 'https://用户名:密码@proxy.example.com:443'
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

- **http / socks5 不加密**：A 到上游这一段，用户名密码和访问的域名都是明文（网页内容大多是 HTTPS，仍然加密）。上游不在内网时脚本会提醒。能用 `https://` 就别用 `http://`
- **UDP**：http / https 代理不支持 UDP；socks5 要看上游有没有开 UDP（很多住宅代理不开）。UDP 不通时，浏览器的 QUIC 会自动退回 TCP，基本不影响上网，但游戏、语音通话这类只走 UDP 的应用用不了
- **DNS 不会从 A 泄露**：A 交给上游的是域名本身，由上游解析
- 拦截 BT、内网地址这些规则由对方负责；对方不拦 BT 的话，版权投诉会发到对方机器的商家

### 8.6 命令详解

所有操作都可以在菜单里完成：`edge` → `12) 链式代理`（内网出口模式是 `2)`），或者直接 `edge chain`。菜单顶部会显示本机的角色、出口、内网入口和通行证数量。

#### `edge upstream` —— 在入口机（A）上操作

| 命令 | 作用 |
|---|---|
| `edge upstream` | 查看当前上游：协议、地址、打码后的链接；没设置时提示怎么设置 |
| `edge upstream '<链接>'` | 设置或更换上游：解析 → 测试 → 通过后写入 `.env` 并生效 |
| `edge upstream '<链接>' --force` | 测试不通过也启用（比如上游暂时挂了，但你确定链接是对的）。在终端里运行时不加 `--force` 也会问你要不要继续 |
| `edge upstream test` | 只测试当前上游，不改任何配置（8.7 节） |
| `edge upstream off` | 取消上游，恢复直接出网 |

细节：

- 链接保存在 `.env` 的 `UPSTREAM='...'`（权限 600，不进 git），不会写进模板
- 生效失败（比如 Xray 配置检查不通过）会自动恢复原来的设置，正在运行的服务不受影响
- 不能把本机自己的链接设成上游
- 设置了上游以后，生成的 Xray 配置只有一个出口 `upstream`，没有 `direct`（freedom），也没有分流规则：就算以后配置写错，A 也不会从本机直连出网

#### `edge relay` —— 在出口机（B）上操作

| 命令 | 作用 |
|---|---|
| `edge relay add <名字>` | 发一张通行证，打印链接。名字只能用字母、数字、`-`、`_`，最长 32 个字符，不能重复 |
| `edge relay list` | 列出已发的通行证和发放日期（不显示链接） |
| `edge relay show <名字>` | 再次显示某张通行证的链接（忘了链接、开了内网入口、轮换密钥之后用） |
| `edge relay remove <名字>` | 吊销：用它的入口机立刻连不上，你的手机和其他通行证不受影响。不带名字时列出来让你选 |

细节：

- 通行证记在 `xray/relays.env`，一行一张：`名字 UUID SS密钥 发放日期`。不要手动改格式
- 发放 / 吊销都会重新生成配置并重启 Xray，正在使用的连接会断开几秒后自动重连
- B 是完整节点时，每张通行证都有公网链接（`vless://`，和手机走同一个 443 入口，只是 UUID 不同）；开了内网入口时再加一条内网链接（`ss://`）
- 通行证就是一个独立用户，公网链接也能直接导入手机客户端，可以用来给别的设备单独发链接
- Xray 日志里，通行证的流量显示为 `relay-<名字>@edge`，手机的是 `default@edge`

#### `edge internal` —— 在出口机（B）上操作

| 命令 | 作用 |
|---|---|
| `edge internal` | 查看内网入口；在终端里运行时会问要不要开启 / 修改 |
| `edge internal set` | 直接进入交互设置：列出本机的内网 IP 供选择，再填端口 |
| `edge internal <内网IP:端口>` | 开启或修改，例如 `edge internal 10.0.0.2:23456` |
| `edge internal off` | 关闭内网入口：通行证的内网链接失效，公网链接不受影响。纯内网出口模式不能关闭 |

细节：

- 只接受内网地址：`10.x`、`172.16-31.x`、`192.168.x`、`100.64-127.x`（Tailscale 用这一段），并且必须是本机网卡上的 IP；不接受 `0.0.0.0` 和公网 IP
- 目前只支持 IPv4
- 端口不能用 443 / 8443 / 10443 和伪装站端口
- **一张通行证都没有时，内网入口不监听**：Shadowsocks 2022 在没有用户时会退化成单用户模式，只凭服务端密钥就能连，而被吊销的入口机手里正好有这个密钥。发出第一张通行证后自动开始监听
- 地址保存在 `.env` 的 `EXIT_LISTEN`；改了内网入口的 IP 或端口后，已发出的内网链接都要重新导入（`edge relay show <名字>`）

### 8.7 验证：流量真的从上游出去了吗

`edge upstream '<链接>'`、`edge upstream test` 和 `edge check` 都会做这个测试：

1. 用 TCP 连一下上游的地址和端口，确认网络是通的
2. 临时启动一个测试用的 Xray 容器（只监听 `127.0.0.1` 的随机端口，出口就是这个上游），**不影响正在运行的 xray**
3. 分别直接访问、经测试容器访问 `https://www.cloudflare.com/cdn-cgi/trace`，取出返回的 IP
4. 经上游拿到的 IP 和本机的不一样，才算通过

```
[+] 能连上上游 10.0.0.2:23456
[+] 出口 IP：203.0.113.20（本机：198.51.100.10），流量确实从上游出去
```

测完测试容器自动删除。

### 8.8 生成的配置长什么样

想看实际配置运行 `edge xray`（密码打码）或 `edge xray --raw`。下面是示意。

**B（完整节点 + 内网入口，发了一张通行证 A01）**：两个入口共用同一套出口和拦截规则

```json
"inbounds": [
  {
    "tag": "vless-reality", "listen": "127.0.0.1", "port": 10443, "protocol": "vless",
    "settings": { "clients": [
      { "id": "<主 UUID>",  "flow": "xtls-rprx-vision", "email": "default@edge" },
      { "id": "<A01 UUID>", "flow": "xtls-rprx-vision", "email": "relay-A01@edge" }
    ] },
    ...REALITY 设置和现在一样...
  },
  {
    "tag": "internal", "listen": "10.0.0.2", "port": 23456, "protocol": "shadowsocks",
    "settings": {
      "network": "tcp,udp", "method": "2022-blake3-aes-128-gcm", "password": "<服务端密钥>",
      "clients": [ { "password": "<A01 密钥>", "email": "relay-A01@edge" } ]
    }
  }
],
"outbounds": [ direct（freedom）, block（blackhole） ],
"routing":   { 拦截 geoip:private、拦截 bittorrent }
```

**A（设置了上游）**：入口和以前一样，出口只有一个，没有分流规则

```json
"outbounds": [
  {
    "tag": "upstream", "protocol": "shadowsocks",
    "settings": { "servers": [ {
      "address": "10.0.0.2", "port": 23456,
      "method": "2022-blake3-aes-128-gcm", "password": "<服务端密钥>:<A01 密钥>"
    } ] }
  }
]
```

各部分的模板在 `templates/xray/` 下（见第 2 节目录结构）。想加自定义分流规则，改 `templates/xray/egress-direct.json.tpl`，然后 `edge apply`。

### 8.9 安全建议

- **一台入口机一张通行证**：某台入口机被攻破或链接泄露，只吊销它那一张，不用轮换 B 的主密钥，手机也不用重新导入
- **链接就是密码**：只发给对应的入口机，不要贴到公开的地方
- **内网入口只对内网放行**：脚本保证 Xray 只监听内网 IP；安全组再限制来源为入口机的内网 IP，多一层保险
- **轮换密钥（`edge rotate-keys`）会让所有通行证的链接失效**（REALITY 公钥和内网入口的服务端密钥都换了），轮换后在 B 上 `edge relay show <名字>`，再到每台入口机上重新 `edge upstream`
- **http / socks5 上游是明文**，走公网时尽量换成 `https://` 或加密协议
- 出口机不在你手里（第三方）时，它能看到你访问了哪些域名；HTTPS 网页的内容它看不到

### 8.10 常见问题

| 现象 | 排查 |
|---|---|
| 测试提示"连不上上游" | B 的 Xray 没在运行（在 B 上 `edge check`）；地址或端口不对；B 的安全组 / 防火墙没放行（内网入口要放行 TCP 和 UDP，来源包含 A 的内网 IP） |
| 测试提示"经上游访问外网失败" | 链接不对或已失效：通行证被吊销、B 轮换过密钥、内网入口的 IP / 端口改过。在 B 上 `edge relay show <名字>` 拿最新链接；也可能是 B 自己出不了网 |
| 测试提示"出口 IP 和本机一样" | 上游其实就是本机，或者上游又把流量转回了本机 |
| 内网入口没有监听 | 还没发过通行证（没有通行证时故意不监听，见 8.6 节）；或者 `EXIT_LISTEN` 的 IP 不在本机网卡上（`ip -4 addr` 查看，WireGuard / Tailscale 的网卡要先起来） |
| A 设置上游后手机上不了网 | B 挂了或链接失效。先在 A 上 `edge upstream test` 看原因；急用时 `edge upstream off` 立刻恢复直接出网 |
| 经 A 打游戏、语音通话不通，网页正常 | UDP 不通：上游是 http / https 代理（不支持 UDP），或 socks5 上游没开 UDP，或内网入口的安全组没放行 UDP |
| `edge relay add` 提示名字已存在 | 换个名字，或 `edge relay show <名字>` 显示原来那张的链接 |
| 手动改了 `.env` 的 `UPSTREAM` 后 `edge apply` 报错 | 链接两边要加单引号：`UPSTREAM='vless://...'`。推荐用 `edge upstream '<链接>'` 设置 |

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

**增加 Xray 用户**：运行 `edge relay add <名字>`。通行证本质上就是一个独立的用户，打印出来的公网链接（`vless://`）可以导入任何客户端，比如发给另一台手机或家人用，不用了 `edge relay remove <名字>` 单独吊销。用户列表由脚本生成，不要再手动改模板里的 `clients`。

**备份**：`/opt/edge`（可以排除 `logs/`）加上 `/root/.acme.sh/`。`xray/keys.env` 和 `xray/relays.env` 都在里面，恢复后已发出的通行证继续有效。换机器时拷到同样的路径，再运行 `bash /opt/edge/edge.sh install` 即可（密钥、证书、站点都会复用，`apps/` 下已发布的应用会按原来的端口自动构建、启动）。应用自己的数据如果用了 Docker 卷，要单独备份。

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

链式代理相关的问题见 8.10 节。

---

## 11. 安全注意事项

- 业务容器的端口**必须**写成 `127.0.0.1:端口:容器端口`：即使安全组以后配错，业务端口也不会绕过 nginx 直接暴露在公网。`edge check` 会列出所有对外监听的端口，方便和安全组规则对照
- Xray 配置里屏蔽了 `geoip:private`，防止通过代理访问本机的 127.0.0.1 服务，不要删除。设置了上游的入口机不做任何分流，这条规则由真正出网的上游负责（见 8.1 节）
- `.env`、`xray/keys.env`、`xray/relays.env`、`xray/config.json`、`certs/*/key.pem` 都是敏感文件（权限 600）
- 链式代理的安全要点（通行证、内网入口、明文上游）见 8.9 节
- 伪装站要像一个真实网站：`apps/decoy/` 里放有正常内容的页面
- 不开 80 端口：现代浏览器默认优先尝试 https，访问过一次后 HSTS 会让浏览器一直走 https；只有极少数手动输入 `http://` 的首次访问会连不上
