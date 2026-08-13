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
echo "  [1] Установить / Обновить"
echo "  [2] Удалить"
echo ""
read -rp "  Выбор [1/2]: " MAIN_ACTION

# ── УДАЛЕНИЕ ──────────────────────────────────────────────────────────────────
if [ "$MAIN_ACTION" = "2" ]; then
    echo ""
    warn "Это удалит контейнер, образ и папку $INSTALL_DIR."
    warn "Бэкапы в /root/remnawave-backups удалены НЕ будут."
    echo ""
    read -rp "  Продолжить? (yes/no): " CONFIRM_DEL
    [ "$CONFIRM_DEL" != "yes" ] && echo "Отменено." && exit 0

    info "Останавливаю и удаляю контейнер..."
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        docker compose down --rmi local 2>/dev/null || true
    else
        docker rm -f remnawave-backup-manager 2>/dev/null || true
    fi

    info "Удаляю папку $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"

    info "Удаляю лог-файл..."
    rm -f "$LOG_FILE"

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ✅  Backup Manager удалён                   ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    exit 0
fi

[ "$MAIN_ACTION" != "1" ] && error "Некорректный выбор"

# ── УСТАНОВКА ─────────────────────────────────────────────────────────────────

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
    [[ "$REISSUE" =~ ^[Yy]$ ]] && ISSUE_CERT=true || ISSUE_CERT=false
    if [ "$ISSUE_CERT" = false ]; then
        info "Используется существующий сертификат"
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
        echo "  [1] Остановить автоматически"
        echo "  [2] Я остановлю вручную (скрипт подождёт)"
        read -rp "  Выбор [1/2]: " CHOICE80
        if [ "$CHOICE80" = "1" ]; then
            kill "$PORT80_PID" 2>/dev/null \
                && info "Процесс $PORT80_NAME (PID $PORT80_PID) остановлен" \
                || error "Не удалось остановить — остановите вручную и запустите скрипт снова"
            sleep 1
        else
            warn "Остановите процесс вручную: kill $PORT80_PID   # $PORT80_NAME"
            read -rp "  Нажмите Enter когда порт 80 освобождён..."
            ss -tlnp | grep -q ':80 ' && error "Порт 80 всё ещё занят"
        fi
    else
        info "Порт 80 свободен"
    fi

    # Выпуск сертификата с режимом ожидания при rate limit
    info "Выпускаю SSL сертификат для $DOMAIN (RSA 2048)..."
    ACME_OUT=$($ACME --issue -d "$DOMAIN" \
        --standalone --server letsencrypt \
        --keylength 2048 \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" 2>&1) && ACME_OK=true || ACME_OK=false

    if [ "$ACME_OK" = true ]; then
        info "SSL сертификат получен: $SSL_DIR"
    else
        # Проверяем на rate limit
        RETRY_AFTER=$(echo "$ACME_OUT" | grep -oP 'retry after \K[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC' || true)
        if [ -n "$RETRY_AFTER" ]; then
            echo ""
            warn "Let's Encrypt rate limit: слишком много сертификатов для $DOMAIN"
            warn "Повтор возможен после: $RETRY_AFTER"
            echo ""
            echo "  Варианты:"
            echo "  [1] Подождать и попробовать снова (скрипт будет ждать)"
            echo "  [2] Использовать другой домен"
            echo "  [3] Пропустить SSL и продолжить без сертификата (небезопасно)"
            echo ""
            read -rp "  Выбор [1/2/3]: " RATE_CHOICE

            case "$RATE_CHOICE" in
                1)
                    warn "Скрипт ждёт. Нажмите Enter когда будете готовы повторить попытку..."
                    read -rp "  (убедитесь что DNS настроен и лимит сброшен) "
                    info "Повторяю выпуск сертификата..."
                    $ACME --issue -d "$DOMAIN" \
                        --standalone --server letsencrypt \
                        --keylength 2048 \
                        --key-file "$KEY_FILE" \
                        --fullchain-file "$CERT_FILE" \
                        && info "SSL сертификат получен" \
                        || error "Не удалось получить сертификат"
                    ;;
                2)
                    prompt "Введите новый домен:"
                    read -rp "  Домен: " DOMAIN
                    [ -z "$DOMAIN" ] && error "Домен не может быть пустым"
                    $ACME --issue -d "$DOMAIN" \
                        --standalone --server letsencrypt \
                        --keylength 2048 \
                        --key-file "$KEY_FILE" \
                        --fullchain-file "$CERT_FILE" \
                        && info "SSL сертификат получен для $DOMAIN" \
                        || error "Не удалось получить сертификат"
                    ;;
                3)
                    warn "Продолжаю без SSL — интерфейс будет доступен только по HTTP"
                    warn "Это небезопасно! Выпустите сертификат позже и пересоберите контейнер."
                    DOMAIN_DISPLAY="http://YOUR_SERVER_IP:8090 (без SSL!)"
                    ;;
                *)
                    error "Некорректный выбор"
                    ;;
            esac
        else
            # Другая ошибка — показываем и ждём
            echo ""
            warn "Ошибка выпуска сертификата:"
            echo "$ACME_OUT" | tail -5
            echo ""
            echo "  [1] Исправить проблему и попробовать снова"
            echo "  [2] Прервать установку"
            read -rp "  Выбор [1/2]: " ERR_CHOICE
            if [ "$ERR_CHOICE" = "1" ]; then
                warn "Исправьте проблему (DNS, порт 80) и нажмите Enter..."
                read -rp "  "
                $ACME --issue -d "$DOMAIN" \
                    --standalone --server letsencrypt \
                    --keylength 2048 \
                    --key-file "$KEY_FILE" \
                    --fullchain-file "$CERT_FILE" \
                    && info "SSL сертификат получен" \
                    || error "Не удалось получить сертификат"
            else
                error "Установка прервана"
            fi
        fi
    fi
fi

# ── 7. Firewall ───────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    ufw allow 8090/tcp 2>/dev/null && info "Порт 8090 открыт в ufw" || true
fi

# ── 8. Лог-файл ───────────────────────────────────────────────────────────────
touch "$LOG_FILE"
info "Лог-файл создан: $LOG_FILE"

# ── 9. Запуск Backup Manager ──────────────────────────────────────────────────
echo ""
info "Собираю и запускаю Backup Manager..."
docker compose up -d --build

# ── Готово ────────────────────────────────────────────────────────────────────
DOMAIN_DISPLAY="${DOMAIN_DISPLAY:-https://$DOMAIN:8090}"
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  Remnawave Backup Manager запущен!                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
printf "║  🌐  %-53s║\n" "$DOMAIN_DISPLAY"
echo "║                                                          ║"
echo "║  Следующие шаги:                                         ║"
echo "║  1. Войдите с логином и паролем из .env                  ║"
echo "║  2. Вкладка SSH → сгенерируйте ключ                     ║"
echo "║  3. Установите ключ на резервные серверы                 ║"
echo "║  4. Настройки → добавьте удалённые хосты для rsync      ║"
echo "║  5. Нажмите «Запустить бэкап» для проверки              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
