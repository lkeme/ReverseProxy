#!/bin/bash

# ======================================================
# ProxyGateway 站点配置部署工具
# ======================================================
# 把项目里的 app.conf 部署到网关 conf.d 并安全重载。
# 相比手动 "cp + reload": 自动定位项目源文件 / 内容变化时
# 备份旧配置 / 语法检查失败时自动回滚, 网关始终不受影响。
# 用法: ./deploy_conf.sh <项目名> [app.conf 路径]
#   项目名 = new-site.sh 接入时填的名字 (conf.d 里的文件名)
#   路径可选: 项目不在仓库根目录下时, 指定 app.conf 的位置
# ======================================================

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    echo "用法: $0 <项目名> [app.conf 路径]"
    echo "示例: $0 my-web                    # 部署 ../my-web/ 下的 app.conf"
    echo "      $0 my-web /opt/proj/app.conf  # 项目在仓库根目录之外时指定路径"
    echo "项目名即 conf.d 里的文件名 (new-site.sh 接入向导中填写的名字)。"
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    exit 1
fi

NAME="$1"
if ! validate_project "$NAME"; then
    die "项目名格式不对: $NAME (字母开头, 仅含字母/数字/./_/-)"
fi

# ---------- 1. 定位项目源 app.conf ----------
SRC_FILE=""
if [ "$#" -eq 2 ]; then
    SRC_FILE="$2"
else
    SRC_FILE=$(project_appconf "$NAME") \
        || die "未找到项目 $NAME 的 app.conf (找过: $ROOT_DIR/$NAME/app.conf 与其 gateway.* 子目录)。项目在别的路径时, 用第 2 参数指定。"
fi
if [ ! -f "$SRC_FILE" ]; then
    die "文件不存在: $SRC_FILE"
fi

# ---------- 2. 源文件检查 ----------
# [Note] 带未替换占位符的模板一旦部署, 网关的下一次 reload 会失败
if grep -q '__[A-Z][A-Z]*__' "$SRC_FILE"; then
    die "$SRC_FILE 仍含未替换的占位符 (__XXX__), 请先填好再部署。"
fi

# ---------- 3. 部署并重载 ----------
container_running "$NGINX_CONTAINER" \
    || die "$NGINX_CONTAINER 未运行, 无法部署。先启动: cd $GATEWAY_DIR && docker compose up -d"

DEST_FILE="$GATEWAY_DIR/nginx/conf.d/${NAME}.conf"
info "源文件: $SRC_FILE"
info "部署到: $DEST_FILE"

# 内容有变化才备份旧配置 (避免重复运行时堆积 .bak)
# [Note] .bak 不匹配 Nginx 的 *.conf 通配, 不会被加载
# [Note] 记录部署前是否已有配置、本次是否生成备份: 内容未变时不会生成新备份,
#        此时若语法检查因其他配置失败, 不能误删/误还原这份配置。
DEST_EXISTED=0
BACKUP_CREATED=0
if [ -f "$DEST_FILE" ]; then
    DEST_EXISTED=1
    if ! cmp -s "$SRC_FILE" "$DEST_FILE"; then
        cp "$DEST_FILE" "$DEST_FILE.bak" || die "无法备份 $DEST_FILE, 已中止 (原配置未改动)"
        BACKUP_CREATED=1
        info "已备份现有配置 → ${NAME}.conf.bak (语法检查失败时自动回滚)"
    fi
fi
if ! cp "$SRC_FILE" "$DEST_FILE"; then
    if [ "$BACKUP_CREATED" -eq 1 ]; then
        cp "$DEST_FILE.bak" "$DEST_FILE" && warn "写入失败, 已从备份还原原配置"
    elif [ "$DEST_EXISTED" -eq 0 ]; then
        rm -f "$DEST_FILE"
    fi
    die "无法写入 $DEST_FILE, 已中止"
fi

if ! nginx_safe_reload; then
    # 回滚到部署前的状态, 网关继续用原有配置运行
    if [ "$BACKUP_CREATED" -eq 1 ]; then
        mv "$DEST_FILE.bak" "$DEST_FILE"
        warn "已回滚 ${NAME}.conf 为部署前版本 (网关不受影响)"
    elif [ "$DEST_EXISTED" -eq 1 ]; then
        warn "该配置内容未变, 已保持原样 (网关不受影响); 失败原因在其他配置文件"
    else
        rm -f "$DEST_FILE"
        warn "已移除新部署的 ${NAME}.conf (网关上此前没有该站点)"
    fi
    ui_hint "常见原因: 语法错误 / 引用了不存在的证书或容器。修正 $SRC_FILE 后重试"
    exit 1
fi

ok "站点配置已部署并重载: nginx/conf.d/${NAME}.conf"
