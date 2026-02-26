# VPNK - Marzban VPN Automated Installer

Production-ready bash script for fully automated installation and configuration of a VPN service based on **Marzban** + **Xray-core** on Ubuntu 24.04.

## Features

- **One-command installation** - only asks for email and domain
- **SSL certificate** via acme.sh with auto-renewal
- **VPN Protocols:**
  - VLESS + Reality (anti-DPI, looks like normal HTTPS to google.com)
  - VLESS + WebSocket + TLS (works behind CDN)
  - Hysteria2 (UDP-based, low latency)
- **System hardening:**
  - TCP BBR congestion control
  - Optimized sysctl for low latency
  - Increased file limits
  - IPv6 disabled
- **Security:**
  - UFW firewall (only 22, 80, 443 open)
  - SSH brute-force protection (rate limiting)
  - Fail2ban
  - Nginx security headers
  - HTTPS-only with HSTS
- **Nginx reverse proxy** with WebSocket support and HTTPS redirect
- **Camouflage** - looks like a normal website to outside observers
- **Anti-DPI** optimizations for Russian mobile networks (4G/5G)
- **Docker-based** with systemd auto-start
- **Automatic swap** creation if RAM < 1GB

## Requirements

- Ubuntu 24.04 (clean installation)
- Root access
- Domain with A record pointing to server IP
- Port 80 must be free

## Quick Start

```bash
# Download and run
curl -fsSL https://raw.githubusercontent.com/Krosrs1/VPNK/main/install.sh -o install.sh
sudo bash install.sh
```

The script will ask for:
1. **Email** - for SSL certificate registration
2. **Domain** - must already point to the server IP

Everything else is fully automatic.

## What Gets Installed

| Component | Purpose |
|-----------|---------|
| Docker + Docker Compose | Container runtime |
| Marzban (latest) | VPN management panel |
| Xray-core | VPN proxy engine |
| Nginx | Reverse proxy + TLS termination |
| acme.sh | SSL certificate management |
| UFW | Firewall |
| Fail2ban | Brute-force protection |

## After Installation

The script outputs:
- Panel URL: `https://your-domain.com/dashboard`
- Admin login and password
- Status of all services

Credentials are also saved to `/root/.marzban_credentials`.

## Ports Used

| Port | Protocol | Service |
|------|----------|---------|
| 22 | TCP | SSH |
| 80 | TCP | HTTP (redirect to HTTPS) |
| 443 | TCP | VLESS+Reality / Nginx HTTPS |
| 443 | UDP | Hysteria2 |
| 8080 | TCP | VLESS+WS (internal, proxied by Nginx) |
| 8443 | TCP | Marzban panel (internal) |

## Directory Structure

```
/opt/marzban/              # Marzban Docker files
  docker-compose.yml
  .env
/var/lib/marzban/          # Marzban data
  xray_config.json
  certs/cert.pem
  certs/key.pem
  db.sqlite3
/var/log/marzban-install.log  # Installation log
/root/.marzban_credentials    # Saved credentials
```

## Management

```bash
# Restart Marzban
docker restart marzban

# View logs
docker logs -f marzban

# Check status
systemctl status marzban

# Update Marzban
cd /opt/marzban && docker compose pull && docker compose up -d
```

## License

MIT
