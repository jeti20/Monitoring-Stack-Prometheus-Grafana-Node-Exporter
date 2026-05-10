#!/bin/bash
set -euo pipefail

# ============================================================
# Monitoring Stack — setup script for Ubuntu on-premises
# Run once before first `docker compose up`
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Must be run from repo root
[ -f docker-compose.yml ] || error "Run this script from the repository root directory."

# ---- Docker check ----
command -v docker &>/dev/null || error "Docker is not installed. See README-onprem.md for installation instructions."
docker compose version &>/dev/null || error "Docker Compose v2 is not available."

# ---- User in docker group ----
if ! groups | grep -q docker; then
    warn "Current user is not in the 'docker' group."
    warn "Run: sudo usermod -aG docker \$USER && newgrp docker"
fi

# ---- Data directories ----
info "Creating data directories..."
mkdir -p data/prometheus data/grafana data/loki

# Prometheus runs as UID 65534 (nobody)
sudo chown -R 65534:65534 data/prometheus
# Grafana runs as UID 472
sudo chown -R 472:472 data/grafana
# Loki runs as UID 10001
sudo chown -R 10001:10001 data/loki

info "Data directory ownership set."

# ---- Secrets ----
info "Setting up secrets directory..."
mkdir -p alertmanager/secrets
chmod 700 alertmanager/secrets

if [ ! -f alertmanager/secrets/gmail_password ]; then
    warn "alertmanager/secrets/gmail_password not found."
    warn "Create it manually:"
    warn "  echo 'YOUR_GMAIL_APP_PASSWORD' > alertmanager/secrets/gmail_password"
    warn "  chmod 600 alertmanager/secrets/gmail_password"
else
    chmod 600 alertmanager/secrets/gmail_password
    info "gmail_password permissions set to 600."
fi

# ---- Summary ----
echo ""
info "Setup complete. Next steps:"
echo "  1. Edit alertmanager/alertmanager.yml — set your Gmail address"
echo "  2. Create alertmanager/secrets/gmail_password (if not done)"
echo "  3. docker compose up -d"
echo "  4. docker compose ps  (verify all containers are running)"
