#!/usr/bin/env bash
# Instaluje stos monitoringu jako natywne serwisy systemd na Ubuntu 22.04/24.04.
# Uruchom z katalogu repozytorium jako użytkownik z sudo.

set -euo pipefail  # -e: przerwij przy błędzie, -u: błąd przy niezdefiniowanej zmiennej, -o pipefail: błąd w pipeline zatrzymuje skrypt

# Wersje instalowanych komponentów — zmień tutaj żeby zaktualizować
PROMETHEUS_VERSION="3.4.0"
ALERTMANAGER_VERSION="0.28.1"
NODE_EXPORTER_VERSION="1.9.1"
LOKI_VERSION="3.5.0"
PROMTAIL_VERSION="3.5.0"

# Wykrywa architekturę CPU i tłumaczy na nazwy używane w archiwach z GitHub (amd64/arm64)
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
# Ścieżka do katalogu głównego repozytorium — działa niezależnie skąd uruchomiono skrypt
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Tymczasowy katalog na pobrane archiwa — usuwany automatycznie po zakończeniu skryptu
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT  # gwarantuje usunięcie TMP nawet przy błędzie

# ---------------------------------------------------------------------------
# Grafana — instalacja przez oficjalne repozytorium apt
# ---------------------------------------------------------------------------

# Instaluje narzędzia potrzebne do dodania zewnętrznego repo apt
sudo apt-get install -y apt-transport-https wget unzip
# Tworzy katalog na klucze GPG zewnętrznych repozytoriów
sudo mkdir -p /etc/apt/keyrings
# Pobiera klucz GPG Grafany i zapisuje w formacie binarnym (dearmor) wymaganym przez apt
wget -q -O - https://apt.grafana.com/gpg.key \
  | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg >/dev/null
# Dodaje repozytorium Grafany do listy źródeł apt
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update -q        # odświeża listę pakietów (w tym nowe repo Grafany)
sudo apt-get install -y grafana  # instaluje Grafanę

# Tworzy katalogi na pliki provisioningu (datasources i dashboardy)
sudo mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
# Kopiuje konfigurację datasources (Prometheus + Loki)
sudo cp "$REPO/grafana/provisioning/datasources/prometheus.yml" /etc/grafana/provisioning/datasources/
# Kopiuje definicję folderu dashboardów (wskazuje gdzie Grafana ma szukać plików JSON)
sudo cp "$REPO/grafana/provisioning/dashboards/dashboard.yml"   /etc/grafana/provisioning/dashboards/
# Kopiuje wszystkie dashboardy JSON (Node Exporter Full, Loki Logs)
sudo cp "$REPO/grafana/provisioning/dashboards/"*.json          /etc/grafana/provisioning/dashboards/
# Ustawia właściciela plików provisioningu na użytkownika grafana
sudo chown -R grafana:grafana /etc/grafana/provisioning
# Włącza Grafanę jako serwis systemd i natychmiast ją startuje
sudo systemctl enable --now grafana-server

# ---------------------------------------------------------------------------
# Node Exporter — eksporter metryk systemowych (/proc, /sys)
# ---------------------------------------------------------------------------

# Pobiera archiwum i od razu rozpakowuje do katalogu tymczasowego (bez zapisywania .tar.gz)
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
  | tar -xz -C "$TMP"
# Kopiuje binarkę do /usr/local/bin z uprawnieniami 755
sudo install -m755 "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
# Tworzy użytkownika systemowego bez powłoki i bez katalogu domowego; || true ignoruje błąd jeśli user już istnieje
sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true
# Instaluje unit systemd
sudo cp "$REPO/systemd/node_exporter.service" /etc/systemd/system/
sudo systemctl daemon-reload           # przeładowuje listę unitów po dodaniu nowego pliku
sudo systemctl enable --now node_exporter  # włącza autostart i startuje serwis

# ---------------------------------------------------------------------------
# Prometheus — silnik zbierania i przechowywania metryk
# ---------------------------------------------------------------------------

curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}.tar.gz" \
  | tar -xz -C "$TMP"
# Skrót do katalogu z rozpakowanym archiwum
PROM_DIR="$TMP/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}"
# Instaluje główną binarkę (prometheus) i narzędzie CLI (promtool)
sudo install -m755 "$PROM_DIR/prometheus" "$PROM_DIR/promtool" /usr/local/bin/
sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus 2>/dev/null || true

# Tworzy katalogi na konfigurację, reguły alertów i szablony konsoli webowej
sudo mkdir -p /etc/prometheus/rules /etc/prometheus/consoles /etc/prometheus/console_libraries
sudo cp "$REPO/Prometheus/prometheus.yml"  /etc/prometheus/              # główna konfiguracja
sudo cp "$REPO/Prometheus/rules/"*.yml     /etc/prometheus/rules/        # reguły alertów
sudo cp -r "$PROM_DIR/consoles/."          /etc/prometheus/consoles/     # szablony HTML konsoli
sudo cp -r "$PROM_DIR/console_libraries/." /etc/prometheus/console_libraries/  # biblioteki JS konsoli
# Przekazuje własność całego /etc/prometheus użytkownikowi prometheus
sudo chown -R prometheus:prometheus /etc/prometheus

# Tworzy katalog na dane TSDB (szeregi czasowe metryk)
sudo mkdir -p /var/lib/prometheus
sudo chown prometheus:prometheus /var/lib/prometheus

sudo cp "$REPO/systemd/prometheus.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus

# ---------------------------------------------------------------------------
# Alertmanager — obsługa i routing alertów (tutaj: wysyłka emailem przez Gmail)
# ---------------------------------------------------------------------------

curl -fsSL "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}.tar.gz" \
  | tar -xz -C "$TMP"
AM_DIR="$TMP/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}"
# Instaluje alertmanager i amtool (CLI do zarządzania alertami)
sudo install -m755 "$AM_DIR/alertmanager" "$AM_DIR/amtool" /usr/local/bin/
sudo useradd --system --no-create-home --shell /usr/sbin/nologin alertmanager 2>/dev/null || true

sudo mkdir -p /etc/alertmanager/secrets  # osobny katalog na sekrety (hasło Gmail)
sudo cp "$REPO/alertmanager/alertmanager.yml" /etc/alertmanager/
# Kopiuje hasło Gmail tylko jeśli plik istnieje — jest w .gitignore i nie trafia do repo
if [[ -f "$REPO/alertmanager/secrets/gmail_password" ]]; then
  sudo cp "$REPO/alertmanager/secrets/gmail_password" /etc/alertmanager/secrets/
  sudo chmod 600 /etc/alertmanager/secrets/gmail_password  # tylko właściciel może czytać
else
  echo "UWAGA: brak alertmanager/secrets/gmail_password — uzupełnij ręcznie i zrestartuj alertmanager"
fi
sudo chown -R alertmanager:alertmanager /etc/alertmanager

# Katalog na stan Alertmanagera (wyciszenia, aktywne alerty)
sudo mkdir -p /var/lib/alertmanager
sudo chown alertmanager:alertmanager /var/lib/alertmanager

sudo cp "$REPO/systemd/alertmanager.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now alertmanager

# ---------------------------------------------------------------------------
# Loki — silnik przechowywania logów
# ---------------------------------------------------------------------------

# Loki i Promtail są dystrybuowane jako .zip, nie .tar.gz
curl -fsSL "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-${ARCH}.zip" \
  -o "$TMP/loki.zip"
unzip -q "$TMP/loki.zip" -d "$TMP/loki"  # -q: cichy tryb bez wypisywania nazw plików
sudo install -m755 "$TMP/loki/loki-linux-${ARCH}" /usr/local/bin/loki
sudo useradd --system --no-create-home --shell /usr/sbin/nologin loki 2>/dev/null || true

# Tworzy katalogi na indeks, cache indeksu i skompresowane bloki logów (chunks)
sudo mkdir -p /etc/loki /var/lib/loki/index /var/lib/loki/index_cache /var/lib/loki/chunks
sudo cp "$REPO/loki/loki.yml" /etc/loki/
sudo chown -R loki:loki /etc/loki /var/lib/loki

sudo cp "$REPO/systemd/loki.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now loki

# ---------------------------------------------------------------------------
# Promtail — agent zbierający logi i wysyłający je do Loki
# ---------------------------------------------------------------------------

curl -fsSL "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip" \
  -o "$TMP/promtail.zip"
unzip -q "$TMP/promtail.zip" -d "$TMP/promtail"
sudo install -m755 "$TMP/promtail/promtail-linux-${ARCH}" /usr/local/bin/promtail
sudo useradd --system --no-create-home --shell /usr/sbin/nologin promtail 2>/dev/null || true
# adm: dostęp do /var/log; systemd-journal: dostęp do logów journald
sudo usermod -aG adm,systemd-journal promtail

sudo mkdir -p /etc/promtail /var/lib/promtail  # /var/lib/promtail przechowuje plik pozycji (positions.yaml)
sudo cp "$REPO/promtail/promtail.yml" /etc/promtail/
sudo chown -R promtail:promtail /etc/promtail /var/lib/promtail

sudo cp "$REPO/systemd/promtail.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now promtail

# ---------------------------------------------------------------------------
# Podsumowanie
# ---------------------------------------------------------------------------

echo ""
echo "=== Instalacja zakończona ==="
# Wypisuje status każdego serwisu (active/inactive/failed)
for svc in grafana-server prometheus alertmanager node_exporter loki promtail; do
  printf "  %-20s %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
done
echo ""
# Pobiera pierwszy adres IP interfejsu sieciowego i wypisuje URL Grafany
echo "Grafana: http://$(hostname -I | awk '{print $1}'):3000  (admin / admin)"
