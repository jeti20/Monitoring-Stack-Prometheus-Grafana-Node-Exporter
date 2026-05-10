# Monitoring Stack - Prometheus + Grafana + Node Exporter

## Stos

| Serwis | Port | Opis |
|---|---|---|
| node_exporter | 9100 | zbiera metryki systemu (CPU, RAM, dysk, sieć) |
| prometheus | 9090 | scrape metryk, przechowywanie TSDB |
| grafana | 3000 | wizualizacja |

---

## Uruchamianie

```bash
docker compose up -d
docker compose down
```

---

## Struktura projektu

```
.
├── docker-compose.yml
├── data/
│   ├── prometheus/    # dane TSDB Prometheusa (bind mount)
│   └── grafana/       # dashboardy i ustawienia Grafany (bind mount)
└── .gitignore         # folder data/ wykluczony z gita
```

---

## Persystencja danych (volumes)

Kontenery są efemeryczne - bez volumes dane znikają po restarcie. Używamy **bind mountów** (ścieżki względne), dzięki czemu dane lądują bezpośrednio w folderze projektu.

```yaml
volumes:
  - ./data/prometheus:/prometheus
  - ./data/grafana:/var/lib/grafana
```

Alternatywa: named volumes (`prometheus_data:/prometheus`) - Docker zarządza lokalizacją sam, dane lądują w:
- Windows: wewnątrz WSL2/Hyper-V VM (`\\wsl$\docker-desktop-data\data\docker\volumes\`)
- Linux: `/var/lib/docker/volumes/`

Bind mounty są czytelniejsze i łatwiejsze do backupu.

---

## Sieć między kontenerami

Docker Compose tworzy wspólną sieć dla wszystkich serwisów. Kontenery komunikują się przez **nazwę serwisu**, nie przez `localhost`.

```
# ŹLE - localhost to sam kontener Grafany
http://localhost:9090

# DOBRZE - Docker DNS rozwiązuje nazwę serwisu
http://prometheus:9090

# lub przez hostname jeśli ustawiony
http://prometheus.test:9090
```

Każdy kontener ma własny, izolowany stos sieciowy. `localhost` wewnątrz kontenera wskazuje na ten sam kontener.

---

## Jak Prometheus przechowuje dane (TSDB)

Prometheus używa własnej bazy szeregów czasowych (TSDB - Time Series Database). Dane w `./data/prometheus/`:

```
data/prometheus/
├── wal/               # Write-Ahead Log - świeże metryki trafiają tutaj
│   ├── 00000000
│   └── 00000001
├── lock               # plik blokady (jeden proces na raz)
├── queries.active     # aktualnie wykonywane zapytania
└── 01ABCDEF.../       # skompaktowane bloki historyczne (po ~2h)
```

**WAL (Write-Ahead Log):**
Wszystkie nowe metryki trafiają najpierw do WAL. Jest to bufor zapisu - szybki, append-only. Po około 2 godzinach Prometheus kompaktuje dane z WAL do bloków i czyści WAL.

**Bloki:**
Niezmienne, skompaktowane fragmenty danych historycznych. Pojawiają się dopiero po ~2 godzinach działania. `prometheus_tsdb_storage_blocks_bytes` pokazuje 0 dopóki pierwszy blok nie powstanie.

**Baza jest append-only** - nie edytujesz istniejących danych. Możesz tylko usuwać serie przez API:
```
POST http://localhost:9090/api/v1/admin/tsdb/delete_series?match[]=nazwa_metryki
```

---

## Seria vs metryka (Cardinality)

**Seria** = unikalna kombinacja nazwy metryki + wszystkich labelów:

```
node_cpu_seconds_total{cpu="0", mode="idle"}   # seria 1
node_cpu_seconds_total{cpu="0", mode="user"}   # seria 2
node_cpu_seconds_total{cpu="1", mode="idle"}   # seria 3
```

To są 3 serie tej samej metryki `node_cpu_seconds_total`.

**Cardinality** = łączna liczba unikalnych serii. Każda seria zajmuje RAM. Wysoka cardinality (miliony serii) to główna przyczyna problemów wydajnościowych Prometheusa.

Zły wzorzec (eksplodująca cardinality):
```
http_requests_total{user_id="12345"}  # każdy user = nowa seria
```

Dobry wzorzec:
```
http_requests_total{endpoint="/api", method="GET"}
```

---

## Retencja

Ustawiana flagą startową w `docker-compose.yml`:

```yaml
command:
  - '--config.file=/etc/prometheus/prometheus.yml'
  - '--storage.tsdb.retention.time=7d'
```

Domyślna retencja: 15 dni. Po upływie czasu stare bloki są automatycznie usuwane.

---

## Przydatne metryki w PromQL

```promql
# Rozmiar bazy (bloki)
prometheus_tsdb_storage_blocks_bytes

# Rozmiar WAL
prometheus_tsdb_wal_storage_size_bytes

# Aktualna liczba aktywnych serii
prometheus_tsdb_head_series

# Łącznie serii od startu (counter, tylko rośnie)
prometheus_tsdb_head_series_created_total

# Top 10 metryk z największą liczbą serii
topk(10, count by (__name__)({__name__=~".+"}))

# Status targetów
up
```

UI Prometheusa: `http://localhost:9090`
TSDB Status: `http://localhost:9090/tsdb-status`

---

## Node Exporter - co zbiera i gdzie

Node Exporter zbiera metryki systemu Linux przez wirtualne systemy plików:

```yaml
volumes:
  - /proc:/host/proc:ro   # procesy, CPU, pamięć
  - /sys:/host/sys:ro     # urządzenia, sieć
  - /:/rootfs:ro          # dyski
command:
  - '--path.procfs=/host/proc'
  - '--path.sysfs=/host/sys'
  - '--path.rootfs=/rootfs'
  - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
```

**Na serwerze Linux:** zbiera metryki prawdziwego hosta - działa natywnie.

**Na Windows z Docker Desktop:** zbiera metryki **maszyny wirtualnej** (WSL2 lub Hyper-V), nie samego Windowsa. Wynika to z architektury Docker na Windows:

```
┌─────────────────────────────────────────────────┐
│                  Windows 11                     │
│                                                 │
│  ┌──────────────────────────────────────────┐  │
│  │         Linux VM (WSL2 / Hyper-V)        │  │
│  │                                          │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ │  │
│  │  │  Grafana │ │Prometheus│ │  node    │ │  │
│  │  │ kontener │ │ kontener │ │ exporter │ │  │
│  │  └──────────┘ └──────────┘ └──────────┘ │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

Kontenery to technologia Linuxowa (`namespaces`, `cgroups`). Na Windows Docker Desktop uruchamia jedną ukrytą VM z Linuxem - wszystkie kontenery działają w tej jednej VM, nie bezpośrednio na Windows.

Do monitorowania hosta Windows potrzebny jest **windows_exporter**:
```powershell
winget install prometheus-community.windows_exporter
```

---

## Instalacja na serwerze Ubuntu

```bash
curl -fsSL https://get.docker.com | sh
docker --version
docker compose version
```

Na Linux nie ma pośredniej VM - Docker Engine działa bezpośrednio na jądrze hosta. Node Exporter zbiera wtedy prawdziwe metryki serwera.
