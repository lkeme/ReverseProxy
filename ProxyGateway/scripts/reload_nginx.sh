#!/bin/bash

# ======================================================
# ProxyGateway 安全重载网关
# ======================================================
# 先做 Nginx 语法检查, 通过才 reload; 失败则保持现有配置
# 继续运行, 不影响线上服务。
# 用法: ./reload_nginx.sh  (可在任意目录运行)
# ======================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if nginx_safe_reload; then
    ok "网关已重载。"
else
    err "网关未重载 (保持原有配置继续运行)。"
    ui_hint "常见原因: conf.d 中有配置引用了不存在的证书或存在语法错误。"
    ui_cmd "docker exec $NGINX_CONTAINER nginx -t   # 排查"
    exit 1
fi
