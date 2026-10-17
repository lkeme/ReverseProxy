#!/bin/bash

# ======================================================
# ProxyGateway 新增 DNS 账号工具
# ======================================================
# 在 docker-compose.override.yml 中自动生成 acme_<账号名> 服务
# (override 文件被 .gitignore 忽略, 不会改动/污染主配置)
# 用法: ./add_account.sh <账号名>
# 生成后: 填 Token → docker compose up -d → ./issue_cert.sh <域名> <dns提供商> <账号名>
# ======================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

OVERRIDE_FILE="$GATEWAY_DIR/docker-compose.override.yml"
MAIN_COMPOSE="$GATEWAY_DIR/docker-compose.yml"

if [ "$#" -lt 1 ]; then
    echo "用法: $0 <账号名>"
    echo "示例: $0 work    # 新增账号 work (第二账号)"
    echo "说明: 账号名用于容器名/凭证文件/数据目录, 需为小写字母开头"
    echo "      签发: $SCRIPT_DIR/issue_cert.sh <域名> <dns提供商> <账号名>"
    exit 1
fi

NAME=$1
validate_account "$NAME" \
    || die "账号名格式不对: 以小写字母开头, 仅含小写字母/数字/下划线/连字符"
if [ "$NAME" = "main" ]; then
    die "main 是主账号, 已存在, 无需新增。"
fi
# 只需 docker CLI 生成/校验 compose 配置, 不要求守护进程已启动
# (本脚本允许在网关部署前先生成账号配置)
command -v docker >/dev/null 2>&1 || die "未安装 Docker。安装: curl -fsSL https://get.docker.com | sh"
if ! container_running "$NGINX_CONTAINER" && ! container_exists "$NGINX_CONTAINER"; then
    warn "网关尚未部署 (未发现 $NGINX_CONTAINER)。"
    ui_hint "本脚本仍会生成配置, 但请先完成初始化: $SCRIPT_DIR/setup.sh"
fi

# ---------- 1. 凭证文件 ----------
ENV_FILE="$GATEWAY_DIR/accounts/${NAME}.env"
if [ -f "$ENV_FILE" ]; then
    info "凭证文件已存在, 跳过: $ENV_FILE"
else
    cat > "$ENV_FILE" <<EOF
# ==========================================
# DNS API Token - 账号 ${NAME}
# 由 add_account.sh 生成, 由 docker-compose.override.yml 中的 acme_${NAME} 服务加载
# ==========================================

# [Option 1] Cloudflare
# CF_Token=
# CF_Account_ID=

# [Option 2] Aliyun
# Ali_Key=
# Ali_Secret=

# [Option 3] DNSPod (腾讯云)
# DP_Id=
# DP_Key=
EOF
    chmod 600 "$ENV_FILE"
    ok "已生成凭证文件: $ENV_FILE (请稍后填入 Token)"
fi

# ---------- 2. 数据目录 ----------
mkdir -p "$GATEWAY_DIR/acme/${NAME}" || die "无法创建目录: $GATEWAY_DIR/acme/${NAME}"
ok "数据目录就绪: acme/${NAME}/ (独立续期记录, 与其他账号互不干扰)"

# ---------- 3. 生成 compose 服务 ----------
# [Rule] 公共字段 (镜像/资源限制/日志/标签/命令) 一律从主 compose 的 x-acme-account
#        锚点提取后展开, 不在这里重抄一份。否则主配置升级后, 用本脚本新增的账号
#        会一直停留在旧设置上 (镜像版本、资源限制静默漂移)。
AWK_EXTRACT='
    /^x-acme-account:/ { capture = 1; next }
    capture && /^[^[:space:]#]/ { exit }
    capture { lines[++n] = $0 }
    END {
        start = 1
        while (start <= n && lines[start] ~ /^[[:space:]]*$/) start++
        while (n >= start && lines[n] ~ /^[[:space:]]*$/) n--
        for (i = start; i <= n; i++) print "  " lines[i]
    }
'
ACME_TEMPLATE=$(awk "$AWK_EXTRACT" "$MAIN_COMPOSE")
if [ -z "$ACME_TEMPLATE" ]; then
    die "未能从 $MAIN_COMPOSE 提取 x-acme-account 锚点 (文件被改动过?), 已中止。"
fi

BLOCK_FILE=$(mktemp)
{
    echo "  # [Account] 由 add_account.sh 生成: 账号 ${NAME}"
    echo "  # [Note] 以下公共字段展开自主 compose 的 x-acme-account 锚点;"
    echo "  #        调整镜像/资源限制请改主 compose, 再重新运行本脚本生成。"
    echo "  acme_${NAME}:"
    printf '%s\n' "$ACME_TEMPLATE"
    echo "    container_name: ${ACME_PREFIX}${NAME}"
    echo "    env_file:"
    echo "      - .env"
    echo "      - accounts/${NAME}.env # 账号 ${NAME} 的 DNS Token"
    echo "    volumes:"
    echo "      - ./nginx/ssl:/etc/nginx/ssl"
    echo "      - ./acme/${NAME}:/acme_config"
    echo "      - /var/run/docker.sock:/var/run/docker.sock"
} > "$BLOCK_FILE"

# [Rollback] 校验不通过时把 override 还原, 不留下半个坏文件
BACKUP_FILE=""
if [ -f "$OVERRIDE_FILE" ]; then
    BACKUP_FILE=$(mktemp)
    cp "$OVERRIDE_FILE" "$BACKUP_FILE"
fi

if [ ! -f "$OVERRIDE_FILE" ]; then
    # 新建 override 文件
    {
        echo "# =========================================="
        echo "# 本地定制配置 (docker compose 会自动叠加本文件)"
        echo "# 已被 .gitignore 忽略, 不会提交到仓库"
        echo "# =========================================="
        echo "services:"
        cat "$BLOCK_FILE"
    } > "$OVERRIDE_FILE"
    ok "已创建 docker-compose.override.yml 并写入 acme_${NAME} 服务"
elif grep -qE "^[[:space:]]*acme_${NAME}:" "$OVERRIDE_FILE"; then
    info "override 文件中已存在 acme_${NAME} 服务, 跳过"
else
    # 插入到 services: 键下
    if grep -q '^services:' "$OVERRIDE_FILE"; then
        sed -i "/^services:/r $BLOCK_FILE" "$OVERRIDE_FILE"
    else
        printf '\nservices:\n' >> "$OVERRIDE_FILE"
        cat "$BLOCK_FILE" >> "$OVERRIDE_FILE"
    fi
    ok "已在 docker-compose.override.yml 中追加 acme_${NAME} 服务"
fi
rm -f "$BLOCK_FILE"

# [Verify] 合并后的 compose 必须能解析, 否则回滚
if [ -f "$GATEWAY_DIR/.env" ] && [ -f "$GATEWAY_DIR/accounts/main.env" ]; then
    if COMPOSE_ERR=$(cd "$GATEWAY_DIR" && docker compose config --quiet 2>&1); then
        ok "compose 配置解析通过"
    else
        if [ -n "$BACKUP_FILE" ]; then
            cp "$BACKUP_FILE" "$OVERRIDE_FILE"
            warn "override 文件已还原为修改前的内容"
        else
            rm -f "$OVERRIDE_FILE"
            warn "已删除本次生成的 override 文件"
        fi
        [ -n "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE"
        err "生成的 compose 配置无法解析, 已回滚。原始报错:"
        echo "$COMPOSE_ERR" | sed 's/^/    /'
        exit 1
    fi
else
    warn "缺少 .env 或 accounts/main.env, 跳过 compose 校验 (先运行 setup.sh)"
fi
[ -n "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE"

# ---------- 4. 后续指引 ----------
echo ""
echo -e "  ${C_STEP}── 后续三步${C_END} ${C_DIM}${UI_TRAIL}${C_END}"
ui_hint "1. 填入 Token: nano ${ENV_FILE}"
ui_hint "   Cloudflare 填 CF_Token / 阿里云填 Ali_Key+Ali_Secret / DNSPod 填 DP_Id+DP_Key"
ui_hint "2. 启动账号容器:"
ui_cmd "cd $GATEWAY_DIR && docker compose up -d"
ui_hint "3. 用该账号签发证书 (dns 提供商按实际选择):"
ui_cmd "bash $SCRIPT_DIR/issue_cert.sh <域名> dns_cf ${NAME}    # 或 dns_ali / dns_dp"
echo ""
ui_hint "提示: 同一域名只能属于一个账号; 自动续期按账号隔离。"
ui_hint "      查看所有账号容器: docker ps -a --format '{{.Names}}' | grep gateway_acme"
ui_hint "      移除账号: 删除 accounts/${NAME}.env 与 acme/${NAME}/, 删掉 override 中的"
ui_hint "                acme_${NAME} 块, 再执行 docker compose up -d --remove-orphans"
