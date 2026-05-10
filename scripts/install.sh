#!/usr/bin/env bash
# Instaluje stos monitoringu jako natywne serwisy systemd na Ubuntu 22.04/24.04.
# Uruchom z katalogu repozytorium jako użytkownik z sudo.

set -euo pipefail

PROMETHEUS_VERSION="3.4.0"
ALERTMANAGER_VERSION="0.28.1"
NODE_EXPORTER_VERSION="1.9.1"
LOKI_VERSION="3.5.0"
PROMTAIL_VERSION="3.5.0"

ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Grafana (apt) ---

sudo apt-get install -y apt-transport-https wget unzip
sudo mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key \
  | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update -q
sudo apt-get install -y grafana

sudo mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
sudo cp "$REPO/grafana/provisioning/datasources/prometheus.yml" /etc/grafana/provisioning/datasources/
sudo cp "$REPO/grafana/provisioning/dashboards/dashboard.yml"   /etc/grafana/provisioning/dashboards/
sudo cp "$REPO/grafana/provisioning/dashboards/"*.json          /etc/grafana/provisioning/dashboards/
sudo chown -R grafana:grafana /etc/grafana/provisioning
sudo systemctl enable --now grafana-server

# --- Node Exporter ---

curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
  | tar -xz -C "$TMP"
sudo install -m755 "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true
sudo cp "$REPO/systemd/node_exporter.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter

# --- Prometheus ---

curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}.tar.gz" \
  | tar -xz -C "$TMP"
PROM_DIR="$TMP/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}"
sudo install -m755 "$PROM_DIR/prometheus" "$PROM_DIR/promtool" /usr/local/bin/
sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus 2>/dev/null || true

sudo mkdir -p /etc/prometheus/rules /etc/prometheus/consoles /etc/prometheus/console_libraries
sudo cp "$REPO/Prometheus/prometheus.yml"  /etc/prometheus/
sudo cp "$REPO/Prometheus/rules/"*.yml     /etc/prometheus/rules/
sudo cp -r "$PROM_DIR/consoles/."          /etc/prometheus/consoles/
sudo cp -r "$PROM_DIR/console_libraries/." /etc/prometheus/console_libraries/
sudo chown -R prometheus:prometheus /etc/prometheus

sudo mkdir -p /var/lib/prometheus
sudo chown prometheus:prometheus /var/lib/prometheus

sudo cp "$REPO/systemd/prometheus.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus

# --- Alertmanager ---

curl -fsSL "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}.tar.gz" \
  | tar -xz -C "$TMP"
AM_DIR="$TMP/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}"
sudo install -m755 "$AM_DIR/alertmanager" "$AM_DIR/amtool" /usr/local/bin/
sudo useradd --system --no-create-home --shell /usr/sbin/nologin alertmanager 2>/dev/null || true

sudo mkdir -p /etc/alertmanager/secrets
sudo cp "$REPO/alertmanager/alertmanager.yml" /etc/alertmanager/
if [[ -f "$REPO/alertmanager/secrets/gmail_password" ]]; then
  sudo cp "$REPO/alertmanager/secrets/gmail_password" /etc/alertmanager/secrets/
  sudo chmod 600 /etc/alertmanager/secrets/gmail_password
else
  echo "UWAGA: brak alertmanager/secrets/gmail_password — uzupełnij ręcznie i zrestartuj alertmanager"
fi
sudo chown -R alertmanager:alertmanager /etc/alertmanager

sudo mkdir -p /var/lib/alertmanager
sudo chown alertmanager:alertmanager /var/lib/alertmanager

sudo cp "$REPO/systemd/alertmanager.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now alertmanager

# --- Loki ---

curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-${ARCH}.zip" \
  -o "$TMP/loki.zip"
unzip -q "$TMP/loki.zip" -d "$TMP/loki"
sudo install -m755 "$TMP/loki/loki-linux-${ARCH}" /usr/local/bin/loki
sudo useradd --system --no-create-home --shell /usr/sbin/nologin loki 2>/dev/null || true

sudo mkdir -p /etc/loki /var/lib/loki/index /var/lib/loki/index_cache /var/lib/loki/chunks
sudo cp "$REPO/loki/loki.yml" /etc/loki/
sudo chown -R loki:loki /etc/loki /var/lib/loki

sudo cp "$REPO/systemd/loki.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now loki

# --- Promtail ---

curl -fsSL "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip" \
  -o "$TMP/promtail.zip"
unzip -q "$TMP/promtail.zip" -d "$TMP/promtail"
sudo install -m755 "$TMP/promtail/promtail-linux-${ARCH}" /usr/local/bin/promtail
sudo useradd --system --no-create-home --shell /usr/sbin/nologin promtail 2>/dev/null || true
sudo usermod -aG adm,systemd-journal promtail

sudo mkdir -p /etc/promtail /var/lib/promtail
sudo cp "$REPO/promtail/promtail.yml" /etc/promtail/
sudo chown -R promtail:promtail /etc/promtail /var/lib/promtail

sudo cp "$REPO/systemd/promtail.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now promtail

# --- Podsumowanie ---

echo ""
echo "=== Instalacja zakończona ==="
for svc in grafana-server prometheus alertmanager node_exporter loki promtail; do
  printf "  %-20s %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
done
echo ""
echo "Grafana: http://$(hostname -I | awk '{print $1}'):3000  (admin / admin)"
