# VPS 边缘层：nginx + Xray（VLESS / REALITY / Vision，偷自己的域名）

在一台只装了 Docker 的 VPS 上：

- **Xray**：VLESS + REALITY + Vision，偷自己的域名（伪装站是你自己的真实网站）
- **nginx**：统一入口，托管多个 HTTPS 站点 / 多个域名
- **证书**：acme.sh + Cloudflare DNS-01 签泛域名证书，自动续期，**不需要 80 端口**
- **DNS**：所有域名都用 Cloudflare 灰云（仅 DNS）
- **端口**：公网入站由 VPS 安全组控制，只放行 SSH 和 443/tcp
- **依赖**：除 Docker 外只需要 curl、openssl、cron、logrotate（缺哪个才装哪个）

**只需要记一个命令**：第一次运行 `bash edge.sh` 一键安装，之后输入 `edge` 打开菜单。

## 快速开始

```bash
# 在 Cloudflare 准备好伪装站域名（灰云）和 API Token 之后（见第 3 节）
cd /opt/edge && bash edge.sh
```

脚本会问 4 个问题（伪装站域名、Cloudflare Token、邮箱、伪装站端口（默认 3000，回车即可）），然后自动完成：补装工具、开 BBR → 签证书 → 生成密钥和配置、启动伪装站应用 → 启动容器 → 健康检查 → 打印客户端分享链接。

装完以后：

```
edge                          打开菜单（所有操作都在里面）
edge add blog.example.com blog 发布 apps/blog（自动分配端口、构建启动、签证书）
edge up blog                  改了 apps/blog 的代码后重新构建、重启
edge check                    健康检查
edge client                   再看一次分享链接
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
│   └── xray-config.json.tpl    Xray 配置
├── nginx/
│   ├── snippets/               公共片段：安全响应头、反代参数
│   ├── nginx.conf              ← 自动生成
│   └── conf.d/                 ← 站点配置（00-decoy.conf 是伪装站，其余每个网站一个文件）
├── xray/
│   ├── config.json             ← 自动生成
│   └── keys.env                ← UUID / 密钥 / shortId（请备份）
├── certs/<根域名>/             ← acme.sh 安装的证书
├── apps/                       应用，每个一个目录（edge 自动构建、启动，见第 5 节）
│   └── decoy/                  伪装站
├── logs/nginx/                 ← nginx 的 access.log / error.log
├── host/logrotate-nginx.tpl    日志轮转规则
└── scripts/                    edge.sh 内部调用的步骤脚本，平时不用直接运行
```

### edge 命令一览

| 命令 | 菜单项 | 作用 |
|---|---|---|
| `edge install` | 9 | 一键安装 / 修复。可以重复执行：已有的密钥、证书、配置、应用都会复用，不会让客户端失效 |
| `edge add <域名> <应用名>` | 3 | 发布 `apps/<应用名>`：自动分配端口、构建启动、签证书（需要时）、配好 HTTPS |
| `edge add <域名> <端口>` | 3 | 反代到一个已经在运行的服务 |
| `edge up [应用名]` | 6 | 应用重新构建、重启（会先拉取最新基础镜像）；不带参数 = 全部应用 |
| `edge remove [域名]` | 4 | 删除网站，对应的应用没有其他网站在用时一并停止（目录保留） |
| `edge sites` | 5 | 查看已有网站、各自的后端和应用 |
| `edge check` | 1 | 检查容器、端口、证书剩余天数、伪装站、各站点、对外暴露的端口 |
| `edge client` | 2 | 打印分享链接和 mihomo 配置片段 |
| `edge apply` | 7 | 改了 `.env` 或模板之后重新生成配置，自动重载（密钥不变） |
| `edge update` | 8 | 拉取 nginx / Xray 新镜像并重启，再 `edge up` 全部应用 |
| `edge rotate-keys` | 10 | 轮换 Xray 密钥（旧客户端失效，需要重新导入） |
| `edge logs [nginx\|xray]` | | 实时查看日志 |
| `edge xray [--raw]` | 11 | 查看 Xray 实际配置（私钥默认隐藏，`--raw` 显示完整），并提示配置是否已生效 |

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
- **伪装站页面**：放在 `apps/decoy/`，安装时会自动构建并启动（见第 6 节）

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

| 想做的事 | 操作 |
|---|---|
| 改页面内容 | 改 `apps/decoy/` 里的文件，然后 `edge up decoy` |
| 根目录新增文件（如 `about.html`） | 在 `apps/decoy/Dockerfile` 第一行 `COPY` 里加上文件名（`assets/` 里加图片不用改），然后 `edge up decoy` |
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

## 8. 日常运维

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

**增加 Xray 用户**：在 `templates/xray-config.json.tpl` 的 `clients` 里加一项（新 UUID 可以用 `cat /proc/sys/kernel/random/uuid` 生成，`email` 填不同的值），然后执行 `edge apply`。

**备份**：`/opt/edge`（可以排除 `logs/`）加上 `/root/.acme.sh/`。换机器时拷到同样的路径，再运行 `bash /opt/edge/edge.sh install` 即可（密钥、证书、站点都会复用，`apps/` 下已发布的应用会按原来的端口自动构建、启动）。应用自己的数据如果用了 Docker 卷，要单独备份。

---

## 9. 常见问题

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

---

## 10. 安全注意事项

- 业务容器的端口**必须**写成 `127.0.0.1:端口:容器端口`：即使安全组以后配错，业务端口也不会绕过 nginx 直接暴露在公网。`edge check` 会列出所有对外监听的端口，方便和安全组规则对照
- Xray 配置里屏蔽了 `geoip:private`，防止通过代理访问本机的 127.0.0.1 服务，不要删除
- `.env`、`xray/keys.env`、`xray/config.json`、`certs/*/key.pem` 都是敏感文件（权限 600）
- 伪装站要像一个真实网站：`apps/decoy/` 里放有正常内容的页面
- 不开 80 端口：现代浏览器默认优先尝试 https，访问过一次后 HSTS 会让浏览器一直走 https；只有极少数手动输入 `http://` 的首次访问会连不上
