# Template-Build 使用说明

适用于：已有完整源代码（包含 `Dockerfile`）的项目，在服务器上本地构建镜像。

> 💡 **推荐**：直接用网关向导，它会按正确顺序自动完成下面全部步骤，不用手改容器名和域名。
> 在 `ProxyGateway/` 下运行 `./scripts/manage.sh` 选「接入新站点」，或直接 `./scripts/new-site.sh`。

## 步骤

1. **复制文件夹**
   ```bash
   cp -r Template-Build my-project
   cd my-project
   ```

2. **迁移源码**
   把 **源代码** 与 **Dockerfile** 放入当前目录，确保 `docker build .` 能成功构建。
   > 模板自带一个 `src/index.html` 占位文件，仅为让 `docker compose up -d --build` 开箱即可跑通；
   > 放入自己的源码后可以直接删掉它（并同步修改 `Dockerfile` 里的 `COPY` 路径）。

3. **准备环境变量**
   ```bash
   cp .env.example .env
   ```
   `docker-compose.yml` 通过 `env_file` 加载它，**必须先复制**，否则 `docker compose` 会报找不到 `.env`。

4. **配置容器**（修改 `docker-compose.yml`）
   - `build: .`: 保持指向 Dockerfile 所在目录。
   - `container_name`: 必须是唯一的容器名 (供 Nginx 引用)。模板里是 `my_build_container`。
   - `volumes`: 需要持久化数据时按注释取消。
   - `networks: proxy_net`: **必须保留**，否则网关连不上业务容器。

5. **配置路由**（修改 `app.conf`，先改好但**暂不部署**）
   ```nginx
   server {
       server_name myapp.example.com;      # 1. 你的域名
       # ssl_certificate 文件名 = issue_cert.sh 的域名参数 (泛域名证书填主域名)

       location / {
           set $upstream_build my_build_container;  # 2. 对应上面的 container_name
           proxy_pass http://$upstream_build:80;    # 3. 改为应用实际监听的端口
       }
   }
   ```

6. **启动业务（构建并运行）**
   ```bash
   docker compose up -d --build
   ```

7. **申请证书**（必须在部署配置之前）
   ```bash
   cd ../ProxyGateway
   ./scripts/issue_cert.sh myapp.example.com dns_cf
   ```

8. **部署配置并重载**
   ```bash
   cp ../my-project/app.conf nginx/conf.d/my-project.conf   # 网关只读取这个目录
   ./scripts/reload_nginx.sh
   ```

完成后访问 https://myapp.example.com 即可。出问题随时运行 `./scripts/doctor.sh` 自检。

---

> ⚠️ **为什么证书必须排在部署配置之前**：`app.conf` 引用了证书文件，若先部署配置再签证书，
> 其间任何一次网关重启都会因找不到证书而失败。更多运维说明见 [仓库根 README](../README.md)。
