# Monitoring Stack

> Production-ready observability для Linux-хоста и Docker-контейнеров.  
> Автоматизированный CI/CD, network segmentation, container hardening из коробки.

[![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat&logo=docker&logoColor=white)](https://www.docker.com/)
[![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=flat&logo=github-actions&logoColor=white)](https://github.com/features/actions)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat&logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=flat&logo=grafana&logoColor=white)](https://grafana.com/)

---

## Что внутри

- **Layered Compose** — core / monitoring / debug через override-файлы
- **Network isolation** — public (nginx + alertmanager egress) и internal (все сервисы)
- **15+ alert rules** — CPU, RAM, Disk, CrashLoop, ServiceDown → Telegram
- **Container hardening** — read_only, cap_drop: ALL, non-root users, secrets через файлы
- **CI validation** — все конфиги проверяются на PR до попадания на сервер
- **Smoke test** — трёхуровневая проверка доступности сервисов после каждого деплоя

## Требования

- Docker 27.0+ (рекомендуется 29.0+)
- Docker Compose v2.20+
- Git 2.30+

Проверено на Ubuntu 20.04 (Docker 28.1) и Ubuntu 24.04 (Docker 29.1).

## Стек

|                   | Технология         | Версия |
| ----------------- | ------------------ | ------ |
| Reverse proxy     | Nginx Alpine       | 1.25   |
| Metrics           | Prometheus         | 2.45   |
| Dashboards        | Grafana            | 10.2   |
| Host metrics      | Node Exporter      | 1.6    |
| Container metrics | cAdvisor (ghcr.io) | 0.56.2 |
| Alerting          | Alertmanager       | 0.31   |
| CI/CD             | GitHub Actions     | —      |

## Архитектура

```
Internet
    │
    ▼
┌──────────────────────────────────────────┐
│  public network                          │
│  ┌───────────────────────────────────┐   │
│  │  Nginx :80  (reverse proxy)       │   │
│  └──────────────┬────────────────────┘   │
│  ┌──────────────────────────────────┐    │
│  │  Alertmanager (egress only)      │    │
│  │  → api.telegram.org              │    │
│  └──────────────────────────────────┘    │
└──────────────────┬───────────────────────┘
                   │ proxy_pass
┌──────────────────▼───────────────────────┐
│  internal network  (no egress)           │
│                                          │
│  Prometheus   Grafana   Alertmanager     │
│  Node Exporter          cAdvisor         │
└──────────────────────────────────────────┘
```

Nginx — единственная точка входа. Prometheus и Alertmanager защищены Basic Auth.  
Alertmanager подключён к обеим сетям: internal для связи с Prometheus, public для исходящих запросов к Telegram API. Порты не публикуются — снаружи недоступен.

## Быстрый старт

```bash
git clone https://github.com/ivanserneev-max/monitoring.git && cd monitoring

# 1. Окружение
cp .env.example .env

# 2. Секреты
mkdir -p secrets
echo "your_postgres_password"   > secrets/postgres_password
echo "your_grafana_password"    > secrets/grafana_admin_password
echo "your_telegram_bot_token"  > secrets/telegram_token
echo "your_telegram_chat_id"    > secrets/telegram_chat_id

# Basic Auth для Prometheus и Alertmanager
docker run --rm httpd:alpine htpasswd -nbB admin your_basic_auth_pass > secrets/nginx_htpasswd
chmod 644 secrets/*

# 3. Запуск
docker compose -f compose.yml -f compose.monitoring.yml up -d
```

| Сервис          | URL                            | Доступ     |
| --------------- | ------------------------------ | ---------- |
| Главная         | http://localhost               | Открыт     |
| Grafana         | http://localhost/grafana/      | Открыт     |
| Prometheus      | http://localhost/prometheus/   | Basic Auth |
| Alertmanager    | http://localhost/alertmanager/ | Basic Auth |
| Adminer (debug) | http://localhost:8080          | Открыт     |

## Compose-профили

```bash
# Production (core + observability)
docker compose -f compose.yml -f compose.monitoring.yml up -d

# Разработка (+ PostgreSQL и Adminer)
docker compose -f compose.yml -f compose.monitoring.yml -f compose.debug.yml --profile debug up -d

# Только nginx
docker compose -f compose.yml up -d
```

Файлы используют паттерн **layered override**: каждый следующий файл расширяет предыдущий. `compose.monitoring.yml` и `compose.debug.yml` не предназначены для отдельного запуска.

## CI/CD

**ci-validate.yml** — запускается на каждый PR и push в master:

- валидирует все три compose-файла (config --quiet)
- проверяет prometheus.yml и alertmanager.yml (--config.check)
- проверяет nginx.conf (nginx -t)

**deploy.yml** — запускается при push в master:

- повторяет все проверки из ci-validate
- деплоит по SSH: git pull → запись секретов → генерация htpasswd → docker compose up
- проверяет healthcheck всех контейнеров
- выполняет трёхуровневый smoke test
- отправляет Telegram-уведомление с номером коммита

### Smoke test

После деплоя pipeline автоматически проверяет доступность всех эндпоинтов.  
Каждая проверка делает до 30 попыток с интервалом 2 секунды — это покрывает время старта сервисов.  
При получении 5xx деплой немедленно останавливается.

| Уровень      | Эндпоинт                         | Ожидаемый код |
| ------------ | -------------------------------- | ------------- |
| Nginx / Web  | `/`                              | 200           |
| Grafana      | `/grafana/`                      | 200, 301, 302 |
| Auth layer   | `/prometheus/`, `/alertmanager/` | 401           |
| Health check | `/prometheus/-/healthy`          | 200           |
| Health check | `/alertmanager/-/healthy`        | 200           |

### GitHub Secrets для деплоя

| Secret                   | Назначение                                   |
| ------------------------ | -------------------------------------------- |
| `SSH_HOST`               | IP production-сервера                        |
| `SSH_USER`               | SSH-пользователь                             |
| `SSH_PRIVATE_KEY`        | Приватный SSH-ключ                           |
| `POSTGRES_USER`          | Пользователь PostgreSQL                      |
| `POSTGRES_DB`            | База данных PostgreSQL                       |
| `POSTGRES_PASSWORD`      | Пароль PostgreSQL                            |
| `GRAFANA_ADMIN_USER`     | Логин Grafana                                |
| `GRAFANA_ADMIN_PASSWORD` | Пароль Grafana                               |
| `BASIC_AUTH_USER`        | Логин Basic Auth (Prometheus, Alertmanager)  |
| `BASIC_AUTH_PASS`        | Пароль Basic Auth (Prometheus, Alertmanager) |
| `TELEGRAM_BOT_TOKEN`     | Токен Telegram-бота                          |
| `TELEGRAM_CHAT_ID`       | ID чата для уведомлений                      |

> Basic Auth для Prometheus и Alertmanager хранится отдельно от Grafana-credentials.  
> Это позволяет менять пароли независимо и следует принципу разделения ответственности.

## Структура проекта

```
monitoring/
├── .github/workflows/
│   ├── ci-validate.yml       # Валидация конфигов на PR
│   └── deploy.yml            # Деплой на сервер
├── alertmanager/
│   └── alertmanager.yml
├── grafana/
│   ├── dashboards/           # cadvisor.json, node-exporter.json
│   └── provisioning/         # datasources, dashboards, alerting
├── nginx/
│   ├── html/index.html
│   └── nginx.conf
├── prometheus/
│   ├── alerts/
│   │   ├── container.yml     # CrashLoop, ContainerDown, cAdvisor
│   │   ├── host.yml          # CPU, RAM, Disk
│   │   └── service.yml       # ServiceDown
│   └── prometheus.yml
├── secrets.example/          # Структура секретов (пустые файлы)
├── .env.example
├── compose.yml               # Core: nginx
├── compose.monitoring.yml    # Overlay: observability стек
└── compose.debug.yml         # Overlay: PostgreSQL, Adminer
```

## Важные технические детали

**cAdvisor и Docker Compose labels**  
Используется ghcr.io/google/cadvisor:v0.56.2 с флагом --store_container_labels=true.  
Без этого флага cAdvisor не передаёт Docker Compose labels в Prometheus — алерты по container_label_com_docker_compose_service не работают. Флаг уже включён в compose.monitoring.yml.  
Версии cAdvisor ниже v0.51 несовместимы с ядром Linux 6.x (Ubuntu 24.04).

**Alertmanager и sub-path routing**  
При --web.route-prefix=/alertmanager/ необходимо указать в prometheus.yml:

- path_prefix: /alertmanager/ в секции alertmanagers
- metrics_path: /alertmanager/metrics для scrape job alertmanager

Без path_prefix Prometheus отправляет алерты на /api/v2/alerts, а alertmanager слушает на /alertmanager/api/v2/alerts — алерты теряются без ошибок.

**Alertmanager и egress из internal-сети**  
internal: true в Docker блокирует весь исходящий трафик, включая TCP — не только DNS. Добавление dns: не решает проблему. Решение: добавить alertmanager в public-сеть. Без опубликованных портов это безопасно.

**running ≠ healthy ≠ работает**  
Контейнер в статусе running и healthy не гарантирует что сервис отвечает на запросы.  
Smoke test проверяет реальную доступность через HTTP после каждого деплоя.

```
**Prometheus не видит alertmanager как target**
Проверьте path_prefix: /alertmanager/ и metrics_path: /alertmanager/metrics в prometheus.yml.
```

## Roadmap

- [ ] HTTPS через Let's Encrypt
- [ ] Terraform для provisioning VPS
- [ ] Ansible для настройки сервера с нуля
- [ ] Миграция на Kubernetes + Helm

---

```

```
