#!/bin/bash

# ======================================================
# ProxyGateway 健康自检工具
# ======================================================
# 一屏总览: Docker 环境 / 配置文件 / Compose 合并 / 容器状态 /
#           公共网络 / Nginx 配置与站点 / 端口监听 / 证书到期 / 磁盘占用
# 用法: ./doctor.sh  (可在任意目录运行)
# ======================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

OK()   { echo -e "  ${C_OK}[正常]${C_END} $1"; }
BAD()  { echo -e "  ${C_ERR}[异常]${C_END} $1"; echo -e "         ${C_ERR}→${C_END} $2"; PROBLEMS=$((PROBLEMS+1)); }
WARN() { echo -e "  ${C_WARN}[提醒]${C_END} $1"; }
SKIP() { echo -e "  ${C_WARN}[跳过]${C_END} $1"; }

PROBLEMS=0

ui_header "ProxyGateway 健康自检  $(date '+%Y-%m-%d %H:%M:%S')"

# ---------- 1. Docker 环境 ----------
ui_section "[1/9] Docker 环境"
if ! command -v docker >/dev/null 2>&1; then
    BAD "Docker 未安装" "安装: curl -fsSL https://get.docker.com | sh"
    echo -e "${C_ERR}${UI_WIDE}${C_END}"
    err "Docker 未安装, 无法继续检查"
    exit 1
fi
OK "Docker 已安装 ($(docker --version | cut -d, -f1))"
if ! docker info >/dev/null 2>&1; then
    BAD "Docker 守护进程未运行" "启动: sudo systemctl start docker"
else
    OK "Docker 守护进程运行中"
fi
if docker compose version >/dev/null 2>&1; then
    OK "Docker Compose v2 可用 ($(docker compose version --short 2>/dev/null || echo v2))"
else
    BAD "docker compose (v2) 不可用" "独立的 docker-compose v1 已 EOL, 请安装 compose 插件"
fi

# ---------- 2. 配置文件 ----------
ui_section "[2/9] 配置文件"
if [ -f "$GATEWAY_DIR/.env" ]; then
    OK ".env 存在"
    # 占位邮箱: 签发能成功, 但 CA 的到期提醒邮件无人接收
    ENV_EMAIL=$(grep -E '^ACME_EMAIL=' "$GATEWAY_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
    if [ -z "$ENV_EMAIL" ] || [ "$ENV_EMAIL" = "$PLACEHOLDER_EMAIL" ]; then
        WARN "ACME_EMAIL 仍是示例值 ($PLACEHOLDER_EMAIL), 证书到期提醒邮件将无人接收"
        echo -e "         ${C_WARN}→${C_END} 编辑 .env 后执行: cd $GATEWAY_DIR && docker compose up -d"
    else
        OK "证书邮箱已配置 ($ENV_EMAIL)"
    fi
else
    BAD ".env 缺失" "执行: cp .env.example .env && nano .env (或运行 $SCRIPT_DIR/setup.sh)"
fi

# 账号凭证: main 之外的账号由 add_account.sh 生成, 一并检查
if [ -f "$GATEWAY_DIR/accounts/main.env" ]; then
    OK "accounts/main.env 存在"
    if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]#]+' "$GATEWAY_DIR/accounts/main.env" 2>/dev/null; then
        OK "main.env 已填写凭证"
    else
        BAD "main.env 未填写 DNS Token (只有注释或空值)" "编辑: nano $GATEWAY_DIR/accounts/main.env"
    fi
else
    BAD "accounts/main.env 缺失" "执行: cp accounts/main.env.example accounts/main.env (或运行 $SCRIPT_DIR/setup.sh)"
fi

for ACCOUNT_ENV in "$GATEWAY_DIR"/accounts/*.env; do
    [ -e "$ACCOUNT_ENV" ] || continue
    ACCOUNT_NAME=$(basename "$ACCOUNT_ENV" .env)
    [ "$ACCOUNT_NAME" = "main" ] && continue
    if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]#]+' "$ACCOUNT_ENV" 2>/dev/null; then
        OK "accounts/${ACCOUNT_NAME}.env 已填写凭证"
    else
        BAD "accounts/${ACCOUNT_NAME}.env 未填写 DNS Token" "编辑: nano $ACCOUNT_ENV"
    fi
done

# ---------- 3. Compose 配置合并 ----------
ui_section "[3/9] Compose 配置合并 (主文件 + docker-compose.override.yml)"
if [ -f "$GATEWAY_DIR/.env" ] && [ -f "$GATEWAY_DIR/accounts/main.env" ]; then
    if COMPOSE_CHECK=$(cd "$GATEWAY_DIR" && docker compose config --quiet 2>&1); then
        OK "compose 配置有效"
    else
        BAD "compose 配置解析失败" "在 ProxyGateway 目录执行: docker compose config 查看详情"
        echo "$COMPOSE_CHECK" | sed 's/^/         /'
    fi
else
    SKIP "配置文件缺失 (见上一节), 跳过合并检查"
fi

# ---------- 4. 容器状态 ----------
ui_section "[4/9] 容器状态"
CHECK_CONTAINER() {
    local C=$1 REQUIRED=${2:-1} STATE
    STATE=$(docker ps -a --filter "name=^${C}$" --format '{{.State}}' 2>/dev/null)
    case "$STATE" in
        running) OK "$C 运行中" ;;
        "")      if [ "$REQUIRED" -eq 1 ]; then
                     BAD "$C 不存在" "在 ProxyGateway 目录执行: docker compose up -d"
                 else
                     WARN "$C 不存在 (override 文件里为它保留了配置?)"
                 fi ;;
        *)       BAD "$C 状态异常 ($STATE)" "查看: docker logs --tail 50 $C" ;;
    esac
}
CHECK_CONTAINER "$NGINX_CONTAINER"
CHECK_CONTAINER "gateway_watchtower"

# 账号容器: main 之外由 add_account.sh 生成, 必须一起检查
# (漏检的账号容器一旦挂掉, 该账号的证书会静默过期)
ACME_LIST=$(acme_containers)
if [ -z "$ACME_LIST" ]; then
    BAD "未发现任何账号容器 (${ACME_PREFIX}*)" "在 ProxyGateway 目录执行: docker compose up -d"
else
    for C in $ACME_LIST; do
        CHECK_CONTAINER "$C"
    done
fi

# ---------- 5. 公共网络 ----------
ui_section "[5/9] 公共网络 proxy_net"
if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx 'proxy_net'; then
    OK "proxy_net 已创建"
else
    BAD "proxy_net 不存在" "先启动网关: cd $GATEWAY_DIR && docker compose up -d (业务容器依赖它)"
fi

# ---------- 6. Nginx 配置与已接入站点 ----------
ui_section "[6/9] Nginx 配置与已接入站点"
if container_running "$NGINX_CONTAINER"; then
    if NGINX_TEST=$(docker exec "$NGINX_CONTAINER" nginx -t 2>&1); then
        CONF_COUNT=$(ls -1 "$GATEWAY_DIR/nginx/conf.d"/*.conf 2>/dev/null | wc -l)
        OK "配置语法正确 (conf.d 共 ${CONF_COUNT} 个文件)"
    else
        BAD "配置语法错误" "docker exec $NGINX_CONTAINER nginx -t 查看详情"
        echo "$NGINX_TEST" | sed 's/^/         /'
    fi
    # 列出已配置的站点域名 (帮助快速确认接入状态)
    SITES=$(site_domains)
    if [ -n "$SITES" ]; then
        echo "$SITES" | while IFS= read -r SITE_ITEM; do ui_bullet "$SITE_ITEM"; done
    else
        WARN "conf.d 中尚未配置任何站点域名 (接入站点: $SCRIPT_DIR/new-site.sh)"
    fi
else
    SKIP "$NGINX_CONTAINER 未运行, 跳过配置检查"
fi

# 站点配置漂移: conf.d 部署副本应与项目源 app.conf 一致 (纯文件比对, 不依赖容器)
# [Note] 找不到项目源的站点 (00_common/default 等网关自身配置, 或项目在仓库外) 自动跳过
DRIFT_CHECKED=0
DRIFT_LIST=""
for DEPLOYED_CONF in "$GATEWAY_DIR"/nginx/conf.d/*.conf; do
    [ -e "$DEPLOYED_CONF" ] || continue
    SITE_NAME=$(basename "$DEPLOYED_CONF" .conf)
    SRC_APPCONF=$(project_appconf "$SITE_NAME") || continue
    DRIFT_CHECKED=$((DRIFT_CHECKED+1))
    cmp -s "$SRC_APPCONF" "$DEPLOYED_CONF" && continue
    DRIFT_LIST="${DRIFT_LIST}${SITE_NAME}
"
done
if [ -n "$DRIFT_LIST" ]; then
    WARN "以下站点的 conf.d 副本与项目源 app.conf 不一致 (改了源未部署, 或手改了 conf.d 未同步回项目)"
    echo -e "         ${C_WARN}→${C_END} 以项目源重新部署: $SCRIPT_DIR/deploy_conf.sh <项目名>; 若 conf.d 才是最新, 先拷回项目 app.conf"
    echo "$DRIFT_LIST" | while IFS= read -r DRIFT_ITEM; do
        [ -n "$DRIFT_ITEM" ] && ui_bullet "$DRIFT_ITEM"
    done
elif [ "$DRIFT_CHECKED" -gt 0 ]; then
    OK "站点配置与项目源一致 (${DRIFT_CHECKED} 个可比对站点)"
fi

# 同一域名被多个 conf 文件声明: Nginx 只认先加载的一个, 其余 server 块被静默忽略
# (new-site.sh 已在入口拦截; 这里兜底检测历史遗留/手改造成的冲突, 纯文件比对不依赖容器)
DUP_LIST=""
while IFS= read -r DUP_DOMAIN; do
    [ -n "$DUP_DOMAIN" ] || continue
    DUP_OWNERS=$(conf_files_with_domain "$DUP_DOMAIN")
    [ "$(printf '%s\n' "$DUP_OWNERS" | grep -c .)" -ge 2 ] || continue
    DUP_LIST="${DUP_LIST}${DUP_DOMAIN} → $(printf '%s' "$DUP_OWNERS" | tr '\n' ' ')
"
done < <(site_domains)
if [ -n "$DUP_LIST" ]; then
    WARN "以下域名被多个配置文件同时声明 (Nginx 只认先加载的一个, 其余不生效):"
    echo -e "         ${C_WARN}→${C_END} 下线多余的配置后重载; 更新某个站点: $SCRIPT_DIR/deploy_conf.sh <项目名>"
    printf '%s' "$DUP_LIST" | while IFS= read -r DUP_ITEM; do
        [ -n "$DUP_ITEM" ] && ui_bullet "$DUP_ITEM"
    done
fi

# ---------- 7. 端口监听 ----------
ui_section "[7/9] 端口监听 (80/443)"
if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
    SKIP "未找到 ss/netstat 工具, 无法检查端口"
else
    for PORT in 80 443; do
        LISTENING=$(port_listener "$PORT")
        if [ -n "$LISTENING" ]; then
            OK "端口 ${PORT} 已监听 ($LISTENING)"
        else
            BAD "端口 ${PORT} 未监听" "检查网关是否启动; 云安全组/防火墙也需放行 ${PORT}"
        fi
    done
fi

# ---------- 8. 证书 ----------
ui_section "[8/9] 证书状态 (剩余有效天数)"
CERT_PROBE=$(acme_containers running | head -1)
CERT_DOMAINS=$(ssl_cert_domains)
if [ -z "$CERT_DOMAINS" ]; then
    WARN "ssl 目录中尚未部署任何证书 (首次使用: $SCRIPT_DIR/new-site.sh)"
else
    while IFS= read -r D; do
        [ -n "$D" ] || continue
        # 缺私钥的证书会让下一次 reload/重启失败, 必须显式报出来
        if [ ! -f "$CERT_DIR_HOST/${D}.key" ]; then
            BAD "$D 证书缺少私钥 (nginx/ssl/${D}.key)" "重新签发: $SCRIPT_DIR/issue_cert.sh $D <dns提供商>"
            continue
        fi
        if [ -n "$CERT_PROBE" ]; then
            DAYS=$(cert_days_left "$CERT_PROBE" "$D" 2>/dev/null || true)
        else
            DAYS=""
        fi
        if [ -z "$DAYS" ]; then
            WARN "$D (无法读取有效期, 需有账号容器在运行)"
        elif [ "$DAYS" -lt 0 ]; then
            BAD "$D 证书已过期 (${DAYS} 天)" "排查: docker logs --tail 50 $CERT_PROBE"
        elif [ "$DAYS" -lt 30 ]; then
            WARN "$D 仅剩 ${DAYS} 天, 自动续期可能已中断"
            echo -e "         ${C_WARN}→${C_END} 排查: docker logs --tail 50 $CERT_PROBE"
        else
            OK "$D 剩余 ${C_BOLD}${DAYS}${C_END} 天"
        fi
    done <<< "$CERT_DOMAINS"
fi

# 未被检测的账号容器 = 该账号的自动续期已停 (证书最终会静默过期)
STOPPED_ACME=$(acme_containers | while IFS= read -r C; do
    [ -n "$C" ] && ! container_running "$C" && echo "$C"
done)
if [ -n "$STOPPED_ACME" ]; then
    BAD "有账号容器未在运行, 其名下证书不会自动续期" "启动: cd $GATEWAY_DIR && docker compose up -d"
    echo "$STOPPED_ACME" | while IFS= read -r STOPPED_ITEM; do ui_bullet "$STOPPED_ITEM"; done
fi

# ---------- 9. 磁盘占用 ----------
ui_section "[9/9] 磁盘占用"
DISK_LINE=$(df -h / 2>/dev/null | awk 'NR==2')
if [ -n "$DISK_LINE" ]; then
    DISK_USE=$(echo "$DISK_LINE" | awk '{print $5}' | tr -d '%')
    DISK_INFO=$(echo "$DISK_LINE" | awk '{print $3" / "$2" ("$5")"}')
    if [ -n "$DISK_USE" ] && [ "$DISK_USE" -ge 90 ]; then
        BAD "根分区使用率 ${DISK_INFO}" "清理: docker system prune -a --volumes 后重试"
    elif [ -n "$DISK_USE" ] && [ "$DISK_USE" -ge 80 ]; then
        WARN "根分区使用率偏高 ${DISK_INFO}"
    else
        OK "根分区 ${DISK_INFO}"
    fi
else
    SKIP "无法读取磁盘信息"
fi
for D in nginx/ssl acme; do
    [ -d "$GATEWAY_DIR/$D" ] || continue
    OK "$D 占用 $(du -sh "$GATEWAY_DIR/$D" 2>/dev/null | cut -f1)"
done

# ---------- 汇总 ----------
echo ""
echo -e "${C_TITLE}${UI_WIDE}${C_END}"
if [ "$PROBLEMS" -eq 0 ]; then
    echo -e " 结果: ${C_OK}${C_BOLD}✓ 全部正常${C_END}"
    exit 0
else
    echo -e " 结果: ${C_ERR}${C_BOLD}✗ 发现 ${PROBLEMS} 个问题${C_END} ${C_DIM}(按上方 → 提示处理)${C_END}"
    exit 1
fi
