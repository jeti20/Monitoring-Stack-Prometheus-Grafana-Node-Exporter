#!/usr/bin/env bash
# Installs Prometheus, Alertmanager, Node Exporter, Loki, Promtail and Grafana
# as native systemd services on Ubuntu 22.04 / 24.04.
# Run as a user with sudo rights from the repository root.

set -euo pipefail

PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-3.4.0}"
ALERTMANAGER_VERSION="${ALERTMANAGER_VERSION:-0.28.1}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.9.1}"
LOKI_VERSION="${LOKI_VERSION:-3.5.0}"
PROMTAIL_VERSION="${PROMTAIL_VERSION:-3.5.0}"

ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then
  ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
  ARCH="arm64"
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "[install] $*"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

download_and_extract() {
  local url="$1" dir="$2"
  local archive="$TMP/$(basename "$url")"
  log "Downloading $url"
  curl -fsSL "$url" -o "$archive"
  mkdir -p "$dir"
  tar -xzf "$archive" -C "$dir" --strip-components=1
}

create_user() {
  local user="$1"
  if ! id "$user" &>/dev/null; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
    log "Created system user: $user"
  fi
}

install_binary() {
  local src="$1" dst="/usr/local/bin/$(basename "$src")"
  sudo install -o root -g root -m 0755 "$src" "$dst"
  log "Installed binary: $dst"
}

install_service() {
  local unit="$1"
  sudo cp "$REPO_DIR/systemd/$unit" /etc/systemd/system/
  log "Installed unit: $unit"
}

# ---------------------------------------------------------------------------
# Grafana (via official apt repo)
# ---------------------------------------------------------------------------

install_grafana() {
  log "Installing Grafana..."
  if ! command -v grafana-server &>/dev/null; then
    sudo apt-get install -y apt-transport-https software-properties-common wget
    sudo mkdir -p /etc/apt/keyrings
    wget -q -O - https://apt.grafana.com/gpg.key \
      | gpg --dearmor \
      | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
      | sudo tee /etc/apt/sources.list.d/grafana.list
    sudo apt-get update
    sudo apt-get install -y grafana
  else
    log "Grafana already installed, skipping."
  fi

  # Provisioning configs
  sudo mkdir -p /etc/grafana/provisioning/datasources
  sudo mkdir -p /etc/grafana/provisioning/dashboards
  sudo cp "$REPO_DIR/grafana/provisioning/datasources/prometheus.yml" \
         /etc/grafana/provisioning/datasources/
  sudo cp "$REPO_DIR/grafana/provisioning/dashboards/dashboard.yml" \
         /etc/grafana/provisioning/dashboards/
  sudo cp "$REPO_DIR/grafana/provisioning/dashboards/node-exporter.json" \
         /etc/grafana/provisioning/dashboards/
  sudo cp "$REPO_DIR/grafana/provisioning/dashboards/loki-logs.json" \
         /etc/grafana/provisioning/dashboards/
  sudo chown -R grafana:grafana /etc/grafana/provisioning

  sudo systemctl daemon-reload
  sudo systemctl enable --now grafana-server
  log "Grafana enabled and started."
}

# ---------------------------------------------------------------------------
# Prometheus
# ---------------------------------------------------------------------------

install_prometheus() {
  log "Installing Prometheus $PROMETHEUS_VERSION..."
  local url="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}.tar.gz"
  local dir="$TMP/prometheus"
  download_and_extract "$url" "$dir"

  create_user prometheus
  install_binary "$dir/prometheus"
  install_binary "$dir/promtool"

  # Console templates (needed for --web.console.* flags)
  sudo mkdir -p /etc/prometheus/consoles /etc/prometheus/console_libraries /etc/prometheus/rules
  sudo cp -r "$dir/consoles/." /etc/prometheus/consoles/
  sudo cp -r "$dir/console_libraries/." /etc/prometheus/console_libraries/

  sudo cp "$REPO_DIR/Prometheus/prometheus.yml" /etc/prometheus/prometheus.yml
  sudo cp "$REPO_DIR/Prometheus/rules/"*.yml /etc/prometheus/rules/
  sudo chown -R prometheus:prometheus /etc/prometheus

  sudo mkdir -p /var/lib/prometheus
  sudo chown prometheus:prometheus /var/lib/prometheus

  install_service prometheus.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now prometheus
  log "Prometheus enabled and started."
}

# ---------------------------------------------------------------------------
# Alertmanager
# ---------------------------------------------------------------------------

install_alertmanager() {
  log "Installing Alertmanager $ALERTMANAGER_VERSION..."
  local url="https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}.tar.gz"
  local dir="$TMP/alertmanager"
  download_and_extract "$url" "$dir"

  create_user alertmanager
  install_binary "$dir/alertmanager"
  install_binary "$dir/amtool"

  sudo mkdir -p /etc/alertmanager/secrets
  sudo cp "$REPO_DIR/alertmanager/alertmanager.yml" /etc/alertmanager/alertmanager.yml

  # Copy gmail_password only if it exists; otherwise remind the user
  if [[ -f "$REPO_DIR/alertmanager/secrets/gmail_password" ]]; then
    sudo cp "$REPO_DIR/alertmanager/secrets/gmail_password" /etc/alertmanager/secrets/gmail_password
    sudo chmod 600 /etc/alertmanager/secrets/gmail_password
  else
    log "WARNING: alertmanager/secrets/gmail_password not found — create it before starting alertmanager:"
    log "  echo 'YOUR_16_CHAR_APP_PASSWORD' | sudo tee /etc/alertmanager/secrets/gmail_password"
    log "  sudo chmod 600 /etc/alertmanager/secrets/gmail_password"
  fi

  sudo chown -R alertmanager:alertmanager /etc/alertmanager

  sudo mkdir -p /var/lib/alertmanager
  sudo chown alertmanager:alertmanager /var/lib/alertmanager

  install_service alertmanager.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now alertmanager
  log "Alertmanager enabled and started."
}

# ---------------------------------------------------------------------------
# Node Exporter
# ---------------------------------------------------------------------------

install_node_exporter() {
  log "Installing Node Exporter $NODE_EXPORTER_VERSION..."
  local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  local dir="$TMP/node_exporter"
  download_and_extract "$url" "$dir"

  create_user node_exporter
  install_binary "$dir/node_exporter"

  install_service node_exporter.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now node_exporter
  log "Node Exporter enabled and started."
}

# ---------------------------------------------------------------------------
# Loki
# ---------------------------------------------------------------------------

install_loki() {
  log "Installing Loki $LOKI_VERSION..."
  local url="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-${ARCH}.zip"
  local archive="$TMP/loki.zip"
  log "Downloading $url"
  curl -fsSL "$url" -o "$archive"
  unzip -q "$archive" -d "$TMP/loki_bin"

  create_user loki
  sudo install -o root -g root -m 0755 "$TMP/loki_bin/loki-linux-${ARCH}" /usr/local/bin/loki

  sudo mkdir -p /etc/loki
  sudo cp "$REPO_DIR/loki/loki.yml" /etc/loki/loki.yml
  sudo chown -R loki:loki /etc/loki

  sudo mkdir -p /var/lib/loki/index /var/lib/loki/index_cache /var/lib/loki/chunks
  sudo chown -R loki:loki /var/lib/loki

  install_service loki.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now loki
  log "Loki enabled and started."
}

# ---------------------------------------------------------------------------
# Promtail
# ---------------------------------------------------------------------------

install_promtail() {
  log "Installing Promtail $PROMTAIL_VERSION..."
  local url="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip"
  local archive="$TMP/promtail.zip"
  log "Downloading $url"
  curl -fsSL "$url" -o "$archive"
  unzip -q "$archive" -d "$TMP/promtail_bin"

  create_user promtail
  # Promtail reads /var/log — needs group adm and systemd-journal for journald
  sudo usermod -aG adm promtail
  sudo usermod -aG systemd-journal promtail

  sudo install -o root -g root -m 0755 "$TMP/promtail_bin/promtail-linux-${ARCH}" /usr/local/bin/promtail

  sudo mkdir -p /etc/promtail /var/lib/promtail
  sudo cp "$REPO_DIR/promtail/promtail.yml" /etc/promtail/promtail.yml
  sudo chown -R promtail:promtail /etc/promtail /var/lib/promtail

  install_service promtail.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now promtail
  log "Promtail enabled and started."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

sudo apt-get update -q

install_grafana
install_node_exporter
install_loki
install_prometheus
install_alertmanager
install_promtail

log ""
log "=== Installation complete ==="
log ""
log "Service status:"
for svc in grafana-server prometheus alertmanager node_exporter loki promtail; do
  status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
  log "  $svc: $status"
done
log ""
log "Grafana: http://$(hostname -I | awk '{print $1}'):3000  (admin / admin — change on first login)"
log ""
log "If alertmanager/secrets/gmail_password was missing, set it now and run:"
log "  sudo systemctl restart alertmanager"
