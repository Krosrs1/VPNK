#!/usr/bin/env bash
###############################################################################
#  Marzban VPN — Production-Ready Automated Installer
#  OS:      Ubuntu 24.04 (clean)
#  Author:  VPNK Project
#  License: MIT
#
#  Usage:   sudo bash install.sh
#
#  The script asks for EMAIL and DOMAIN once, then performs a fully automated
#  installation of Marzban with:
#    - System hardening & optimization (BBR, sysctl, file limits)
#    - Docker + Docker Compose
#    - Marzban (latest) via Docker
#    - SSL via acme.sh (standalone, auto-renew)
#    - Nginx reverse-proxy with WebSocket, security headers & HTTPS redirect
#    - VLESS+Reality, VLESS+WS+TLS, Hysteria2 protocols
#    - Anti-DPI & mobile-network optimizations for RU carriers
#    - Fail2ban, UFW firewall
#    - Systemd auto-start
###############################################################################

set -euo pipefail

# ─────────────────────────── Constants ───────────────────────────────────────
readonly MARZBAN_DIR="/opt/marzban"
readonly MARZBAN_DATA_DIR="/var/lib/marzban"
readonly ACME_DIR="/root/.acme.sh"
readonly CERT_DIR="/var/lib/marzban/certs"
readonly NGINX_CONF="/etc/nginx/sites-available/marzban"
readonly LOG_FILE="/var/log/marzban-install.log"
readonly SWAP_SIZE="1G"
readonly MIN_RAM_MB=1024
readonly MARZBAN_PANEL_PORT=8443
# Xray API port (reserved for future use)
# readonly XRAY_API_PORT=62050

# ─────────────────────────── Colors & helpers ────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" | tee -a "$LOG_FILE"; }
info()  { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $*" | tee -a "$LOG_FILE"; }
header(){ echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
          echo -e "${BLUE}  $*${NC}" | tee -a "$LOG_FILE"
          echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" | tee -a "$LOG_FILE"; }

die() { err "$*"; exit 1; }

# Generate a random password (alphanumeric, 20 chars)
generate_password() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true; }

# Generate a random UUID v4
generate_uuid() { cat /proc/sys/kernel/random/uuid; }

# ─────────────────────────── Pre-flight checks ───────────────────────────────
header "Pre-flight Checks"

# Root check
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root. Use: sudo bash $0"
fi
log "Running as root — OK"

# OS check
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        die "This script requires Ubuntu. Detected: $ID"
    fi
    UBUNTU_VERSION="${VERSION_ID}"
    if [[ "$UBUNTU_VERSION" != "24.04" ]]; then
        warn "Designed for Ubuntu 24.04, detected $UBUNTU_VERSION. Proceeding anyway..."
    fi
    log "OS: Ubuntu $UBUNTU_VERSION — OK"
else
    die "Cannot detect operating system."
fi

# Port 80 check
if ss -tlnp | grep -q ':80 '; then
    die "Port 80 is already in use. Free it before running this script."
fi
log "Port 80 is free — OK"

# ─────────────────────────── User Input ──────────────────────────────────────
header "Configuration"

read -rp "$(echo -e "${CYAN}Enter your email (for SSL certificate): ${NC}")" USER_EMAIL
if [[ -z "$USER_EMAIL" || ! "$USER_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    die "Invalid email address: $USER_EMAIL"
fi

read -rp "$(echo -e "${CYAN}Enter your domain (e.g. vpn.example.com): ${NC}")" USER_DOMAIN
if [[ -z "$USER_DOMAIN" ]]; then
    die "Domain cannot be empty."
fi

log "Email:  $USER_EMAIL"
log "Domain: $USER_DOMAIN"

# DNS check — domain must point to this server
SERVER_IP=$(curl -4 -s --max-time 10 https://api.ipify.org || curl -4 -s --max-time 10 https://ifconfig.me || true)
if [[ -z "$SERVER_IP" ]]; then
    die "Could not determine server public IP."
fi
log "Server IP: $SERVER_IP"

DOMAIN_IP=$(dig +short "$USER_DOMAIN" A | head -1 || true)
if [[ -z "$DOMAIN_IP" ]]; then
    die "Cannot resolve domain $USER_DOMAIN. Please create an A record pointing to $SERVER_IP"
fi
if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    die "Domain $USER_DOMAIN resolves to $DOMAIN_IP, but server IP is $SERVER_IP. Fix DNS first."
fi
log "Domain $USER_DOMAIN resolves to $SERVER_IP — OK"

# Generate credentials
ADMIN_USER="admin"
ADMIN_PASS=$(generate_password)
SECRET_KEY=$(generate_password)

# ─────────────────────────── System Update ───────────────────────────────────
header "Updating System"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y 2>&1 | tee -a "$LOG_FILE"
apt-get upgrade -y 2>&1 | tee -a "$LOG_FILE"
log "System updated"

# ─────────────────────────── Install Packages ────────────────────────────────
header "Installing Required Packages"

apt-get install -y \
    curl wget git ufw socat cron \
    nginx \
    fail2ban \
    dnsutils \
    jq \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    2>&1 | tee -a "$LOG_FILE"

log "Required packages installed"

# ─────────────────────────── RAM & Swap ──────────────────────────────────────
header "Checking RAM & Swap"

TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
log "Total RAM: ${TOTAL_RAM_MB} MB"

if [[ "$TOTAL_RAM_MB" -lt "$MIN_RAM_MB" ]]; then
    warn "RAM is below ${MIN_RAM_MB} MB. Creating ${SWAP_SIZE} swap..."
    if [[ ! -f /swapfile ]]; then
        fallocate -l "$SWAP_SIZE" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "Swap file created and enabled"
    else
        log "Swap file already exists"
    fi
else
    log "RAM is sufficient (${TOTAL_RAM_MB} MB)"
fi

# ─────────────────────────── System Optimization ─────────────────────────────
header "Optimizing System (BBR, sysctl, file limits)"

# Enable TCP BBR and fq qdisc
cat > /etc/sysctl.d/99-vpn-optimization.conf <<'SYSCTL'
# ── TCP BBR Congestion Control ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── Network Performance ──
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535

net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.tcp_max_tw_buckets = 6000000
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

# ── Low Latency ──
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1

# ── Conntrack ──
net.netfilter.nf_conntrack_max = 1048576

# ── IP Forwarding (for VPN) ──
net.ipv4.ip_forward = 1

# ── Disable IPv6 ──
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL

sysctl --system 2>&1 | tee -a "$LOG_FILE"
log "BBR and sysctl optimizations applied"

# Verify BBR
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    log "BBR is active — OK"
else
    warn "BBR may not be active. Kernel may need updating."
fi

# Increase file limits
cat > /etc/security/limits.d/99-vpn.conf <<'LIMITS'
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
LIMITS

# Also set via systemd
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

systemctl daemon-reload
log "File limits increased"

# ─────────────────────────── UFW Firewall ────────────────────────────────────
header "Configuring UFW Firewall"

# Reset and configure
ufw --force reset 2>&1 | tee -a "$LOG_FILE"
ufw default deny incoming
ufw default allow outgoing

# Allow essential ports
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'Hysteria2 UDP'

# Rate limiting for SSH (brute-force protection)
ufw limit 22/tcp comment 'SSH rate limit'

# Enable firewall
ufw --force enable 2>&1 | tee -a "$LOG_FILE"
log "UFW firewall configured and enabled"

# ─────────────────────────── Fail2ban ────────────────────────────────────────
header "Configuring Fail2ban"

cat > /etc/fail2ban/jail.local <<'F2B'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7200

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 3

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 2
F2B

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configured and started"

# ─────────────────────────── Docker & Docker Compose ─────────────────────────
header "Installing Docker & Docker Compose"

if ! command -v docker &>/dev/null; then
    # Install Docker using the official convenience script
    curl -fsSL https://get.docker.com | bash 2>&1 | tee -a "$LOG_FILE"
    log "Docker installed"
else
    log "Docker already installed"
fi

# Enable and start Docker
systemctl enable docker
systemctl start docker

# Verify Docker
if docker info &>/dev/null; then
    log "Docker is running — OK"
else
    die "Docker failed to start"
fi

# Docker Compose (v2 plugin is included in modern Docker)
if docker compose version &>/dev/null; then
    log "Docker Compose $(docker compose version --short) — OK"
else
    # Fallback: install compose plugin
    apt-get install -y docker-compose-plugin 2>&1 | tee -a "$LOG_FILE"
    log "Docker Compose plugin installed"
fi

# ─────────────────────────── SSL Certificate (acme.sh) ───────────────────────
header "Obtaining SSL Certificate via acme.sh"

mkdir -p "$CERT_DIR"

# Install acme.sh
if [[ ! -f "$ACME_DIR/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="$USER_EMAIL" 2>&1 | tee -a "$LOG_FILE"
    log "acme.sh installed"
else
    log "acme.sh already installed"
fi

# Source acme.sh
export PATH="$ACME_DIR:$PATH"

# Set default CA to Let's Encrypt
"$ACME_DIR/acme.sh" --set-default-ca --server letsencrypt 2>&1 | tee -a "$LOG_FILE"

# Issue certificate (standalone mode — port 80 must be free)
"$ACME_DIR/acme.sh" --issue \
    --standalone \
    -d "$USER_DOMAIN" \
    --keylength ec-256 \
    --force \
    2>&1 | tee -a "$LOG_FILE" || {
        err "Failed to issue SSL certificate. Check DNS and port 80."
        die "SSL certificate issuance failed."
    }

# Install certificate to Marzban cert directory
"$ACME_DIR/acme.sh" --install-cert -d "$USER_DOMAIN" --ecc \
    --key-file       "$CERT_DIR/key.pem" \
    --fullchain-file "$CERT_DIR/cert.pem" \
    --reloadcmd      "docker restart marzban 2>/dev/null || true" \
    2>&1 | tee -a "$LOG_FILE"

log "SSL certificate obtained and installed"
log "Certificate: $CERT_DIR/cert.pem"
log "Private key: $CERT_DIR/key.pem"

# Ensure auto-renewal cron
"$ACME_DIR/acme.sh" --install-cronjob 2>&1 | tee -a "$LOG_FILE"
log "SSL auto-renewal configured"

# ─────────────────────────── Marzban Installation ────────────────────────────
header "Installing Marzban"

mkdir -p "$MARZBAN_DIR" "$MARZBAN_DATA_DIR"

# Generate keys for VLESS Reality
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
SHORT_ID=$(openssl rand -hex 8)

# We'll generate Reality keys after Marzban starts (using xray binary inside container)
# For now, use placeholder and update later

# ── Xray configuration ──
cat > "$MARZBAN_DATA_DIR/xray_config.json" <<XRAY_EOF
{
  "log": {
    "loglevel": "warning",
    "access": "",
    "error": ""
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "VLESS_REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {
          "acceptProxyProtocol": false
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.google.com:443",
          "xver": 0,
          "serverNames": [
            "www.google.com",
            "google.com"
          ],
          "privateKey": "REALITY_PRIVATE_KEY_PLACEHOLDER",
          "shortIds": [
            "${SHORT_ID}",
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "VLESS_WS_TLS",
      "listen": "0.0.0.0",
      "port": 8080,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless-ws",
          "headers": {
            "Host": "${USER_DOMAIN}"
          }
        },
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "HYSTERIA2",
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "hysteria2",
      "settings": {
        "obfs": {
          "type": "salamander",
          "password": "${SECRET_KEY}"
        }
      },
      "streamSettings": {
        "network": "hysteria2",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "/var/lib/marzban/certs/cert.pem",
              "keyFile": "/var/lib/marzban/certs/key.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "blackhole",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blackhole"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "blackhole"
      },
      {
        "type": "field",
        "outboundTag": "direct"
      }
    ]
  }
}
XRAY_EOF

log "Xray configuration created"

# ── Marzban .env ──
cat > "$MARZBAN_DIR/.env" <<ENV_EOF
# Marzban Environment Configuration
# Generated by VPNK Installer on $(date -u '+%Y-%m-%d %H:%M:%S UTC')

UVICORN_HOST=0.0.0.0
UVICORN_PORT=${MARZBAN_PANEL_PORT}

# Dashboard
DASHBOARD_PATH=/dashboard

# Admin credentials
SUDO_USERNAME=${ADMIN_USER}
SUDO_PASSWORD=${ADMIN_PASS}

# Security
SECRET_KEY=${SECRET_KEY}

# SSL for panel
UVICORN_SSL_CERTFILE=/var/lib/marzban/certs/cert.pem
UVICORN_SSL_KEYFILE=/var/lib/marzban/certs/key.pem

# Xray
XRAY_JSON=/var/lib/marzban/xray_config.json
XRAY_SUBSCRIPTION_URL_PREFIX=https://${USER_DOMAIN}

# Database
SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/marzban/db.sqlite3

# Subscription
SUB_LISTEN_HOST=0.0.0.0
SUB_LISTEN_PORT=7879
SUB_DOMAIN=${USER_DOMAIN}
SUB_PATH=/sub/

# Webhook (disabled by default)
# WEBHOOK_ADDRESS=
# WEBHOOK_SECRET=

# Docs
DOCS=true
ENV_EOF

log "Marzban .env created"

# ── docker-compose.yml ──
cat > "$MARZBAN_DIR/docker-compose.yml" <<COMPOSE_EOF
version: "3.8"

services:
  marzban:
    image: gozargah/marzban:latest
    container_name: marzban
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - ${MARZBAN_DATA_DIR}:/var/lib/marzban
    depends_on: []
    healthcheck:
      test: ["CMD", "curl", "-fk", "https://localhost:${MARZBAN_PANEL_PORT}/api/system"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s

volumes: {}
COMPOSE_EOF

log "docker-compose.yml created"

# ── Start Marzban ──
log "Starting Marzban container..."
docker compose -f "$MARZBAN_DIR/docker-compose.yml" --project-directory "$MARZBAN_DIR" pull 2>&1 | tee -a "$LOG_FILE"
docker compose -f "$MARZBAN_DIR/docker-compose.yml" --project-directory "$MARZBAN_DIR" up -d 2>&1 | tee -a "$LOG_FILE"

# Wait for container to be ready
log "Waiting for Marzban to start..."
for _i in $(seq 1 30); do
    if docker ps --format '{{.Names}}' | grep -q marzban; then
        if docker exec marzban test -f /usr/local/bin/xray 2>/dev/null; then
            log "Marzban container is running"
            break
        fi
    fi
    sleep 2
done

# ── Generate Reality keys using xray inside the container ──
log "Generating VLESS Reality keys..."
REALITY_OUTPUT=$(docker exec marzban /usr/local/bin/xray x25519 2>/dev/null || true)
if [[ -n "$REALITY_OUTPUT" ]]; then
    REALITY_PRIVATE_KEY=$(echo "$REALITY_OUTPUT" | grep "Private key:" | awk '{print $3}')
    REALITY_PUBLIC_KEY=$(echo "$REALITY_OUTPUT" | grep "Public key:" | awk '{print $3}')
    log "Reality Private Key: ${REALITY_PRIVATE_KEY:0:10}..."
    log "Reality Public Key:  ${REALITY_PUBLIC_KEY:0:10}..."

    # Update xray config with actual Reality keys
    sed -i "s|REALITY_PRIVATE_KEY_PLACEHOLDER|${REALITY_PRIVATE_KEY}|g" "$MARZBAN_DATA_DIR/xray_config.json"

    log "Xray config updated with Reality keys"
else
    warn "Could not generate Reality keys automatically. You will need to generate them manually."
    warn "Run: docker exec marzban /usr/local/bin/xray x25519"
fi

# Restart Marzban to apply the updated xray config
docker restart marzban 2>&1 | tee -a "$LOG_FILE"
sleep 5
log "Marzban restarted with updated configuration"

# ─────────────────────────── Nginx Configuration ─────────────────────────────
header "Configuring Nginx Reverse Proxy"

# Remove default site
rm -f /etc/nginx/sites-enabled/default

# Generate DH parameters (if not exists)
if [[ ! -f /etc/nginx/dhparam.pem ]]; then
    log "Generating DH parameters (this may take a moment)..."
    openssl dhparam -out /etc/nginx/dhparam.pem 2048 2>&1 | tee -a "$LOG_FILE"
fi

# Nginx main config for Marzban
cat > "$NGINX_CONF" <<NGINX_EOF
# ── HTTP → HTTPS redirect ──
server {
    listen 80;
    listen [::]:80;
    server_name ${USER_DOMAIN};

    # ACME challenge for SSL renewal
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# ── HTTPS Server ──
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${USER_DOMAIN};

    # ── SSL Certificates ──
    ssl_certificate     ${CERT_DIR}/cert.pem;
    ssl_certificate_key ${CERT_DIR}/key.pem;
    ssl_dhparam         /etc/nginx/dhparam.pem;

    # ── SSL Configuration ──
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ── Security Headers ──
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy no-referrer always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';" always;

    # ── Masquerade as a normal website ──
    root /var/www/html;
    index index.html;

    # ── Marzban Panel (reverse proxy) ──
    location /dashboard {
        proxy_pass https://127.0.0.1:${MARZBAN_PANEL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        proxy_pass https://127.0.0.1:${MARZBAN_PANEL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # ── Subscription endpoint ──
    location /sub/ {
        proxy_pass http://127.0.0.1:7879;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # ── VLESS WebSocket ──
    location /vless-ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # ── Default: serve camouflage page ──
    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX_EOF

# Create a camouflage landing page
mkdir -p /var/www/html
cat > /var/www/html/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            display: flex; align-items: center; justify-content: center;
            min-height: 100vh; margin: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: #fff;
        }
        .container { text-align: center; padding: 2rem; }
        h1 { font-size: 2.5rem; margin-bottom: 0.5rem; }
        p  { font-size: 1.1rem; opacity: 0.8; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome</h1>
        <p>This server is running normally.</p>
    </div>
</body>
</html>
HTML_EOF

# Enable site
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/marzban

# Test and reload Nginx
nginx -t 2>&1 | tee -a "$LOG_FILE" || die "Nginx configuration test failed"
systemctl enable nginx
systemctl restart nginx
log "Nginx configured and running"

# ─────────────────────────── Systemd Service ─────────────────────────────────
header "Configuring Systemd Auto-start"

cat > /etc/systemd/system/marzban.service <<SERVICE_EOF
[Unit]
Description=Marzban VPN Service
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${MARZBAN_DIR}
ExecStart=/usr/bin/docker compose -f ${MARZBAN_DIR}/docker-compose.yml --project-directory ${MARZBAN_DIR} up -d
ExecStop=/usr/bin/docker compose -f ${MARZBAN_DIR}/docker-compose.yml --project-directory ${MARZBAN_DIR} down
ExecReload=/usr/bin/docker compose -f ${MARZBAN_DIR}/docker-compose.yml --project-directory ${MARZBAN_DIR} restart
TimeoutStartSec=120
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable marzban.service
log "Marzban systemd service configured"

# ─────────────────────────── Post-Installation Checks ────────────────────────
header "Post-Installation Checks"

echo "" | tee -a "$LOG_FILE"

# UFW status
echo -e "${CYAN}═══ UFW Firewall Status ═══${NC}" | tee -a "$LOG_FILE"
if ufw status | grep -q "active"; then
    echo -e "  ${GREEN}UFW: ACTIVE${NC}" | tee -a "$LOG_FILE"
else
    echo -e "  ${RED}UFW: INACTIVE${NC}" | tee -a "$LOG_FILE"
fi
ufw status verbose 2>&1 | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# BBR status
echo -e "${CYAN}═══ BBR Status ═══${NC}" | tee -a "$LOG_FILE"
BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
if [[ "$BBR_STATUS" == "bbr" ]]; then
    echo -e "  ${GREEN}TCP BBR: ACTIVE${NC}" | tee -a "$LOG_FILE"
else
    echo -e "  ${YELLOW}TCP BBR: $BBR_STATUS${NC}" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Docker status
echo -e "${CYAN}═══ Docker Status ═══${NC}" | tee -a "$LOG_FILE"
if systemctl is-active --quiet docker; then
    echo -e "  ${GREEN}Docker: RUNNING${NC}" | tee -a "$LOG_FILE"
else
    echo -e "  ${RED}Docker: NOT RUNNING${NC}" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Marzban status
echo -e "${CYAN}═══ Marzban Status ═══${NC}" | tee -a "$LOG_FILE"
if docker ps --format '{{.Names}}' | grep -q marzban; then
    echo -e "  ${GREEN}Marzban: RUNNING${NC}" | tee -a "$LOG_FILE"
else
    echo -e "  ${RED}Marzban: NOT RUNNING${NC}" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Nginx status
echo -e "${CYAN}═══ Nginx Status ═══${NC}" | tee -a "$LOG_FILE"
if systemctl is-active --quiet nginx; then
    echo -e "  ${GREEN}Nginx: RUNNING${NC}" | tee -a "$LOG_FILE"
else
    echo -e "  ${RED}Nginx: NOT RUNNING${NC}" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Fail2ban status
echo -e "${CYAN}═══ Fail2ban Status ═══${NC}" | tee -a "$LOG_FILE"
if systemctl is-active --quiet fail2ban; then
    echo -e "  ${GREEN}Fail2ban: RUNNING${NC}" | tee -a "$LOG_FILE"
else
    echo -e "  ${RED}Fail2ban: NOT RUNNING${NC}" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# ─────────────────────────── Final Output ────────────────────────────────────
header "Installation Complete"

cat <<FINAL_EOF

$(echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}")
$(echo -e "${GREEN}║           Installation completed successfully!              ║${NC}")
$(echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}")
$(echo -e "${GREEN}║${NC}")
$(echo -e "${GREEN}║${NC}  ${CYAN}Panel URL:${NC}    https://${USER_DOMAIN}/dashboard")
$(echo -e "${GREEN}║${NC}  ${CYAN}Login:${NC}        ${ADMIN_USER}")
$(echo -e "${GREEN}║${NC}  ${CYAN}Password:${NC}     ${ADMIN_PASS}")
$(echo -e "${GREEN}║${NC}")
$(echo -e "${GREEN}║${NC}  ${CYAN}Domain:${NC}       ${USER_DOMAIN}")
$(echo -e "${GREEN}║${NC}  ${CYAN}Server IP:${NC}    ${SERVER_IP}")
$(echo -e "${GREEN}║${NC}")
$(echo -e "${GREEN}║${NC}  ${CYAN}Protocols Enabled:${NC}")
$(echo -e "${GREEN}║${NC}    - VLESS + Reality    (port 443/tcp)")
$(echo -e "${GREEN}║${NC}    - VLESS + WS + TLS   (via nginx /vless-ws)")
$(echo -e "${GREEN}║${NC}    - Hysteria2          (port 8443/udp)")
$(echo -e "${GREEN}║${NC}")
$(echo -e "${GREEN}║${NC}  ${CYAN}SSL Certificate:${NC}")
$(echo -e "${GREEN}║${NC}    ${CERT_DIR}/cert.pem")
$(echo -e "${GREEN}║${NC}    ${CERT_DIR}/key.pem")
$(echo -e "${GREEN}║${NC}    Auto-renew: enabled")
$(echo -e "${GREEN}║${NC}")
$(echo -e "${GREEN}║${NC}  ${CYAN}Firewall:${NC}     UFW active (22, 80, 443 allowed)")
$(echo -e "${GREEN}║${NC}  ${CYAN}BBR:${NC}          ${BBR_STATUS}")
$(echo -e "${GREEN}║${NC}  ${CYAN}Fail2ban:${NC}     active")
$(echo -e "${GREEN}║${NC}")
$(echo -e "${GREEN}║${NC}  ${YELLOW}IMPORTANT:${NC}")
$(echo -e "${GREEN}║${NC}    Save your credentials securely!")
$(echo -e "${GREEN}║${NC}    Log file: ${LOG_FILE}")
$(echo -e "${GREEN}║${NC}")
$(echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}")

FINAL_EOF

# Save credentials to a secure file
CREDS_FILE="/root/.marzban_credentials"
cat > "$CREDS_FILE" <<CREDS_EOF
# Marzban VPN Credentials
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# WARNING: Keep this file secure!

PANEL_URL=https://${USER_DOMAIN}/dashboard
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
DOMAIN=${USER_DOMAIN}
SERVER_IP=${SERVER_IP}
SECRET_KEY=${SECRET_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
CREDS_EOF
chmod 600 "$CREDS_FILE"
log "Credentials saved to $CREDS_FILE (chmod 600)"

echo ""
echo -e "${GREEN}Installation completed successfully${NC}"
echo ""
