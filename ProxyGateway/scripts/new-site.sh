#!/bin/bash

# ======================================================
# ProxyGateway 一键接入新站点向导
# ======================================================
# 问答式完成: 生成项目文件 → 签发/复用证书 → 启动业务 → 部署网关配置并安全重载
# 自动保证安全顺序 (证书先于配置部署), 自动保证容器名/域名/证书名一致
# 支持四种业务形态: 现成镜像 / 本地构建 / 宿主机直跑 / 已有 compose 项目
# 高级选项: 可直接粘贴原生 nginx 指令, 追加进生成的 app.conf (默认模板不够用时)
# 用法: ./new-site.sh  (需在终端交互运行; 入口即校验网关必须已启动)
# ======================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# ---------- 交互环境检查 ----------
require_interactive

# ---------- 入口前置检查: 网关必须在运行 ----------
# [Note] 放在最前面: 若等 7 步问答答完才报"网关未运行", 用户输入全部作废
require_docker
require_compose_v2
if ! container_running "$NGINX_CONTAINER"; then
    err "网关未运行 ($NGINX_CONTAINER), 本向导需要网关先启动。"
    ui_hint "启动: cd $GATEWAY_DIR && docker compose up -d"
    ui_hint "首次使用: bash $SCRIPT_DIR/setup.sh   (或 manage.sh 菜单选 1 初始化网关)"
    exit 1
fi

# ---------- 本向导专用辅助 ----------
# 列出仓库根目录下"自带 compose 文件"的已有项目 (供模式 4 直接选用)
# 排除: 网关自身 / 模板 / 向导自己生成的项目 / 不能用作项目名的目录名
list_compose_projects() {
    local D BASE CF
    for D in "$ROOT_DIR"/*/; do
        [ -d "$D" ] || continue
        BASE=$(basename "$D")
        [ "$BASE" = "$(basename "$GATEWAY_DIR")" ] && continue
        case "$BASE" in Template-*) continue ;; esac
        validate_project "$BASE" || continue
        CF=$(compose_file "$D") || continue
        grep -q "由 new-site.sh 生成" "$D/$CF" 2>/dev/null && continue
        echo "$BASE"
    done
}

# 模式 4 网关文件子目录名: gateway.<项目名 hash 前 8 位>
# 用 hash 而非项目名本身: 项目自身可能有同名 gateway 目录, hash 几乎不会撞;
# 同一项目名 hash 稳定, 重跑向导会落进同一个子目录
gateway_subdir() { # gateway_subdir <项目名>
    printf 'gateway.%s' "$(printf '%s' "$1" | md5sum | cut -c1-8)"
}

# 文件已存在且不含向导生成标记 → 视为用户文件 (写入前必须征得同意)
is_foreign_file() { # is_foreign_file <路径> <向导标记>
    [ -f "$1" ] || return 1
    ! grep -q "$2" "$1" 2>/dev/null
}

# 确认业务容器已加入网关网络 (模式 4 最容易漏的一步)
# 容器未加入时站点会返回 502; 这里尝试即时接入, 失败也不中止向导
ensure_proxy_net() { # ensure_proxy_net <容器名>
    local C=$1
    if container_networks "$C" | grep -qw proxy_net; then
        ok "已接入网关网络 proxy_net"
        return 0
    fi
    warn "容器 $C 尚未接入网关网络 proxy_net (Nginx 无法访问它)"
    if ask_yn "  立即接入? docker network connect proxy_net $C" Y; then
        if docker network connect proxy_net "$C"; then
            ok "已接入 (重建容器前有效; 永久生效需改 compose, 见 GATEWAY.md)"
        else
            warn "接入失败, 站点将返回 502, 请手动接入"
            ui_cmd "docker network connect proxy_net $C"
        fi
    else
        warn "未接入 proxy_net, 站点将返回 502; 接入后自动恢复"
        ui_cmd "docker network connect proxy_net $C"
    fi
}

# 覆盖用户文件前备份 (仅在用户同意覆盖后调用)
backup_file() {
    [ -f "$1" ] || return 0
    cp "$1" "$1.bak"
    info "已备份 $(basename "$1") → $(basename "$1").bak"
}

# 内容变化时备份: 向导生成的文件含生成标记, 重跑时会被直接覆盖,
# 但用户可能在上面做过手工修改 (调资源 / 加指令), 覆盖前留底可找回
backup_if_changed() { # backup_if_changed <新内容> <目标文件>
    [ -f "$2" ] || return 0
    printf '%s\n' "$1" | cmp -s - "$2" && return 0
    backup_file "$2"
}

# 多行粘贴输入: 逐行读取直到单独一行 END, 首行直接回车 = 留空
# [Note] 终端粘贴多行文本时, 每个换行都会结束一次 read, 因此逐行收集再拼接;
#        顺手去掉行尾 \r (从 Windows 文档粘贴时常见)
ask_block() { # ask_block <提示> <结果变量名>
    local LINE ACC=""
    ask "$1" LINE
    LINE=${LINE%$'\r'}
    if [ -n "$LINE" ] && [ "$LINE" != "END" ]; then
        ACC="$LINE"
        ui_hint "(继续粘贴或输入, 单独一行 END 结束)"
        while IFS= read -r LINE; do
            LINE=${LINE%$'\r'}
            [ "$LINE" = "END" ] && break
            ACC="${ACC}
${LINE}"
        done
    fi
    printf -v "$2" '%s' "$ACC"
}

# 高级选项片段组装: 原始输入逐行加缩进, 首行前置标记注释
# [Note] 与占位符"整行替换"配套 (见下方替换处): 输出以换行开头、不以换行结尾,
#        留空时输出空串 → 占位符所在行彻底消失, 产物与默认模板一致
build_extra_block() { # build_extra_block <原始输入> <缩进> <标记注释>
    local LINE OUT=""
    [ -n "$1" ] || return 0
    OUT="
${2}${3}"
    while IFS= read -r LINE; do
        [ -n "$LINE" ] || continue
        LINE=${LINE%$'\r'}
        OUT="${OUT}
${2}${LINE}"
    done <<< "$1"
    printf '%s' "$OUT"
}

ui_header "ProxyGateway 新站点向导"

# ---------- 1. 收集信息 ----------
# 项目名 (同时用作: 目录名 / 配置文件名; 容器方式下默认也是容器名)
ui_step 1 7 "项目名"
while true; do
    ask "  项目名 (字母开头, 可含数字与 . _ -, 如 my-web / ProxyGateway): " NAME
    if ! validate_project "$NAME"; then
        warn "格式不对: 以字母开头, 仅含字母/数字/./_/-, 且不能以 . 结尾"
    elif [ "$NAME" = "$(basename "$GATEWAY_DIR")" ]; then
        warn "$(basename "$GATEWAY_DIR") 是网关自身目录, 请换一个项目名"
    elif [ "${NAME#Template-}" != "$NAME" ]; then
        warn "Template-* 是模板目录, 请换一个项目名"
    elif [ -e "$ROOT_DIR/$NAME" ]; then
        if ask_yn "  目录 $ROOT_DIR/$NAME 已存在, 复用并继续? (只重新生成网关接入文件, 保留 .env 与源码)" N; then
            break
        fi
        warn "请换个名字"
    elif container_exists "$NAME"; then
        warn "已有同名容器 $NAME, 请换个名字"
    else
        break
    fi
done

# 域名
# [Note] 已被其他配置占用的域名会导致 server_name 冲突: Nginx 只认先加载的
#        配置, 后部署的 server 块被静默忽略 (看似部署成功, 实际不生效),
#        因此在输入处就拦下并指路
ui_step 2 7 "站点域名"
CONFIRMED_CONFLICT_FOR=""
while true; do
    ask "  域名 (如 app.example.com): " DOMAIN
    if ! validate_domain "$DOMAIN"; then
        warn "域名格式不对, 示例: app.example.com"
        continue
    fi
    DOMAIN_OWNERS=$(conf_files_with_domain "$DOMAIN" "${NAME}.conf")
    if [ -n "$DOMAIN_OWNERS" ]; then
        warn "域名 $DOMAIN 已被接入 (conf.d 里已有配置声明它):"
        echo "$DOMAIN_OWNERS" | while IFS= read -r OWNER; do
            [ -n "$OWNER" ] && ui_bullet "${OWNER} (项目 ${OWNER%.conf})"
        done
        ui_hint "想更新已有站点 → manage.sh 菜单 5 (更新站点配置), 或重跑向导时项目名填对应项目名"
        if ask_yn "  仍要用 $DOMAIN 继续吗? (新旧配置会冲突, 只有一个生效)" N; then
            CONFIRMED_CONFLICT_FOR="${NAME}|${DOMAIN}"
        else
            warn "请换一个域名"
            continue
        fi
    fi
    break
done

# 上游类型
ui_step 3 7 "业务运行方式"
echo "    1) 现成 Docker 镜像 (最常见)"
echo "    2) 本地 Dockerfile 构建"
echo "    3) 宿主机直跑程序 (非容器)"
echo "    4) 项目自带 compose 文件 (只生成网关接入配置, 不动你的 compose)"
ask "  选择 [1-4, 默认 1]: " TYPE_CHOICE
case "$TYPE_CHOICE" in
    2) UPSTREAM_TYPE="build" ;;
    3) UPSTREAM_TYPE="host" ;;
    4) UPSTREAM_TYPE="existing" ;;
    *) UPSTREAM_TYPE="image" ;;
esac

# 类型相关参数
IMAGE_NAME=""
APP_PORT="80"
CONTAINER="$NAME"    # image/build 模式: 容器名 = 项目名; existing 模式: 由用户指定
COMPOSE_FILE_NAME="" # existing 模式: 检测到的 compose 文件名
if [ "$UPSTREAM_TYPE" = "image" ]; then
    while true; do
        ask "  镜像地址 (如 nginx:latest / ghcr.io/xxx/yyy:latest): " IMAGE_NAME
        case "$IMAGE_NAME" in
            "")             warn "不能为空" ;;
            *[[:space:]#]*) warn "镜像地址不能包含空格或 # (会破坏生成的 YAML)" ;;
            *)              break ;;
        esac
    done
fi
if [ "$UPSTREAM_TYPE" = "existing" ]; then
    ui_hint "已有 compose 项目: 业务由你自己的 compose 管理, 向导只生成网关接入配置"
    ui_hint "网关文件放在项目目录下的专属子目录 (gateway.<hash>), 不与项目文件混放"
    # 直接列出根目录下自带 compose 的项目: 进本模式的多为接入已有项目, 免得先猜名字
    PICK_LIST=$(list_compose_projects)
    if [ -n "$PICK_LIST" ]; then
        [ -d "$ROOT_DIR/$NAME" ] || warn "未找到目录 $ROOT_DIR/$NAME"
        info "发现这些自带 compose 文件的已有项目:"
        PICK_NAMES=()
        while IFS= read -r P; do
            [ -n "$P" ] || continue
            PICK_NAMES+=("$P")
            PICK_MARK=""
            [ -f "$GATEWAY_DIR/nginx/conf.d/${P}.conf" ] && PICK_MARK=" ${C_DIM}(已接入)${C_END}"
            echo "    ${C_NUM}${#PICK_NAMES[@]}${C_END}) $P${PICK_MARK}"
        done <<< "$PICK_LIST"
        ask "  输入序号选用, 或直接回车继续用 ${NAME}: " PICK
        if echo "$PICK" | grep -qE '^[0-9]+$' && [ "$PICK" -ge 1 ] && [ "$PICK" -le "${#PICK_NAMES[@]}" ]; then
            NAME="${PICK_NAMES[$((PICK - 1))]}"
            info "选用已有项目: $ROOT_DIR/$NAME"
        fi
    else
        ui_hint "根目录下暂未发现自带 compose 文件的项目"
        ui_hint "目录 $ROOT_DIR/$NAME 不存在时会创建它 (网关文件放在其专属子目录)"
        ui_hint "可把项目克隆/移动到该目录; 项目放在别处也行 (接入只认容器名, 不看路径)"
    fi
    # 检测 compose 文件 (docker compose 会自动识别标准命名) —— 提前到提问之前:
    # 检测结果用作容器名默认值, 并在生成 GATEWAY.md 时引用
    COMPOSE_FILE_NAME=$(compose_file "$ROOT_DIR/$NAME" 2>/dev/null || true)
    if [ -n "$COMPOSE_FILE_NAME" ]; then
        ok "检测到 compose 文件: $COMPOSE_FILE_NAME"
    elif [ -d "$ROOT_DIR/$NAME" ]; then
        ui_hint "目录里暂无标准命名的 compose 文件 (compose.yaml / compose.yml / docker-compose.yml / docker-compose.yaml)"
        ui_hint "非标准文件名也可以, 启动时用 docker compose -f <文件名> 指定"
    fi
    # 容器名默认值: 项目 compose 里的 container_name (有则免手填)
    # [Note] 剥掉成对引号 —— compose 里 container_name: "xxx" 是合法且常见的写法;
    #        多个服务时全部列出提示 (默认取文件中的第一个, 主服务通常写在前)
    CONTAINER_DEFAULT=""
    if [ -n "$COMPOSE_FILE_NAME" ]; then
        CONTAINER_CANDIDATES=$(sed -n 's/^[[:space:]]*container_name:[[:space:]]*\([^[:space:]#]*\).*/\1/p' \
            "$ROOT_DIR/$NAME/$COMPOSE_FILE_NAME" \
            | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")
        CONTAINER_DEFAULT=$(printf '%s\n' "$CONTAINER_CANDIDATES" | head -1)
        if [ "$(printf '%s\n' "$CONTAINER_CANDIDATES" | grep -c .)" -gt 1 ]; then
            info "compose 里有多个 container_name: $(echo "$CONTAINER_CANDIDATES" | tr '\n' ' ')"
            ui_hint "默认取第一个, 请确认它是网关要反代的业务容器 (不是数据库等辅助服务)"
        fi
    fi
    while true; do
        if [ -n "$CONTAINER_DEFAULT" ]; then
            ask "  业务容器名 [默认 ${CONTAINER_DEFAULT}]: " CONTAINER
            CONTAINER="${CONTAINER:-$CONTAINER_DEFAULT}"
        else
            ask "  业务容器名 (compose 里对外提供服务的 container_name): " CONTAINER
        fi
        if ! validate_container_name "$CONTAINER"; then
            warn "容器名格式不对 (字母/数字开头, 可含 . _ -)"
        elif [ "$CONTAINER" = "$NGINX_CONTAINER" ] || [ "$CONTAINER" = "gateway_watchtower" ]; then
            warn "这是网关自身的容器, 请填业务容器名"
        else
            break
        fi
    done
    # 端口默认值: 容器在运行时从镜像暴露的端口里取 (单个直接默认, 多个列出供选)
    PORT_CANDIDATES=""
    if container_running "$CONTAINER"; then
        PORT_CANDIDATES=$(docker inspect -f '{{range $p, $_ := .NetworkSettings.Ports}}{{$p}} {{end}' "$CONTAINER" 2>/dev/null \
            | tr ' ' '\n' | grep -oE '^[0-9]+' | sort -un)
    fi
    if [ -n "$PORT_CANDIDATES" ]; then
        PORT_DEFAULT=$(printf '%s\n' "$PORT_CANDIDATES" | head -1)
        if [ "$(printf '%s\n' "$PORT_CANDIDATES" | grep -c .)" -gt 1 ]; then
            info "容器 $CONTAINER 的镜像暴露了多个端口: $(echo "$PORT_CANDIDATES" | tr '\n' ' ')"
            ui_hint "默认按第一个填, 请确认它是业务真正监听的端口"
        fi
        ask "  容器内部端口 [默认 ${PORT_DEFAULT}]: " APP_PORT
        APP_PORT="${APP_PORT:-$PORT_DEFAULT}"
    else
        ask "  容器内部端口: " APP_PORT
    fi
elif [ "$UPSTREAM_TYPE" = "host" ]; then
    ui_hint "业务程序直接跑在宿主机上, 网关通过 host.docker.internal 访问"
    ask "  宿主机监听端口: " APP_PORT
else
    ask "  容器内部端口 [默认 80]: " PORT_INPUT
    APP_PORT="${PORT_INPUT:-80}"
fi
while ! echo "$APP_PORT" | grep -qE '^[0-9]+$' || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; do
    ask "  端口无效, 请输入 1-65535: " APP_PORT
done

# 宿主机模式预检: 只监听回环地址的程序, 容器内的网关访问不到 (必然 502)
if [ "$UPSTREAM_TYPE" = "host" ] && { command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; }; then
    HOST_LISTEN=$(port_listener "$APP_PORT")
    if [ -z "$HOST_LISTEN" ]; then
        warn "宿主机端口 $APP_PORT 当前没有程序监听 (启动程序后站点自动恢复)"
    else
        case "${HOST_LISTEN%:*}" in
            127.*|localhost|"[::1]"|::1)
                warn "端口 $APP_PORT 只监听在 $HOST_LISTEN, 容器内的网关无法访问"
                ui_hint "请让程序监听 0.0.0.0 (或至少 Docker 网桥地址)" ;;
            0.0.0.0|"*"|"[::]"|::)
                ok "宿主机端口 $APP_PORT 已监听 ($HOST_LISTEN)" ;;
            *)
                warn "端口 $APP_PORT 监听在 $HOST_LISTEN, 请确认网关能通过 host.docker.internal 访问" ;;
        esac
    fi
fi

# 证书域名: 已有证书直接复用, 没有则签发 (放在 DNS 步骤之前:
# 复用证书时无需 DNS 账号, 免得多问一轮)
ui_step 4 7 "站点证书"
EXISTING_CERTS=$(ssl_cert_domains)
if [ -n "$EXISTING_CERTS" ]; then
    ui_hint "网关已部署的证书 (填其中任意一个域名 = 直接复用, 不重新签发):"
    echo "$EXISTING_CERTS" | while IFS= read -r CERT_ITEM; do
        ui_bullet "$CERT_ITEM"
    done
    ui_hint "填新域名 = 自动签发 (DNS-01, 不依赖网关)"
else
    ui_hint "网关暂无可用证书, 将按下方域名自动签发"
    ui_hint "若已为整个主域签过泛域名证书, 可填主域名 (所有子域名共用一份)"
fi
ask "  证书域名 [默认 ${DOMAIN}]: " CERT_DOMAIN
CERT_DOMAIN="${CERT_DOMAIN:-$DOMAIN}"
while ! validate_domain "$CERT_DOMAIN"; do
    ask "  证书域名格式不对 (示例: example.com), 请重新输入: " CERT_DOMAIN
    CERT_DOMAIN="${CERT_DOMAIN:-$DOMAIN}"
done
if [ -f "$CERT_DIR_HOST/${CERT_DOMAIN}.pem" ] && [ -f "$CERT_DIR_HOST/${CERT_DOMAIN}.key" ]; then
    CERT_ACTION="reuse"
    # 复用证书时做一次域名归属提醒 (字符串判断, 覆盖主域与常见泛域名场景;
    # 证书 SAN 含多个域名时可能合法, 因此只提醒不拦截)
    if [ "$CERT_DOMAIN" != "$DOMAIN" ]; then
        case "$DOMAIN" in
            *."$CERT_DOMAIN") ;;
            *) warn "证书 $CERT_DOMAIN 未必包含站点域名 $DOMAIN, 浏览器可能报证书错误" ;;
        esac
    fi
else
    CERT_ACTION="issue"
fi

# DNS 提供商与账号 (仅在需要签发新证书时才需要)
ui_step 5 7 "DNS 提供商与账号"
if [ "$CERT_ACTION" = "reuse" ]; then
    ok "复用已有证书 $CERT_DOMAIN, 无需 DNS 账号, 跳过"
else
    echo "    1) Cloudflare (dns_cf)    2) 阿里云 (dns_ali)    3) DNSPod (dns_dp)"
    ask "  选择 [1-3, 默认 1]: " DNS_INPUT
    case "$DNS_INPUT" in
        2) DNS_PROVIDER="dns_ali" ;;
        3) DNS_PROVIDER="dns_dp" ;;
        *) DNS_PROVIDER="dns_cf" ;;
    esac
    ask "  DNS 账号名 [默认 main, 多账号见 add_account.sh]: " ACCOUNT
    ACCOUNT="${ACCOUNT:-main}"
    while ! validate_account "$ACCOUNT"; do
        ask "  账号名格式不对 (小写字母开头, 仅含小写字母/数字/下划线/连字符): " ACCOUNT
    done
    # 签发依赖账号容器: 问完账号立即校验 (失败点前移, 免得答完全部才报错)
    if ! container_running "${ACME_PREFIX}${ACCOUNT}"; then
        err "账号容器 ${ACME_PREFIX}${ACCOUNT} 未运行, 无法签发证书。"
        ui_cmd "$SCRIPT_DIR/add_account.sh ${ACCOUNT}   # 新增账号"
        ui_cmd "cd $GATEWAY_DIR && docker compose up -d  # 启动网关"
        exit 1
    fi
fi

# 高级选项 (可选): 默认模板覆盖不了的场景, 直接粘贴原生 nginx 指令
ui_step 6 7 "高级选项 (可选)"
ui_hint "默认模板不够用时, 在这里直接粘贴原生 nginx 指令, 会追加进生成的 app.conf"
ui_hint "常见例子: SSE 流式响应 proxy_buffering off; / 慢接口 proxy_read_timeout 300s;"
ui_hint "多行可整段粘贴 (单独一行 END 结束); 全部留空 = 生成的配置与默认模板一致"
ask_block "  追加到 location / 的指令 (回车跳过): " EXTRA_LOCATION_INPUT
ask_block "  追加到 server 块的指令 (如额外 location, 回车跳过): " EXTRA_SERVER_INPUT

# 汇总确认
ui_step 7 7 "确认配置"
echo -e "  ${C_STEP}项目目录${C_END} ${C_DIM}:${C_END} $ROOT_DIR/$NAME"
echo -e "  ${C_STEP}站点域名${C_END} ${C_DIM}:${C_END} $DOMAIN (HTTPS)"
case "$UPSTREAM_TYPE" in
    image)    echo -e "  ${C_STEP}运行方式${C_END} ${C_DIM}:${C_END} 现成镜像 ${C_INFO}$IMAGE_NAME${C_END} (容器 $CONTAINER, 内部端口 $APP_PORT)" ;;
    build)    echo -e "  ${C_STEP}运行方式${C_END} ${C_DIM}:${C_END} 本地 Dockerfile 构建 (容器 $CONTAINER, 内部端口 $APP_PORT)" ;;
    existing)
        echo -e "  ${C_STEP}运行方式${C_END} ${C_DIM}:${C_END} 已有 compose 项目 (容器 ${C_INFO}$CONTAINER${C_END}, 内部端口 $APP_PORT)"
        echo -e "  ${C_STEP}网关文件${C_END} ${C_DIM}:${C_END} $(gateway_subdir "$NAME")/ 子目录 (不与项目文件混放)"
        if [ -n "$COMPOSE_FILE_NAME" ]; then
            echo -e "  ${C_STEP}compose${C_END}  ${C_DIM}:${C_END} $COMPOSE_FILE_NAME (docker compose 自动识别)"
        else
            echo -e "  ${C_STEP}compose${C_END}  ${C_DIM}:${C_END} ${C_WARN}未检测到标准命名文件${C_END} (启动时需 -f 指定)"
        fi
        ;;
    *)        echo -e "  ${C_STEP}运行方式${C_END} ${C_DIM}:${C_END} 宿主机程序 host.docker.internal:$APP_PORT" ;;
esac
if [ -n "$EXTRA_LOCATION_INPUT" ] || [ -n "$EXTRA_SERVER_INPUT" ]; then
    echo -e "  ${C_STEP}高级选项${C_END} ${C_DIM}:${C_END} 追加自定义 nginx 指令 (内容见生成的 app.conf)"
fi
if [ "$CERT_ACTION" = "reuse" ]; then
    echo -e "  ${C_STEP}证书${C_END}     ${C_DIM}:${C_END} 复用已有 ${C_OK}${CERT_DOMAIN}${C_END}"
else
    echo -e "  ${C_STEP}证书${C_END}     ${C_DIM}:${C_END} 新签发 ${C_ACCENT}${CERT_DOMAIN}${C_END} (+ *.${CERT_DOMAIN}, 账号 $ACCOUNT, $DNS_PROVIDER)"
fi
echo ""
if ! ask_yn "  确认开始?" Y; then
    info "已取消。"
    exit 0
fi

# ---------- 2. 前置检查 ----------
# (网关状态已在入口校验; 签发用的账号容器已在 DNS 步骤校验)
ui_section "前置检查"

# 同名配置已部署 = 重跑向导: 区分"同域名更新"与"项目名被挪用"
if [ -f "$GATEWAY_DIR/nginx/conf.d/${NAME}.conf" ]; then
    OLD_DOMAINS=$(conf_server_names "$GATEWAY_DIR/nginx/conf.d/${NAME}.conf")
    if printf '%s\n' "$OLD_DOMAINS" | grep -qx "$DOMAIN"; then
        info "检测到 ${NAME}.conf 已部署同域名配置, 本次为更新 (自动备份, 失败自动回滚)"
    else
        warn "conf.d/${NAME}.conf 已存在, 声明的域名与本次不同:"
        ui_bullet "旧: $(printf '%s\n' "$OLD_DOMAINS" | tr '\n' ' ')"
        ui_bullet "新: $DOMAIN"
        if ! ask_yn "  替换该配置? (自动备份, 语法检查失败自动回滚)" Y; then
            die "已中止, 未改动任何文件 (想换域名请先下线旧站点, 或换一个项目名)"
        fi
    fi
fi

# 域名冲突复核: 步骤 2 检查后 NAME 可能因选用已有项目而变化, 以最终组合再验一次
# (同名文件已在上面的更新分支处理, 这里只查其他文件)
DOMAIN_OWNERS=$(conf_files_with_domain "$DOMAIN" "${NAME}.conf")
if [ -n "$DOMAIN_OWNERS" ] && [ "$CONFIRMED_CONFLICT_FOR" != "${NAME}|${DOMAIN}" ]; then
    err "域名 $DOMAIN 已被其他配置占用, 本次部署不会生效 (Nginx 会忽略其一):"
    echo "$DOMAIN_OWNERS" | while IFS= read -r OWNER; do
        [ -n "$OWNER" ] && ui_bullet "${OWNER} (项目 ${OWNER%.conf})"
    done
    die "请换一个项目名/域名重跑, 或先下线占用该域名的旧站点"
fi

# 同名文件冲突: 向导即将在项目目录写 app.conf 等文件, 已有"非向导生成"的同名文件时
# 逐一确认, 绝不静默覆盖用户文件 (此时尚未生成任何东西, 拒绝即零副作用)
# 模式 4 除外: 它的网关文件全部写入专属子目录 gateway.<hash>, 与项目文件天然隔离
BACKUP_APPCONF=0
BACKUP_COMPOSE=0
if [ "$UPSTREAM_TYPE" != "existing" ] && is_foreign_file "$ROOT_DIR/$NAME/app.conf" "由 new-site.sh 生成"; then
    warn "目录里已有 app.conf (非向导生成, 可能是项目自身的配置文件)"
    if ask_yn "  覆盖为网关反代配置? (原文件备份为 app.conf.bak)" N; then
        BACKUP_APPCONF=1
    else
        die "已中止, 未改动任何文件 (可换个项目名, 或先改名现有 app.conf)"
    fi
fi
if [ "$UPSTREAM_TYPE" != "existing" ] && [ "$UPSTREAM_TYPE" != "host" ]; then
    # 其他标准命名的 compose 文件优先于向导生成的 docker-compose.yml 被识别,
    # 两者并存时 docker compose 实际启动的是前者, 向导的容器名/网络配置全部落空
    OTHER_CF=$(compose_file "$ROOT_DIR/$NAME" 2>/dev/null || true)
    if [ -n "$OTHER_CF" ] && is_foreign_file "$ROOT_DIR/$NAME/$OTHER_CF" "由 new-site.sh 生成"; then
        case "$OTHER_CF" in
            compose.yaml|compose.yml)
                warn "目录里已有 $OTHER_CF (非向导生成), 它会优先于向导生成的 docker-compose.yml"
                die "请改用「项目自带 compose 文件」方式接入, 或先把 $OTHER_CF 移走"
                ;;
            docker-compose.yaml)
                warn "目录里已有 $OTHER_CF (非向导生成), 但 docker compose 会优先使用向导生成的 docker-compose.yml"
                ui_hint "如果 $OTHER_CF 才是项目真正使用的 compose, 请改用「项目自带 compose 文件」方式接入"
                ;;
        esac
    fi
    if is_foreign_file "$ROOT_DIR/$NAME/docker-compose.yml" "由 new-site.sh 生成"; then
        warn "目录里已有 docker-compose.yml (非向导生成, 可能是项目自己的 compose)"
        if ask_yn "  覆盖? (原文件备份为 docker-compose.yml.bak)" N; then
            BACKUP_COMPOSE=1
        else
            die "已中止。若想沿用这份 compose, 请改用「项目自带 compose 文件」方式接入"
        fi
    fi
fi

# ---------- 3. 生成项目文件 ----------
PROJECT_DIR="$ROOT_DIR/$NAME"
ui_step 1 4 "生成项目文件"
info "目标目录: $PROJECT_DIR"
if [ "$UPSTREAM_TYPE" = "existing" ]; then
    # 模式 4: 网关文件全部放进专属子目录, 与项目自身文件 (app.conf / compose 等) 隔离
    GATEWAY_SUBDIR="$PROJECT_DIR/$(gateway_subdir "$NAME")"
    APPCONF_FILE="$GATEWAY_SUBDIR/app.conf"
    info "网关文件子目录: $GATEWAY_SUBDIR"
    mkdir -p "$GATEWAY_SUBDIR" || die "无法创建目录: $GATEWAY_SUBDIR"
else
    APPCONF_FILE="$PROJECT_DIR/app.conf"
    [ -d "$PROJECT_DIR" ] || ui_hint "(新目录, 将用于存放网关接入配置与项目文件)"
    mkdir -p "$PROJECT_DIR" || die "无法创建目录: $PROJECT_DIR"
    if [ "$BACKUP_APPCONF" -eq 1 ]; then
        backup_file "$APPCONF_FILE"
    fi
fi

# 反代配置模板 (占位符随后用 bash 变量替换, 不用 sed:
# sed 遇到域名里的 / 或 & 会中断或静默改错, 且失败后会把带占位符的文件留在磁盘上)
if [ "$UPSTREAM_TYPE" = "host" ]; then
    APP_CONF=$(cat <<'EOF'
# 由 new-site.sh 生成: __DOMAIN__ → 宿主机程序 host.docker.internal:__PORT__
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name __DOMAIN__;

    # 证书 (由 issue_cert.sh 部署到网关 ssl 目录)
    ssl_certificate     /etc/nginx/ssl/__CERTDOMAIN__.pem;
    ssl_certificate_key /etc/nginx/ssl/__CERTDOMAIN__.key;

    location / {
        # host.docker.internal 由网关内置 host-gateway 映射指向宿主机
        proxy_pass http://host.docker.internal:__PORT__;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        __EXTRA_LOCATION__
    }
    __EXTRA_SERVER__
}

# HTTP 自动跳转 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    rewrite ^(.*)$ https://$host$1 permanent;
}
EOF
)
else
    # 容器方式 (镜像 / 本地构建 / 已有 compose): 反代到容器名
    APP_CONF=$(cat <<'EOF'
# 由 new-site.sh 生成: __DOMAIN__ → 容器 __CONTAINER__:__PORT__
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name __DOMAIN__;

    # 证书 (由 issue_cert.sh 部署到网关 ssl 目录)
    ssl_certificate     /etc/nginx/ssl/__CERTDOMAIN__.pem;
    ssl_certificate_key /etc/nginx/ssl/__CERTDOMAIN__.key;

    location / {
        # [Critical] 动态解析容器名, 防止业务容器未启动导致网关崩溃
        resolver 127.0.0.11 valid=30s;
        set $upstream_app __CONTAINER__;
        proxy_pass http://$upstream_app:__PORT__;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket 支持 (使用 00_common.conf 全局定义的 map)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        __EXTRA_LOCATION__
    }
    __EXTRA_SERVER__
}

# HTTP 自动跳转 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    rewrite ^(.*)$ https://$host$1 permanent;
}
EOF
)
fi

# 容器方式 (镜像/本地构建): 生成 docker-compose.yml + .env
# "现成镜像"与"本地构建"只差一行, 其余配置共用同一份模板, 避免两边改漏
if [ "$UPSTREAM_TYPE" = "image" ] || [ "$UPSTREAM_TYPE" = "build" ]; then
    # [Note] 这里不带缩进 —— 模板中的占位符行本身已有 4 空格缩进
    if [ "$UPSTREAM_TYPE" = "image" ]; then
        APP_SOURCE="image: __IMAGE__"
    else
        APP_SOURCE="build: . # 源码与 Dockerfile 放在本目录"
    fi
    COMPOSE_CONTENT=$(cat <<'EOF'
# 由 new-site.sh 生成: __NAME__
services:
  app:
    __SOURCE__
    container_name: __CONTAINER__ # 网关 app.conf 通过此名称访问本容器
    restart: always
    env_file:
      - .env
    environment:
      - TZ=Asia/Shanghai
    volumes:
      # 需要持久化数据时取消注释 (如数据库文件 / 上传目录)
      # - ./data:/app/data
    networks:
      - proxy_net
    labels:
      - "com.centurylinklabs.watchtower.enable=true" # 允许被网关自动更新 (不需要可删除此行)
    # [Log] 限制日志大小, 防止占满磁盘
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    # [Resource] 限制资源, 防止单个应用拖垮宿主机
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

networks:
  # 必须加入网关网络, 否则 Nginx 连不上
  proxy_net:
    external: true
EOF
)
    # __SOURCE__ 必须先替换 (其内容里含 __IMAGE__ 占位符)
    COMPOSE_CONTENT=${COMPOSE_CONTENT//__SOURCE__/$APP_SOURCE}
    COMPOSE_CONTENT=${COMPOSE_CONTENT//__NAME__/$NAME}
    COMPOSE_CONTENT=${COMPOSE_CONTENT//__CONTAINER__/$CONTAINER}
    COMPOSE_CONTENT=${COMPOSE_CONTENT//__IMAGE__/$IMAGE_NAME}
    if echo "$COMPOSE_CONTENT" | grep -q '__[A-Z][A-Z]*__'; then
        die "docker-compose.yml 生成异常, 仍含未替换的占位符, 已中止。"
    fi
    if [ "$BACKUP_COMPOSE" -eq 1 ]; then
        backup_file "$PROJECT_DIR/docker-compose.yml"
    else
        # 向导生成的旧 compose 可能被手工改过 (资源/标签), 内容有变化时留底
        backup_if_changed "$COMPOSE_CONTENT" "$PROJECT_DIR/docker-compose.yml"
    fi
    printf '%s\n' "$COMPOSE_CONTENT" > "$PROJECT_DIR/docker-compose.yml"

    # .env 保留用户已填写的内容 (复用场景不覆盖)
    if [ ! -f "$PROJECT_DIR/.env" ]; then
        PROJECT_ENV=$(cat <<'EOF'
# __NAME__ 应用环境变量 (docker-compose.yml 通过 env_file 加载到容器)
# 按需添加, 例如:
# PORT=3000
# API_KEY=xxx
EOF
)
        PROJECT_ENV=${PROJECT_ENV//__NAME__/$NAME}
        printf '%s\n' "$PROJECT_ENV" > "$PROJECT_DIR/.env"
    fi
fi

# 高级选项片段 (步骤 6 的粘贴输入; 为空时占位符整行消失)
EXTRA_LOCATION_BLOCK=$(build_extra_block "$EXTRA_LOCATION_INPUT" "        " "# [Custom] location 级追加指令 (new-site.sh 高级选项)")
EXTRA_SERVER_BLOCK=$(build_extra_block "$EXTRA_SERVER_INPUT" "    " "# [Custom] server 级追加指令 (new-site.sh 高级选项)")

# 占位符替换 (bash 字面替换: 替换内容中的 / 和 & 都不会被解释)
APP_CONF=${APP_CONF//__DOMAIN__/$DOMAIN}
APP_CONF=${APP_CONF//__CERTDOMAIN__/$CERT_DOMAIN}
APP_CONF=${APP_CONF//__PORT__/$APP_PORT}
APP_CONF=${APP_CONF//__CONTAINER__/$CONTAINER}
# [Note] 高级选项占位符按"整行"替换: 模式里带上前置换行与行首缩进,
#        留空时该行 (含缩进) 彻底消失, 生成的文件与默认模板逐字一致
APP_CONF=${APP_CONF//$'\n        __EXTRA_LOCATION__'/"$EXTRA_LOCATION_BLOCK"}
APP_CONF=${APP_CONF//$'\n    __EXTRA_SERVER__'/"$EXTRA_SERVER_BLOCK"}
# 向导生成的旧 app.conf 可能已被手工修改 (加指令/调参数), 覆盖前留底
if [ "$BACKUP_APPCONF" -eq 0 ]; then
    backup_if_changed "$APP_CONF" "$APPCONF_FILE"
fi
printf '%s\n' "$APP_CONF" > "$APPCONF_FILE"

# 校验替换结果, 避免带着占位符进入后续步骤
if grep -q '__[A-Z][A-Z]*__' "$APPCONF_FILE"; then
    die "app.conf 生成异常, 仍含未替换的占位符, 已中止。请反馈: $APPCONF_FILE"
fi
if [ "$UPSTREAM_TYPE" = "existing" ]; then
    if [ -n "$COMPOSE_FILE_NAME" ]; then
        COMPOSE_DESC="\`$COMPOSE_FILE_NAME\` (已检测到)"
    else
        COMPOSE_DESC="未检测到标准命名文件 (启动时用 \`-f\` 指定)"
    fi

    # compose 参考模板: 展示"要加什么" (标 [必须] 的两项) 与可选的标准配置,
    # 用户据此合并进项目自己的 compose (详见 GATEWAY.md)
    # [Note] 旧文件可能被用户改过 (合并时加的注释/笔记), 覆盖前有变化则留底
    COMPOSE_TEMPLATE=$(cat <<EOF
# 由 new-site.sh 生成: $NAME 网关接入 compose 模板
# [模板] 不能直接运行 —— 按项目实际情况修改出一份可用的, 放到项目根目录。
# 项目已有 compose 文件时: 把标 [必须] 的两项合并进去即可, 其余可选项按需取用
# (详见同目录 GATEWAY.md); 文件名冲突时可另存别名, 用 docker compose -f 指定。
services:
  app: # ← 服务名按项目实际修改
    image: REPLACE_ME # ← 换成项目实际镜像地址, 或改为 build: .
    container_name: $CONTAINER # [必须] 网关 app.conf 通过此名称访问本容器
    restart: always
    env_file: # [可选] 项目用 .env 注入变量时保留 (没有 .env 就删掉这两行)
      - .env
    environment:
      - TZ=Asia/Shanghai
    volumes: # [可选] 需要持久化数据时按需
      # - ./data:/app/data
    labels:
      - "com.centurylinklabs.watchtower.enable=true" # [可选] 允许被网关自动更新 (不需要可删除此行)
    networks:
      - proxy_net # [必须] 加入网关网络, 否则 Nginx 连不上
    # [Log] 限制日志大小, 防止占满磁盘
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    # [Resource] 限制资源, 防止单个应用拖垮宿主机
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

networks:
  proxy_net: # [必须] 声明使用网关已创建的外部网络
    external: true
EOF
)
    backup_if_changed "$COMPOSE_TEMPLATE" "$GATEWAY_SUBDIR/docker-compose.yml"
    printf '%s\n' "$COMPOSE_TEMPLATE" > "$GATEWAY_SUBDIR/docker-compose.yml"

    GATEWAY_MD=$(cat <<EOF
# Gateway 接入说明 ($NAME)

本项目使用自有的 compose 运行业务, 网关只负责反代与证书。
向导生成的网关文件全部在本子目录里, 与项目自身文件互不干扰:

- 站点域名: https://$DOMAIN
- 业务容器: $CONTAINER (内部端口 $APP_PORT)
- 反代配置: 本目录 \`app.conf\`
- compose 模板: 本目录 \`docker-compose.yml\`
- 项目自己的 compose: $COMPOSE_DESC

## 必须完成: 让业务容器加入网关网络 proxy_net

Nginx 通过 Docker 内部网络访问容器。参照本目录 \`docker-compose.yml\` 模板,
把标了 [必须] 的 \`container_name\` 与 \`networks\` 合并进项目自己的 compose 文件
(其余 [可选] 项按需取用):

\`\`\`yaml
services:
  <你的服务名>:
    # ...原有配置保持不变...
    container_name: $CONTAINER # [必须]
    networks:
      - proxy_net # [必须]
    # 可选项 (完整说明见本目录 docker-compose.yml 模板):
    # environment:
    #   - TZ=Asia/Shanghai
    # labels:
    #   - "com.centurylinklabs.watchtower.enable=true" # 允许被网关自动更新

networks:
  proxy_net:
    external: true
\`\`\`

修改出可用的 compose 后放到项目根目录 (\`docker compose\` 会自动识别标准命名;
与已有文件冲突时可另存别名, 启动时用 \`docker compose -f <文件名> up -d\` 指定)。

> 临时救急 (不重建容器时): \`docker network connect proxy_net $CONTAINER\`

## 启动业务

在项目根目录执行, \`docker compose\` 会自动识别这些标准文件名 (无需 -f):
\`compose.yaml\` / \`compose.yml\` / \`docker-compose.yml\` / \`docker-compose.yaml\`

使用其他文件名时:

\`\`\`bash
docker compose -f <你的文件名> up -d
\`\`\`

## 修改反代规则后如何生效

在本目录执行 (自动备份旧配置, 语法检查失败自动回滚):

\`\`\`bash
../../ProxyGateway/scripts/deploy_conf.sh ${NAME}
\`\`\`

## 常用命令

\`\`\`bash
docker compose up -d      # 启动/更新业务 (在项目根目录执行)
docker compose logs -f    # 查看日志
../../ProxyGateway/scripts/doctor.sh  # 网关自检
\`\`\`
EOF
)
    backup_if_changed "$GATEWAY_MD" "$GATEWAY_SUBDIR/GATEWAY.md"
    printf '%s\n' "$GATEWAY_MD" > "$GATEWAY_SUBDIR/GATEWAY.md"
    ok "已生成网关接入文件 → $(basename "$GATEWAY_SUBDIR")/ (app.conf + docker-compose.yml 模板 + GATEWAY.md)"
fi

# 项目内说明文件 (镜像/构建/宿主机模式)
# [Note] README.md 被用户文件占用时, 说明改写入 GATEWAY.md, 绝不覆盖
if [ "$UPSTREAM_TYPE" != "existing" ]; then
    if [ "$UPSTREAM_TYPE" = "host" ]; then
        RUN_DESC="宿主机程序 (host.docker.internal:$APP_PORT)"
        COMMON_CMDS=""
    else
        if [ "$UPSTREAM_TYPE" = "image" ]; then
            RUN_DESC="Docker 镜像 ($IMAGE_NAME)"
        else
            RUN_DESC="本地 Dockerfile 构建"
        fi
        COMMON_CMDS="docker compose up -d      # 启动/更新容器
docker compose logs -f     # 查看日志
docker compose down        # 停止
"
    fi
    WRITE_DOC=1
    DOC_FILE="$PROJECT_DIR/README.md"
    if is_foreign_file "$DOC_FILE" '由 ProxyGateway `new-site.sh` 生成'; then
        if is_foreign_file "$PROJECT_DIR/GATEWAY.md" "Gateway 接入说明"; then
            warn "README.md 与 GATEWAY.md 均非向导生成, 跳过说明文件写入"
            WRITE_DOC=0
        else
            warn "README.md 已存在 (非向导生成), 未改动"
            DOC_FILE="$PROJECT_DIR/GATEWAY.md"
            info "项目说明改写入 GATEWAY.md"
        fi
    fi
    if [ "$WRITE_DOC" -eq 1 ]; then
        cat > "$DOC_FILE" <<EOF
# $NAME

由 ProxyGateway \`new-site.sh\` 生成的业务项目。

- 站点域名: https://$DOMAIN
- 运行方式: $RUN_DESC
- 反代配置: \`app.conf\` (修改后需重新部署到网关, 见下)

## 修改配置后如何生效

\`\`\`bash
# 部署 app.conf 到网关并安全重载 (自动备份旧配置, 失败自动回滚)
../ProxyGateway/scripts/deploy_conf.sh ${NAME}
\`\`\`

## 常用命令

\`\`\`bash
${COMMON_CMDS}../ProxyGateway/scripts/doctor.sh  # 网关自检
\`\`\`

> 网关的全局配置与证书都在 \`../ProxyGateway/\`, 站点目录只放业务本身的文件。
EOF
    fi
    ok "已生成 app.conf$([ "$UPSTREAM_TYPE" = "host" ] || echo ' + docker-compose.yml + .env')"
fi

# ---------- 4. 准备证书 (必须在部署配置之前!) ----------
# 顺序原因: app.conf 引用了证书文件, 若先部署配置再签证书,
# 其间任何一次网关重启都会因找不到证书而失败。
ui_step 2 4 "准备证书: $CERT_DOMAIN"
if [ "$CERT_ACTION" = "reuse" ]; then
    ok "复用已部署的证书 $CERT_DOMAIN, 跳过签发"
else
    info "证书不存在, 开始签发 (DNS-01 验证, 通常 1-2 分钟)..."
    if ! bash "$SCRIPT_DIR/issue_cert.sh" "$CERT_DOMAIN" "$DNS_PROVIDER" "$ACCOUNT"; then
        err "证书签发失败, 已中止 (网关配置尚未部署, 现有服务不受影响)。"
        ui_hint "排查后可重新运行本向导, 或手动执行:"
        ui_cmd "bash $SCRIPT_DIR/issue_cert.sh $CERT_DOMAIN $DNS_PROVIDER $ACCOUNT"
        ui_cmd "bash $SCRIPT_DIR/deploy_conf.sh ${NAME}"
        exit 1
    fi
fi
# 部署前必须确认证书文件真的在, 否则网关重启会加载失败
if [ ! -f "$CERT_DIR_HOST/${CERT_DOMAIN}.pem" ] || [ ! -f "$CERT_DIR_HOST/${CERT_DOMAIN}.key" ]; then
    die "证书文件缺失: nginx/ssl/${CERT_DOMAIN}.pem / .key, 已中止 (网关配置未部署)。"
fi

# ---------- 5. 启动业务 (先起业务再改网关, 失败时网关完全不受影响) ----------
# START_RESULT: ok=已启动 / skipped=用户主动跳过 / failed=启动报错
START_RESULT="ok"
ui_step 3 4 "启动业务"
if [ "$UPSTREAM_TYPE" = "host" ]; then
    info "宿主机程序模式, 跳过容器启动 (请确认程序已在端口 $APP_PORT 运行)"
    START_RESULT="skipped"
elif [ "$UPSTREAM_TYPE" = "existing" ]; then
    if container_running "$CONTAINER"; then
        ok "容器 $CONTAINER 已在运行"
    else
        # 容器未运行: 优先用标准命名的 compose 启动, 其次让用户指定文件名
        START_CF=$(compose_file "$PROJECT_DIR" 2>/dev/null || true)
        if [ -n "$START_CF" ]; then
            if ask_yn "  容器未运行, 现在用项目自己的 compose 启动?" Y; then
                info "启动: cd $PROJECT_DIR && docker compose up -d"
                (cd "$PROJECT_DIR" && docker compose up -d) || START_RESULT="failed"
            else
                ui_hint "稍后手动启动: cd $PROJECT_DIR && docker compose up -d"
                START_RESULT="skipped"
            fi
        else
            OTHER_YAML=$(cd "$PROJECT_DIR" 2>/dev/null && ls -1 -- *.yml *.yaml 2>/dev/null | head -5 || true)
            if [ -n "$OTHER_YAML" ]; then
                warn "未找到标准命名的 compose 文件 (自动识别: compose.yaml / compose.yml / docker-compose.yml / docker-compose.yaml)"
                info "目录里有其他 yaml 文件:"
                printf '%s\n' "$OTHER_YAML" | sed 's/^/      /'
                ask "  输入 compose 文件名 (留空跳过启动): " CF_CUSTOM
                if [ -n "$CF_CUSTOM" ]; then
                    if [ -f "$PROJECT_DIR/$CF_CUSTOM" ]; then
                        info "启动: cd $PROJECT_DIR && docker compose -f $CF_CUSTOM up -d"
                        (cd "$PROJECT_DIR" && docker compose -f "$CF_CUSTOM" up -d) || START_RESULT="failed"
                    else
                        warn "文件不存在: $CF_CUSTOM, 跳过启动"
                        START_RESULT="skipped"
                    fi
                else
                    START_RESULT="skipped"
                fi
            else
                warn "项目目录中没有 compose 文件"
                ui_hint "可参照 $GATEWAY_SUBDIR/docker-compose.yml 模板与 GATEWAY.md, 修改出可用的 compose 放到项目根目录"
                ui_hint "业务启动后站点自动生效, 无需重跑向导"
                START_RESULT="skipped"
            fi
        fi
    fi
elif [ "$UPSTREAM_TYPE" = "build" ]; then
    if ask_yn "  源码和 Dockerfile 已放入 $PROJECT_DIR 了吗?" Y; then
        info "构建并启动 (首次构建可能较慢)..."
        (cd "$PROJECT_DIR" && docker compose up -d --build) || START_RESULT="failed"
    else
        ui_hint "已跳过启动。稍后放好源码后执行:"
        ui_cmd "cd $PROJECT_DIR && docker compose up -d --build"
        START_RESULT="skipped"
    fi
else
    info "启动业务容器..."
    (cd "$PROJECT_DIR" && docker compose up -d) || START_RESULT="failed"
fi

# docker compose up -d 成功只代表容器已创建: 镜像拉取失败会重试, 配置错误会立刻退出。
# 再确认一次容器真的在运行, 避免带着一个 502 站点继续部署。
if [ "$START_RESULT" = "ok" ] && ! wait_container_running "$CONTAINER" 10; then
    START_RESULT="failed"
    err "容器 $CONTAINER 启动后未进入运行状态。"
fi
# 模式 4: 业务容器必须加入网关网络 (含刚启动的容器)
if [ "$UPSTREAM_TYPE" = "existing" ] && [ "$START_RESULT" = "ok" ]; then
    ensure_proxy_net "$CONTAINER"
fi

if [ "$START_RESULT" = "failed" ]; then
    echo ""
    warn "业务容器启动失败, 已中止 (网关配置尚未部署, 其他站点不受影响)。"
    ui_hint "常见原因: 镜像名/标签写错、私有镜像未登录、build 目录缺少 Dockerfile 或源码、"
    ui_hint "          compose 缺少 .env、compose 里的 container_name 与上面填写的不一致。"
    ui_hint "排查:"
    ui_cmd "cd $PROJECT_DIR && docker compose up -d"
    ui_hint "修好之后只需部署网关配置 (证书与项目文件都已就绪):"
    ui_cmd "bash $SCRIPT_DIR/deploy_conf.sh ${NAME}"
    ui_hint "或直接重新运行本向导 (检测到同名目录会询问是否复用)。"
    exit 1
fi
if [ "$START_RESULT" = "skipped" ]; then
    warn "业务尚未运行, 站点稍后会返回 502。启动业务后无需任何额外操作。"
fi

# ---------- 6. 部署网关配置并安全重载 ----------
# 复用 deploy_conf.sh: 自动定位项目源 app.conf / 内容变化时备份 / nginx -t
# 失败自动回滚 —— 更新与首次接入享受同一套保护 (直接 cp + rm 在更新场景会误删旧配置)
ui_step 4 4 "部署网关配置并重载"
if ! bash "$SCRIPT_DIR/deploy_conf.sh" "$NAME"; then
    echo ""
    warn "网关配置部署失败, 站点尚未上线 (证书与项目文件都已就绪, 其他站点不受影响)。"
    ui_hint "排查 $APPCONF_FILE 后重新部署:"
    ui_cmd "bash $SCRIPT_DIR/deploy_conf.sh ${NAME}"
    exit 1
fi

ui_done "完成! 网关配置已部署: https://$DOMAIN"
ui_hint "验证: curl -I https://$DOMAIN"
echo ""
info "后续常用操作:"
if [ "$UPSTREAM_TYPE" = "existing" ]; then
    ui_hint "容器加入 proxy_net → 参照 $GATEWAY_SUBDIR/docker-compose.yml 模板与 GATEWAY.md 修改你的 compose"
fi
ui_hint "修改反代规则 → 编辑 $APPCONF_FILE, 然后:"
ui_cmd "bash $SCRIPT_DIR/deploy_conf.sh ${NAME}"
ui_hint "排查问题 → 网关自检:"
ui_cmd "bash $SCRIPT_DIR/doctor.sh"
