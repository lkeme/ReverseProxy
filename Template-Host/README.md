# Template-Host 使用说明

适用于：业务程序**直接运行在网关所在的这台 Linux 服务器上**（没有容器化，例如直接启动的
Java / Go / Python 程序或二进制文件），希望通过 Docker 网关对外提供 HTTPS 访问。

> 💡 **推荐**：直接用网关向导，在 `ProxyGateway/` 下运行 `./scripts/manage.sh` 选「接入新站点」，
> 第 3 步选「宿主机直跑程序」，一条命令自动完成下面全部步骤。

## 原理
ProxyGateway 的 Nginx 通过特殊域名 `host.docker.internal` 访问宿主机的端口。
网关已内置 `host-gateway` 映射（见 `ProxyGateway/docker-compose.yml` 的 `extra_hosts`），
Linux 宿主机开箱即用，无需额外配置。

> ⚠️ 网关本身只能跑在 Linux 上（依赖 Docker Unix Socket 与宿主机时区挂载）。
> 如果程序跑在 Windows/macOS 电脑上、而网关跑在 Linux 服务器上，`host.docker.internal`
> 指向的是**网关所在的服务器**，不是你的电脑 —— 这种跨机器场景请改用公网地址或内网 IP 反代。

## 步骤

1. **复制文件夹**
   ```bash
   cp -r Template-Host my-host-app
   cd my-host-app
   ```

2. **准备 Nginx 配置**（修改 `app.conf`）
   - `server_name`: 填入域名。
   - `proxy_pass`: 填入 `http://host.docker.internal:端口`（**不要填 127.0.0.1**，那指向容器自身）。
   - 宿主机程序必须监听 `0.0.0.0`（或至少 Docker 网桥地址）。只绑 `127.0.0.1` 时，
     容器内的网关访问不到，站点会返回 502。
   - `ssl_certificate`: 文件名 = 下一步 `issue_cert.sh` 的域名参数（泛域名证书填主域名）。

3. **申请证书**（必须在部署配置之前）
   ```bash
   cd ../ProxyGateway
   ./scripts/issue_cert.sh your-domain.com dns_cf
   ```

4. **部署配置**
   当前目录已是 `ProxyGateway`，把项目里的 `app.conf` 复制过来：
   ```bash
   cp ../my-host-app/app.conf nginx/conf.d/my-host-app.conf
   ```

5. **重载网关**
   本模板没有业务容器需要启动，所以必须手动让网关加载新配置：
   ```bash
   ./scripts/reload_nginx.sh
   ```

6. **完成**
   访问 https://your-domain.com 即可。出问题随时运行 `./scripts/doctor.sh` 自检。

---

> ⚠️ **为什么证书必须排在部署配置之前**：`app.conf` 引用了证书文件，若先部署配置再签证书，
> 其间任何一次网关重启都会因找不到证书而失败。更多运维说明见 [仓库根 README](../README.md)。
