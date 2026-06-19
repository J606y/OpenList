#!/bin/bash
# ============================================================================
#  Nginx 反向代理一键脚本（增强版）
#  基于「一点科技 Nginx 反代脚本」的功能，额外增加：
#    - acme.sh 自动申请证书（HTTP-01 webroot / DNS API 泛域名）
#    - acme.sh 自动续签（内置 cron，签发即托管，附续签管理菜单）
#    - 针对不同站点的 Nginx 缓存开关（无缓存 / 普通缓存 / 视频分片缓存）
#
#  目标环境：Debian / Ubuntu + 系统 nginx（apt / systemd），nginx >= 1.25
#  适用场景：边缘 nginx 反代到源站（如 OpenList origin:5244 视频流）
#
#  用法：  sudo bash nginx-rp.sh
# ============================================================================

set -o pipefail

# ----------------------------- 全局变量 -------------------------------------
SITES_AVAIL="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
GLOBAL_CONF="/etc/nginx/conf.d/00-1keji-rp.conf"
CERT_DIR="/etc/nginx/certs"
ACME_WEBROOT="/var/www/acme"
CACHE_DIR="/var/cache/nginx/1keji_rp"
ACME_HOME="$HOME/.acme.sh"
ACME="$ACME_HOME/acme.sh"
REQUIRED_PORTS=(80 443)

# 快捷命令：安装到固定路径后，输入 SHORTCUT_CMD 即可打开本菜单
INSTALL_PATH="/usr/local/bin/nginx-rp.sh"
SHORTCUT_CMD="n"
SHORTCUT_PATH="/usr/local/bin/$SHORTCUT_CMD"

# ----------------------------- 颜色输出 -------------------------------------
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[36m%s\033[0m\n' "$*"; }
info()  { c_blue  "[*] $*"; }
ok()    { c_green "[✓] $*"; }
warn()  { c_yellow "[!] $*"; }
err()   { c_red   "[✗] $*"; }

pause() { read -rp "按回车键继续..." _; }

# ----------------------------- 前置检查 -------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请用 root 运行： sudo bash $0"
        exit 1
    fi
}

require_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        err "本脚本面向 Debian / Ubuntu（apt）。当前系统不支持，请手动适配。"
        exit 1
    fi
}

# 通过 curl|bash 运行时 stdin 是管道而非键盘：read -rp 不显示提示、且会卡住/读到 EOF
# （表现为“输入后直接卡死”）。把交互输入接回控制终端即可。
ensure_tty() { [ -t 0 ] || { [ -r /dev/tty ] && exec </dev/tty; }; return 0; }

# 安装快捷命令：把脚本拷到 /usr/local/bin，并创建命令 n。
# 每次启动调用：已安装则静默（顺便更新脚本本体），首次安装则提示。
setup_shortcut() {
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"

    # 把（可能在仓库目录里运行的）脚本安装/更新到固定路径
    if [ -n "$self" ] && [ -f "$self" ] && [ "$self" != "$INSTALL_PATH" ]; then
        cp -f "$self" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH"
    fi

    # 已存在快捷命令
    if [ -e "$SHORTCUT_PATH" ]; then
        grep -q "nginx-rp" "$SHORTCUT_PATH" 2>/dev/null || \
            warn "命令「$SHORTCUT_CMD」已被占用（非本脚本），跳过创建。可改用其它名字（编辑脚本顶部 SHORTCUT_CMD）。"
        return 0
    fi

    # 首次创建快捷命令
    cat > "$SHORTCUT_PATH" <<EOF
#!/bin/bash
# nginx-rp 快捷启动器
exec bash "$INSTALL_PATH" "\$@"
EOF
    chmod +x "$SHORTCUT_PATH"
    clear
    ok "快捷命令安装成功！以后在任意目录输入  $SHORTCUT_CMD  即可打开本菜单。"
    echo "  脚本已安装到：$INSTALL_PATH"
    pause
}

reload_nginx() {
    if nginx -t 2>/tmp/nginx_test.log; then
        systemctl reload nginx 2>/dev/null || nginx -s reload
        ok "Nginx 配置已重载"
        return 0
    else
        err "Nginx 配置测试失败，未重载。错误如下："
        cat /tmp/nginx_test.log
        return 1
    fi
}

# ----------------------------- 防火墙 ---------------------------------------
open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in "${REQUIRED_PORTS[@]}"; do ufw allow "$p"/tcp >/dev/null 2>&1; done
        ok "ufw 已放行 ${REQUIRED_PORTS[*]}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        for p in "${REQUIRED_PORTS[@]}"; do firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1; done
        firewall-cmd --reload >/dev/null 2>&1
        ok "firewalld 已放行 ${REQUIRED_PORTS[*]}"
    elif command -v iptables >/dev/null 2>&1; then
        for p in "${REQUIRED_PORTS[@]}"; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        done
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
        ok "iptables 已放行 ${REQUIRED_PORTS[*]}（如需持久化请确认 netfilter-persistent）"
    else
        warn "未检测到受支持的防火墙，跳过。请自行确认 80/443 已放行。"
    fi
}

# ------------------- 后端端口直连封锁（仅经域名/Nginx 访问） -----------------
# 反代建好后，常希望禁止公网再用 http://IP:端口 直连后端（如 OpenList 5244）。
# 做法：iptables 丢弃「非回环」入站到该端口的流量，保留 lo 让 Nginx(127.0.0.1) 仍可访问。
# 注意：Docker 发布的端口（compose 里 5244:5244）走 DOCKER-USER 链，绕过 INPUT/ufw，
#       所以必须同时在 DOCKER-USER 链下规则，否则封不住。

# 需要操作的链：DOCKER-USER（存在则优先，管 Docker 发布端口）+ INPUT（管本机服务）
_iptables_block_chains() {
    iptables -nL DOCKER-USER >/dev/null 2>&1 && echo DOCKER-USER
    echo INPUT
}

# 任一链已存在 DROP 规则即视为已封锁
backend_port_blocked() {
    local port="$1" ch
    for ch in $(_iptables_block_chains); do
        iptables -C "$ch" -p tcp --dport "$port" ! -i lo -j DROP 2>/dev/null && return 0
    done
    return 1
}

restrict_port() {
    local port="$1" ch
    command -v iptables >/dev/null 2>&1 || {
        warn "未找到 iptables，跳过。请用云安全组/防火墙封锁端口 $port 的公网入站。"; return 0; }
    for ch in $(_iptables_block_chains); do
        iptables -C "$ch" -p tcp --dport "$port" ! -i lo -j DROP 2>/dev/null || \
            iptables -I "$ch" 1 -p tcp --dport "$port" ! -i lo -j DROP
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    ok "已封锁公网直连 :$port（保留本机回环，Nginx 反代不受影响）"
    warn "云厂商安全组/安全列表（Oracle / 阿里云等）需另在控制台收紧，本脚本只改本机 iptables。"
}

unrestrict_port() {
    local port="$1" ch
    command -v iptables >/dev/null 2>&1 || return 0
    for ch in $(_iptables_block_chains); do
        while iptables -C "$ch" -p tcp --dport "$port" ! -i lo -j DROP 2>/dev/null; do
            iptables -D "$ch" -p tcp --dport "$port" ! -i lo -j DROP
        done
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    ok "已解除端口 $port 的公网直连封锁"
}

# 从反代目标解析端口并校验是否本机，再封锁
restrict_backend_port() {
    local target="$1" hp host port
    hp="${target#*://}"; hp="${hp%%/*}"     # 去掉 scheme 和路径 -> host[:port]
    host="${hp%%:*}"; port="${hp##*:}"
    [ "$host" = "$port" ] && port=""        # 没写端口
    case "$target" in https://*) port="${port:-443}" ;; *) port="${port:-80}" ;; esac
    case "$host" in
        127.0.0.1|localhost|::1|0.0.0.0) ;;
        *) warn "反代目标 $host 不在本机，无法在此封锁端口 $port。"
           warn "请到后端所在主机上操作，或把后端端口仅绑定 127.0.0.1。"; return 0 ;;
    esac
    restrict_port "$port"
}

# ----------------------------- 全局配置 -------------------------------------
# 写入 http 上下文的公共配置：缓存区、websocket upgrade map、媒体类型跳过缓存 map
ensure_global_conf() {
    mkdir -p "$ACME_WEBROOT" "$CACHE_DIR" "$CERT_DIR"
    id www-data >/dev/null 2>&1 && chown -R www-data:www-data "$CACHE_DIR" 2>/dev/null
    cat > "$GLOBAL_CONF" <<'EOF'
# 由 nginx-rp.sh 管理，请勿手动编辑。
# 反代缓存区（普通缓存 / 视频分片缓存共用）
proxy_cache_path /var/cache/nginx/1keji_rp levels=1:2 keys_zone=rpcache:100m max_size=10g inactive=7d use_temp_path=off;

# WebSocket: 根据 Upgrade 头决定 Connection
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# 普通缓存模式下：命中这些响应类型时不写入缓存（视频/音频/大文件流/m3u8/dash）
map $upstream_http_content_type $rp_skip_media {
    default                    0;
    ~*^video/                  1;
    ~*^audio/                  1;
    application/octet-stream   1;
    ~*mpegurl                  1;
    ~*dash\+xml                1;
}
EOF
    ok "公共配置已写入 $GLOBAL_CONF"
}

# ----------------------------- 安装 Nginx -----------------------------------
install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        warn "Nginx 已安装：$(nginx -v 2>&1)"
    else
        info "更新软件源并安装 Nginx..."
        apt-get update -y && apt-get install -y nginx
        ok "Nginx 安装完成"
    fi

    mkdir -p "$SITES_AVAIL" "$SITES_ENABLED"
    # 确保 nginx.conf 引入 sites-enabled（部分精简安装没有）
    if ! grep -qE "include\s+/etc/nginx/sites-enabled/\*" /etc/nginx/nginx.conf; then
        sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        warn "已向 nginx.conf 补充 sites-enabled 引入"
    fi

    ensure_global_conf
    open_firewall
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
    reload_nginx
    ok "Nginx 就绪"
    pause
}

# ----------------------------- 确保 acme.sh ---------------------------------
# 证书功能首次使用时自动安装 acme.sh（含自动续签 cron）。返回 0 成功 / 1 失败。
ensure_acme() {
    if [ -f "$ACME" ]; then
        "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1
        return 0
    fi
    info "首次使用证书功能，自动安装 acme.sh..."
    apt-get install -y curl socat >/dev/null 2>&1
    local email
    read -rp "请输入用于注册 Let's Encrypt 的邮箱（接收到期提醒）: " email
    [ -z "$email" ] && { err "邮箱不能为空"; return 1; }
    curl -fsSL https://get.acme.sh | sh -s email="$email"
    if [ ! -f "$ACME" ]; then
        err "acme.sh 安装失败，请检查网络。"
        return 1
    fi
    # 默认 CA 用 Let's Encrypt（避免 ZeroSSL 需要 EAB 注册）；安装即自带续签 cron
    "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1
    "$ACME" --upgrade --auto-upgrade >/dev/null 2>&1
    ok "acme.sh 就绪；自动续签 cron 已自动安装"
    return 0
}

# ----------------------------- 证书签发 -------------------------------------
# 通过 webroot(HTTP-01) 签发；要求该域名已 A 记录指向本机且 80 端口可达，
# 且本机已存在监听该域名 80 端口、serving /var/www/acme 的 server（add_site 会先建）。
issue_cert_http() {
    local domain="$1"
    ensure_acme || return 1
    info "通过 HTTP-01(webroot) 为 $domain 申请证书..."
    "$ACME" --issue -d "$domain" --webroot "$ACME_WEBROOT" --keylength ec-256 --server letsencrypt
}

# 通过 DNS API 签发（支持泛域名 *.domain）
issue_cert_dns() {
    local domain="$1" provider="$2"
    ensure_acme || return 1
    local dnsapi=""
    case "$provider" in
        cloudflare)
            read -rp "Cloudflare API Token (CF_Token): " CF_Token
            export CF_Token; dnsapi="dns_cf" ;;
        aliyun)
            read -rp "阿里云 Ali_Key: "    Ali_Key
            read -rp "阿里云 Ali_Secret: " Ali_Secret
            export Ali_Key Ali_Secret; dnsapi="dns_ali" ;;
        tencent)
            read -rp "DNSPod DP_Id: "  DP_Id
            read -rp "DNSPod DP_Key: " DP_Key
            export DP_Id DP_Key; dnsapi="dns_dp" ;;
        *) err "未知 DNS 服务商"; return 1 ;;
    esac
    info "通过 DNS API($dnsapi) 为 $domain 及 *.$domain 申请证书..."
    "$ACME" --issue --dns "$dnsapi" -d "$domain" -d "*.$domain" --keylength ec-256 --server letsencrypt
}

# 把已签发证书安装到 nginx 目录，并登记 reloadcmd（续签后自动 reload）
install_cert_to_nginx() {
    local domain="$1"
    mkdir -p "$CERT_DIR/$domain"
    "$ACME" --install-cert -d "$domain" --ecc \
        --key-file       "$CERT_DIR/$domain/key.pem" \
        --fullchain-file "$CERT_DIR/$domain/fullchain.pem" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || nginx -s reload"
}

# ----------------------------- 渲染站点配置 ---------------------------------
# 参数: domain target maxbody(MB) cache(none|normal|slice) ssl(none|le|dns|file) crt key
render_site_file() {
    local domain="$1" target="$2" maxbody="$3" cache="$4" ssl="$5" crt="$6" key="$7"
    local file="$SITES_AVAIL/$domain.conf"

    # 缓存指令块（$'' 内 nginx 变量保持字面量，\n 为真实换行）
    local cache_block
    case "$cache" in
        none)
            cache_block=$'        # 无缓存：关闭缓冲，适合纯流媒体/上传\n        proxy_buffering off;\n        proxy_request_buffering off;' ;;
        normal)
            cache_block=$'        # 普通缓存：缓存网页/静态；Range 请求或视频/音频/大文件自动绕过\n        proxy_cache rpcache;\n        proxy_cache_key $scheme$host$request_uri;\n        proxy_cache_valid 200 301 302 10m;\n        proxy_cache_valid 404 1m;\n        proxy_cache_bypass $http_range $arg_nocache;\n        proxy_no_cache $http_range $rp_skip_media;\n        add_header X-Cache-Status $upstream_cache_status always;' ;;
        slice)
            cache_block=$'        # 视频分片缓存：按 1MB 切片缓存 Range 响应（206）\n        slice 1m;\n        proxy_cache rpcache;\n        proxy_cache_key $scheme$host$uri$is_args$args$slice_range;\n        proxy_set_header Range $slice_range;\n        proxy_cache_valid 200 206 1d;\n        proxy_cache_valid 404 1m;\n        add_header X-Cache-Status $upstream_cache_status always;' ;;
    esac

    # 元信息（manage 解析用）
    {
        echo "# ===== 1keji-rp BEGIN ====="
        echo "# domain=$domain"
        echo "# target=$target"
        echo "# maxbody=$maxbody"
        echo "# cache=$cache"
        echo "# ssl=$ssl"
        echo "# crt=$crt"
        echo "# key=$key"
        echo "# ===== 1keji-rp END ====="
    } > "$file"

    if [ "$ssl" = "none" ]; then
        cat >> "$file" <<EOF

server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
    }

    location / {
        proxy_pass $target;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        client_max_body_size ${maxbody}m;
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
$cache_block
    }
}
EOF
    else
        cat >> "$file" <<EOF

server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
    }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $domain;

    ssl_certificate     $crt;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
    }

    location / {
        proxy_pass $target;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        client_max_body_size ${maxbody}m;
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
$cache_block
    }
}
EOF
    fi

    ln -sf "$file" "$SITES_ENABLED/$domain.conf"
}

# ----------------------------- 元信息读取 -----------------------------------
get_meta() {  # get_meta <key> <file>
    grep -m1 "^# $1=" "$2" 2>/dev/null | cut -d= -f2-
}

# ----------------------------- 缓存模式选择 ---------------------------------
choose_cache_mode() {
    # 结果写入全局变量 CACHE_MODE
    echo "  请选择该站点的缓存模式：" >&2
    echo "    1) 无缓存      —— 关闭缓冲，纯流媒体/直连源站（如 OpenList 视频，推荐）" >&2
    echo "    2) 普通缓存    —— 缓存网页/静态，Range 与视频自动绕过" >&2
    echo "    3) 视频分片缓存 —— slice 切片缓存 Range 响应（源站直链带签名时命中率低，慎用）" >&2
    local c; read -rp "  输入 [1-3]（默认1）: " c
    case "$c" in
        2) CACHE_MODE="normal" ;;
        3) CACHE_MODE="slice" ;;
        *) CACHE_MODE="none" ;;
    esac
}

# ----------------------------- 新增反代站点 ---------------------------------
configure_reverse_proxy() {
    command -v nginx >/dev/null 2>&1 || { err "请先安装 Nginx（菜单 1）"; pause; return; }
    ensure_global_conf

    local domain target maxbody created=0
    read -rp "请输入域名（如 v.example.com）: " domain
    [ -z "$domain" ] && { err "域名不能为空"; pause; return; }
    read -rp "请输入反代目标（如 http://127.0.0.1:5244）: " target
    [ -z "$target" ] && { err "目标不能为空"; pause; return; }
    read -rp "客户端最大请求体大小 MB（上传用，默认 1024）: " maxbody
    [ -z "$maxbody" ] && maxbody=1024

    choose_cache_mode

    echo "  请选择 HTTPS 证书方式："
    echo "    1) acme.sh 自动申请（HTTP-01，需 80 端口可达，推荐）"
    echo "    2) acme.sh 自动申请（DNS API，支持泛域名）"
    echo "    3) 使用已有证书文件（输入路径）"
    echo "    4) 不启用 HTTPS（仅 80）"
    local s; read -rp "  输入 [1-4]（默认1）: " s

    case "$s" in
        4)
            render_site_file "$domain" "$target" "$maxbody" "$CACHE_MODE" "none" "" ""
            reload_nginx && { ok "已创建（仅 HTTP）：http://$domain"; created=1; }
            ;;
        3)
            local crt key
            read -rp "  证书 fullchain 路径: " crt
            read -rp "  私钥 key 路径: " key
            if [ ! -f "$crt" ] || [ ! -f "$key" ]; then err "证书文件不存在"; pause; return; fi
            render_site_file "$domain" "$target" "$maxbody" "$CACHE_MODE" "file" "$crt" "$key"
            reload_nginx && { ok "已创建（HTTPS，自带证书）：https://$domain"; created=1; }
            ;;
        2)
            echo "    DNS 服务商： 1) Cloudflare  2) 阿里云  3) 腾讯云(DNSPod)"
            local dp; read -rp "    选择 [1-3]: " dp
            local prov; case "$dp" in 1) prov=cloudflare;; 2) prov=aliyun;; 3) prov=tencent;; *) err "无效"; pause; return;; esac
            if issue_cert_dns "$domain" "$prov" && install_cert_to_nginx "$domain"; then
                render_site_file "$domain" "$target" "$maxbody" "$CACHE_MODE" "dns" \
                    "$CERT_DIR/$domain/fullchain.pem" "$CERT_DIR/$domain/key.pem"
                reload_nginx && { ok "已创建（HTTPS + 泛域名证书）：https://$domain"; created=1; }
            else
                err "证书申请失败，未创建 HTTPS 站点。"
            fi
            ;;
        *)
            # 先建 HTTP 站点以承载 acme challenge，再签发，最后换成 HTTPS
            render_site_file "$domain" "$target" "$maxbody" "$CACHE_MODE" "none" "" ""
            reload_nginx || { err "初始 HTTP 配置失败"; pause; return; }
            created=1
            if issue_cert_http "$domain" && install_cert_to_nginx "$domain"; then
                render_site_file "$domain" "$target" "$maxbody" "$CACHE_MODE" "le" \
                    "$CERT_DIR/$domain/fullchain.pem" "$CERT_DIR/$domain/key.pem"
                reload_nginx && ok "已创建（HTTPS + 自动证书）：https://$domain"
            else
                err "证书申请失败，已保留仅 HTTP 站点。请检查域名解析 / 80 端口可达性。"
            fi
            ;;
    esac

    # 反代建好后，询问是否封锁公网经 IP:端口 直连后端（仅当目标在本机时有意义）
    if [ "$created" = 1 ]; then
        local _hp _host
        _hp="${target#*://}"; _hp="${_hp%%/*}"; _host="${_hp%%:*}"
        case "$_host" in
            127.0.0.1|localhost|::1|0.0.0.0)
                echo
                local _yn
                read -rp "是否关闭通过 IP:端口 直连后端，仅允许经域名/Nginx 访问？(y/N): " _yn
                case "$_yn" in y|Y) restrict_backend_port "$target" ;; esac
                ;;
        esac
    fi
    pause
}

# ----------------------------- 列出/管理站点 -------------------------------
list_sites() {
    local found=0 i=1
    SITE_FILES=()
    for f in "$SITES_AVAIL"/*.conf; do
        [ -e "$f" ] || continue
        grep -q "1keji-rp BEGIN" "$f" || continue
        local d t c s
        d=$(get_meta domain "$f"); t=$(get_meta target "$f")
        c=$(get_meta cache "$f");  s=$(get_meta ssl "$f")
        printf "  %d) %-28s -> %-28s [缓存:%s 证书:%s]\n" "$i" "$d" "$t" "$c" "$s"
        SITE_FILES+=("$f"); i=$((i+1)); found=1
    done
    [ "$found" -eq 0 ] && { warn "没有由本脚本管理的反代站点"; return 1; }
    return 0
}

manage_reverse_proxy() {
    echo "已配置的反代站点："
    list_sites || { pause; return; }
    local idx; read -rp "选择要管理的站点序号（回车返回）: " idx
    [ -z "$idx" ] && return
    local f="${SITE_FILES[$((idx-1))]}"
    [ -z "$f" ] || [ ! -f "$f" ] && { err "无效序号"; pause; return; }

    local domain target maxbody cache ssl crt key
    domain=$(get_meta domain "$f"); target=$(get_meta target "$f")
    maxbody=$(get_meta maxbody "$f"); cache=$(get_meta cache "$f")
    ssl=$(get_meta ssl "$f"); crt=$(get_meta crt "$f"); key=$(get_meta key "$f")

    echo "  当前： $domain -> $target  [缓存:$cache 证书:$ssl 上限:${maxbody}m]"
    echo "    1) 修改反代目标"
    echo "    2) 修改缓存模式"
    echo "    3) 申请/更换 HTTPS 证书"
    echo "    4) 删除该站点"
    echo "    0) 返回"
    local op; read -rp "  选择: " op
    case "$op" in
        1)
            read -rp "  新目标: " target
            [ -z "$target" ] && { err "不能为空"; pause; return; }
            render_site_file "$domain" "$target" "$maxbody" "$cache" "$ssl" "$crt" "$key"
            reload_nginx && ok "目标已更新"
            ;;
        2)
            choose_cache_mode
            render_site_file "$domain" "$target" "$maxbody" "$CACHE_MODE" "$ssl" "$crt" "$key"
            reload_nginx && ok "缓存模式已改为 $CACHE_MODE"
            ;;
        3)
            ensure_global_conf
            if issue_cert_http "$domain" && install_cert_to_nginx "$domain"; then
                render_site_file "$domain" "$target" "$maxbody" "$cache" "le" \
                    "$CERT_DIR/$domain/fullchain.pem" "$CERT_DIR/$domain/key.pem"
                reload_nginx && ok "证书已申请并启用 HTTPS"
            else
                err "证书申请失败"
            fi
            ;;
        4)
            read -rp "  确认删除 $domain ？(y/N): " yn
            if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
                rm -f "$f" "$SITES_ENABLED/$domain.conf"
                reload_nginx && ok "已删除（证书保留在 $CERT_DIR/$domain）"
            fi
            ;;
        *) return ;;
    esac
    pause
}

# ----------------------------- 证书 / 续签管理 -----------------------------
cert_menu() {
    ensure_acme || { pause; return; }
    echo "证书 / 自动续签管理："
    echo "    1) 查看已签发证书列表"
    echo "    2) 立即续签全部（强制）"
    echo "    3) 续签指定域名"
    echo "    4) 查看自动续签计划（cron）"
    echo "    0) 返回"
    local op; read -rp "  选择: " op
    case "$op" in
        1) "$ACME" --list ;;
        2) "$ACME" --cron --force; ok "已触发强制续签" ;;
        3) local d; read -rp "  域名: " d; "$ACME" --renew -d "$d" --ecc --force ;;
        4)
            if crontab -l 2>/dev/null | grep -q acme.sh; then
                ok "自动续签已启用："; crontab -l 2>/dev/null | grep acme.sh
            else
                warn "未发现 acme.sh 续签 cron。请重新申请一次证书以触发安装/修复。"
            fi
            ;;
        *) return ;;
    esac
    pause
}

# ----------------------------- 卸载 -----------------------------------------
uninstall_nginx() {
    read -rp "确认卸载 Nginx 并清理本脚本配置？(y/N): " yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || return
    systemctl stop nginx 2>/dev/null
    systemctl disable nginx 2>/dev/null
    apt-get purge -y nginx nginx-common nginx-core >/dev/null 2>&1
    rm -f "$GLOBAL_CONF"
    rm -rf "$CACHE_DIR"
    warn "Nginx 已卸载。证书目录 $CERT_DIR 与 acme.sh($ACME_HOME) 保留，如需彻底清理请手动删除。"
    pause
}

# ------------------- 后端端口直连封锁开关 -----------------------------------
port_block_menu() {
    echo "后端端口直连封锁：禁止公网用 IP:端口 直连后端（保留本机回环给 Nginx）"
    local port; read -rp "  输入后端端口（如 5244，回车返回）: " port
    [ -z "$port" ] && return
    case "$port" in *[!0-9]*) err "端口需为数字"; pause; return ;; esac
    if backend_port_blocked "$port"; then
        warn "端口 $port 当前【已封锁】公网直连"
        local yn; read -rp "  解除封锁？(y/N): " yn
        case "$yn" in y|Y) unrestrict_port "$port" ;; esac
    else
        info "端口 $port 当前【未封锁】"
        local yn; read -rp "  现在封锁？(y/N): " yn
        case "$yn" in y|Y) restrict_port "$port" ;; esac
    fi
    pause
}

# ----------------------------- 管理子菜单 -----------------------------------
manage_menu() {
    while true; do
        clear
        c_green "------------- 管理反向代理 -------------"
        echo "  1. 管理已配置站点（改目标 / 改缓存 / 换证书 / 删除）"
        echo "  2. 证书 / 自动续签管理"
        echo "  3. 后端端口直连封锁（开 / 关）"
        echo "  0. 返回上级"
        echo "----------------------------------------"
        local op; read -rp "请选择 [0-3]: " op
        case "$op" in
            1) manage_reverse_proxy ;;
            2) cert_menu ;;
            3) port_block_menu ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ----------------------------- 主菜单 ---------------------------------------
main_menu() {
    while true; do
        clear
        c_green "=================================="
        c_green "        Nginx 反向代理脚本"
        c_green "  acme 自动证书 · 自动续签 · 缓存"
        c_green "=================================="
        echo "  1. 安装 Nginx"
        echo "  2. 配置反向代理"
        echo "  3. 管理反向代理"
        echo "  4. 卸载 Nginx"
        echo "  0. 退出"
        echo "----------------------------------"
        echo "  提示：下次直接输入  $SHORTCUT_CMD  即可打开本菜单"
        local opt; read -rp "请选择一个选项 [0-4]: " opt
        case "$opt" in
            1) install_nginx ;;
            2) configure_reverse_proxy ;;
            3) manage_menu ;;
            4) uninstall_nginx ;;
            0) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

require_root
require_apt
ensure_tty
setup_shortcut
main_menu
