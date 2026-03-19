# DevOps Monitoring Stack

Production-ready мониторинг для Linux-хоста и Docker-контейнеров.
Разверни полный observability-стек одной командой — метрики, дашборды и Telegram-алерты из коробки.

**Tech Stack:**
`Docker Compose` · `Prometheus` · `Grafana` · `Alertmanager` · `Nginx` · `PostgreSQL` · `Node Exporter` · `cAdvisor` · `GitHub Actions`

---

📋 Prerequisites

- Docker >= 24.0 + Docker Compose >= 2.20
- Linux-хост (VPS или локальная машина)
- Открыт только порт *80* (остальные сервисы доступны через Nginx reverse proxy)
- Telegram Bot Token → [@BotFather](https://t.me/BotFather)
- Telegram Chat ID → [@userinfobot](https://t.me/userinfobot)

---

🚀 Быстрый старт

Шаг 1 — Клонируй репозиторий

git clone https://github.com/ivanserneev-max/web-app.git
cd web-app

Шаг 2 — Заполни переменные окружения

cp .env.example .env
nano .env

Обязательно укажи `SERVER_HOST` — IP или домен твоего сервера:

SERVER_HOST=your_server_ip   # например: 192.168.1.100 или monitoring.example.com
Локально: SERVER_HOST=localhost

Шаг 3 — Создай секреты


mkdir -p secrets

echo "your_postgres_password"   > secrets/postgres_password
echo "your_grafana_password"    > secrets/grafana_admin_password
echo "your_telegram_bot_token"  > secrets/telegram_token
echo "your_telegram_chat_id"    > secrets/telegram_chat_id

# Пароль для доступа к Prometheus через браузер (basic auth)
# Требует Docker — ничего дополнительно устанавливать не нужно
docker run --rm httpd:alpine htpasswd -nbB admin your_prometheus_password \
  > secrets/nginx_htpasswd

# Права на файлы
chmod 644 secrets/*   # контейнеры читают от своих пользователей
chmod 700 secrets/    # папка закрыта снаружи

Шаг 4 — Запусти стек

chmod +x setup.sh
./setup.sh

Скрипт проверит зависимости, секреты, запустит все сервисы и выведет итоговые URLs.

Доступ

| Сервис     | URL                                            |
|------------|------------------------------------------------|
| Приложение | `http://<SERVER_HOST>/`                        |
| Grafana    | `http://<SERVER_HOST>/grafana`                 |
| Prometheus | `http://<SERVER_HOST>/prometheus` (basic auth) |


# Debug-режим — запуск с Adminer (веб-интерфейс для PostgreSQL)
docker compose --profile debug up -d
# Adminer доступен через SSH-туннель: ssh -L 8080:localhost:8080 user@server



🔧 Настройка под себя

| Что              | Где                             | Описание                                     |
|------------------|---------------------------------|----------------------------------------------|
| Пороги алертов   | `prometheus/alerts.yml`         | warning >80%, critical >95% для CPU/RAM/Disk |
| Retention метрик | `prometheus/prometheus.yml`     | По умолчанию 15 дней                         |
| Интервал сбора   | `prometheus/prometheus.yml`     | По умолчанию каждые 30s                      |
| Порты сервисов   | `.env`                          | Изменить если порты заняты                   |
| Telegram         | `secrets/telegram_*`            | Токен бота и Chat ID                         |
| Повтор алертов   | `alertmanager/alertmanager.yml` | critical: 1h, monitoring: 30m, default: 4h   |



🏗️ Архитектура


Интернет
    │
    ▼
 :80 (единственный открытый порт)
    │
  Nginx — reverse proxy
    ├── /              → статика
    ├── /grafana/      → grafana:3000     (авторизация Grafana)
    └── /prometheus/   → prometheus:9090  (basic auth)

Изолированы от интернета (internal: true):
    prometheus, grafana, node-exporter, cadvisor, alertmanager*, postgres

* alertmanager имеет исходящий доступ в интернет для отправки в Telegram


Сетевая сегментация:

frontend  — nginx, alertmanager          (есть выход в интернет)
backend   — postgres                     (internal: true, изолирован)
monitoring — все сервисы мониторинга     (internal: true, изолирован)


DNS внутри Docker:** nginx использует `resolver 127.0.0.11` — резолвинг имён контейнеров происходит в момент запроса, а не при старте. Это позволяет nginx стартовать независимо от порядка запуска сервисов.


⚙️ CI/CD Pipeline

При пуше в ветку `master/main` автоматически запускается GitHub Actions:

1. Validate — проверка синтаксиса `docker-compose.yml` с заглушками
2. Deploy via SSH — деплой на сервер:
   - `git pull` → запись секретов из GitHub Secrets → генерация `.env`
   - `docker compose pull` → `docker compose up -d --remove-orphans`
   - Ожидание 60s → проверка healthchecks → `docker image prune`

Секреты передаются как переменные окружения SSH-сессии — не попадают в логи Actions.

Необходимые GitHub Secrets

| Secret                   | Описание                      |
|--------------------------|-------------------------------|
| `SSH_HOST`               | IP сервера                    |
| `SSH_USER`               | Пользователь SSH (не root)    |
| `SSH_PRIVATE_KEY`        | Приватный SSH-ключ            |
| `POSTGRES_USER`          | Имя пользователя PostgreSQL   |
| `POSTGRES_DB`            | Имя базы данных               |
| `POSTGRES_PASSWORD`      | Пароль PostgreSQL             |
| `GRAFANA_ADMIN_USER`     | Логин администратора Grafana  |
| `GRAFANA_ADMIN_PASSWORD` | Пароль администратора Grafana |
| `TELEGRAM_BOT_TOKEN`     | Токен Telegram-бота           |
| `TELEGRAM_CHAT_ID`       | ID чата для алертов           |

После деплоя не забудь вручную создать `secrets/nginx_htpasswd` на сервере (см. Шаг 3).


📊 Мониторинг и Alerting

Сбор метрик: Node Exporter (хост) + cAdvisor (контейнеры), scrape каждые 30s

Alert rules — 15 правил в 3 группах:**

| Группа             | Алерты                                                                                                     |
|--------------------|------------------------------------------------------------------------------------------------------------|
| `node_alerts`      | HighCPU/Critical (>80/95%), HighMemory/Critical, HighDisk/Critical (>80/95%), HighSystemLoad               |
| `container_alerts` | ContainerHighCPU, ContainerHighMemory, ContainerRestarted, ContainerCrashLoop, ContainerDown, CAdvisorDown |
| `service_alerts`   | ServiceDown (все Prometheus targets)                                                                       |

Alertmanager:
- Маршрутизация по `severity` + `component`
- Inhibit rules — critical подавляет warning для того же компонента
- Telegram-уведомления с именем контейнера, хостом и временем события
- Мгновенные алерты для `component: monitoring`, повтор каждые 30 минут

Grafana — дашборды подключаются автоматически через provisioning при старте:
- Node Exporter Full (метрики хоста)
- cAdvisor (метрики контейнеров)


🔐 Безопасность

- Секреты в `secrets/` — не в Git, папка закрыта `chmod 700`
- Файлы секретов монтируются в контейнеры через volumes (`chmod 644`) — Docker Compose не поддерживает `uid/gid/mode` для secrets (только Docker Swarm)
- `no-new-privileges: true` + `cap_drop: ALL` + минимальный `cap_add` для всех сервисов
- `read_only: true` + `tmpfs` для временных файлов
- `internal: true` для сетей backend и monitoring
- Единственная точка входа — Nginx на порту 80
- basic auth на `/prometheus/` — Prometheus не имеет встроенной аутентификации
- Grafana — собственная аутентификация, проверка обновлений отключена
- Resource reservations на все контейнеры

⚠️ Текущая версия использует HTTP. Для production с реальными данными рекомендуется добавить домен и HTTPS (см. Roadmap v3.0).



🛠️ Troubleshooting

Grafana недоступна (`502 Bad Gateway`)

# Убедись что контейнер grafana запущен
docker compose ps | grep grafana
# Если отсутствует — запусти
docker compose up -d grafana


Prometheus: ошибка 500 при входе

# Проверь что nginx применил актуальный конфиг
docker exec webapp_nginx nginx -T | grep "location /prometheus"
# Проверь логи nginx
docker exec webapp_nginx cat /var/log/nginx/error.log
```

Алерты не приходят в Telegram

Проверь что файлы читаемы изнутри контейнера
docker exec webapp_alertmanager cat /run/secrets/telegram_token
docker compose logs alertmanager | grep -i "error\|permission"


Grafana: метрики не отображаются (`Status: 500`)**

Проверь datasource — URL должен быть с /prometheus
cat grafana/provisioning/datasources/*.yml | grep url
Должно быть: url: http://prometheus:9090/prometheus

Проверь targets в Prometheus
http://<SERVER_HOST>/prometheus/targets — все должны быть UP


Контейнер в статусе `unhealthy`**

docker inspect <container_name> --format='{{json .State.Health}}' | jq
docker compose logs <service_name> --tail=30


Доступ к внутренним сервисам (Alertmanager, Adminer) через SSH-туннель**

ssh -L 9093:localhost:9093 -L 8080:localhost:8080 user@your_server
Затем в браузере: http://localhost:9093 (Alertmanager)


📁 Структура проекта


├── .github/workflows/deploy.yml      # CI/CD pipeline
├── alertmanager/
│   └── alertmanager.yml              # Маршрутизация алертов, Telegram
├── grafana/
│   ├── dashboards/
│   │   ├── cadvisor.json             # Dashboard контейнеров
│   │   └── node-exporter.json        # Dashboard хоста
│   └── provisioning/                 # Автонастройка при старте контейнера
│       ├── dashboards/
│       └── datasources/
├── nginx/
│   ├── html/index.html
│   └── nginx.conf                    # Reverse proxy: /grafana, /prometheus
├── postgres/init/                    # Инициализация БД
├── prometheus/
│   ├── prometheus.yml                # Scrape configs
│   └── alerts.yml                    # 15 alert rules
├── secrets/                          # Runtime-секреты (не в Git)
├── secrets.example/                  # Шаблоны для onboarding
├── .env.example                      # Все переменные с описанием
├── .gitignore
├── setup.sh                          # Скрипт первого запуска
└── docker-compose.yml                # 8 сервисов, YAML anchors, 3 сети, 4 volume
```

---

 🎯 Roadmap

- v2.1 — Loki + Promtail (централизованные логи)
- v3.0 — HTTPS + Let's Encrypt (требует домен)
- v4.0 — Terraform + Ansible (IaC)
- v5.0 — Kubernetes + Helm + ArgoCD



> Проект создан в рамках изучения DevOps-практик: контейнеризация, автоматизация деплоя, observability и управление инфраструктурой.
