#!/bin/bash

# ======================================================
# ProxyGateway 证书一键申请工具 (多账号版)
# ======================================================
# 用法: ./issue_cert.sh <域名> [dns提供商] [账号名] [--force]
#   账号名对应 compose (含 override) 中的 acme_<账号名> 服务
#   凭证来自 accounts/<账号名>.env, 默认账号为 main
#   --force: 证书已存在时强制重签 (默认跳过, 避免触发 CA 频率限制)
#
# [Note] 每次签发都会同时申请 <域名> 与 *.<域名> 两个名字 (通配符)。
#        DNS-01 验证不依赖 Nginx 网关, 只需对应账号容器在运行。
# ======================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    echo "用法: $0 <域名> [dns提供商] [账号名] [--force]"
    echo "示例: $0 example.com dns_cf                 # 主账号 (Cloudflare)"
    echo "      $0 example2.com dns_cf work           # 同运营商第二账号"
    echo "      $0 example.com dns_cf --force         # 已有证书时强制重签"
    echo "可用 DNS: dns_cf (Cloudflare), dns_ali (Aliyun), dns_dp (DNSPod)..."
    echo "账号:   compose 中的 acme_* 服务 (默认: main), 新增账号用 add_account.sh"
    echo ""
    echo "注意: 签发的是 <域名> 及其通配符 *.<域名>, 例如传入 app.example.com"
    echo "      会同时申请 app.example.com 与 *.app.example.com。"
}

# 解析参数: 分离 --force 标志与位置参数
# [Note] 不使用空数组展开 ("${arr[@]}"), 该写法在 bash < 4.4 上会多出一个空参数,
#        导致"无参数时绕过用法检查"与"空参数传给 acme.sh"两个问题
FORCE=0
ARGS=()
for ARG in "$@"; do
    case "$ARG" in
        -f|--force) FORCE=1 ;;
        *) ARGS+=("$ARG") ;;
    esac
done

if [ "${#ARGS[@]}" -lt 1 ]; then
    usage
    exit 1
fi

DOMAIN="${ARGS[0]}"
DNS_PROVIDER="${ARGS[1]:-dns_cf}" # 默认使用 CF
ACCOUNT="${ARGS[2]:-main}"        # 默认主账号

if ! validate_domain "$DOMAIN"; then
    die "域名格式不对: $DOMAIN (示例: app.example.com, 不要带 https:// 或路径)"
fi
if ! validate_account "$ACCOUNT"; then
    die "账号名格式不对: $ACCOUNT (小写字母开头, 仅含小写字母/数字/下划线/连字符)"
fi

require_docker

CONTAINER_ACME="${ACME_PREFIX}${ACCOUNT}"

ui_section "签发目标"
echo -e "  ${C_STEP}域名${C_END}       ${C_DIM}:${C_END} $DOMAIN (+ *.$DOMAIN)"
echo -e "  ${C_STEP}DNS 提供商${C_END} ${C_DIM}:${C_END} $DNS_PROVIDER"
echo -e "  ${C_STEP}账号${C_END}       ${C_DIM}:${C_END} $ACCOUNT (${CONTAINER_ACME})"

# [Pre-check] 目标账号的 acme 容器必须存在
# 凭证 (accounts/<账号名>.env) 与公共配置 (.env) 全部注入在该容器环境中
if ! container_exists "$CONTAINER_ACME"; then
    if [ "$ACCOUNT" = "main" ]; then
        err "acme 容器 $CONTAINER_ACME 不存在。"
        ui_cmd "cd $GATEWAY_DIR && docker compose up -d   # 或先运行 setup.sh"
    else
        err "账号 ${ACCOUNT} 尚未创建 (容器 $CONTAINER_ACME 不存在)。"
        ui_cmd "$SCRIPT_DIR/add_account.sh ${ACCOUNT}"
        ui_cmd "cd $GATEWAY_DIR && docker compose up -d"
    fi
    exit 1
fi
if ! container_running "$CONTAINER_ACME"; then
    err "acme 容器 $CONTAINER_ACME 未运行 (状态异常)。"
    RUNNING_ACCOUNTS=$(acme_containers running)
    if [ -n "$RUNNING_ACCOUNTS" ]; then
        info "当前运行中的账号容器:"
        echo "$RUNNING_ACCOUNTS" | while IFS= read -r ACCT_ITEM; do ui_bullet "$ACCT_ITEM"; done
    else
        info "当前没有运行中的账号容器"
    fi
    ui_cmd "cd $GATEWAY_DIR && docker compose up -d"
    ui_cmd "docker logs --tail 50 $CONTAINER_ACME   # 排查"
    exit 1
fi

# [Pre-check] 跨账号冲突: 同一域名只能属于一个账号
# 否则两个账号实例的自动续期会互相覆盖 nginx/ssl 下的同名证书文件
# [Fix] acme.sh 默认使用 ec-256, 记录目录是 <域名>_ecc 而不是 <域名>;
#       只查后者会让这段检测永远不触发 (cert_in_account 两种都查)。
#       同时遍历"全部"账号容器而非仅运行中的, 停掉的账号同样持有域名记录。
for OTHER in $(acme_containers); do
    [ "$OTHER" = "$CONTAINER_ACME" ] && continue
    if cert_in_account "$OTHER" "$DOMAIN"; then
        err "${DOMAIN} 已由账号容器 ${OTHER} 管理, 不能在 ${ACCOUNT} 下重复签发。"
        ui_hint "原因: 两个账号会为同一域名写同名证书文件, 自动续期时互相覆盖。"
        ui_hint "处理: 先移除旧账号的记录, 再用新账号签发"
        ui_cmd "docker exec ${OTHER} acme.sh --remove -d ${DOMAIN} --ecc"
        ui_hint "(若该账号用的是 RSA 证书, 去掉 --ecc 再执行一次)"
        exit 1
    fi
done

# [Note] reloadcmd 依赖的 curl 已内置于 neilpang/acme.sh 镜像 (支持 unix-socket), 无需安装。
# [Rule] 网关未运行时视为"无需重载" (容器不存在 404 / 已停止 409): 证书仍会正常安装,
#        网关下次启动时自动加载。运行中的重载失败则返回非 0, 由 acme.sh 记录续期错误。
RELOAD_CMD="code=\$(curl -s -o /dev/null -w '%{http_code}' -X POST --unix-socket /var/run/docker.sock \"http://localhost/containers/${NGINX_CONTAINER}/kill?signal=HUP\"); [ \"\$code\" = 204 ] || [ \"\$code\" = 404 ] || [ \"\$code\" = 409 ]"

# 0. 读取公共配置 (从容器环境读取, 确保 .env 中的 ACME_EMAIL/ACME_SERVER 生效)
ACME_EMAIL=$(docker exec "$CONTAINER_ACME" printenv ACME_EMAIL 2>/dev/null || true)
ACME_SERVER=$(docker exec "$CONTAINER_ACME" printenv ACME_SERVER 2>/dev/null || true)
ACME_SERVER=${ACME_SERVER:-letsencrypt}

if [ -z "$ACME_EMAIL" ] || [ "$ACME_EMAIL" = "$PLACEHOLDER_EMAIL" ]; then
    warn "ACME_EMAIL 尚未填写 (仍是示例值)。"
    ui_hint "CA 发出的证书到期提醒邮件将无人接收 (不影响签发本身)。"
    ui_hint "修正: 编辑 $GATEWAY_DIR/.env 后执行 cd $GATEWAY_DIR && docker compose up -d"
    ACME_FALLBACK_EMAIL="admin@localhost.local"
else
    ACME_FALLBACK_EMAIL="$ACME_EMAIL"
fi

# [Pre-check] 证书已存在时的处理说明
# 到这里已确认本账号持有该域名, 因此这份提示与实际行为一致
if docker exec "$CONTAINER_ACME" test -f "${CERT_DIR_CONTAINER}/${DOMAIN}.pem" 2>/dev/null; then
    if [ "$FORCE" -eq 1 ]; then
        warn "${DOMAIN} 已有证书, 本次将强制重签并覆盖。"
    else
        info "${DOMAIN} 已有证书, 默认跳过重签 (如需强制重签请加 --force)。"
    fi
fi

# 1. 注册账号 (如果 .env 里配了邮箱)
# [Fix] 必须带 --server: acme.sh 3.x 的默认 CA 是 ZeroSSL, 不指定会把邮箱注册到
#       与后续签发不同的 CA 上 (签发用的是 .env 里的 ACME_SERVER)。
#       这一步失败不影响后续 (签发时会自动补注册), 因此不中断。
ui_step 1 5 "注册账号 ($ACME_SERVER)"
docker exec "$CONTAINER_ACME" acme.sh --register-account --server "$ACME_SERVER" -m "$ACME_FALLBACK_EMAIL" \
    || info "注册返回非 0 (通常表示已注册过), 继续签发。"

# 2. 申请证书 (Issue)
ui_step 2 5 "向 ${ACME_SERVER} 申请证书"
set -- --issue
if [ "$FORCE" -eq 1 ]; then
    set -- "$@" --force
fi
set -- "$@" --server "$ACME_SERVER" \
    --dns "$DNS_PROVIDER" \
    --dnssleep 60 \
    -d "$DOMAIN" -d "*.$DOMAIN"
docker exec "$CONTAINER_ACME" acme.sh "$@"
ISSUE_RC=$?

# [Note] acme.sh 的退出码: 0=成功签发, 2=证书已存在且未到期(跳过), 其他=失败
if [ "$ISSUE_RC" -ne 0 ] && [ "$ISSUE_RC" -ne 2 ]; then
    err "证书签发失败 (退出码 ${ISSUE_RC})。常见原因:"
    ui_hint "  1. DNS Token 无效或权限不足 (Cloudflare 需 'Edit zone DNS' 权限)"
    ui_hint "  2. 域名的 DNS 未托管在所填账号下"
    ui_hint "  3. 触发 CA 频率限制 (Let's Encrypt: 每小时 5 次失败验证, 需等待 1 小时)"
    ui_cmd "docker logs --tail 100 ${CONTAINER_ACME}   # 查看详细日志"
    ui_hint "调试建议: 把 .env 中 ACME_SERVER 改为 letsencrypt_test 后执行"
    ui_hint "          cd $GATEWAY_DIR && docker compose up -d   (改 .env 必须重建容器才生效)"
    exit 1
fi
if [ "$ISSUE_RC" -eq 2 ]; then
    info "证书已存在且未到期, 跳过重签, 直接部署现有证书。"
fi

# 3. 安装证书 (Install)
ui_step 3 5 "安装证书到共享目录"
if ! docker exec "$CONTAINER_ACME" acme.sh --install-cert -d "$DOMAIN" \
    --key-file       "${CERT_DIR_CONTAINER}/${DOMAIN}.key"  \
    --fullchain-file "${CERT_DIR_CONTAINER}/${DOMAIN}.pem" \
    --reloadcmd      "$RELOAD_CMD"; then
    err "证书安装失败 (详见上方输出), 网关未受影响。"
    ui_cmd "docker exec ${CONTAINER_ACME} acme.sh --list   # 排查"
    exit 1
fi

# 4. 校验证书文件确实落到共享目录
ui_step 4 5 "校验证书文件"
if [ ! -f "$CERT_DIR_HOST/${DOMAIN}.pem" ] || [ ! -f "$CERT_DIR_HOST/${DOMAIN}.key" ]; then
    err "安装命令已返回成功, 但 ${CERT_DIR_HOST}/${DOMAIN}.pem 不存在。"
    ui_cmd "docker exec ${CONTAINER_ACME} acme.sh --list   # 排查"
    exit 1
fi
ok "证书文件已就位"

# 5. 安全重载网关 (Reload)
# [Rule] 先 nginx -t 语法检查, 通过才 reload; 失败则保持现有配置继续运行,
#        避免任一配置有误 (如证书缺失) 把运行中的网关打死。
# [Note] 网关未启动时不算失败: DNS-01 签发不依赖网关, 配置会在下次启动时加载。
ui_step 5 5 "重载网关 Nginx"
if container_running "$NGINX_CONTAINER"; then
    if ! nginx_safe_reload; then
        warn "证书已就绪, 但网关重载失败 (证书本身没问题)。"
        ui_hint "通常是 conf.d 中有配置引用了不存在的证书或存在语法错误, 排查:"
        ui_cmd "docker exec $NGINX_CONTAINER nginx -t"
        exit 1
    fi
    ok "网关已重载"
else
    warn "网关 ($NGINX_CONTAINER) 未运行, 跳过重载。"
    ui_hint "证书已就绪, 启动网关时会自动加载: cd $GATEWAY_DIR && docker compose up -d"
fi

ui_done "证书已部署 (账号: ${ACCOUNT})"
echo -e "  ${C_STEP}证书${C_END}     ${C_DIM}:${C_END} ProxyGateway/nginx/ssl/${DOMAIN}.pem"
echo -e "  ${C_STEP}私钥${C_END}     ${C_DIM}:${C_END} ProxyGateway/nginx/ssl/${DOMAIN}.key"
DAYS_LEFT=$(cert_days_left "$CONTAINER_ACME" "$DOMAIN" 2>/dev/null || true)
[ -n "$DAYS_LEFT" ] && echo -e "  ${C_STEP}有效期${C_END}   ${C_DIM}:${C_END} 剩余 ${C_BOLD}${DAYS_LEFT}${C_END} 天 (到期前自动续签)"
ui_hint "提示: 子域名的 conf 可直接复用 ${DOMAIN}.pem (无需重复签发)"
