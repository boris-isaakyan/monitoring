#!/bin/bash
# setup.sh — первый запуск monitoring stack
#
# Что делает скрипт:
#   1. Проверяет зависимости (Docker, Docker Compose)
#   2. Проверяет наличие .env
#   3. Определяет SERVER_HOST — спрашивает пользователя или автоопределяет
#   4. Проверяет наличие всех secrets/ и исправляет права
#   5. Валидирует docker-compose.yml
#   6. Запускает docker compose up -d
#   7. Ожидает готовности сервисов
#   8. Выводит итоговые URLs

set -euo pipefail
# set -e        — остановка при любой ошибке
# set -u        — остановка при обращении к неопределённой переменной
# set -o pipefail — ошибка в пайпе не игнорируется

# ─── Цвета для вывода ────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color — сброс цвета

# ─── Вспомогательные функции ─────────────────────────────────────
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

echo ""
echo "=================================================="
echo "   DevOps Monitoring Stack — Setup"
echo "=================================================="
echo ""

# ─── ШАГ 1: Проверка Docker ──────────────────────────────────────
info "Проверка зависимостей..."

if ! command -v docker &> /dev/null; then
    fail "Docker не найден. Установи Docker: https://docs.docker.com/engine/install/"
fi

DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+' | head -1)
DOCKER_MAJOR=$(echo "$DOCKER_VERSION" | cut -d. -f1)

if [ "$DOCKER_MAJOR" -lt 24 ]; then
    fail "Требуется Docker >= 24.0. Установлена версия: $DOCKER_VERSION"
fi
ok "Docker $DOCKER_VERSION"

# ─── ШАГ 2: Проверка Docker Compose ─────────────────────────────
if ! docker compose version &> /dev/null; then
    fail "Docker Compose (v2) не найден. Установи плагин docker-compose-plugin."
fi

COMPOSE_VERSION=$(docker compose version --short)
ok "Docker Compose $COMPOSE_VERSION"

# ─── ШАГ 3: Проверка .env ────────────────────────────────────────
info "Проверка конфигурации..."

if [ ! -f ".env" ]; then
    warn ".env не найден. Создаю из .env.example..."
    if [ ! -f ".env.example" ]; then
        fail ".env.example не найден. Склонируй репозиторий заново."
    fi
    cp .env.example .env
    fail "Заполни .env перед запуском:\n   nano .env\n   Затем запусти setup.sh снова."
fi

# Проверяем обязательные переменные — не пустые и не содержат плейсхолдеры
check_env_var() {
    local var_name=$1
    local var_value
    var_value=$(grep "^${var_name}=" .env | cut -d'=' -f2- | tr -d ' ')

    if [ -z "$var_value" ]; then
        fail "Переменная ${var_name} не заполнена в .env"
    fi

    if echo "$var_value" | grep -qi "example\|your_\|changeme\|replace"; then
        fail "Переменная ${var_name} содержит placeholder-значение. Замени на реальное."
    fi
}

check_env_var "POSTGRES_USER"
check_env_var "POSTGRES_DB"
check_env_var "GRAFANA_ADMIN_USER"
ok ".env заполнен корректно"

# ─── ШАГ 4: Определение SERVER_HOST ──────────────────────────────
# Порядок приоритетов:
#   1. SERVER_HOST уже задан в .env и не содержит плейсхолдер → используем
#   2. Спрашиваем пользователя — он может ввести IP/домен или нажать Enter
#   3. Пользователь нажал Enter → автоопределяем через hostname -I
#
# Важно: этот шаг выполняется ДО запуска сервисов и ДО вывода URLs,
# чтобы пользователь увидел корректные ссылки в конце скрипта.

SERVER_HOST=$(grep "^SERVER_HOST=" .env 2>/dev/null | cut -d'=' -f2- | tr -d ' ')

if [ -z "$SERVER_HOST" ] || echo "$SERVER_HOST" | grep -qi "your_\|example"; then

    # Определяем IP автоматически как подсказку пользователю
    AUTO_IP=$(hostname -I | awk '{print $1}')
    [ -z "$AUTO_IP" ] && AUTO_IP="localhost"

    echo ""
    echo -e "${BLUE}ℹ️  Укажи IP-адрес или домен сервера для формирования ссылок.${NC}"
    echo -e "   Примеры: 192.168.1.100 | 88.218.67.44 | monitoring.example.com"
    echo -e "   Нажми ${GREEN}Enter${NC} для автоопределения: ${GREEN}${AUTO_IP}${NC}"
    echo -n "   SERVER_HOST [${AUTO_IP}]: "

    # read -r  — читаем ввод без интерпретации спецсимволов (\n, \t и др.)
    # -t 30    — таймаут 30 секунд для неинтерактивного режима (CI/CD, ssh-скрипты)
    #            после таймаута скрипт продолжает с автоопределённым IP
    read -r -t 30 USER_INPUT || true

    echo ""

    if [ -z "$USER_INPUT" ]; then
        SERVER_HOST="$AUTO_IP"
        info "Используется автоопределённый адрес: $SERVER_HOST"
    else
        SERVER_HOST="$USER_INPUT"
        info "Используется введённый адрес: $SERVER_HOST"
    fi

    # Сохраняем в .env — при следующем запуске скрипт не будет спрашивать снова
    if grep -q "^SERVER_HOST=" .env; then
        sed -i "s/^SERVER_HOST=.*/SERVER_HOST=${SERVER_HOST}/" .env
    else
        echo "SERVER_HOST=${SERVER_HOST}" >> .env
    fi

    ok "SERVER_HOST сохранён в .env: $SERVER_HOST"

else
    ok "SERVER_HOST: $SERVER_HOST"
fi

# ─── ШАГ 5: Проверка secrets/ ────────────────────────────────────
info "Проверка секретов..."

REQUIRED_SECRETS=(
    "secrets/postgres_password"
    "secrets/grafana_admin_password"
    "secrets/telegram_token"
    "secrets/telegram_chat_id"
    "secrets/nginx_htpasswd"
)

for secret in "${REQUIRED_SECRETS[@]}"; do
    if [ ! -f "$secret" ]; then
        fail "Файл секрета не найден: $secret\n   См. README раздел 'Быстрый старт'"
    fi

    if [ ! -s "$secret" ]; then
        fail "Файл секрета пустой: $secret"
    fi
done

# Права на папку secrets/ — закрыта для всех кроме владельца
SECRETS_PERMS=$(stat -c "%a" secrets/)
if [ "$SECRETS_PERMS" != "700" ]; then
    warn "Устанавливаю права 700 на папку secrets/..."
    chmod 700 secrets/
    ok "Права папки secrets/ → 700"
fi

# Права на файлы секретов — 644
# Контейнеры запущены от разных пользователей (nobody/65534, grafana/472, postgres/70)
# 644 позволяет им читать файлы. 600 не работает в Docker Compose —
# uid/gid/mode для secrets поддерживается только в Docker Swarm
for secret in "${REQUIRED_SECRETS[@]}"; do
    FILE_PERMS=$(stat -c "%a" "$secret")
    if [ "$FILE_PERMS" != "644" ]; then
        warn "$secret имеет права $FILE_PERMS. Исправляю на 644..."
        chmod 644 "$secret"
        ok "Права исправлены: $secret → 644"
    fi
done

ok "Все секреты найдены"

# ─── ШАГ 6: Валидация docker-compose.yml ─────────────────────────
info "Валидация docker-compose.yml..."

if ! docker compose config --quiet 2>/dev/null; then
    fail "Ошибка в docker-compose.yml. Запусти 'docker compose config' для деталей."
fi
ok "docker-compose.yml синтаксически корректен"

# ─── ШАГ 7: Запуск стека ─────────────────────────────────────────
info "Запуск сервисов..."
echo ""

docker compose pull --quiet
docker compose up -d --remove-orphans

echo ""
info "Ожидание готовности сервисов (60 сек)..."
sleep 60

# ─── ШАГ 8: Проверка статуса ─────────────────────────────────────
echo ""
info "Проверка статуса контейнеров..."
echo ""

UNHEALTHY=$(docker compose ps --format json 2>/dev/null \
    | grep -c '"Health":"unhealthy"' || true)

if [ "$UNHEALTHY" -gt 0 ]; then
    echo ""
    docker compose ps
    echo ""
    warn "Есть unhealthy контейнеры. Проверь логи:"
    warn "  docker compose logs <service_name>"
    warn "  docker inspect <container> --format='{{json .State.Health}}' | jq"
    echo ""
    exit 1
fi

docker compose ps

# ─── ШАГ 9: Итоговые URLs ────────────────────────────────────────
# SERVER_HOST определён в Шаге 4 — используем напрямую без повторного чтения
echo ""
echo "=================================================="
echo -e "${GREEN}   Stack is running! 🚀${NC}"
echo "=================================================="
echo ""
echo -e "  🌐 App:        http://${SERVER_HOST}/"
echo -e "  📊 Grafana:    http://${SERVER_HOST}/grafana"
echo -e "  📈 Prometheus: http://${SERVER_HOST}/prometheus  (basic auth)"
echo ""
echo -e "  Grafana логин:  $(grep '^GRAFANA_ADMIN_USER=' .env | cut -d'=' -f2)"
echo -e "  Grafana пароль: из secrets/grafana_admin_password"
echo ""
echo "=================================================="
echo ""