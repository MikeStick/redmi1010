#!/bin/bash
# ============================================================
# VLESS + WebSocket + TLS + Cloudflare CDN 一键部署脚本
# 专为 Debian 系统优化
# ============================================================

set -e

# 预设标准化配置（直接回车使用以下默认值）
PRESET_UUID="0ad7d003-8e79-4529-8b55-09610947c09b"
PRESET_WS_PATH="/stickrouter"
PRESET_SING_PORT="10000"
PRESET_NGINX_PORT="2053"
PRESET_EMAIL="a79376464@gmail.com"
BASE_DOMAIN="stickrouter.com"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

ask() {
    echo -e "${BLUE}[?]${NC} $1"
    read INPUT_VAR
    eval "$2=\$INPUT_VAR"
}

ask_enter() {
    echo -e "${BLUE}[?]${NC} $1"
    read DUMMY
}

# ============================================================
# 检查 root 权限
# ============================================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行此脚本"
    fi
}

# ============================================================
# 检查 Debian 系统
# ============================================================
check_debian() {
    if [ ! -f /etc/debian_version ]; then
        error "此脚本仅支持 Debian 系统"
    fi
    DEBIAN_VER=$(cat /etc/debian_version | cut -d. -f1)
    info "检测到 Debian 版本：$(cat /etc/debian_version)"
    if [ "$DEBIAN_VER" -lt 10 ] 2>/dev/null; then
        warning "建议使用 Debian 10 或更高版本，当前版本可能存在兼容性问题"
    fi
}

# ============================================================
# 欢迎信息
# ============================================================
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "======================================================"
    echo "   VLESS + WebSocket + TLS + Cloudflare CDN"
    echo "          一键部署脚本 (Debian 专版)"
    echo "======================================================"
    echo -e "${NC}"
    echo ""
    warning "部署前请确认："
    echo "  1. 子域名已在 Cloudflare 添加 A 记录指向本机 IP"
    echo "  2. Cloudflare 代理已关闭（灰色云朵）用于申请证书"
    echo "  3. Cloudflare SSL/TLS 模式已设为 完全(Full) 或 完全严格"
    echo ""
    ask_enter "确认以上条件已满足？按 Enter 继续，Ctrl+C 退出..."
}

# ============================================================
# 收集用户输入
# ============================================================
collect_info() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "开始收集配置信息..."
    echo ""

    # 子域名输入（只需输入前缀）
    while true; do
        ask "请输入子域名前缀（例如输入 hk01，域名将为 hk01.${BASE_DOMAIN}）：" SUBDOMAIN
        if echo "$SUBDOMAIN" | grep -qE '^[a-zA-Z0-9-]+$'; then
            DOMAIN="${SUBDOMAIN}.${BASE_DOMAIN}"
            info "完整域名：$DOMAIN"
            break
        else
            warning "子域名只能包含字母、数字和连字符，请重新输入"
        fi
    done

    # 邮箱（回车使用默认值）
    echo ""
    ask "请输入邮箱地址（直接回车使用预设值：${PRESET_EMAIL}）：" INPUT_EMAIL
    EMAIL=${INPUT_EMAIL:-$PRESET_EMAIL}
    info "使用邮箱：$EMAIL"

    # UUID
    echo ""
    ask "请输入 UUID（直接回车使用预设值：${PRESET_UUID}）：" INPUT_UUID
    UUID=${INPUT_UUID:-$PRESET_UUID}

    # WS 路径
    ask "请输入 WebSocket 路径（直接回车使用预设值：${PRESET_WS_PATH}）：" INPUT_WS_PATH
    if [ -z "$INPUT_WS_PATH" ]; then
        WS_PATH="$PRESET_WS_PATH"
    else
        WS_PATH="$INPUT_WS_PATH"
        case "$WS_PATH" in
            /*) ;;
            *) WS_PATH="/$WS_PATH" ;;
        esac
    fi

    # sing-box 内部端口
    ask "请输入 sing-box 本地监听端口（直接回车使用预设值：${PRESET_SING_PORT}）：" INPUT_PORT
    SING_PORT=${INPUT_PORT:-$PRESET_SING_PORT}

    # 对外端口
    ask "请输入对外监听端口（直接回车使用预设值：${PRESET_NGINX_PORT}）：" INPUT_NGINX_PORT
    NGINX_PORT=${INPUT_NGINX_PORT:-$PRESET_NGINX_PORT}

    # 确认信息
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "配置信息确认："
    echo ""
    echo "  完整域名：      $DOMAIN"
    echo "  邮箱：          $EMAIL"
    echo "  UUID：          $UUID"
    echo "  WS 路径：       $WS_PATH"
    echo "  sing-box 端口： $SING_PORT (本地内部)"
    echo "  对外端口：      $NGINX_PORT (客户端连接)"
    echo ""
    ask "确认以上信息正确？直接回车继续，输入 n 重新填写：" CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        collect_info
    fi
}

# ============================================================
# 修复 APT 源（兼容 Debian 11/12）
# ============================================================
fix_apt_sources() {
    echo ""
    info "检查并修复 APT 源..."

    DEBIAN_VER=$(cat /etc/debian_version | cut -d. -f1)

    if [ "$DEBIAN_VER" = "11" ]; then
        warning "检测到 Debian 11，修复 backports 源..."
        # 修复 sources.list 里的 backports
        sed -i 's|deb.debian.org/debian bullseye-backports|archive.debian.org/debian bullseye-backports|g' \
            /etc/apt/sources.list 2>/dev/null || true
        # 注释掉 sources.list.d 里失效的 backports
        if ls /etc/apt/sources.list.d/*.list >/dev/null 2>&1; then
            sed -i '/bullseye-backports/s/^/#/' /etc/apt/sources.list.d/*.list 2>/dev/null || true
        fi
        success "Debian 11 源修复完成"
    elif [ "$DEBIAN_VER" = "12" ]; then
        success "Debian 12 源正常，无需修复"
    else
        info "Debian 版本：$DEBIAN_VER，跳过源修复"
    fi
}

# ============================================================
# 安装依赖（Debian 专用）
# ============================================================
install_deps() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "更新系统并安装依赖..."

    rm -f /var/lib/dpkg/lock-frontend
    rm -f /var/lib/apt/lists/lock

    apt-get update -qq
    apt-get install -y \
        nginx \
        certbot \
        python3-certbot-nginx \
        curl \
        wget \
        openssl \
        cron \
        -qq

    systemctl enable cron
    systemctl start cron

    success "依赖安装完成"
}

# ============================================================
# 安装 sing-box
# ============================================================
install_singbox() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VER=$(sing-box version | head -1)
        warning "sing-box 已安装：$CURRENT_VER"
        ask "是否重新安装最新版？(y/N)：" REINSTALL
        if [ "$REINSTALL" != "y" ] && [ "$REINSTALL" != "Y" ]; then
            success "跳过安装，使用现有版本"
            return
        fi
    fi

    bash <(curl -fsSL https://sing-box.app/deb-install.sh)

    if command -v sing-box >/dev/null 2>&1; then
        success "sing-box 安装成功：$(sing-box version | head -1)"
    else
        error "sing-box 安装失败，请检查网络连接"
    fi
}

# ============================================================
# 配置 sing-box
# ============================================================
configure_singbox() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "配置 sing-box..."

    mkdir -p /etc/sing-box

    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": ${SING_PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

    if sing-box check -c /etc/sing-box/config.json; then
        success "sing-box 配置验证通过"
    else
        error "sing-box 配置有误，请检查"
    fi

    systemctl enable sing-box
    systemctl restart sing-box
    sleep 2

    if systemctl is-active --quiet sing-box; then
        success "sing-box 启动成功，监听 127.0.0.1:${SING_PORT}"
    else
        error "sing-box 启动失败：$(systemctl status sing-box | tail -3)"
    fi
}

# ============================================================
# 申请 SSL 证书
# ============================================================
request_cert() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "申请 SSL 证书..."

    SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null)
    DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)

    info "本机 IP：${SERVER_IP:-获取失败}"
    info "域名解析 IP：${DOMAIN_IP:-解析失败}"

    if [ -z "$SERVER_IP" ] || [ -z "$DOMAIN_IP" ]; then
        warning "IP 获取失败，请检查网络连接"
    elif [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
        warning "IP 不一致！请确认："
        warning "  1. Cloudflare 中 $DOMAIN 的 A 记录已指向 ${SERVER_IP}"
        warning "  2. Cloudflare 已切换为灰色云朵（仅DNS）"
        ask "是否仍然继续申请？(y/N)：" FORCE
        if [ "$FORCE" != "y" ] && [ "$FORCE" != "Y" ]; then
            error "请修复域名解析后重新运行脚本"
        fi
    else
        success "域名解析验证通过：$DOMAIN → $SERVER_IP"
    fi

    systemctl stop nginx 2>/dev/null || true
    sleep 1

    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" \
        -d "$DOMAIN"

    CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
    if [ -f "$CERT_PATH/fullchain.pem" ]; then
        CERT_EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH/fullchain.pem" | cut -d= -f2)
        success "SSL 证书申请成功！有效期至：$CERT_EXPIRY"
    else
        error "证书申请失败，请检查：1.域名解析 2.80端口是否开放 3.Cloudflare是否灰色云朵"
    fi
}

# ============================================================
# 配置 Nginx
# ============================================================
configure_nginx() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "配置 Nginx 反向代理..."

    cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
  <title>Welcome to nginx!</title>
  <style>
    body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
  </style>
</head>
<body>
  <h1>Welcome to nginx!</h1>
  <p>If you see this page, the nginx web server is successfully installed and working.</p>
</body>
</html>
HTMLEOF

    rm -f /etc/nginx/sites-enabled/default

    cat > /etc/nginx/sites-available/sing-box << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${NGINX_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 伪装页面
    location / {
        root /var/www/html;
        index index.html;
    }

    # WebSocket 代理
    location ${WS_PATH} {
        proxy_pass http://127.0.0.1:${SING_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/sing-box /etc/nginx/sites-enabled/

    if nginx -t 2>/dev/null; then
        success "Nginx 配置验证通过"
    else
        nginx -t
        error "Nginx 配置有误"
    fi

    systemctl enable nginx
    systemctl start nginx

    if systemctl is-active --quiet nginx; then
        success "Nginx 启动成功，监听端口 ${NGINX_PORT}"
    else
        error "Nginx 启动失败：$(systemctl status nginx | tail -3)"
    fi
}

# ============================================================
# 配置证书自动续期
# ============================================================
setup_auto_renew() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "配置证书自动续期..."

    if certbot renew --dry-run --quiet 2>/dev/null; then
        success "续期测试通过"
    else
        warning "续期测试未通过，不影响当前使用，请稍后手动检查"
    fi

    cat > /etc/cron.d/certbot-renew << 'CRONEOF'
# Let's Encrypt 证书自动续期 - 每周一凌晨3点执行
0 3 * * 1 root certbot renew --quiet && systemctl reload nginx
CRONEOF

    chmod 644 /etc/cron.d/certbot-renew
    systemctl restart cron

    success "已配置自动续期定时任务（每周一凌晨 3 点）"
}

# ============================================================
# 最终验证
# ============================================================
verify_services() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    info "验证服务状态..."

    if systemctl is-active --quiet sing-box; then
        success "sing-box 运行中 ✓"
    else
        warning "sing-box 未运行，尝试重启..."
        systemctl restart sing-box
    fi

    if systemctl is-active --quiet nginx; then
        success "nginx 运行中 ✓"
    else
        warning "nginx 未运行，尝试重启..."
        systemctl restart nginx
    fi

    if ss -tlnp | grep -q ":${NGINX_PORT}"; then
        success "端口 ${NGINX_PORT} 监听正常 ✓"
    else
        warning "端口 ${NGINX_PORT} 未监听，请检查 nginx 配置"
    fi

    if ss -tlnp | grep -q "127.0.0.1:${SING_PORT}"; then
        success "sing-box 端口 ${SING_PORT} 监听正常 ✓"
    else
        warning "sing-box 端口 ${SING_PORT} 未监听，请检查配置"
    fi
}

# ============================================================
# 打印最终结果
# ============================================================
print_result() {
    WS_PATH_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}'))" 2>/dev/null || echo "${WS_PATH}")
    VLESS_LINK="vless://${UUID}@${DOMAIN}:${NGINX_PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${WS_PATH_ENCODED}#VLESS-WS-TLS"

    echo ""
    echo -e "${GREEN}"
    echo "======================================================"
    echo "                  部署完成！"
    echo "======================================================"
    echo -e "${NC}"

    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "${GREEN}客户端配置参数：${NC}"
    echo ""
    echo "  协议：          VLESS"
    echo "  地址：          $DOMAIN"
    echo "  端口：          $NGINX_PORT"
    echo "  UUID：          $UUID"
    echo "  传输方式：      WebSocket (ws)"
    echo "  WS 路径：       $WS_PATH"
    echo "  WS Host：       $DOMAIN"
    echo "  TLS：           开启"
    echo "  SNI：           $DOMAIN"
    echo "  指纹：          chrome"
    echo "  REALITY：       关闭"
    echo "  允许不安全：    关闭"
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "${YELLOW}VLESS 链接（可直接导入客户端）：${NC}"
    echo ""
    echo "$VLESS_LINK"
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "${YELLOW}请在 Cloudflare 确认：${NC}"
    echo "  1. 橙色云朵已开启（已代理）"
    echo "  2. SSL/TLS 模式：完全(Full) 或 完全严格"
    echo ""
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "${YELLOW}常用管理命令：${NC}"
    echo "  查看 sing-box 状态：  systemctl status sing-box"
    echo "  查看 nginx 状态：     systemctl status nginx"
    echo "  查看 sing-box 日志：  journalctl -u sing-box -f"
    echo "  手动续期证书：        certbot renew"
    echo "  配置文件位置："
    echo "    sing-box:  /etc/sing-box/config.json"
    echo "    nginx:     /etc/nginx/sites-available/sing-box"
    echo "    证书：     /etc/letsencrypt/live/$DOMAIN/"
    echo "    续期任务： /etc/cron.d/certbot-renew"
    echo ""

    CONFIG_FILE="/root/vless-config.txt"
    cat > "$CONFIG_FILE" << EOF
VLESS + WebSocket + TLS + Cloudflare CDN 配置
生成时间：$(date)
系统：Debian $(cat /etc/debian_version)

域名：          $DOMAIN
端口：          $NGINX_PORT
UUID：          $UUID
WS 路径：       $WS_PATH
TLS：           开启
SNI：           $DOMAIN
指纹：          chrome

VLESS 链接：
$VLESS_LINK

文件路径：
  sing-box 配置：/etc/sing-box/config.json
  nginx 配置：   /etc/nginx/sites-available/sing-box
  证书：         /etc/letsencrypt/live/$DOMAIN/
  续期任务：     /etc/cron.d/certbot-renew
EOF
    success "配置已保存至 $CONFIG_FILE"
}

# ============================================================
# 主流程
# ============================================================
main() {
    check_root
    check_debian
    print_banner
    collect_info
    fix_apt_sources
    install_deps
    install_singbox
    configure_singbox
    request_cert
    configure_nginx
    setup_auto_renew
    verify_services
    print_result
}

main
