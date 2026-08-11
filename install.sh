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

# ── 1. Docker ────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
    info "Docker установлен"
else
    info "Docker уже установлен: $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

# ── 2. acme.sh ───────────────────────────────────────────────────────────────
if [ ! -f ~/.acme.sh/acme.sh ]; then
    info "Устанавливаю acme.sh..."
    curl https://get.acme.sh | sh -s email=admin@localhost
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

# ── 5. .env ───────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
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
else
    warn ".env уже существует — не перезаписываю"
fi

# ── 6. Домен и SSL ────────────────────────────────────────────────────────────
echo ""
prompt "Введите домен для Backup Manager (например: backup.your-domain.com):"
read -rp "  Домен: " DOMAIN
[ -z "$DOMAIN" ] && error "Домен не может быть пустым"

SSL_DIR="/opt/remnawave/nginx"
CERT_FILE="$SSL_DIR/backup.fullchain.pem"
KEY_FILE="$SSL_DIR/backup.privkey.key"

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
        kill "$PORT80_PID" 2>/dev/null && info "Процесс $PORT80_NAME (PID $PORT80_PID) остановлен" \
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

# Выпуск сертификата
info "Выпускаю SSL сертификат для $DOMAIN..."
mkdir -p "$SSL_DIR"
$ACME --issue -d "$DOMAIN" \
    --standalone --server letsencrypt \
    --keylength 2048 \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    && info "SSL сертификат получен" \
    || error "Не удалось получить сертификат. Проверьте что $DOMAIN указывает на этот сервер"

# ── 7. Nginx ──────────────────────────────────────────────────────────────────
echo ""
info "Определяю путь к nginx..."

NGINX_DIR=""
CANDIDATES=(
    "/opt/remnawave/nginx"
    "/root/remnawave/nginx"
    "/home/remnawave/nginx"
)
for C in "${CANDIDATES[@]}"; do
    if [ -f "$C/nginx.conf" ] && [ -f "$C/docker-compose.yml" ]; then
        NGINX_DIR="$C"
        break
    fi
done

if [ -n "$NGINX_DIR" ]; then
    info "Найден nginx: $NGINX_DIR"
    read -rp "  Использовать этот путь? [Y/n]: " CONFIRM_NGINX
    if [[ "$CONFIRM_NGINX" =~ ^[Nn]$ ]]; then
        NGINX_DIR=""
    fi
fi

if [ -z "$NGINX_DIR" ]; then
    prompt "Введите полный путь к папке nginx (где лежат nginx.conf и docker-compose.yml):"
    read -rp "  Путь: " NGINX_DIR
    [ ! -f "$NGINX_DIR/nginx.conf" ] && error "nginx.conf не найден в $NGINX_DIR"
    [ ! -f "$NGINX_DIR/docker-compose.yml" ] && error "docker-compose.yml не найден в $NGINX_DIR"
fi

NGINX_CONF="$NGINX_DIR/nginx.conf"
NGINX_COMPOSE="$NGINX_DIR/docker-compose.yml"

# Добавляем server block в nginx.conf
if grep -q "$DOMAIN" "$NGINX_CONF" 2>/dev/null; then
    warn "Server block для $DOMAIN уже существует в nginx.conf — пропускаю"
else
    cat >> "$NGINX_CONF" << NGINXBLOCK

server {
    server_name $DOMAIN;
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ignore_client_abort on;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_certificate     "/etc/nginx/ssl/backup.fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/backup.privkey.key";
}
NGINXBLOCK
    info "Server block добавлен в nginx.conf"
fi

# Добавляем тома сертификатов в nginx docker-compose.yml
if grep -q "backup.fullchain.pem" "$NGINX_COMPOSE" 2>/dev/null; then
    warn "Тома сертификатов уже есть в nginx docker-compose.yml — пропускаю"
else
    # Вставляем после последнего тома в секции volumes
    python3 - "$NGINX_COMPOSE" "$CERT_FILE" "$KEY_FILE" << 'PYEOF'
import sys, re

path, cert, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()

new_volumes = (
    f"      - {cert}:/etc/nginx/ssl/backup.fullchain.pem:ro\n"
    f"      - {key}:/etc/nginx/ssl/backup.privkey.key:ro\n"
)

# Ищем последний том в секции volumes и вставляем после него
pattern = r'(volumes:(?:\n\s+- [^\n]+)+)'
match = re.search(pattern, content)
if match:
    insert_pos = match.end()
    content = content[:insert_pos] + new_volumes + content[insert_pos:]
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("VOLUMES_NOT_FOUND")
PYEOF
    info "Тома сертификатов добавлены в nginx docker-compose.yml"
fi

# Перезапускаем nginx
info "Перезапускаю nginx..."
cd "$NGINX_DIR"
docker compose down && docker compose up -d
cd "$INSTALL_DIR"
info "nginx перезапущен"

# ── 8. Лог-файл ───────────────────────────────────────────────────────────────
touch "$LOG_FILE"
info "Лог-файл создан: $LOG_FILE"

# ── 9. Запуск Backup Manager ──────────────────────────────────────────────────
echo ""
info "Собираю и запускаю Backup Manager..."
docker compose up -d --build

# ── Готово ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  Remnawave Backup Manager запущен!               ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                      ║"
printf "║  🌐  https://%-38s║\n" "$DOMAIN"
echo "║                                                      ║"
echo "║  Следующие шаги:                                     ║"
echo "║  1. Войдите с логином и паролем из .env              ║"
echo "║  2. Вкладка SSH → сгенерируйте ключ                 ║"
echo "║  3. Установите ключ на резервные серверы             ║"
echo "║  4. Настройки → добавьте удалённые хосты            ║"
echo "║  5. Нажмите «Запустить бэкап» для проверки          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
