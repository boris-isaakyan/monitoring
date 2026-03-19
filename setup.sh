#!/bin/bash
# setup.sh — первый запуск monitoring stack
#
# Что делает скрипт:
#   1. Проверяет зависимости (Docker, Docker Compose)
#   2. Проверяет наличие .env
#   3. Проверяет наличие всех secrets/
#   4. Запускает docker compose up -d
#   5. Ожидает готовности сервисов
#   6. Выводит итоговые URLs

set -euo pipefail
# set -e  — остановка при любой ошибке
# set -u  — остановка при обращении к неопределённой переменной
# set -o pipefail — ошибка в пайпе не игнорируется

# Цвета для вывода 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color — сброс цвета

# Вспомогательные функции 
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

echo "   Monitoring Stack — Setup"

# ШАГ 1: Проверка Docker
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

# ШАГ 2: Проверка Docker Compose
if ! docker compose version &> /dev/null; then
    fail "Docker Compose (v2) не найден. Убедись что установлен Docker Desktop или плагин docker-compose-plugin."
fi

COMPOSE_VERSION=$(docker compose version --short)
ok "Docker Compose $COMPOSE_VERSION"

# ШАГ 3: Проверка .env
info "Проверка конфигурации..."

if [ ! -f ".env" ]; then
    warn ".env не найден. Создаю из .env.example..."
    if [ ! -f ".env.example" ]; then
        fail ".env.example тоже не найден. Склонируй репозиторий заново."
    fi
    cp .env.example .env
    fail "Заполни .env перед запуском:\n   nano .env\n   Затем запусти setup.sh снова."
fi

# Проверяем что обязательные переменные заполнены (не пустые и не содержат 'example')
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

# ШАГ 4: Проверка secrets/
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

# Проверяем права доступа на secrets/
SECRETS_PERMS=$(stat -c "%a" secrets/)
if [ "$SECRETS_PERMS" != "700" ] && [ "$SECRETS_PERMS" != "750" ] && [ "$SECRETS_PERMS" != "755" ]; then
    warn "Рекомендуется ограничить права на папку secrets/: chmod 700 secrets/"
fi

# Проверяем права на файлы секретов
for secret in "${REQUIRED_SECRETS[@]}"; do
    FILE_PERMS=$(stat -c "%a" "$secret")
    if [ "$FILE_PERMS" != "644" ]; then
        warn "$secret имеет права $FILE_PERMS. Исправляю на 644..."
        chmod 644 "$secret"
        ok "Права исправлены: $secret → 644"
        # 644 — контейнеры читают от своих пользователей (nobody, grafana и др.)
        # 600 не работает в Docker Compose — uid/gid/mode поддерживает только Swarm
    fi
done

ok "Все секреты найдены"

# ШАГ 5: Валидация docker-compose.yml
info "Валидация docker-compose.yml..."

if ! docker compose config --quiet 2>/dev/null; then
    fail "Ошибка в docker-compose.yml. Запусти 'docker compose config' для деталей."
fi
ok "docker-compose.yml синтаксически корректен"

# ШАГ 6: Запуск стека 
info "Запуск сервисов..."
echo ""

docker compose pull --quiet
docker compose up -d --remove-orphans

echo ""
info "Ожидание готовности сервисов (60 сек)..."
sleep 60

# ШАГ 7: Проверка статуса 
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

# ШАГ 8: Итоговые URLs 

# Определяем хост из .env или используем localhost
SERVER_HOST=$(grep "^SERVER_HOST=" .env 2>/dev/null | cut -d'=' -f2- | tr -d ' ')
if [ -z "$SERVER_HOST" ]; then
    SERVER_HOST="localhost"
fi


echo -e "${GREEN}   Stack is running! 🚀${NC}"
echo -e "  🌐 App:        http://${SERVER_HOST}"
echo -e "  📊 Grafana:    http://${SERVER_HOST}/grafana"
echo -e "  📈 Prometheus: http://${SERVER_HOST}/prometheus  (basic auth)"
echo -e "  Grafana логин: $(grep '^GRAFANA_ADMIN_USER=' .env | cut -d'=' -f2)"
echo -e "  Grafana пароль: из secrets/grafana_admin_password"
