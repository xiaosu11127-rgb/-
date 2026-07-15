#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

BRAND="科恩 Dujiao-Next 一键部署脚本 @d11129"
INSTALL_DIR="${INSTALL_DIR:-/opt/dujiao-next}"
WEBROOT="/var/www/dujiao-acme"
SSL_DIR="/etc/nginx/ssl/dujiao-next"

green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
red() { echo -e "\033[31m$*\033[0m"; }
die() { red "错误：$*"; exit 1; }

banner() {
  echo "======================================"
  echo " $BRAND"
  echo "======================================"
}

need_root() {
  [ "$(id -u)" = "0" ] || die "请使用 root 用户执行"
}

rand_hex() {
  openssl rand -hex "${1:-16}" 2>/dev/null || date +%s%N | sha256sum | cut -c1-32
}

ask() {
  local var="$1"
  local text="$2"
  local def="${3:-}"
  local val="${!var:-}"

  if [ -z "$val" ] && [ -r /dev/tty ]; then
    read -r -p "$text" val < /dev/tty || true
  fi

  val="${val:-$def}"
  printf -v "$var" "%s" "$val"
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
  else
    die "不支持的系统：未找到 apt / yum / dnf"
  fi
}

fix_centos7_repo() {
  if [ "${PM}" != "yum" ]; then
    return
  fi

  if [ -f /etc/centos-release ] && grep -qE 'CentOS.* 7\.' /etc/centos-release; then
    if ! yum -q makecache -y >/dev/null 2>&1; then
      yellow "检测到 CentOS 7 源异常，尝试切换 vault 源"
      cp -a /etc/yum.repos.d "/etc/yum.repos.d.bak.$(date +%Y%m%d%H%M%S)" || true
      sed -i 's/^mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo || true
      sed -i 's|^#baseurl=http://mirror.centos.org/centos/$releasever|baseurl=http://vault.centos.org/7.9.2009|g' /etc/yum.repos.d/CentOS-*.repo || true
      yum clean all || true
      yum makecache -y || true
    fi
  fi
}

install_packages() {
  green "安装基础依赖"

  if [ "$PM" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl wget ca-certificates openssl nginx cron tar gzip
  elif [ "$PM" = "dnf" ]; then
    dnf install -y curl wget ca-certificates openssl nginx cronie tar gzip
  else
    yum install -y epel-release || true
    yum install -y curl wget ca-certificates openssl nginx cronie tar gzip
  fi
}

service_start() {
  local name="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now "$name" 2>/dev/null || systemctl start "$name" 2>/dev/null || true
  else
    service "$name" start 2>/dev/null || true
  fi
}

service_reload() {
  local name="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload "$name" 2>/dev/null || systemctl restart "$name" 2>/dev/null || true
  else
    service "$name" reload 2>/dev/null || service "$name" restart 2>/dev/null || true
  fi
}

open_firewall() {
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-service=http --permanent >/dev/null 2>&1 || true
    firewall-cmd --add-service=https --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
  fi

  setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    green "安装 Docker"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh || true
  fi

  if ! command -v docker >/dev/null 2>&1; then
    if [ "$PM" = "apt" ]; then
      apt-get install -y docker.io
    elif [ "$PM" = "dnf" ]; then
      dnf install -y docker
    else
      yum install -y docker
    fi
  fi

  service_start docker

  docker info >/dev/null 2>&1 || die "Docker 启动失败"
}

install_compose() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    return
  fi

  green "安装 Docker Compose"

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "不支持的架构：$arch" ;;
  esac

  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose

  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

prepare_input() {
  ask FRONT_DOMAIN "请输入前台域名，例如 shop.example.com: " "${FRONT_DOMAIN:-}"
  ask ADMIN_DOMAIN "请输入后台域名，例如 admin.example.com: " "${ADMIN_DOMAIN:-}"
  ask API_DOMAIN "请输入 API 域名，例如 api.example.com: " "${API_DOMAIN:-}"
  ask ADMIN_USER "请输入后台用户名，默认 admin: " "${ADMIN_USER:-admin}"

  [ -n "$FRONT_DOMAIN" ] || die "前台域名不能为空"
  [ -n "$ADMIN_DOMAIN" ] || die "后台域名不能为空"
  [ -n "$API_DOMAIN" ] || die "API 域名不能为空"

  [ "$FRONT_DOMAIN" != "$ADMIN_DOMAIN" ] || die "前台域名和后台域名不能一样"
  [ "$FRONT_DOMAIN" != "$API_DOMAIN" ] || die "前台域名和 API 域名不能一样"
  [ "$ADMIN_DOMAIN" != "$API_DOMAIN" ] || die "后台域名和 API 域名不能一样"

  EMAIL="${EMAIL:-admin@$FRONT_DOMAIN}"
  ADMIN_PASS="${ADMIN_PASS:-$(rand_hex 8)}"

  echo "$ADMIN_PASS" | grep -q '[[:space:]]' && die "后台密码不能包含空格"
}

prepare_files() {
  green "生成 Dujiao-Next 配置"

  mkdir -p "$INSTALL_DIR"/{config,data/db,data/uploads,data/logs,data/redis}
  chmod -R 777 "$INSTALL_DIR/data"

  REDIS_PASSWORD="${REDIS_PASSWORD:-$(rand_hex 16)}"
  APP_SECRET="${APP_SECRET:-$(rand_hex 32)}"
  JWT_SECRET="${JWT_SECRET:-$(rand_hex 32)}"
  USER_JWT_SECRET="${USER_JWT_SECRET:-$(rand_hex 32)}"

  if [ -f "$INSTALL_DIR/.env" ]; then
    cp -a "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$INSTALL_DIR/.env" <<EOF
TAG=latest
TZ=Asia/Shanghai
API_PORT=5280
USER_PORT=5281
ADMIN_PORT=5282
REDIS_PASSWORD=${REDIS_PASSWORD}
DJ_DEFAULT_ADMIN_USERNAME=${ADMIN_USER}
DJ_DEFAULT_ADMIN_PASSWORD=${ADMIN_PASS}
EOF

  cat > "$INSTALL_DIR/config/config.yml" <<EOF
app:
  secret_key: "${APP_SECRET}"

server:
  port: 8080
  upload_path: /app/uploads
  log_path: /app/logs
  mode: release

database:
  driver: sqlite
  dsn: /app/db/dujiao.db

redis:
  enabled: true
  host: redis
  port: 6379
  password: "${REDIS_PASSWORD}"
  db: 0
  prefix: "dj"

queue:
  enabled: true
  host: redis
  port: 6379
  password: "${REDIS_PASSWORD}"
  db: 1
  concurrency: 10
  queues:
    default: 10
    critical: 5

jwt:
  secret: "${JWT_SECRET}"
  expire: 86400

user_jwt:
  secret: "${USER_JWT_SECRET}"
  expire: 604800

cors:
  allowed_origins:
    - https://${FRONT_DOMAIN}
    - https://${ADMIN_DOMAIN}
    - https://${API_DOMAIN}
    - http://${FRONT_DOMAIN}
    - http://${ADMIN_DOMAIN}
    - http://${API_DOMAIN}

upload:
  driver: local
  local:
    path: /app/uploads

email:
  enabled: false
  host: ""
  port: 587
  username: ""
  password: ""
  from: ""
  from_name: ""
  use_tls: false
  use_ssl: false
  verify_code:
    expire_minutes: 10
    send_interval_seconds: 60
    max_attempts: 5
    length: 6
EOF

  cat > "$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  redis:
    image: redis:7-alpine
    container_name: dujiaonext-redis
    restart: unless-stopped
    command: ["redis-server", "--dir", "/data", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      - ./data/redis:/data
    networks:
      - dujiao-net

  api:
    image: dujiaonext/api:${TAG}
    container_name: dujiaonext-api
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      DJ_DEFAULT_ADMIN_USERNAME: ${DJ_DEFAULT_ADMIN_USERNAME}
      DJ_DEFAULT_ADMIN_PASSWORD: ${DJ_DEFAULT_ADMIN_PASSWORD}
    ports:
      - "127.0.0.1:${API_PORT}:8080"
    volumes:
      - ./config/config.yml:/app/config.yml:ro
      - ./data/db:/app/db
      - ./data/uploads:/app/uploads
      - ./data/logs:/app/logs
    depends_on:
      - redis
    networks:
      - dujiao-net

  user:
    image: dujiaonext/user:${TAG}
    container_name: dujiaonext-user
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${USER_PORT}:80"
    depends_on:
      - api
    networks:
      - dujiao-net

  admin:
    image: dujiaonext/admin:${TAG}
    container_name: dujiaonext-admin
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${ADMIN_PORT}:80"
    depends_on:
      - api
    networks:
      - dujiao-net

networks:
  dujiao-net:
    driver: bridge
EOF
}

start_dujiao() {
  green "启动 Dujiao-Next Docker 容器"
  cd "$INSTALL_DIR"
  compose pull
  compose up -d

  for i in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:5280/health >/dev/null 2>&1; then
      green "API 健康检查通过"
      return
    fi
    sleep 2
  done

  docker logs --tail=100 dujiaonext-api || true
  die "Dujiao-Next API 启动失败"
}

nginx_conf_path() {
  if [ -d /etc/nginx/sites-available ] && [ -d /etc/nginx/sites-enabled ]; then
    NGINX_CONF="/etc/nginx/sites-available/dujiao-next.conf"
    rm -f /etc/nginx/sites-enabled/default || true
  else
    NGINX_CONF="/etc/nginx/conf.d/dujiao-next.conf"
  fi
}

enable_nginx_conf() {
  if [ -d /etc/nginx/sites-enabled ] && [ "$NGINX_CONF" = "/etc/nginx/sites-available/dujiao-next.conf" ]; then
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/dujiao-next.conf
  fi
}

write_nginx_http() {
  green "写入 Nginx HTTP 反代配置"

  nginx_conf_path
  mkdir -p "$(dirname "$NGINX_CONF")" "$WEBROOT/.well-known/acme-challenge"

  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${FRONT_DOMAIN};
    client_max_body_size 100m;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:5281;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        add_header X-OneClick "Keen @d11129" always;
    }
}

server {
    listen 80;
    server_name ${ADMIN_DOMAIN};
    client_max_body_size 100m;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:5282;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        add_header X-OneClick "Keen @d11129" always;
    }
}

server {
    listen 80;
    server_name ${API_DOMAIN};
    client_max_body_size 100m;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        add_header X-OneClick "Keen @d11129" always;
    }
}
EOF

  enable_nginx_conf
  nginx -t
  service_start nginx
  service_reload nginx
}

install_acme() {
  green "安装 acme.sh"

  if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
  fi

  ACME="$HOME/.acme.sh/acme.sh"
  [ -x "$ACME" ] || die "acme.sh 安装失败"

  "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$ACME" --register-account -m "$EMAIL" --server letsencrypt >/dev/null 2>&1 || true
}

issue_cert() {
  green "自动申请 SSL 证书"

  mkdir -p "$SSL_DIR"

  if "$ACME" --issue \
    -d "$FRONT_DOMAIN" \
    -d "$ADMIN_DOMAIN" \
    -d "$API_DOMAIN" \
    -w "$WEBROOT" \
    --server letsencrypt \
    --keylength ec-256 \
    --force; then

    "$ACME" --install-cert -d "$FRONT_DOMAIN" --ecc \
      --key-file "$SSL_DIR/key.pem" \
      --fullchain-file "$SSL_DIR/fullchain.pem" \
      --reloadcmd "nginx -s reload || systemctl reload nginx || true"

    return 0
  fi

  return 1
}

write_nginx_https() {
  green "写入 Nginx HTTPS 配置"

  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${FRONT_DOMAIN} ${ADMIN_DOMAIN} ${API_DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${FRONT_DOMAIN};
    client_max_body_size 100m;

    ssl_certificate ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/key.pem;

    location /api/ {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location = /sitemap.xml {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
    }

    location = /robots.txt {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
    }

    location / {
        proxy_pass http://127.0.0.1:5281;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        add_header X-OneClick "Keen @d11129" always;
    }
}

server {
    listen 443 ssl http2;
    server_name ${ADMIN_DOMAIN};
    client_max_body_size 100m;

    ssl_certificate ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/key.pem;

    location /api/ {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        proxy_pass http://127.0.0.1:5282;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        add_header X-OneClick "Keen @d11129" always;
    }
}

server {
    listen 443 ssl http2;
    server_name ${API_DOMAIN};
    client_max_body_size 100m;

    ssl_certificate ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/key.pem;

    location / {
        proxy_pass http://127.0.0.1:5280;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        add_header X-OneClick "Keen @d11129" always;
    }
}
EOF

  nginx -t
  service_reload nginx
}

save_info() {
  cat > /root/dujiao-next-admin.txt <<EOF
${BRAND}

安装目录: ${INSTALL_DIR}

前台: https://${FRONT_DOMAIN}
后台: https://${ADMIN_DOMAIN}
API:  https://${API_DOMAIN}

后台用户名: ${ADMIN_USER}
后台密码: ${ADMIN_PASS}

本地端口:
API:   127.0.0.1:5280
前台:  127.0.0.1:5281
后台:  127.0.0.1:5282
EOF
}

main() {
  banner
  need_root
  prepare_input
  detect_pm
  fix_centos7_repo
  install_packages
  open_firewall
  install_docker
  install_compose
  prepare_files
  start_dujiao
  write_nginx_http
  install_acme

  if issue_cert; then
    write_nginx_https
    SSL_OK="yes"
  else
    SSL_OK="no"
    yellow "SSL 自动申请失败，已保留 HTTP 反代配置。请检查域名解析和 80/443 端口后重跑脚本。"
  fi

  save_info

  echo
  green "安装完成"
  echo "前台: ${FRONT_DOMAIN}"
  echo "后台: ${ADMIN_DOMAIN}"
  echo "API:  ${API_DOMAIN}"
  echo "后台用户名: ${ADMIN_USER}"
  echo "后台密码: ${ADMIN_PASS}"
  echo "SSL: ${SSL_OK}"
  echo "信息保存: /root/dujiao-next-admin.txt"
  echo
  echo "由 ${BRAND} 完成"
}

main "$@"
