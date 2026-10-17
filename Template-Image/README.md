# Template-Image 使用说明

适用于：有一个现成的 Docker 镜像（如 `gemini-balance`），只需要配置并运行。

> 💡 **推荐**：直接用网关向导，它会按正确顺序自动完成下面全部步骤，不用手改容器名和域名。
> 在 `ProxyGateway/` 下运行 `./scripts/manage.sh` 选「接入新站点」，或直接 `./scripts/new-site.sh`。

## 步骤

1. **复制文件夹**
   ```bash
   cp -r Template-Image my-web-app
   cd my-web-app
   ```

2. **准备环境变量**
   ```bash
   cp .env.example .env
   ```
   `docker-compose.yml` 通过 `env_file` 加载它，**必须先复制**，否则 `docker compose` 会报找不到 `.env`。

3. **配置容器**（修改 `docker-compose.yml`）
   - `image`: 填入你的镜像地址。
   - `container_name`: 起个独一无二的名字 (例如 `my_web_app`)。
   - `environment` / `.env`: 填入应用需要的环境变量。
   - `volumes`: 需要持久化数据时按注释取消。

4. **配置路由**（修改 `app.conf`，先改好但**暂不部署**）
   - `server_name`: 你的域名。
   - `set $upstream_app`: 与上面的 `container_name` 完全一致。
   - `proxy_pass` 端口: 容器**内部**端口 (不映射到宿主机)。
   - `ssl_certificate`: 文件名 = 下一步 `issue_cert.sh` 的域名参数 (签过泛域名证书的填主域名，如 `example.com.pem`)。

5. **启动业务容器**
   ```bash
   docker compose up -d
   ```

6. **申请证书**（必须在部署配置之前）
   ```bash
   cd ../ProxyGateway
   ./scripts/issue_cert.sh your-domain.com dns_cf
   ```

7. **部署配置并重载**
   ```bash
   cp ../my-web-app/app.conf nginx/conf.d/my-web-app.conf   # 网关只读取这个目录
   ./scripts/reload_nginx.sh
   ```

完成后访问 https://your-domain.com 应该就是 HTTPS 了。出问题随时运行 `./scripts/doctor.sh` 自检。

---

> ⚠️ **为什么证书必须排在部署配置之前**：`app.conf` 引用了证书文件，若先部署配置再签证书，
> 其间任何一次网关重启都会因找不到证书而失败。更多运维说明见 [仓库根 README](../README.md)。
