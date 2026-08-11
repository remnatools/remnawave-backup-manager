#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

REPO_URL="https://github.com/remnatools/remnawave-backup-manager.git"
INSTALL_DIR="${INSTALL_DIR:-/root/remnawave-backup-manager}"
LOG_FILE="/var/log/remnawave_backup.log"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     Remnawave Backup Manager — Install   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Docker
if ! command -v docker &>/dev/null; then
    info "Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
else
    info "Docker уже установлен"
fi

# Docker network
if ! docker network ls | grep -q remnawave-network; then
    info "Создаю Docker сеть remnawave-network..."
    docker network create remnawave-network
else
    info "Сеть remnawave-network уже существует"
fi

# Клонируем репо
if [ -d "$INSTALL_DIR" ]; then
    warn "Папка $INSTALL_DIR уже существует — обновляю..."
    cd "$INSTALL_DIR" && git pull
else
    info "Клонирую репо в $INSTALL_DIR..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# .env
if [ ! -f .env ]; then
    cp .env.example .env
    info "Создан .env из примера"

    echo ""
    warn "Задайте пароль для веб-интерфейса:"
    read -rp "  ADMIN_USER [admin]: " AU
    read -rsp "  ADMIN_PASS: " AP
    echo ""

    sed -i "s/^ADMIN_USER=.*/ADMIN_USER=${AU:-admin}/" .env
    sed -i "s/^ADMIN_PASS=.*/ADMIN_PASS=$AP/" .env
    info ".env настроен"
else
    warn ".env уже существует — не перезаписываю"
fi

# Лог файл
touch "$LOG_FILE"
info "Лог-файл создан: $LOG_FILE"

# Запуск
info "Собираю и запускаю контейнер..."
docker compose up -d --build

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  ✅  Backup Manager запущен!             ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Доступен на: http://YOUR_SERVER_IP:8090 ║"
echo "║  (настройте nginx + SSL для HTTPS)       ║"
echo "╚══════════════════════════════════════════╝"
echo ""
info "Документация: $INSTALL_DIR/README.md"
