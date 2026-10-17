# Docker 模块化反向代理网关 (Modular Reverse Proxy)

一套基于 **Nginx + acme.sh + Watchtower** 的现代化、即插即用反向代理解决方案。
专为解决多项目端口冲突、证书管理繁琐、配置耦合度高的问题而设计。

---

## ✅ 前置条件 (开始前自查)

| 检查项 | 说明 | 自查命令 |
|---|---|---|
| Linux 服务器 | 方案依赖 Docker Unix Socket 与宿主机时区挂载, 不支持 Windows/macOS 宿主 | - |
| Docker Engine 24.0+ | 已安装且运行 | `docker info` |
| Docker Compose v2 | 使用内置的 `docker compose` (独立的 v1 已停止维护) | `docker compose version` |
| 域名 | DNS 托管在支持 API 的服务商 (Cloudflare / 阿里云 / DNSPod 等) | - |
| 域名解析 | 域名 A 记录已指向本服务器公网 IP | `ping your-domain.com` |
| 端口放行 | 服务器防火墙与云安全组已放行 80 / 443 | `curl -I http://服务器IP` |

> 💡 DNS API Token 的获取方式见下文 [获取 DNS API Token](#-获取-dns-api-token)。

---

## 📂 目录结构

```text
/ReverseProxy
├── ProxyGateway/                   # [核心] 网关基础设施 (必须先启动)
│   ├── docker-compose.yml          # Nginx + acme(每账号一实例) + Watchtower
│   ├── .env.example                # 环境变量模板 (邮箱 / CA / 时区等公共配置)
│   ├── accounts/                   # [凭证] DNS 账号 Token, 每账号一份 <账号名>.env
│   ├── nginx/
│   │   ├── conf.d/                 # [挂载] 网关配置目录
│   │   │   ├── 00_common.conf      #   ⚠ 全局公共配置, 勿删 (见下方说明)
│   │   │   ├── default.conf        #   未匹配域名时的兜底响应
│   │   │   └── <项目名>.conf       #   你的站点配置 (从这里读取)
│   │   ├── ssl/                    # [挂载] 证书存储池 (所有项目共享)
│   │   └── html/                   # [挂载] 静态文件目录 (默认不对外提供)
│   ├── acme/                       # [数据] acme 账号数据, 每账号一个子目录
│   └── scripts/                    # [工具] 全套运维脚本
│       ├── lib.sh                  #   共享函数库 (被下列脚本引用, 不单独执行)
│       ├── manage.sh               #   ★ 统一管理面板 (新手推荐入口)
│       ├── setup.sh                #   交互式初始化
│       ├── new-site.sh             #   一键接入新站点 (自动保证正确顺序)
│       ├── deploy_conf.sh          #   部署/更新站点配置 (改完 app.conf 用, 备份+回滚)
│       ├── issue_cert.sh           #   证书申请 (多账号, --force 强制重签)
│       ├── reload_nginx.sh         #   安全重载网关 (先语法检查再重载)
│       ├── add_account.sh          #   新增 DNS 账号 (自动生成配置)
│       └── doctor.sh               #   健康自检 (容器/配置/证书/端口/磁盘)
│
├── Template-Image/                 # [模板] 适用于: 现成 Docker 镜像 (如 gemini-balance)
├── Template-Build/                 # [模板] 适用于: 本地 Dockerfile 构建
├── Template-Host/                  # [模板] 适用于: 宿主机直跑程序 (非容器)
│
└── [Your-Project]/                 # 你的实际业务项目
```

> ⚠️ **请勿删除或覆盖 `nginx/conf.d/00_common.conf`**。它提供全局公共配置:
> TLS 协议与加密套件、HSTS、上传大小限制、代理超时、gzip, 以及所有站点配置都要用到的
> `$connection_upgrade` 变量。缺了它, 每个站点的 `nginx -t` 都会失败。
> `default.conf` 负责未匹配域名的请求, 同样建议保留原样。

> 📌 `docker-compose.override.yml` 是本地定制文件: `docker compose` 会自动叠加它,
> 且已被 `.gitignore` 忽略不会提交 (适合放"网关加入特殊网络"等私有配置,
> `add_account.sh` 新增的账号服务也写入这里)。

> 📦 项目已有自己的 compose 文件? 不需要模板, 运行 `new-site.sh` 时
> 选「**项目自带 compose 文件**」即可接入, 向导不会改动你的 compose (详见 FAQ)。

---

## 🚀 快速开始

### 方式一: 管理面板 (推荐)

```bash
cd ProxyGateway
./scripts/manage.sh
# 若提示 Permission denied (zip 下载或从 Windows 拷贝会丢失执行位),
# 处理方法见 FAQ「运行脚本提示 Permission denied」
```

菜单里依次选 **1) 初始化网关** → **2) 接入新站点**, 全程问答, 不用记脚本名。

### 方式二: 分步执行 (与面板等价)

```bash
cd ProxyGateway

# 1. 交互式初始化: 配置邮箱 + DNS Token, 并启动网关
./scripts/setup.sh

# 2. 一键接入第一个站点 (问答式, 自动按安全顺序完成全部步骤)
./scripts/new-site.sh

# 3. 随时自检 (容器/配置/证书/端口/磁盘 一屏总览)
./scripts/doctor.sh
```

### 方式三: 全手动 (不用向导)

<details>
<summary>展开查看手动步骤</summary>

```bash
cd ProxyGateway

# 1. 准备配置 (不熟悉 vi 可用 nano)
cp .env.example .env                             # 邮箱 / 证书颁发机构
cp accounts/main.env.example accounts/main.env   # DNS Token
nano .env
nano accounts/main.env

# 2. 启动网关并确认 (应看到 gateway_nginx / gateway_acme_main / gateway_watchtower)
docker compose up -d
docker ps

# 3. 从模板复制一个业务项目 (以 Template-Image 为例)
cd ..
cp -r Template-Image my-web-app && cd my-web-app
cp .env.example .env
nano docker-compose.yml   # 改 image 与 container_name
nano app.conf             # 改 server_name / 容器名 / 端口 / 证书文件名, 先改好但暂不部署
docker compose up -d

# 4. 申请证书 (必须在部署配置之前, 原因见下)
cd ../ProxyGateway
./scripts/issue_cert.sh app.example.com dns_cf

# 5. 部署配置并重载
cp ../my-web-app/app.conf nginx/conf.d/my-web-app.conf
./scripts/reload_nginx.sh
```

</details>

> ⚠️ **顺序很重要**: `app.conf` 引用了证书文件。若先把配置放进 `conf.d` 再签证书,
> 其间任何一次网关重启都会因找不到证书而失败。DNS-01 签发不依赖网关,
> 因此**永远先签证书, 再部署配置**。用 `new-site.sh` 或 `manage.sh` 会自动保证这个顺序。

### 🔑 获取 DNS API Token

Token 填写在 `accounts/<账号名>.env` (主账号为 `accounts/main.env`):

*   **Cloudflare**:
    *   地址: [My Profile > API Tokens](https://dash.cloudflare.com/profile/api-tokens)
    *   模板: 选择 "Edit zone DNS"
    *   权限: Zone / DNS / Edit
    *   填入 `CF_Token` (`CF_Account_ID` 一般留空)
*   **阿里云**:
    *   地址: [RAM 访问控制](https://ram.console.aliyun.com/users)
    *   建议: 创建一个专用子账号, 仅授权 `AliyunDNSFullAccess`
    *   填入 `Ali_Key` 与 `Ali_Secret`
*   **DNSPod (腾讯云)**:
    *   地址: [DNSPod 密钥管理](https://console.dnspod.cn/account/token/token)
    *   创建密钥后取 **ID** 与 **Token** 两项, 填入 `DP_Id` 与 `DP_Key`

### 🌐 泛域名证书: 一次签发, 全站复用

签发时会**自动同时申请 `<域名>` 和 `*.<域名>`** 两个名字, 例如:

```bash
./scripts/issue_cert.sh example.com dns_cf    # → example.com + *.example.com
./scripts/issue_cert.sh app.example.com dns_cf # → app.example.com + *.app.example.com
```

拿到 `example.com` 的证书后, 所有子域名 (如 `a.example.com`, `b.example.com`) 的
`app.conf` 中 `ssl_certificate` 直接指向 `/etc/nginx/ssl/example.com.pem` 即可,
无需重复签发。证书已存在时重复执行会自动跳过 (避免触发 CA 频率限制),
需要强制重签时加 `--force`。

---

## 🛠️ 进阶运维

### 自动续期原理
*   每个账号一个 `acme_<账号名>` 容器 (默认 `gateway_acme_main`), 容器内自带定时任务,
    **每天检查 4 次** (每 6 小时一次)。
*   到期前自动续签: Let's Encrypt 等支持 ACME ARI (RFC 9773) 的 CA 会按 CA 建议的窗口执行
    (90 天证书通常在剩余约 30 天时续签), 其他 CA 按 acme.sh 的默认续期周期处理。
    续签成功后自动通知 Nginx 热重载。
*   **无需人工干预**; 想确认状态运行 `./scripts/doctor.sh` (会列出每个证书的剩余天数)。

### 镜像自动更新
网关内置 Watchtower ([nickfedor/watchtower](https://github.com/nicholas-fedor/watchtower)),
每天凌晨 4:17 检查并更新**所有带
`com.centurylinklabs.watchtower.enable=true` 标签的容器** —— 包括网关自身
(`gateway_nginx` / `gateway_acme_*` / `gateway_watchtower` 都带该标签)。

*   不希望业务容器被自动更新: 不要给它加这个标签。
*   想完全关闭自动更新: 停掉 Watchtower 容器即可
    ```bash
    cd ProxyGateway && docker compose stop watchtower
    ```

### 升级网关 (拉取本仓库更新)
```bash
cd /path/to/ReverseProxy
git pull
cd ProxyGateway
docker compose up -d      # 让 compose 文件的变更生效 (通常无需重建)
./scripts/doctor.sh       # 确认一切正常
```
> 升级**不会**触碰你的业务项目目录、`nginx/ssl` 证书、`accounts/` 凭证与 `acme/` 数据
> (这些都已被 `.gitignore` 排除)。若本次更新只涉及 `scripts/` 下的脚本,
> 连 `docker compose up -d` 都不用执行, 脚本改动立即生效。

### 健康自检
```bash
./scripts/doctor.sh
# 一屏总览: Docker 环境 / 配置文件 / Compose 合并 / 容器状态 / 网络与端口 /
#           Nginx 配置与已接入站点 / 证书剩余天数 / 磁盘占用
```
发现问题时, 每条异常下面都会有一行 `→` 给出对应的处理命令。

### 更新站点配置
改了项目里的 `app.conf` (例如调整反代规则) 后, 一条命令部署到网关并安全重载:

```bash
cd ProxyGateway
./scripts/deploy_conf.sh <项目名>   # 或 manage.sh 菜单「5) 更新站点配置」
```

部署前自动备份旧配置 (`.conf.bak`), 语法检查失败时自动回滚, 网关不受影响。
项目源文件与 `conf.d` 副本不一致时, `doctor.sh` 会给出漂移提醒。

### 手动重载 Nginx
直接改了 `conf.d` 里的文件、或想单独重载网关时:

```bash
cd ProxyGateway
./scripts/reload_nginx.sh   # 先做语法检查, 通过才重载; 失败不影响运行中的网关
```

### 查看日志
所有网关容器均已限制日志大小 (10m × 3 份), 不会撑爆磁盘:

```bash
# 网关访问/错误日志
docker logs -f --tail 100 gateway_nginx
# 证书申请与续期日志 (按账号选择容器)
docker logs -f gateway_acme_main
```

### 新增同运营商 DNS 账号
不同域名托管在同一 DNS 服务商的不同账号下 (如两个 Cloudflare 账号) 时,
为每个账号启用一个独立的 acme 实例:

```bash
cd ProxyGateway

# 1. 一键生成凭证模板 + compose 配置 (写入 docker-compose.override.yml, 不动主文件)
./scripts/add_account.sh <账号名>

# 2. 填入第二账号的 Token
nano accounts/<账号名>.env

# 3. 启动新账号实例并签发
docker compose up -d
./scripts/issue_cert.sh other.example.com dns_cf <账号名>
```

> 每个账号实例使用独立的凭证文件 (`accounts/<账号名>.env`) 与独立的数据目录
> (`acme/<账号名>`), 自动续期按账号隔离、互不覆盖。主账号为 `main`。
> 同一域名只能属于一个账号 —— 若该域名已被其他账号管理, `issue_cert.sh` 会直接拒绝。

### 下线站点 / 移除账号

<details>
<summary>展开查看退役步骤</summary>

**下线一个站点**:

```bash
cd ProxyGateway

# 1. 摘掉网关配置 (该域名立即断开入口, 不影响其他站点)
rm nginx/conf.d/<项目名>.conf
./scripts/reload_nginx.sh

# 2. 停止业务容器 (加 --rmi all --volumes 可一并清理镜像与数据卷)
cd ../<项目名> && docker compose down

# 3. (可选) 不再使用该域名时, 删除证书记录, 免得继续自动续期
docker exec gateway_acme_main acme.sh --remove -d <域名> --ecc   # 报错则去掉 --ecc
rm -f ../ProxyGateway/nginx/ssl/<域名>.pem ../ProxyGateway/nginx/ssl/<域名>.key
```

**移除一个 DNS 账号**:

```bash
cd ProxyGateway
nano docker-compose.override.yml   # 删掉 acme_<账号名> 整个服务块
rm -f accounts/<账号名>.env
rm -rf acme/<账号名>               # 该账号的所有签发记录
docker compose up -d --remove-orphans   # --remove-orphans 用于清掉遗留容器
```

> 若该账号名下还有在用证书, 先按上面的方式重新用另一个账号签发, 再删除。

</details>

### 本地定制
需要网关加入特殊网络、或任何私有改动时, 写入 `ProxyGateway/docker-compose.override.yml`
(`docker compose` 自动叠加, 已被 `.gitignore` 忽略), 不要改动主 `docker-compose.yml`。

---

## ❓ 常见问题 (FAQ)

**Q: 执行 `docker-compose` 提示命令不存在?**
A: 旧的独立 `docker-compose` (v1) 已停止维护。请使用内置的 `docker compose` (空格分隔, v2), 需安装 Compose 插件。

**Q: 运行脚本提示 `Permission denied`?**
A: 脚本丢失了可执行位 (zip 下载、从 Windows 拷贝时常见; `git clone` 不受影响)。临时绕过: `bash scripts/xxx.sh`; 一次性恢复 (只加入口脚本, 不动被 source 的 lib.sh):
```bash
chmod +x ProxyGateway/scripts/{manage,setup,new-site,deploy_conf,issue_cert,reload_nginx,add_account,doctor}.sh
```
提交新脚本时用 `git update-index --chmod=+x <文件>` 保住执行位。

**Q: `docker ps` 里 `gateway_watchtower` 显示 `8080/tcp`, 是网关开了端口吗?**
A: 不是。那只是 Watchtower 镜像自带的 `EXPOSE 8080` 声明 (它可选的 HTTP API 端口, 本方案未启用), 属于镜像元数据; 网关的 compose 没有做任何端口映射, 该端口未发布到宿主机, 外部不可访问, 无安全影响。`EXPOSE` 声明无法在 compose 层面移除, 属正常显示。

**Q: 我的项目已有自己的 compose 文件, 怎么接入网关?**
A: 运行 `./scripts/new-site.sh`, 在「业务以什么方式运行」选 **4) 项目自带 compose 文件**。向导只生成网关接入文件, 不会改动你的 compose。

- **文件位置**: 网关文件全部放在项目目录下的专属子目录 `gateway.<hash>` 里 (`app.conf` 反代配置、`docker-compose.yml` 参考模板、`GATEWAY.md` 说明), 与项目自身文件互不干扰, 不会重名。其余运行方式 (镜像/构建/宿主机) 仍直接写项目目录, 遇到非向导生成的同名文件会先询问并备份 (`.bak`), 绝不静默覆盖。
- **项目选择**: 选 4 后向导会列出根目录下检测到的项目供直接选用 (回车则沿用输入的名字); 项目放在其他路径也可以 —— 接入只认容器名, 不看路径。
- **compose 接入**: 参考子目录里的 `docker-compose.yml` 模板与 `GATEWAY.md`, 把 `container_name` 与 `proxy_net` 网络配置合并进你自己的 compose; 文件名冲突时可另存别名, 用 `docker compose -f <文件名> up -d` 指定。
- **文件名**: `docker compose` 会自动识别标准命名 (`compose.yaml` / `compose.yml` / `docker-compose.yml` / `docker-compose.yaml`); 用了其他文件名, 启动时 `docker compose -f <文件名> up -d`, 向导也会引导填写。

唯一要求: 业务容器必须加入网关网络 `proxy_net`:
```yaml
services:
  <你的服务名>:
    networks:
      - proxy_net

networks:
  proxy_net:
    external: true
```
不想改文件时也可临时接入 (容器重建后失效): `docker network connect proxy_net <容器名>`。

**Q: 启动业务容器时报错 `network proxy_net not found`?**
A: 必须先启动 `ProxyGateway`, 它负责创建这个公共网络。

**Q: 网站打不开 / 一直转圈?**
A: 按顺序检查: ① 域名 A 记录是否指向本服务器 IP; ② 云厂商安全组/服务器防火墙是否放行 80/443; ③ `./scripts/doctor.sh` 自检。

**Q: 网站返回 502 Bad Gateway?**
A: 网关正常, 是后端没接上。检查 ① 业务容器是否在运行 (`docker ps`); ② `app.conf` 里的容器名/端口是否与业务实际一致。`new-site.sh` 在容器启动失败/未进入运行状态时会直接中止; 若容器在运行但应用自身没监听端口, 站点仍会 502, 需查看后端日志。

**Q: 重启服务器后网关起不来 / 反复重启, 日志报 `cannot load certificate`?**
A: `conf.d` 里有配置引用了尚不存在的证书文件 (先部署了配置但没签证书)。
处理: 先移走该 `.conf` → `docker compose up -d` 恢复网关 → 签发证书 → 再放回配置 → `./scripts/reload_nginx.sh`。按本文档顺序操作不会遇到此问题。

**Q: 证书申请失败, 反复重试后一直失败?**
A: 可能触发了 Let's Encrypt 频率限制 (每小时 5 次失败验证)。把 `.env` 中 `ACME_SERVER` 改为 `letsencrypt_test` (测试环境, 不受限制) 排查, 成功后改回。**改完 `.env` 必须执行 `docker compose up -d`**, 因为环境变量是在容器创建时注入的, 改文件本身不生效。详细日志: `docker logs --tail 100 gateway_acme_main`。

**Q: 申请证书报错 `invalid domain`?**
A: 常见原因: ① API Token 没有该域名的 Zone / DNS 编辑权限, 或域名的 DNS 并不托管在该账号下; ② Cloudflare Token 设置了 **IP 地址白名单**, 而当前服务器 IP 不在白名单内 (前往 Cloudflare 后台 -> API Tokens -> 编辑 Token -> Client IP Address Filtering 放行或移除限制)。

**Q: 签发时为什么把 `*.域名` 也一起签了? 能只签单个域名吗?**
A: 脚本固定同时申请 `<域名>` 与 `*.<域名>` (DNS-01 验证, 顺带覆盖所有子域名), 便于后续复用同一份证书。确实只需要单域名证书时, 可跳过脚本直接执行底层命令:

```bash
cd ProxyGateway
# 1. 注册 CA 账号 (与 .env 的 ACME_SERVER 一致; 已注册过可跳过)
docker exec gateway_acme_main acme.sh --register-account --server letsencrypt -m you@example.com
# 2. 只签发单个域名 (不带通配符)
docker exec gateway_acme_main acme.sh --issue --server letsencrypt --dns dns_cf --dnssleep 60 -d your-domain.com
# 3. 安装到共享证书目录并通知网关热重载 (网关需在运行)
docker exec gateway_acme_main acme.sh --install-cert -d your-domain.com \
    --key-file       /etc/nginx/ssl/your-domain.com.key \
    --fullchain-file /etc/nginx/ssl/your-domain.com.pem \
    --reloadcmd      "curl -s -X POST --unix-socket /var/run/docker.sock http://localhost/containers/gateway_nginx/kill?signal=HUP"
./scripts/reload_nginx.sh
```

> 用第二个账号时把 `gateway_acme_main` 换成 `gateway_acme_<账号名>`; 用阿里云 / DNSPod 时把 `dns_cf` 换成 `dns_ali` / `dns_dp`; `.env` 中 `ACME_SERVER` 不是 `letsencrypt` 时, 把两处 `--server` 换成对应值。

**Q: 如何查看证书到期时间?**
A: `./scripts/doctor.sh` 会列出每个已部署证书的剩余天数。也可用 `docker exec gateway_acme_main acme.sh --list`。续期全自动, 一般无需关心。

**Q: 修改了 `app.conf` 但没生效?**
A: 网关只读取 `ProxyGateway/nginx/conf.d/` 下的文件, 改完项目里的 `app.conf` 必须再部署一次 ——
见上文 [更新站点配置](#更新站点配置)。

**Q: 站点需要默认模板没有的 nginx 参数 (超时 / SSE / 额外 location)?**
A: 运行 `new-site.sh` 时, 「高级选项」一步可直接粘贴原生 nginx 指令, 分别追加到生成的 `location /` 与 `server` 块 (多行整段粘贴, 单独一行 `END` 结束; 全部留空则与默认模板完全一致)。事后调整则直接编辑项目里的 `app.conf`, 再用 `./scripts/deploy_conf.sh <项目名>` 部署。
> ⚠️ 若追加的指令里包含 `add_header`, 注意 Nginx 的继承规则: `location` 块内一旦出现
> `add_header`, 就不再继承外层 (含 `00_common.conf` 的 HSTS 头)。需要 HSTS 时请在
> 同一 `location` 里显式重写一份 `add_header Strict-Transport-Security ...`。

**Q: 上传大文件报 413 Request Entity Too Large?**
A: 不会。全局配置 (`00_common.conf`) 已将 `client_max_body_size` 设为 0 (无限制)。请检查你后端应用本身的限制。

**Q: 子项目挂了，网关会挂吗？**
A: 不会。使用了 Docker DNS 动态解析 (`resolver 127.0.0.11`)，子项目宕机只会导致该域名返回 502 Bad Gateway，不影响其他服务。

**Q: 如何让我的业务容器也自动更新？**
A: 在你的 `docker-compose.yml` 服务下添加 Label，Gateway 里的 Watchtower 就会自动扫描并更新它：
```yaml
labels:
  - "com.centurylinklabs.watchtower.enable=true"
```

**Q: 如何添加同运营商的第二个账号 (如另一个 Cloudflare 账号)?**
A: 见上文 [新增同运营商 DNS 账号](#新增同运营商-dns-账号), 一条命令完成。

---

## 📄 许可

见 [LICENSE](LICENSE)。
