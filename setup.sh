#!/usr/bin/env bash
set -euo pipefail

echo "=== wl-gateway Setup ==="
echo ""
echo "One-time setup for the multi-site gateway."
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSL_DIR="${SCRIPT_DIR}/nginx/ssl"

# ── 1. Generate self-signed fallback cert ───────────────────────────────────

if [[ ! -f "${SSL_DIR}/fallback.crt" ]]; then
  echo "Generating fallback self-signed certificate..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${SSL_DIR}/fallback.key" \
    -out "${SSL_DIR}/fallback.crt" \
    -subj "/CN=fallback" 2>/dev/null
  echo "✓ Generated fallback certificate"
else
  echo "✓ Fallback certificate already exists"
fi

# ── 2. Create the Docker network (if it doesn't exist) ─────────────────────

if docker network inspect wl-gateway &>/dev/null; then
  echo "✓ Docker network 'wl-gateway' already exists"
else
  docker network create wl-gateway
  echo "✓ Created Docker network 'wl-gateway'"
fi

# ── 3. Start the gateway ───────────────────────────────────────────────────

echo ""
echo "Starting gateway..."
docker compose up -d

echo ""
echo "========================================="
echo "  wl-gateway is running on port 8443"
echo "========================================="
echo ""
echo "  Next steps:"
echo "  1. Open port 8443 on your router → ODROID"
echo "  2. Deploy a wl-website client site"
echo "  3. Add it to the gateway:"
echo "     ./add-site.sh <domain> <container-name>"
echo "  4. Place Cloudflare origin cert:"
echo "     nginx/ssl/<domain>/origin.pem"
echo "     nginx/ssl/<domain>/origin.key"
echo "  5. Create Cloudflare Origin Rule:"
echo "     Hostname = <domain> → Destination Port = 8443"
echo ""
