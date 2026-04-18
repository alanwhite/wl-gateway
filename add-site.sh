#!/usr/bin/env bash
set -euo pipefail

# Adds a wl-website client to the gateway.
# Usage: ./add-site.sh <domain> <container-name>
#
# Example:
#   ./add-site.sh alpha.example.com client-alpha-app
#
# Prerequisites:
#   1. The wl-website clone must be running and connected to the wl-gateway network.
#   2. Place Cloudflare origin cert at: nginx/ssl/<domain>/origin.pem + origin.key

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITES_DIR="${SCRIPT_DIR}/nginx/sites"
SSL_DIR="${SCRIPT_DIR}/nginx/ssl"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <domain> <container-name>"
  echo ""
  echo "  domain          The domain name (e.g. alpha.example.com)"
  echo "  container-name  The Docker container name (e.g. client-alpha-app)"
  echo ""
  echo "Current sites:"
  for f in "${SITES_DIR}"/*.conf; do
    [[ -f "$f" ]] || continue
    site_domain=$(basename "$f" .conf)
    echo "  $site_domain"
  done
  exit 1
fi

DOMAIN="$1"
CONTAINER="$2"
SAFE_NAME=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
CONF_FILE="${SITES_DIR}/${DOMAIN}.conf"

# ── Input validation ───────────────────────────────────────────────────────

if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
  echo "Error: Invalid domain format: $DOMAIN"
  exit 1
fi

if [[ ! "$CONTAINER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  echo "Error: Invalid container name format: $CONTAINER"
  exit 1
fi

# ── Uniqueness validation ──────────────────────────────────────────────────

if [[ -f "$CONF_FILE" ]]; then
  echo "Error: Config already exists at ${CONF_FILE}"
  echo "  Remove it first if you want to recreate."
  exit 1
fi

# Check container exists and is on the gateway network
if ! docker inspect "$CONTAINER" &>/dev/null; then
  echo "Warning: Container '$CONTAINER' not found."
  echo "  Make sure the wl-website stack is running and the container name matches."
  echo ""
  read -rp "Continue anyway? [y/N] " yn
  case "$yn" in
    [yY]*) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Check SSL certs
if [[ ! -f "${SSL_DIR}/${DOMAIN}/origin.pem" ]] || [[ ! -f "${SSL_DIR}/${DOMAIN}/origin.key" ]]; then
  echo "Warning: SSL certificate not found."
  echo ""
  echo "  Place your Cloudflare origin certificate at:"
  echo "    ${SSL_DIR}/${DOMAIN}/origin.pem"
  echo "    ${SSL_DIR}/${DOMAIN}/origin.key"
  echo ""
  echo "  To generate one:"
  echo "    1. Cloudflare dashboard → SSL/TLS → Origin Server"
  echo "    2. Create Certificate (covers *.${DOMAIN} and ${DOMAIN})"
  echo "    3. Save the PEM and Key to the paths above"
  echo ""
  read -rp "Continue anyway? [y/N] " yn
  case "$yn" in
    [yY]*) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
  mkdir -p "${SSL_DIR}/${DOMAIN}"
fi

# ── Generate config ─────────────────────────────────────────────────────────

cat > "$CONF_FILE" <<EOF
upstream app_${SAFE_NAME} {
    server ${CONTAINER}:3000;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    # Cloudflare origin certificate
    ssl_certificate     /etc/nginx/ssl/${DOMAIN}/origin.pem;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/origin.key;

    # Modern TLS
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Cloudflare authenticated origin pulls
    ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull-ca.pem;
    ssl_verify_client optional;

    # Silently drop non-Cloudflare, non-local traffic
    if (\$allow_access = 0) {
        return 444;
    }

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Rate limiting
    limit_req zone=general_limit burst=60 nodelay;
    limit_conn conn_limit 20;

    # Block common exploit paths
    location ~* (\.php|\.asp|\.aspx|\.jsp|\.cgi|wp-admin|wp-login) {
        return 444;
    }
    location ~* (\.git|\.env|\.DS_Store|\.htaccess) {
        return 444;
    }

    # Health check (no rate limiting, no access log)
    location /api/health {
        proxy_pass http://app_${SAFE_NAME};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        access_log off;
    }

    # Main proxy
    location / {
        proxy_pass http://app_${SAFE_NAME};
        proxy_http_version 1.1;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeouts
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }
}
EOF

echo "✓ Created ${CONF_FILE}"
echo "  ${DOMAIN} → ${CONTAINER}:3000"
echo ""

# ── Test and reload ─────────────────────────────────────────────────────────

echo "Testing nginx config..."
if docker compose exec nginx nginx -t 2>&1; then
  echo ""
  read -rp "Reload nginx now? [Y/n] " yn
  case "$yn" in
    [nN]*) echo "Skipped. Reload manually: docker compose exec nginx nginx -s reload" ;;
    *) docker compose exec nginx nginx -s reload && echo "✓ nginx reloaded" ;;
  esac
else
  echo ""
  echo "⚠ nginx config test failed — fix the error above, then:"
  echo "  docker compose exec nginx nginx -s reload"
fi

echo ""
echo "Don't forget to:"
echo "  1. Place Cloudflare origin cert at: nginx/ssl/${DOMAIN}/"
echo "  2. Create Cloudflare Origin Rule: ${DOMAIN} → port 8443"
echo "  3. Confirm Authenticated Origin Pulls is enabled on the zone:"
echo "     Cloudflare dashboard → SSL/TLS → Origin Server"
echo "     → Authenticated Origin Pulls → \"Global\" on"
echo "     (if not enabled, nginx returns 444 for all CF traffic to this site)"
