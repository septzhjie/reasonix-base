# 阿里企业邮箱 SMTP 发送邮件（mailx + 外部 SMTP）

用 `scripts/send-ali-mail.sh` 通过阿里企业邮箱 SMTP 发送邮件，适用于 Debian/Ubuntu/RHEL/CentOS/Arch 等 Linux（macOS 仅支持 `--check` / `--dry-run`）。

## 1. 阿里企业邮箱 SMTP 参数

官方文档：https://help.aliyun.com/zh/document_detail/36576.html （IMAP/POP3/SMTP 协议服务器地址与端口设置）

| 项目 | 值 |
|---|---|
| SMTP 服务器 | `smtp.qiye.aliyun.com` |
| SSL 端口（推荐） | **465** |
| 非加密端口 | 25（80/587 暂未开通） |
| 旧版地址 | `smtp.mxhichina.com`（465/25） |
| 中国香港地区 | `smtphk.qiye.aliyun.com`（465/25） |

> 注意区分：SMTP 服务器地址是 `smtp.qiye.aliyun.com`（发信），`imap.qiye.aliyun.com` / `pop.qiye.aliyun.com` 是收信，不要搞混。

### 密码要求（重要）

- 阿里企业邮箱**默认禁止三方客户端**：需由邮箱管理员开启该账号的 POP3/IMAP 服务权限、允许三方客户端登录。
- 若账号（或组织强制）开启了"**三方客户端安全密码**"功能，SMTP 登录密码**不能填登录密码**，必须使用在邮箱设置里生成的"三方客户端安全密码"（独立生成的授权码）。
- 详见官方文档：如何允许/关闭使用三方客户端功能、员工如何开启和使用三方客户端安全密码（`https://help.aliyun.com/zh/document_detail/444269.html`）。

## 2. 安装 mailx（Linux）

本脚本需要支持外部 SMTP 的 mailx 变体：**s-nail**（推荐，Debian/Ubuntu/Arch）或 **Heirloom mailx**（RHEL/CentOS 的 mailx 包）。

```bash
# Debian / Ubuntu
apt install s-nail

# RHEL / CentOS
yum install mailx

# Arch
pacman -S s-nail
```

验证：

```bash
./scripts/send-ali-mail.sh --check
```

输出类似：

```
[send-mail] mailx 变体 : s-nail（/usr/bin/s-nail）
[send-mail] 外部 SMTP  : 支持（smtps:// 隐式 SSL）
```

## 3. 用法

### 3.1 命令行传账号密码

```bash
scripts/send-ali-mail.sh \
  -u user@yourdomain.com -p '三方客户端安全密码' \
  -s "磁盘空间告警" -b "根分区使用率超过 90%" \
  ops@yourdomain.com
```

### 3.2 环境变量（推荐，cron 友好）

```bash
export ALI_MAIL_USER=user@yourdomain.com
export ALI_MAIL_PASS='三方客户端安全密码'
printf '正文' | scripts/send-ali-mail.sh -s "告警" ops@yourdomain.com
```

### 3.3 配置文件（推荐，避免命令行/环境变量泄漏）

默认路径 `~/.config/ali-mail/smtp.conf`，可用 `-c` 覆盖：

```bash
# ~/.config/ali-mail/smtp.conf   （文件名可任意，内容是 shell 变量赋值）
ALI_MAIL_USER=user@yourdomain.com
ALI_MAIL_PASS='三方客户端安全密码'
# ALI_MAIL_SMTP=smtp.qiye.aliyun.com   # 默认即可，可不写
# ALI_MAIL_PORT=465                    # 默认 465，可不写；用 --no-ssl 时改 25
```

```bash
chmod 600 ~/.config/ali-mail/smtp.conf
scripts/send-ali-mail.sh -s "告警" ops@yourdomain.com < /tmp/body.txt
```

**优先级**：命令行 `-u/-p` > 环境变量 `ALI_MAIL_USER`/`ALI_MAIL_PASS` > 配置文件。

### 3.4 带附件 / 中文主题 / 正文文件

```bash
scripts/send-ali-mail.sh \
  -s "报表（中文主题自动编码）" \
  -f /tmp/report.txt \
  -a /tmp/report.xlsx -a /tmp/readme.pdf \
  leader@yourdomain.com
```

正文三选一：`-b "文本"` / `-f 文件` / 管道 stdin；附件可重复 `-a`。

### 3.5 非加密 25 端口

```bash
scripts/send-ali-mail.sh --no-ssl -P 25 -s "t" -b "b" -u a@x.com -p 'pw' b@x.com
```

> 阿里企业邮箱 25 端口出于安全考虑常被云厂商/ISP 屏蔽，企业邮箱一般也要求走 465 SSL，建议默认用 465。

## 4. cron 示例（定时发告警）

```cron
0 * * * * /root/scripts/send-ali-mail.sh -s "小时例行检查" -f /var/log/check.txt -u alert@yourdomain.com -p '安全密码' ops@yourdomain.com >> /var/log/ali-mail.log 2>&1
```

安全提示：

- 密码放进命令行会在 `ps` 里可见；**cron 场景优先用配置文件（chmod 600）或环境变量**。
- 若用 `-p` 传密码，注意进程列表可见性，仅在临时/交互场景使用。

## 5. 排查

| 现象 | 原因与处理 |
|---|---|
| `554 sender is rejected` / 认证失败 | 邮箱未开三方客户端权限；或填了登录密码而不是"三方客户端安全密码" |
| `Name or service not known` | SMTP 地址拼错，正确是 `smtp.qiye.aliyun.com` |
| SSL 连接失败 | 勾了 SSL 但端口仍用 25/110——SSL 必须配 465 |
| `SMTPS` unsupported | mailx 是 BSD/mailutils 版，按第 2 节装 s-nail / heirloom mailx |
| 发不出去、不确定配置 | 加 `--verbose` 看 SMTP 会话；或先 `--dry-run` 预览配置（密码只显示 `****`） |

## 6. 脚本行为说明

- 密码只写入临时目录（`mktemp`，权限 600）的一次性 `mailrc`，通过 `MAILRC` 环境变量传给 mailx，**不进命令行参数**，用完 `trap` 自动删除。
- 自动探测机器上的 s-nail / heirloom mailx，生成对应语法：
  - **s-nail**：`set v15-compat=yes` + `set mta="smtps://USER:PASS@HOST:465"`（现代写法，凭据 URL 编码内嵌，无过时警告）
  - **heirloom mailx**：`smtp` + `smtp-use-ssl` + `smtp-auth-*`
- 中文主题自动转为 RFC2047 Base64 编码（`=?UTF-8?B?...?=`）。
- 默认 60 秒 SMTP 超时（`--timeout N`，0 不限制；需要 GNU `timeout` 命令，coreutils）。

## 7. 已在 yoga13 实测验证（2026-08-19）

- 服务器：Ubuntu + `s-nail v14.9.23`（`apt install s-nail`），脚本部署在 `/usr/local/bin/send-ali-mail.sh`
- 真实发送成功：`cone-vps@septop.top` → `postmaster@septop.top`，TLSv1.3 握手 + 认证 + 投递全通过，脚本 exit 0
- 发送失败时 s-nail 会在当前目录留 `/root/dead.letter` 残骸（本次成功发送未产生）；失败排查时可删除

## 8. 防止凭据泄漏的用法建议

服务器上建议把账号密码写进 `~/.config/ali-mail/smtp.conf`（`chmod 600`），脚本自动读取，命令行/环境变量/进程列表均不出现密码：

```bash
install -d -m 700 ~/.config/ali-mail
cat > ~/.config/ali-mail/smtp.conf <<'EOF'
ALI_MAIL_USER=cone-vps@septop.top
ALI_MAIL_PASS='你的安全密码'
EOF
chmod 600 ~/.config/ali-mail/smtp.conf
send-ali-mail.sh -s "告警" -b "正文" postmaster@septop.top
```