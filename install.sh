#!/bin/bash
set -e

# Проверка интерактивного режима — curl | bash не поддерживает ввод с клавиатуры
if [ ! -t 0 ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Скрипт требует интерактивного режима.                      ║"
    echo "║  Запустите так:                                             ║"
    echo "║                                                              ║"
    echo "║  curl -fsSL https://raw.githubusercontent.com/remnatools/  ║"
    echo "║    remnawave-backup-manager/main/install.sh -o install.sh   ║"
    echo "║  chmod +x install.sh && ./install.sh                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
prompt()  { echo -e "${CYAN}[?]${NC} $1"; }

REPO_URL="https://github.com/remnatools/remnawave-backup-manager.git"
INSTALL_DIR="${INSTALL_DIR:-/root/remnawave-backup-manager}"
LOG_FILE="${LOG_FILE:-/var/log/remnawave_backup.log}"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     Remnawave Backup Manager — Installer     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── 1. Docker ─────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
    info "Docker установлен"
else
    info "Docker уже установлен: $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

# ── 2. acme.sh ────────────────────────────────────────────────────────────────
if [ ! -f ~/.acme.sh/acme.sh ]; then
    info "Устанавливаю acme.sh..."
    echo ""
    DEFAULT_EMAIL="admin@gmail.com"
    prompt "Email для регистрации SSL сертификатов (Let\'s Encrypt) [по умолчанию: $DEFAULT_EMAIL]:"
    read -rp "  Подтвердить? [Y/n]: " CONFIRM_EMAIL
    if [[ "$CONFIRM_EMAIL" =~ ^[Nn]$ ]]; then
        read -rp "  Введите email: " ACME_EMAIL
        [ -z "$ACME_EMAIL" ] && ACME_EMAIL="$DEFAULT_EMAIL"
    else
        ACME_EMAIL="$DEFAULT_EMAIL"
        info "Используется email: $ACME_EMAIL"
    fi
    curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
    source ~/.bashrc 2>/dev/null || true
    info "acme.sh установлен"
else
    info "acme.sh уже установлен"
fi
ACME="$HOME/.acme.sh/acme.sh"

# ── 3. Docker network ─────────────────────────────────────────────────────────
if ! docker network ls | grep -q remnawave-network; then
    docker network create remnawave-network
    info "Создана Docker сеть remnawave-network"
else
    info "Сеть remnawave-network уже существует"
fi

# ── 4. Клонирование репо ──────────────────────────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
    warn "Папка $INSTALL_DIR уже существует — обновляю..."
    cd "$INSTALL_DIR" && git pull
else
    info "Клонирую репо в $INSTALL_DIR..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

# ── 5. .env — всегда пересоздаём ─────────────────────────────────────────────
cp .env.example .env
echo ""
prompt "Задайте учётные данные для входа в веб-интерфейс:"
read -rp "  ADMIN_USER [admin]: " AU
while true; do
    read -rsp "  ADMIN_PASS: " AP; echo ""
    read -rsp "  ADMIN_PASS (повтор): " AP2; echo ""
    [ "$AP" = "$AP2" ] && break
    warn "Пароли не совпадают, попробуйте снова"
done
sed -i "s/^ADMIN_USER=.*/ADMIN_USER=${AU:-admin}/" .env
sed -i "s/^ADMIN_PASS=.*/ADMIN_PASS=$AP/" .env
info ".env настроен"

# ── 6. SSL сертификат ─────────────────────────────────────────────────────────
echo ""
prompt "Введите домен для Backup Manager (например: backup.your-domain.com):"
read -rp "  Домен: " DOMAIN
[ -z "$DOMAIN" ] && error "Домен не может быть пустым"

SSL_DIR="$INSTALL_DIR/app/ssl"
CERT_FILE="$SSL_DIR/fullchain.pem"
KEY_FILE="$SSL_DIR/privkey.key"
mkdir -p "$SSL_DIR"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    warn "Сертификат уже существует: $SSL_DIR"
    read -rp "  Перевыпустить? [y/N]: " REISSUE
    if [[ "$REISSUE" =~ ^[Yy]$ ]]; then
        ISSUE_CERT=true
    else
        info "Используется существующий сертификат"
        ISSUE_CERT=false
    fi
else
    ISSUE_CERT=true
fi

if [ "$ISSUE_CERT" = true ]; then
    # Проверка порта 80
    echo ""
    info "Проверяю порт 80..."
    PORT80_PID=$(ss -tlnp | grep ':80 ' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    PORT80_NAME=$([ -n "$PORT80_PID" ] && cat /proc/$PORT80_PID/comm 2>/dev/null || true)

    if [ -n "$PORT80_PID" ]; then
        warn "Порт 80 занят: $PORT80_NAME (PID $PORT80_PID)"
        echo ""
        echo "  [1] Остановить автоматически"
        echo "  [2] Я остановлю вручную (скрипт подождёт)"
        read -rp "  Выбор [1/2]: " CHOICE80

        if [ "$CHOICE80" = "1" ]; then
            kill "$PORT80_PID" 2>/dev/null \
                && info "Процесс $PORT80_NAME (PID $PORT80_PID) остановлен" \
                || error "Не удалось остановить процесс — остановите вручную и запустите скрипт снова"
            sleep 1
        else
            warn "Остановите процесс вручную:"
            echo "    kill $PORT80_PID   # $PORT80_NAME"
            echo ""
            read -rp "  Нажмите Enter когда порт 80 освобождён..."
            ss -tlnp | grep -q ':80 ' && error "Порт 80 всё ещё занят — запустите скрипт снова"
        fi
    else
        info "Порт 80 свободен"
    fi

    info "Выпускаю SSL сертификат для $DOMAIN (RSA 2048)..."
    $ACME --issue -d "$DOMAIN" \
        --standalone --server letsencrypt \
        --keylength 2048 \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" \
        && info "SSL сертификат получен: $SSL_DIR" \
        || error "Не удалось получить сертификат. Проверьте что $DOMAIN указывает на этот сервер"
fi

# ── 7. Лог-файл ───────────────────────────────────────────────────────────────
touch "$LOG_FILE"
info "Лог-файл создан: $LOG_FILE"

# ── 8. Запуск Backup Manager ──────────────────────────────────────────────────
echo ""
info "Собираю и запускаю Backup Manager..."
docker compose up -d --build

# ── Готово ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  Remnawave Backup Manager запущен!                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
printf "║  🌐  https://%-44s║\n" "$DOMAIN:8090"
echo "║                                                          ║"
echo "║  Следующие шаги:                                         ║"
echo "║  1. Войдите с логином и паролем из .env                  ║"
echo "║  2. Вкладка SSH → сгенерируйте ключ                     ║"
echo "║  3. Установите ключ на резервные серверы                 ║"
echo "║  4. Настройки → добавьте удалённые хосты для rsync      ║"
echo "║  5. Нажмите «Запустить бэкап» для проверки              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
