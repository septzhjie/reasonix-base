#!/usr/bin/env bash
#
# send-ali-mail.sh —— 通过阿里企业邮箱 SMTP 发送邮件（mailx / s-nail + 外部 SMTP）
#
# 适用：Linux（Debian/Ubuntu/RHEL/CentOS/Arch 等），macOS 仅支持 --check / --dry-run
#        （macOS 自带 BSD mailx 不支持外部 SMTP）。
#
# 特性：
#   1. 自动探测 mailx 变体（s-nail / Heirloom mailx），生成对应语法的一次性配置
#   2. 默认使用 SSL 465 端口（阿里企业邮箱推荐），无需系统 sendmail
#   3. 密码绝不进命令行参数（只写入临时 600 权限的 mailrc，用完即删），避免被 ps 泄露
#   4. 账号/密码可通过 命令行 > 环境变量 > 配置文件 三层方式注入，方便 cron 等场景
#   5. 支持附件、中文主题自动 RFC2047 Base64 编码、SMTP 超时保护
#
# 阿里企业邮箱 SMTP 参数（官方文档：IMAP/POP3/SMTP 协议服务器地址与端口设置，
#   https://help.aliyun.com/zh/document_detail/36576.html）：
#     SMTP 服务器：smtp.qiye.aliyun.com
#     SSL 端口：465（推荐） | 非加密端口：25（80/587 暂未开通）
#     旧版地址：smtp.mxhichina.com（465/25）  中国香港：smtphk.qiye.aliyun.com（465/25）
#   注意：若管理员/账号开启了"三方客户端安全密码"，这里填的是生成的客户端安全密码，
#         而不是登录密码（见 docs/ali-email-smtp.md）。
#
# 用法示例：
#   ./send-ali-mail.sh -s "测试" -b "正文" -u user@yourdomain.com -p '安全密码' a@example.com
#   ALI_MAIL_USER=user@yourdomain.com ALI_MAIL_PASS='安全密码' \
#     ./send-ali-mail.sh --subject "告警" --file /tmp/alert.txt ops@example.com
#   ./send-ali-mail.sh --config ~/.config/ali-mail.conf -s "带附件" \
#     -a /tmp/report.pdf leader@example.com
#
# 退出码：0=成功  1=参数/配置错误  2=发送失败

set -uo pipefail

# ---------------- 默认配置 ----------------
DEFAULT_SMTP="smtp.qiye.aliyun.com"
DEFAULT_PORT=465
DEFAULT_TIMEOUT=60          # 秒；--timeout 0 表示不限制

# ---------------- 工具函数 ----------------
log()  { printf '\033[1;34m[send-mail]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail ]\033[0m %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
用法: send-ali-mail.sh [选项] 收件人...

必填:
  收件人               一个或多个收件人地址（空格分隔）
  -u, --user <邮箱>    发件账号（如 user@yourdomain.com）
  -p, --pass <密码>    密码 / 三方客户端安全密码

账号密码来源优先级（可省略 -u/-p，按序查找）:
  1) 命令行 -u / -p
  2) 环境变量 ALI_MAIL_USER / ALI_MAIL_PASS
  3) 配置文件（--config，或默认 ~/.config/ali-mail/smtp.conf）

正文（三选一，互斥）:
  -b, --body <文本>    直接给正文文本
  -f, --file <路径>    从文件读正文
  (都不给时)           从 stdin 读取正文（管道方式）

其他选项:
  -s, --subject <主题>     邮件主题（中文自动转 RFC2047 编码）
  -a, --attach <路径>      附件，可重复指定多个
      --from <地址>        覆盖发件人（默认用账号邮箱）
  -H, --smtp <地址>        SMTP 服务器（默认 smtp.qiye.aliyun.com）
  -P, --port <端口>        端口（默认 465）
      --no-ssl             使用非加密端口 25（阿里另有 80/587 未开通）
      --insecure           跳过 SSL 证书校验（仅自签名内网 SMTP 需要，慎用）
      --timeout <秒>       SMTP 超时（默认 60，0=不限）
      --variant <s-nail|heirloom>  强制指定 mailx 变体（默认自动探测）
      --verbose            显示 SMTP 会话详情（mailx -v）
      --dry-run            只打印将使用的配置与命令，不真正发送
      --check              检测当前环境 mailx 支持情况，不发送
  -h, --help               显示本帮助

示例:
  ./send-ali-mail.sh -s "磁盘告警" -f /tmp/disk.txt -u a@x.com -p 'pwd' ops@x.com
  printf '正文' | ALI_MAIL_USER=a@x.com ALI_MAIL_PASS=pwd ./send-ali-mail.sh -s hi b@x.com
EOF
    exit 0
}

# mailrc 变量值转义（包引号，转义内部的 " 和 \）
esc() { printf '%s' "$1" | sed 's/["\]/\\&/g'; }

# RFC2047 编码主题（非 ASCII 时转 Base64，兼容中文主题）
encode_subject() {
    local s="$1"
    if LC_ALL=C printf '%s' "$s" | grep -q '[^ -~]'; then
        local b64
        b64="$(printf '%s' "$s" | base64 | tr -d '\n')"
        printf '=?UTF-8?B?%s?=' "$b64"
    else
        printf '%s' "$s"
    fi
}

# ---------------- 参数解析 ----------------
USER_OPT="" PASS_OPT="" SUBJECT="" BODY="" BODY_FILE="" SMTP_HOST="" SMTP_PORT=""
FROM_OPT="" CONFIG_FILE="" VARIANT_OPT="" TIMEOUT="$DEFAULT_TIMEOUT"
USE_SSL=1 VERBOSE=0 DRY_RUN=0 CHECK=0 INSECURE=0
ATTACHES=() RECIPIENTS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)     [ $# -ge 2 ] || die "选项 $1 缺少参数"; USER_OPT="$2"; shift 2 ;;
        -p|--pass)     [ $# -ge 2 ] || die "选项 $1 缺少参数"; PASS_OPT="$2"; shift 2 ;;
        -s|--subject)  [ $# -ge 2 ] || die "选项 $1 缺少参数"; SUBJECT="$2"; shift 2 ;;
        -b|--body)     [ $# -ge 2 ] || die "选项 $1 缺少参数"; [ -z "$BODY_FILE" ] || die "-b/-f 只能二选一"; BODY="$2"; shift 2 ;;
        -f|--file)     [ $# -ge 2 ] || die "选项 $1 缺少参数"; [ -z "$BODY" ] || die "-b/-f 只能二选一"; BODY_FILE="$2"; shift 2 ;;
        -a|--attach)   [ $# -ge 2 ] || die "选项 $1 缺少参数"; ATTACHES+=("$2"); shift 2 ;;
        -H|--smtp)     [ $# -ge 2 ] || die "选项 $1 缺少参数"; SMTP_HOST="$2"; shift 2 ;;
        -P|--port)     [ $# -ge 2 ] || die "选项 $1 缺少参数"; SMTP_PORT="$2"; shift 2 ;;
        --from)        [ $# -ge 2 ] || die "选项 $1 缺少参数"; FROM_OPT="$2"; shift 2 ;;
        -c|--config)   [ $# -ge 2 ] || die "选项 $1 缺少参数"; CONFIG_FILE="$2"; shift 2 ;;
        --timeout)     [ $# -ge 2 ] || die "选项 $1 缺少参数"; TIMEOUT="$2"; shift 2 ;;
        --variant)     [ $# -ge 2 ] || die "选项 $1 缺少参数"; VARIANT_OPT="$2"; shift 2 ;;
        --no-ssl)      USE_SSL=0; shift ;;
        --insecure)    INSECURE=1; shift ;;
        --verbose)     VERBOSE=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --check)       CHECK=1; shift ;;
        -h|--help)     usage ;;
        -*)            die "未知选项: $1（用 -h 查看帮助）" ;;
        *)             RECIPIENTS+=("$1"); shift ;;
    esac
done

# ---------------- 变体探测 ----------------
# 返回 0 且设置 MAIL_BIN/VARIANT = 找到支持外部 SMTP 的 mailx；返回 1 = 未找到
detect_variant() {
    case "$VARIANT_OPT" in
        s-nail)
            VARIANT="s-nail"
            MAIL_BIN="$(command -v s-nail 2>/dev/null || command -v mailx 2>/dev/null || true)"
            [ -n "$MAIL_BIN" ] || return 1
            return 0 ;;
        heirloom)
            VARIANT="heirloom"
            MAIL_BIN="$(command -v mailx 2>/dev/null || command -v mail 2>/dev/null || true)"
            [ -n "$MAIL_BIN" ] || return 1
            return 0 ;;
        '') : ;;
        *) die "不支持的 --variant: $VARIANT_OPT（可选 s-nail / heirloom）" ;;
    esac
    if command -v s-nail >/dev/null 2>&1; then
        MAIL_BIN="$(command -v s-nail)"; VARIANT="s-nail"; return 0
    fi
    if command -v mailx >/dev/null 2>&1; then
        MAIL_BIN="$(command -v mailx)"
        if "$MAIL_BIN" -V 2>&1 | grep -qi 's-nail'; then VARIANT="s-nail"; return 0; fi
        if "$MAIL_BIN" -V 2>&1 | grep -qi 'heirloom'; then VARIANT="heirloom"; return 0; fi
        return 1
    fi
    if command -v mail >/dev/null 2>&1; then
        MAIL_BIN="$(command -v mail)"
        if "$MAIL_BIN" -V 2>&1 | grep -qi 's-nail'; then VARIANT="s-nail"; return 0; fi
        return 1
    fi
    return 1
}

INSTALL_HINT="安装：Debian/Ubuntu: apt install s-nail；RHEL/CentOS: yum install mailx；Arch: pacman -S s-nail"

if ! detect_variant; then
    if [ "$CHECK" -eq 1 ]; then
        warn "当前环境没有支持外部 SMTP 的 mailx（BSD/mailutils 版不支持，或未安装）"
        warn "$INSTALL_HINT"
        exit 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "当前环境没有支持外部 SMTP 的 mailx，以下按 heirloom 语法生成配置预览（未经本机验证）"
        VARIANT="heirloom"; MAIL_BIN="mailx"
    else
        die "未找到支持外部 SMTP 的 mailx。$INSTALL_HINT"
    fi
fi

if [ "$CHECK" -eq 1 ]; then
    case "$VARIANT" in
        s-nail)    SMTP_OK="支持（smtps:// 隐式 SSL）" ;;
        heirloom)  SMTP_OK="支持（smtp-use-ssl 隐式 SSL）" ;;
        *)         SMTP_OK="未知" ;;
    esac
    log "mailx 变体 : $VARIANT（$MAIL_BIN）"
    log "外部 SMTP  : $SMTP_OK"
    log "阿里邮箱配置: $DEFAULT_SMTP:465 (SSL) / 25 (明文)"
    exit 0
fi

# ---------------- 配置装载（账号密码层级） ----------------
: "${CONFIG_FILE:=$HOME/.config/ali-mail/smtp.conf}"
USER="$USER_OPT" PASS="$PASS_OPT"
if [ -z "$USER" ] && [ -n "${ALI_MAIL_USER:-}" ]; then USER="$ALI_MAIL_USER"; fi
if [ -z "$PASS" ] && [ -n "${ALI_MAIL_PASS:-}" ]; then PASS="$ALI_MAIL_PASS"; fi
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    [ -z "$USER" ] && USER="${ALI_MAIL_USER:-}"
    [ -z "$PASS" ] && PASS="${ALI_MAIL_PASS:-}"
fi

SMTP_HOST="${SMTP_HOST:-${ALI_MAIL_SMTP:-$DEFAULT_SMTP}}"
SMTP_PORT="${SMTP_PORT:-${ALI_MAIL_PORT:-$DEFAULT_PORT}}"

# ---------------- 校验 ----------------
[ "${#RECIPIENTS[@]}" -gt 0 ] || die "缺少收件人地址（用 -h 查看帮助）"
[ -n "$USER" ] || die "缺少发件账号（-u / ALI_MAIL_USER / 配置文件）"
[ -n "$PASS" ] || die "缺少密码（-p / ALI_MAIL_PASS / 配置文件）"
case "$SMTP_PORT" in
    ''|*[!0-9]*) die "端口必须是数字: $SMTP_PORT" ;;
esac
[ "$TIMEOUT" -eq "$TIMEOUT" ] 2>/dev/null || die "--timeout 必须是数字"

for f in ${ATTACHES[@]+"${ATTACHES[@]}"}; do
    [ -f "$f" ] || die "附件不存在: $f"
done

# 正文来源：-b 文本 / -f 文件 / stdin
if [ -n "$BODY_FILE" ]; then
    [ -f "$BODY_FILE" ] || die "正文文件不存在: $BODY_FILE"
    BODY_SRC="$BODY_FILE"
elif [ -n "$BODY" ]; then
    BODY_SRC=""
else
    if [ ! -t 0 ]; then
        BODY_SRC=""   # stdin
    else
        die "未提供正文：请用 -b/-f 或通过管道传入（用 -h 查看帮助）"
    fi
fi

# ---------------- 生成一次性配置 ----------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ali-mail.XXXXXX")"
chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

MAILRC="$TMP_DIR/.mailrc"
FROM_ADDR="${FROM_OPT:-$USER}"

if [ "$VARIANT" = "s-nail" ]; then
    # s-nail 现代写法：mta=smtps://USER:PASS@HOST:PORT（v15-compat，免过时警告）
    # URL 中用户名/密码需 URL 编码：@ → %40，特殊字符按 RFC3986 编码
    urlencode() {
        LC_ALL=C printf '%s' "$1" | sed 's/%/%25/g; s/@/%40/g; s/:/%3A/g; s/\//%2F/g; s/ /%20/g; s/+/%2B/g'
    }
    URL_USER="$(urlencode "$USER")"
    URL_PASS="$(urlencode "$PASS")"
    if [ "$USE_SSL" -eq 1 ]; then
        SMTP_URL="smtps://${URL_USER}:${URL_PASS}@${SMTP_HOST}:${SMTP_PORT}"
    else
        SMTP_URL="smtp://${URL_USER}:${URL_PASS}@${SMTP_HOST}:${SMTP_PORT}"
    fi
    {
        echo "set v15-compat=yes"
        echo "set mta=\"$(esc "$SMTP_URL")\""
        echo "set smtp-auth=login"
        echo "set from=\"$(esc "$FROM_ADDR")\""
        [ "$INSECURE" -eq 1 ] && echo "set ssl-verify=ignore"
        echo "set ssl-auth=no"
    } > "$MAILRC"
else
    {
        echo "set smtp=\"$(esc "${SMTP_HOST}:${SMTP_PORT}")\""
        [ "$USE_SSL" -eq 1 ] && echo "set smtp-use-ssl"
        echo "set smtp-auth=login"
        echo "set smtp-auth-user=\"$(esc "$USER")\""
        echo "set smtp-auth-password=\"$(esc "$PASS")\""
        echo "set from=\"$(esc "$FROM_ADDR")\""
        [ "$INSECURE" -eq 1 ] && echo "set ssl-verify=ignore"
    } > "$MAILRC"
fi
chmod 600 "$MAILRC"

SUBJ_ENCODED="$(encode_subject "$SUBJECT")"

# 组装命令
CMD_ARGS=()
for f in ${ATTACHES[@]+"${ATTACHES[@]}"}; do CMD_ARGS+=(-a "$f"); done
[ -n "$SUBJ_ENCODED" ] && CMD_ARGS+=(-s "$SUBJ_ENCODED")
[ "$VERBOSE" -eq 1 ] && CMD_ARGS+=(-v)
CMD_ARGS+=(${RECIPIENTS[@]+"${RECIPIENTS[@]}"})

RUNNER=()
if command -v timeout >/dev/null 2>&1 && [ "$TIMEOUT" -gt 0 ]; then
    RUNNER=(timeout "$TIMEOUT")
fi

# ---------------- 发送 / Dry-run 预览 ----------------
if [ "$DRY_RUN" -eq 1 ]; then
    log "--- 配置预览（密码已打码） ---"
    sed -E 's/(mta="[^:]+:\/\/[^:@]+:)[^@]*(@)/\1****\2/; s/(smtp-auth-password=).*/\1"****"/' "$MAILRC" | sed 's/^/    /'
    log "正文来源: ${BODY_SRC:-<stdin>}"
    log "收件人  : ${RECIPIENTS[*]}"
    log "主题    : $SUBJECT"
    log "附件    : ${ATTACHES[*]:-（无）}"
    log "--- 将执行的命令（stdin 为正文） ---"
    printf '    %s %s %s < %s\n' "${RUNNER[*]:-}" "$MAIL_BIN" "${CMD_ARGS[*]}" "${BODY_SRC:-<stdin>}"
    ok "dry-run 完成，未发送"
    exit 0
fi

# 正文写入临时文件（统一从文件重定向，避免 shell 拼接问题）
BODY_IN="$TMP_DIR/body.txt"
if [ -n "$BODY_SRC" ]; then
    cp "$BODY_SRC" "$BODY_IN"
else
    cat > "$BODY_IN"
fi

log "使用 $VARIANT 通过 ${SMTP_HOST}:${SMTP_PORT} 发送，收件人: ${RECIPIENTS[*]}"
if [ -n "${RUNNER[*]:-}" ]; then
    "${RUNNER[@]}" env MAILRC="$MAILRC" "$MAIL_BIN" "${CMD_ARGS[@]}" < "$BODY_IN"
else
    MAILRC="$MAILRC" "$MAIL_BIN" "${CMD_ARGS[@]}" < "$BODY_IN"
fi
RC=$?
[ $RC -ne 0 ] && { [ -n "${RUNNER[*]:-}" ] && [ $RC -eq 124 ] && die "发送超时（>${TIMEOUT}s）" || die "发送失败（mailx 退出码 $RC）"; }

ok "邮件已提交到 SMTP: ${USER} → ${RECIPIENTS[*]}"