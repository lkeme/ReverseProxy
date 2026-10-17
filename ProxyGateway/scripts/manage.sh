#!/bin/bash

# ======================================================
# ProxyGateway 管理面板 (统一入口)
# ======================================================
# 一个菜单完成所有日常操作, 不用记脚本名。
# 用法: ./manage.sh  (需在终端交互运行; 各步也可直接用 scripts/ 下的单个脚本)
# ======================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_interactive

pause() {
    ask "${C_DIM}  按回车返回菜单...${C_END}" _PAUSE
}

# --- 网关状态拦截: 需要网关在运行的菜单项, 未启动时提示后返回菜单 ---
# [Note] 免得答完一长串问答才被告知"网关未运行", 输入全部作废
require_gateway() {
    container_running "$NGINX_CONTAINER" && return 0
    warn "网关未运行 ($NGINX_CONTAINER), 此操作需要网关先启动。"
    ui_hint "启动: 本菜单选 1 (初始化网关), 或: cd $GATEWAY_DIR && docker compose up -d"
    return 1
}

# --- 顶部状态总览 (网关 / 账号容器 / 证书 / 站点) ---
show_summary() {
    local GW_STATE ACME_COUNT CERT_COUNT SITE_COUNT
    if container_running "$NGINX_CONTAINER"; then
        GW_STATE="${C_OK}✓ 运行中${C_END}"
    else
        GW_STATE="${C_ERR}✗ 未运行${C_END}"
    fi
    ACME_COUNT=$(acme_containers | grep -c .)
    CERT_COUNT=$(ssl_cert_domains | grep -c .)
    SITE_COUNT=$(site_domains | grep -c .)
    echo -e "  网关: ${GW_STATE}    账号容器: ${C_BOLD}${ACME_COUNT}${C_END}    证书: ${C_BOLD}${CERT_COUNT}${C_END}    站点: ${C_BOLD}${SITE_COUNT}${C_END}"
}

show_menu() {
    echo ""
    echo -e "  ${C_STEP}─ 部署 ────────────────────────────────${C_END}"
    echo -e "   ${C_NUM}1${C_END}) 初始化网关        ${C_DIM}首次部署: 配置邮箱与 DNS Token 并启动${C_END}"
    echo -e "   ${C_NUM}2${C_END}) 接入新站点        ${C_DIM}问答式: 证书 → 启动业务 → 部署配置 → 重载${C_END}"
    echo -e "  ${C_STEP}─ 证书 ────────────────────────────────${C_END}"
    echo -e "   ${C_NUM}3${C_END}) 签发 / 更新证书   ${C_DIM}为某个域名签发 (含通配符)${C_END}"
    echo -e "   ${C_NUM}4${C_END}) 新增 DNS 账号     ${C_DIM}同一运营商有多个账号时使用${C_END}"
    echo -e "  ${C_STEP}─ 日常运维 ────────────────────────────${C_END}"
    echo -e "   ${C_NUM}5${C_END}) 更新站点配置      ${C_DIM}改完项目 app.conf 后部署到网关 (备份+回滚)${C_END}"
    echo -e "   ${C_NUM}6${C_END}) 重载网关          ${C_DIM}直接重载网关 Nginx (先语法检查)${C_END}"
    echo -e "   ${C_NUM}7${C_END}) 健康自检          ${C_DIM}容器 / 配置 / 证书 / 端口 一屏总览${C_END}"
    echo -e "   ${C_NUM}8${C_END}) 状态与日志        ${C_DIM}容器状态 + 站点列表 + 最近日志${C_END}"
    echo ""
    echo -e "   ${C_NUM}0${C_END}) 退出"
}

show_status() {
    ui_section "容器状态"
    docker ps -a --filter "name=gateway_" --format "table {{.Names}}\t{{.Status}}" | sed 's/^/  /'
    ui_section "已部署证书"
    CERT_DOMAINS=$(ssl_cert_domains)
    if [ -n "$CERT_DOMAINS" ]; then
        echo "$CERT_DOMAINS" | while IFS= read -r CERT_ITEM; do ui_bullet "$CERT_ITEM"; done
    else
        ui_hint "(无)"
    fi
    ui_section "已接入站点 (conf.d)"
    SITES=$(site_domains)
    if [ -n "$SITES" ]; then
        echo "$SITES" | while IFS= read -r SITE_ITEM; do ui_bullet "$SITE_ITEM"; done
    else
        ui_hint "(无)"
    fi
    if container_running "$NGINX_CONTAINER"; then
        ui_section "网关最近日志 (20 行)"
        docker logs --tail 20 "$NGINX_CONTAINER" 2>&1 | sed 's/^/  /'
    else
        ui_section "网关最近日志"
        warn "$NGINX_CONTAINER 未运行, 无法读取日志"
    fi
}

ui_header "ProxyGateway 管理面板"
ui_hint "仓库目录: $GATEWAY_DIR"

while true; do
    show_summary   # 每轮刷新: 菜单 1 启动网关后, 状态行不再停留在"未运行"
    show_menu
    ask "${C_BOLD}  请选择${C_END} [0-8]: " CHOICE
    case "$CHOICE" in
        1)
            bash "$SCRIPT_DIR/setup.sh"
            pause
            ;;
        2)
            require_gateway || { pause; continue; }
            bash "$SCRIPT_DIR/new-site.sh"
            pause
            ;;
        3)
            ui_section "签发 / 更新证书"
            ui_hint "每次签发都会同时申请 <域名> 与 *.<域名> (通配符)"
            ask "  域名 (如 app.example.com): " CERT_DOMAIN
            if [ -z "$CERT_DOMAIN" ]; then
                warn "域名不能为空"
                pause
                continue
            fi
            echo "    1) Cloudflare    2) 阿里云    3) DNSPod"
            ask "  选择 [1-3, 默认 1]: " DNS_CHOICE
            case "$DNS_CHOICE" in
                2) DNS_PROVIDER="dns_ali" ;;
                3) DNS_PROVIDER="dns_dp" ;;
                *) DNS_PROVIDER="dns_cf" ;;
            esac
            ask "  账号名 [默认 main]: " ACCOUNT
            ACCOUNT="${ACCOUNT:-main}"
            echo ""
            bash "$SCRIPT_DIR/issue_cert.sh" "$CERT_DOMAIN" "$DNS_PROVIDER" "$ACCOUNT"
            pause
            ;;
        4)
            ui_section "新增 DNS 账号"
            ui_hint "用于: 多个域名托管在同一运营商的不同账号下"
            ask "  账号名 (小写字母开头, 如 work): " NEW_ACCOUNT
            if [ -z "$NEW_ACCOUNT" ]; then
                warn "账号名不能为空"
                pause
                continue
            fi
            echo ""
            bash "$SCRIPT_DIR/add_account.sh" "$NEW_ACCOUNT"
            pause
            ;;
        5)
            require_gateway || { pause; continue; }
            echo ""
            ui_section "更新站点配置"
            ui_hint "把项目里的 app.conf 部署到网关 conf.d 并安全重载 (自动备份旧配置)"
            ask "  项目名 (new-site.sh 接入时填写的名字): " DEPLOY_NAME
            if [ -z "$DEPLOY_NAME" ]; then
                warn "项目名不能为空"
                pause
                continue
            fi
            bash "$SCRIPT_DIR/deploy_conf.sh" "$DEPLOY_NAME"
            pause
            ;;
        6)
            require_gateway || { pause; continue; }
            echo ""
            bash "$SCRIPT_DIR/reload_nginx.sh"
            pause
            ;;
        7)
            echo ""
            bash "$SCRIPT_DIR/doctor.sh"
            pause
            ;;
        8)
            show_status
            pause
            ;;
        0|q|Q|exit|quit)
            info "已退出。"
            exit 0
            ;;
        *)
            warn "无效选项, 请输入 0-8。"
            ;;
    esac
done
