#!/bin/bash

# ======================================================
# ProxyGateway 交互式初始化向导
# ======================================================
# 一步步完成: 邮箱配置 → DNS Token 填写 → 端口预检 → 启动网关
# 配置已填好会自动跳过; 仍是示例值 (占位内容) 时会提示重新填写
# 用法: ./setup.sh  (在任意目录运行均可)
# ======================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_interactive

ui_header "ProxyGateway 初始化向导"

# ---------- 0. 环境检查 ----------
ui_section "环境检查"
require_docker
require_compose_v2
ok "Docker 与 Compose v2 正常"

# ---------- 1. 公共配置 .env ----------
# [Note] 文件存在不代表配置可用: 只跳过"已填写有效邮箱"的情况, 仍是占位值时重新填写。
#        重写时沿用已有的 TZ / ACME_SERVER, 避免重跑向导把用户改过的设置带回默认值。
ENV_FILE="$GATEWAY_DIR/.env"
ENV_EXISTING_EMAIL=""
ENV_EXISTING_TZ=""
ENV_EXISTING_SERVER=""
if [ -f "$ENV_FILE" ]; then
    ENV_EXISTING_EMAIL=$(grep -E '^ACME_EMAIL=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    ENV_EXISTING_TZ=$(grep -E '^TZ=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    ENV_EXISTING_SERVER=$(grep -E '^ACME_SERVER=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
fi

ui_step 1 4 "公共配置 .env"
if [ -n "$ENV_EXISTING_EMAIL" ] && [ "$ENV_EXISTING_EMAIL" != "$PLACEHOLDER_EMAIL" ]; then
    ok "已配置 (邮箱 ${ENV_EXISTING_EMAIL}), 跳过"
else
    if [ -f "$ENV_FILE" ]; then
        warn "文件存在但邮箱仍是示例值, 重新填写 (原文件已备份为 .env.bak)"
        cp "$ENV_FILE" "$ENV_FILE.bak" || die "无法备份 $ENV_FILE, 已中止"
    else
        info "生成公共配置 .env"
    fi
    while true; do
        ask "  证书注册邮箱 (Let's Encrypt 到期提醒用): " ACME_EMAIL
        if echo "$ACME_EMAIL" | grep -qE '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; then
            break
        fi
        warn "邮箱格式不对, 请重新输入 (如 admin@example.com)"
    done
    echo "    证书颁发机构:"
    echo "      1) Let's Encrypt (正式环境)"
    echo "      2) Let's Encrypt 测试环境 (调试用, 不受频率限制)"
    echo "      3) ZeroSSL"
    case "$ENV_EXISTING_SERVER" in
        letsencrypt_test) CA_DEFAULT=2 ;;
        zerossl)          CA_DEFAULT=3 ;;
        *)                CA_DEFAULT=1 ;;
    esac
    ask "  选择 [1-3, 默认 ${CA_DEFAULT}]: " CA_CHOICE
    case "${CA_CHOICE:-$CA_DEFAULT}" in
        2) ACME_SERVER="letsencrypt_test" ;;
        3) ACME_SERVER="zerossl" ;;
        *) ACME_SERVER="letsencrypt" ;;
    esac
    TZ_VALUE=${ENV_EXISTING_TZ:-Asia/Shanghai}
    if [ -f "$ENV_FILE" ]; then
        # 已有文件只更新这三个键, 保留用户自行添加的变量与注释
        TMP_ENV=$(mktemp) || die "无法创建临时文件"
        if ! awk -v email="$ACME_EMAIL" -v server="$ACME_SERVER" -v tz="$TZ_VALUE" '
            BEGIN { e = 0; s = 0; t = 0 }
            /^ACME_EMAIL=/  { print "ACME_EMAIL=" email; e = 1; next }
            /^ACME_SERVER=/ { print "ACME_SERVER=" server; s = 1; next }
            /^TZ=/          { print "TZ=" tz; t = 1; next }
            { print }
            END {
                if (!e) print "ACME_EMAIL=" email
                if (!s) print "ACME_SERVER=" server
                if (!t) print "TZ=" tz
            }
        ' "$ENV_FILE" > "$TMP_ENV"; then
            rm -f "$TMP_ENV"
            die "更新 $ENV_FILE 失败 (原文件未改动)"
        fi
        mv "$TMP_ENV" "$ENV_FILE" || { rm -f "$TMP_ENV"; die "无法写入 $ENV_FILE"; }
    else
        cat > "$ENV_FILE" <<EOF
# ==========================================
# ProxyGateway 通用配置 (所有 acme 账号共享)
# 由 setup.sh 生成, DNS 账号凭证在 accounts/<账号名>.env
# ==========================================

# 时区: 注入网关所有容器, 决定证书续期与镜像自动更新在何时执行
TZ=${TZ_VALUE}

# 证书注册邮箱 (Let's Encrypt 会发续期提醒)
ACME_EMAIL=${ACME_EMAIL}

# 证书颁发机构 (letsencrypt / letsencrypt_test / zerossl)
ACME_SERVER=${ACME_SERVER}
EOF
    fi
    ok "已写入 $ENV_FILE"
    ui_hint "此后任何对 .env 的修改都要执行 docker compose up -d 才会生效 (容器不会自动重读)"
fi

# ---------- 2. 主账号凭证 accounts/main.env ----------
MAIN_ENV="$GATEWAY_DIR/accounts/main.env"
MAIN_ENV_READY=0
if [ -f "$MAIN_ENV" ] && grep -qE '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]#]+' "$MAIN_ENV" 2>/dev/null; then
    MAIN_ENV_READY=1
fi

ui_step 2 4 "主账号凭证 accounts/main.env"
if [ "$MAIN_ENV_READY" -eq 1 ]; then
    ok "已填写凭证, 跳过"
else
    if [ -f "$MAIN_ENV" ]; then
        warn "文件存在但没有填写任何凭证, 重新填写"
    else
        info "生成主账号凭证 accounts/main.env"
    fi
    echo "  DNS 托管在哪家? (需要该平台的 API Token)"
    echo "    1) Cloudflare"
    echo "    2) 阿里云"
    echo "    3) DNSPod (腾讯云)"
    ask "  选择 [1-3, 默认 1]: " DNS_CHOICE
    ENV_CONTENT="# ==========================================
# DNS API Token - 主账号 (main)
# 由 setup.sh 生成, 由 docker-compose.yml 中的 acme_main 服务加载
# ==========================================
"
    case "$DNS_CHOICE" in
        2)
            while true; do
                ask "  阿里云 AccessKey ID (Ali_Key): " ALI_KEY
                [ -n "$ALI_KEY" ] && break
                warn "不能为空"
            done
            while true; do
                ask "  阿里云 AccessKey Secret (Ali_Secret): " ALI_SECRET
                [ -n "$ALI_SECRET" ] && break
                warn "不能为空"
            done
            ENV_CONTENT="$ENV_CONTENT
# Aliyun
Ali_Key=${ALI_KEY}
Ali_Secret=${ALI_SECRET}
"
            ;;
        3)
            while true; do
                ask "  DNSPod ID (DP_Id): " DP_ID
                [ -n "$DP_ID" ] && break
                warn "不能为空"
            done
            while true; do
                ask "  DNSPod Key (DP_Key): " DP_KEY
                [ -n "$DP_KEY" ] && break
                warn "不能为空"
            done
            ENV_CONTENT="$ENV_CONTENT
# DNSPod
DP_Id=${DP_ID}
DP_Key=${DP_KEY}
"
            ;;
        *)
            while true; do
                ask "  Cloudflare API Token (CF_Token): " CF_TOKEN
                [ -n "$CF_TOKEN" ] && break
                warn "不能为空"
            done
            ask "  Cloudflare Account ID (CF_Account_ID, 一般可留空直接回车): " CF_ACCOUNT_ID
            if [ -n "$CF_ACCOUNT_ID" ]; then
                CF_ACCOUNT_LINE="CF_Account_ID=${CF_ACCOUNT_ID}"
            else
                CF_ACCOUNT_LINE="# CF_Account_ID= # 一般不需要"
            fi
            ENV_CONTENT="$ENV_CONTENT
# Cloudflare
CF_Token=${CF_TOKEN}
${CF_ACCOUNT_LINE}
"
            ;;
    esac
    mkdir -p "$GATEWAY_DIR/accounts" || die "无法创建目录: $GATEWAY_DIR/accounts"
    printf '%s\n' "$ENV_CONTENT" > "$MAIN_ENV"
    chmod 600 "$MAIN_ENV"
    ok "已写入 accounts/main.env (权限 600)"
    echo ""
    ui_hint "Token 获取方式:"
    ui_hint "  Cloudflare: https://dash.cloudflare.com/profile/api-tokens"
    ui_hint "              模板选 'Edit zone DNS' (权限: Zone/DNS/Edit)"
    ui_hint "              若 Token 设了 IP 白名单, 记得放行本机公网 IP"
    ui_hint "  阿里云:     RAM 访问控制 (https://ram.console.aliyun.com/users)"
    ui_hint "              建议专用子账号, 仅授权 AliyunDNSFullAccess"
    ui_hint "  DNSPod:     https://console.dnspod.cn/account/token/token"
    ui_hint "              创建密钥后取 ID 与 Token 两项"
fi

# ---------- 3. 端口预检 (80/443 被占用是最常见的启动失败原因) ----------
# 网关已在运行时其监听属正常情况, 不再提示
ui_section "端口预检 (80/443)"
PORT_CONFLICT=0
if ! container_running "$NGINX_CONTAINER"; then
    for PORT in 80 443; do
        if port_listening "$PORT"; then
            PORT_CONFLICT=1
            warn "端口 ${PORT} 已被其他程序监听, 网关可能启动失败:"
            if command -v ss >/dev/null 2>&1; then
                ss -tlnp 2>/dev/null | grep -E "[:.]${PORT}\s" | sed 's/^/      /'
            fi
        fi
    done
fi
if [ "$PORT_CONFLICT" -eq 1 ]; then
    ui_hint "常见占用者: 宿主机自带 nginx / apache / 宝塔等面板"
    if ! ask_yn "  仍要继续启动吗?" N; then
        info "已取消。请先释放 80/443 端口后重试。"
        exit 1
    fi
fi

# ---------- 4. 启动网关 ----------
ui_step 3 4 "启动网关"
if ! (cd "$GATEWAY_DIR" && docker compose up -d); then
    err "网关启动失败, 请检查上方报错信息。"
    ui_hint "常见原因: 80/443 端口被占用; accounts/main.env 未填写。"
    ui_cmd "bash $SCRIPT_DIR/doctor.sh   # 自检"
    exit 1
fi

# 等待容器就绪后验证
sleep 3
ui_step 4 4 "验证容器状态"
docker ps --filter "name=gateway_" --format "table {{.Names}}\t{{.Status}}" | sed 's/^/  /'

MISSING=0
for C in "$NGINX_CONTAINER" "${ACME_PREFIX}main" "gateway_watchtower"; do
    container_running "$C" || MISSING=1
done
# 通过 add_account.sh 新增的账号容器同样纳入检查
for C in $(acme_containers); do
    container_running "$C" || MISSING=1
done

if [ "$MISSING" -eq 1 ]; then
    warn "有容器未正常运行, 排查:"
    ui_cmd "bash $SCRIPT_DIR/doctor.sh"
    ui_cmd "docker logs --tail 50 $NGINX_CONTAINER"
    exit 1
fi

ui_done "网关已就绪!"
echo ""
if ask_yn "  现在就接入第一个站点吗? (问答式向导)" Y; then
    echo ""
    bash "$SCRIPT_DIR/new-site.sh"
else
    info "后续操作:"
    ui_cmd "bash $SCRIPT_DIR/manage.sh    # 全部功能菜单"
    ui_cmd "bash $SCRIPT_DIR/new-site.sh  # 接入站点"
    ui_cmd "bash $SCRIPT_DIR/doctor.sh    # 健康自检"
fi
