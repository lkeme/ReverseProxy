#!/bin/bash

# ======================================================
# ProxyGateway 脚本共享函数库
# ======================================================
# 仅由 scripts/ 下的其他脚本 source 使用, 不单独执行。
# 提供: 路径定位 / 统一 TUI 输出组件 / 交互读取 / 环境前置检查
#       容器与证书查询 / 端口检查 / Nginx 安全重载
#
# [Rule] 所有脚本共用的路径与容器名只在"常量区"定义一次,
#        新增脚本请直接复用这里的函数, 不要再各写一份。
# [Rule] 用户可见输出统一走本库的 TUI 组件 (ui_* / ok / warn / err / info),
#        保证全部脚本格式一致: 步骤头、缩进、配色、符号。
# ======================================================

# --- 路径定位 (基于本文件位置, 在任意目录调用脚本均有效) ---
# shellcheck disable=SC2034  # 下列变量供 source 本库的脚本使用
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$LIB_DIR"        # 脚本目录
GATEWAY_DIR="$(dirname "$LIB_DIR")"  # 网关目录 (ProxyGateway)
ROOT_DIR="$(dirname "$GATEWAY_DIR")" # 仓库根目录 (业务项目所在处)

# --- 常量区 ---
NGINX_CONTAINER="gateway_nginx"
ACME_PREFIX="gateway_acme_"                # 账号容器名前缀 (gateway_acme_<账号>)
ACME_CONFIG_HOME="/acme_config"            # 账号容器内的 acme 数据目录
CERT_DIR_CONTAINER="/etc/nginx/ssl"        # 容器内证书目录
CERT_DIR_HOST="$GATEWAY_DIR/nginx/ssl"     # 宿主机证书目录 (与上面是同一个目录)
# 域名格式 (用于校验用户输入; 不匹配 IP、带协议或路径的写法)
DOMAIN_RE='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'
# 账号名格式 (与容器名/文件名/目录名共用, 必须同时是合法的文件与 YAML 键)
ACCOUNT_RE='^[a-z][a-z0-9_-]*$'
# 项目名格式 (同时用作目录名/配置文件名, 容器方式下也是容器名; 允许大写与 . _ -,
# 如 my-web / ProxyGateway / My.App_2; 另由 validate_project 拒绝以 . 结尾)
PROJECT_RE='^[a-zA-Z][a-zA-Z0-9._-]*$'
# 容器名格式 (Docker 规则, 比项目名宽松: 允许下划线与数字开头, 用于手填已有容器名)
CONTAINER_RE='^[a-zA-Z0-9][a-zA-Z0-9_.-]*$'
# .env 中未填写时的占位邮箱, 用于检测"配了但没改"
PLACEHOLDER_EMAIL='your_email@example.com'

# --- TUI 分隔线 (宽 54 列, 与中文两倍宽字符搭配使用) ---
UI_WIDE='══════════════════════════════════════════════════════'
UI_THIN='──────────────────────────────────────────────────────'
UI_TRAIL='────────────────────────' # 24 列, 小节标题尾部装饰

# --- 配色 (非终端时自动降级为纯文本; 设 NO_COLOR=1 可强制关闭) ---
# [Note] 必须用 $'...' 写成真正的转义字节: echo -e 会解析 "\033", 但 read -p
#        (ask 用的交互提示) 不解析, 会把 \033[1m 原样打印出来。写成真字节两边都对。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_END=$'\033[0m'
    C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'; C_INFO=$'\033[0;36m'
    C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
    C_TITLE=$'\033[1;36m'; C_STEP=$'\033[1;37m'; C_NUM=$'\033[1;35m'; C_ACCENT=$'\033[0;35m'
else
    C_END=''
    C_OK=''; C_ERR=''; C_WARN=''; C_INFO=''
    C_BOLD=''; C_DIM=''
    C_TITLE=''; C_STEP=''; C_NUM=''; C_ACCENT=''
fi

# --- 统一前缀输出 (符号 + 颜色) ---
info() { echo -e "  ${C_INFO}ℹ${C_END} $*"; }   # 一般说明
ok()   { echo -e "  ${C_OK}✓${C_END} $*"; }     # 成功/正常
warn() { echo -e "  ${C_WARN}⚠${C_END} $*"; }   # 警告 (可继续)
err()  { echo -e "  ${C_ERR}✗${C_END} $*" >&2; } # 错误 (不退出)
die()  { err "$*"; exit 1; }                     # 错误并退出

# --- TUI 组件 ---
ui_header() {  # 脚本横幅: ui_header <标题>
    echo ""
    echo -e "${C_TITLE}${UI_WIDE}${C_END}"
    echo -e "  ${C_BOLD}$*${C_END}"
    echo -e "${C_TITLE}${UI_WIDE}${C_END}"
}

ui_section() {  # 小节标题: ui_section <标题>
    echo ""
    echo -e "${C_STEP}── $*${C_END} ${C_DIM}${UI_TRAIL}${C_END}"
}

ui_step() {  # 向导步骤头: ui_step <序号> <总数> <标题>
    echo ""
    echo -e "${C_ACCENT}▶${C_END} ${C_NUM}[$1/$2]${C_END} ${C_BOLD}$3${C_END}"
}

ui_bullet() {  # 列表项
    echo -e "  ${C_ACCENT}●${C_END} $*"
}

ui_hint() {  # 次要说明 (弱化显示)
    echo -e "  ${C_DIM}$*${C_END}"
}

ui_cmd() {  # 可照抄执行的命令建议
    echo -e "  ${C_DIM}\$${C_END} ${C_INFO}$*${C_END}"
}

ui_done() {  # 完成横幅: ui_done <标题>
    echo ""
    echo -e "${C_OK}${UI_THIN}${C_END}"
    echo -e "  ${C_BOLD}$*${C_END}"
    echo -e "${C_OK}${UI_THIN}${C_END}"
}

# --- 交互读取 (遇到 EOF/Ctrl+D 时优雅退出, 避免校验循环死循环) ---
# [Note] 顺手去掉行尾 \r: 从 Windows 终端/文档粘贴时可能带 CRLF,
#        留着会让域名/项目名校验永远失败, 用户被困在重输循环里。
ask() {
    local _ANSWER
    read -r -p "$1" _ANSWER || { echo ""; info "已取消。"; exit 1; }
    _ANSWER=${_ANSWER%$'\r'}
    printf -v "$2" '%s' "$_ANSWER"
}

# --- 是/否询问: ask_yn <提示> [Y|N]; 返回 0=是, 1=否 ---
ask_yn() {
    local PROMPT DEFAULT ANSWER
    DEFAULT=${2:-N}
    if [ "$DEFAULT" = "Y" ]; then
        PROMPT="$1 [Y/n]: "
    else
        PROMPT="$1 [y/N]: "
    fi
    ask "$PROMPT" ANSWER
    case "$ANSWER" in
        "")      [ "$DEFAULT" = "Y" ] ;;
        y|Y|yes) return 0 ;;
        *)       return 1 ;;
    esac
}

# --- 环境前置检查 (失败即退出, 提示可直接照抄执行) ---
require_docker() {
    command -v docker >/dev/null 2>&1 || die "未安装 Docker。安装: curl -fsSL https://get.docker.com | sh"
    docker info >/dev/null 2>&1 || die "Docker 守护进程未运行, 请先启动 (sudo systemctl start docker)。"
}

require_compose_v2() {
    if ! docker compose version >/dev/null 2>&1; then
        err "docker compose (v2) 不可用。旧的独立 docker-compose (v1) 已停止维护, 请安装 Compose 插件。"
        ui_hint "安装文档: https://docs.docker.com/compose/install/linux/"
        exit 1
    fi
}

# --- 需要交互式终端 (向导类脚本前置检查) ---
require_interactive() {
    [ -t 0 ] || die "本脚本需要交互式终端运行 (请直接登录服务器执行, 不要用管道或定时任务调用)。"
}

# --- 容器查询 ---
container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# --- 等待容器进入运行状态 (最多 <秒数>, 默认 10); 返回 0=运行中 ---
# [Note] docker compose up -d 成功只代表容器已创建, 镜像错误/启动即崩时
#        进程会立刻退出, 需要再确认一次才算真正启动成功
wait_container_running() { # wait_container_running <容器名> [秒数]
    local C=$1 MAX=${2:-10} I=0
    while [ "$I" -lt "$MAX" ]; do
        container_running "$C" && return 0
        sleep 1
        I=$((I + 1))
    done
    return 1
}

# --- 容器已接入的 Docker 网络列表 (空格分隔; 容器不存在时输出为空) ---
container_networks() {
    docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null
}

# --- 账号容器列表 (默认含已停止的; 传 running 只列运行中的) ---
acme_containers() {
    if [ "${1:-}" = "running" ]; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep "^${ACME_PREFIX}" || true
    else
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^${ACME_PREFIX}" || true
    fi
}

# --- 校验 ---
# [Rule] 这些值会直接写入 nginx / compose 配置, 因此必须整串匹配且不含换行。
#        echo + grep 会把多行输入拆开逐行匹配, 换行后的内容可绕过校验注入配置。
_validate_value() { # _validate_value <值> <正则>
    case "$1" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac
    printf '%s' "$1" | grep -qxE "$2"
}
validate_domain()         { _validate_value "$1" "$DOMAIN_RE"; }
validate_account()        { _validate_value "$1" "$ACCOUNT_RE"; }
validate_container_name() { _validate_value "$1" "$CONTAINER_RE"; }
validate_project() {
    _validate_value "$1" "$PROJECT_RE" || return 1
    [ "${1%.}" = "$1" ] # 拒绝以 . 结尾 (避免生成 app..conf 这类文件名)
}

# --- 目录内的 compose 文件 (按 docker compose v2 的自动识别顺序) ---
# 用法: compose_file <目录>; 找到时输出文件名 (仅文件名) 并返回 0, 未找到返回 1
compose_file() {
    local F
    for F in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
        if [ -f "$1/$F" ]; then
            echo "$F"
            return 0
        fi
    done
    return 1
}

# --- 项目源 app.conf 定位 (deploy_conf.sh / doctor.sh 共用) ---
# 查找顺序: gateway.<hash> 子目录 (自带 compose 模式, 向导专属空间)
#         > 项目根 app.conf (镜像/构建/宿主机模式)
# 用法: project_appconf <项目名>; 找到时输出路径并返回 0, 未找到返回 1
# [Note] 项目放在仓库根目录之外时 (接入只认容器名) 返回 1, 由调用方处理
project_appconf() {
    local SUB
    for SUB in "$ROOT_DIR/$1"/gateway.*/app.conf; do
        [ -f "$SUB" ] || continue
        echo "$SUB"
        return 0
    done
    if [ -f "$ROOT_DIR/$1/app.conf" ]; then
        echo "$ROOT_DIR/$1/app.conf"
        return 0
    fi
    return 1
}

# --- 某域名在某账号下是否已有签发记录 ---
# [Note] acme.sh 默认使用 ec-256, 数据目录为 <域名>_ecc; 显式指定 RSA 时为 <域名>。
#        两种都要查, 否则冲突检测会漏判。
# [Fix] 已停止的账号容器无法 docker exec (会直接报错), 只查容器会让它名下持有的域名
#       全部漏判 —— 而这正是需要拦截的情况 (停掉的账号同样持有签发记录)。
#       因此容器不在运行时改查它在宿主机上的数据目录 (compose 把 ./acme/<账号>
#       绑定挂载为容器内的 $ACME_CONFIG_HOME)。
cert_in_account() { # cert_in_account <acme容器> <域名>
    if container_running "$1"; then
        docker exec "$1" test -d "${ACME_CONFIG_HOME}/$2" 2>/dev/null && return 0
        docker exec "$1" test -d "${ACME_CONFIG_HOME}/$2_ecc" 2>/dev/null && return 0
        return 1
    fi
    local ACCOUNT_DIR="$GATEWAY_DIR/acme/${1#"$ACME_PREFIX"}"
    [ -d "$ACCOUNT_DIR/$2" ] || [ -d "$ACCOUNT_DIR/$2_ecc" ]
}

# --- 已部署证书的域名列表 (来自宿主机 ssl 目录的 *.pem 文件名) ---
ssl_cert_domains() {
    local F
    for F in "$CERT_DIR_HOST"/*.pem; do
        [ -e "$F" ] || continue
        basename "$F" .pem
    done
}

# --- 已接入站点的域名列表 (conf.d 中所有 server_name, 去重) ---
site_domains() {
    grep -hE '^\s*server_name' "$GATEWAY_DIR/nginx/conf.d"/*.conf 2>/dev/null \
        | sed 's/.*server_name\s*//; s/;.*//' | tr -s ' ' '\n' | grep -vE '^(_|\*|)$' | sort -u
}

# --- 某配置文件声明的所有 server_name 域名 (去重, 每行一个) ---
conf_server_names() { # conf_server_names <conf文件>
    grep -hE '^\s*server_name' "$1" 2>/dev/null \
        | sed 's/.*server_name\s*//; s/;.*//' | tr -s ' ' '\n' | grep -vE '^(_|\*|)$' | sort -u
}

# --- 声明了某域名的 conf.d 文件列表 (每行一个文件名, 未发现时输出为空) ---
# 用法: conf_files_with_domain <域名> [排除文件名]
# [Note] 同一域名出现在多个 conf 文件时, Nginx 只认先加载的一个 (其余 server 块
#       被静默忽略) —— 向导与自检据此拦截"重复接入同一域名"
conf_files_with_domain() {
    local F
    for F in "$GATEWAY_DIR"/nginx/conf.d/*.conf; do
        [ -e "$F" ] || continue
        [ "$(basename "$F")" = "${2:-}" ] && continue
        # [Note] 按 server_name 的完整 token 精确比较 (大小写不敏感, 与 Nginx 行为一致):
        #        不能用 grep -w —— 连字符不属于词字符, 会把 my-app.example.com 误判为占用 app.example.com
        if grep -hE '^\s*server_name' "$F" 2>/dev/null \
            | sed 's/.*server_name\s*//; s/;.*//' | tr -s '[:space:]' '\n' | grep -qxiF "$1"; then
            basename "$F"
        fi
    done
}

# --- 证书剩余有效天数 (读取容器内证书; acme.sh 镜像自带 openssl) ---
# 用法: cert_days_left <acme容器> <域名>; 成功输出整数天数, 失败返回非 0
cert_days_left() {
    local ENDDATE END_TS
    ENDDATE=$(docker exec "$1" openssl x509 -in "${CERT_DIR_CONTAINER}/$2.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$ENDDATE" ] || return 1
    END_TS=$(date -d "$ENDDATE" +%s 2>/dev/null) || return 1
    echo $(( (END_TS - $(date +%s)) / 86400 ))
}

# --- Nginx 语法检查 (结果存入 NGINX_TEST_OUTPUT, 返回码即检查结果) ---
nginx_test() {
    NGINX_TEST_OUTPUT=$(docker exec "$NGINX_CONTAINER" nginx -t 2>&1)
}

# --- Nginx 安全重载: 先语法检查, 通过才 reload, 失败不影响运行中的网关 ---
# 返回 0=已重载; 1=未重载 (未运行/语法错误, 详细输出已打印)
nginx_safe_reload() {
    if ! container_running "$NGINX_CONTAINER"; then
        err "$NGINX_CONTAINER 未运行, 无法重载。"
        return 1
    fi
    if ! nginx_test; then
        err "Nginx 配置检查未通过, 已保持现有配置继续运行 (网关未受影响):"
        echo "$NGINX_TEST_OUTPUT" | sed 's/^/    /'
        return 1
    fi
    if ! docker exec "$NGINX_CONTAINER" nginx -s reload; then
        err "reload 命令执行失败 (网关保持原有配置运行)。"
        return 1
    fi
    # [Note] nginx -t 对"server_name 重复"等只给 [warn] 且退出码为 0, reload 照常
    #       执行, 但被忽略的 server 块永远不会生效 —— 必须透出, 否则用户无从察觉
    local WARN_LINES
    WARN_LINES=$(printf '%s\n' "$NGINX_TEST_OUTPUT" | grep -F '[warn]')
    if [ -n "$WARN_LINES" ]; then
        warn "网关已重载, 但 Nginx 报告了以下警告 (部分配置可能未生效):"
        printf '%s\n' "$WARN_LINES" | sed 's/^/    /'
    fi
}

# --- 宿主机端口监听查询 (尽力而为, 无 ss/netstat 时返回空) ---
# 用法: port_listener <端口>  输出监听地址, 未监听或无工具时输出为空
port_listener() {
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -E "[:.]${1}\$" | head -1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -E "[:.]${1}\$" | head -1
    fi
}

# --- 用法: port_listening <端口>; 返回 0=已被占用 ---
port_listening() {
    [ -n "$(port_listener "$1")" ]
}
