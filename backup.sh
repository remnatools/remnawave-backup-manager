#!/bin/bash
BACKUP_ROOT="${BACKUP_ROOT:-/root/remnawave-backups}"
KEEP_LOCAL="${KEEP_LOCAL:-7}"
PANEL_DB_CONTAINER="${PANEL_DB_CONTAINER:-remnawave-db}"
PANEL_DB_USER="${PANEL_DB_USER:-postgres}"
PANEL_DB_NAME="${PANEL_DB_NAME:-postgres}"
PANEL_ENV="${PANEL_DIR:-/opt/remnawave}/.env"
BOT_DB_CONTAINER="${BOT_DB_CONTAINER:-remnawave_bot_db}"
BOT_DB_USER="${BOT_DB_USER:-remnawave_user}"
BOT_DB_NAME="${BOT_DB_NAME:-remnawave_bot}"
BOT_ENV="${BOT_SRC:-/root/remnawave-bedolaga-telegram-bot}/.env"
CABINET_SRC="${CABINET_SRC:-/root/bedolaga-cabinet}"
BOT_SRC="${BOT_SRC:-/root/remnawave-bedolaga-telegram-bot}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Старт бэкапа..."
docker exec "$PANEL_DB_CONTAINER" pg_dump -U "$PANEL_DB_USER" "$PANEL_DB_NAME" > "${BACKUP_DIR}/panel_db.sql" && echo "[$(date)] OK БД панели" || echo "[$(date)] ОШИБКА БД панели"
docker exec "$BOT_DB_CONTAINER" pg_dump -U "$BOT_DB_USER" "$BOT_DB_NAME" > "${BACKUP_DIR}/bot_db.sql" && echo "[$(date)] OK БД бота" || echo "[$(date)] ОШИБКА БД бота"
[ -f "$PANEL_ENV" ] && cp "$PANEL_ENV" "${BACKUP_DIR}/panel.env" && echo "[$(date)] OK .env панели"
[ -f "$BOT_ENV" ] && cp "$BOT_ENV" "${BACKUP_DIR}/bot.env" && echo "[$(date)] OK .env бота"
[ -f "${PANEL_DIR:-/opt/remnawave}/docker-compose.yml" ] && cp "${PANEL_DIR:-/opt/remnawave}/docker-compose.yml" "${BACKUP_DIR}/panel_compose.yml" && echo "[$(date)] OK docker-compose панели"
[ -f "${BOT_SRC:-/root/remnawave-bedolaga-telegram-bot}/docker-compose.yml" ] && cp "${BOT_SRC:-/root/remnawave-bedolaga-telegram-bot}/docker-compose.yml" "${BACKUP_DIR}/bot_compose.yml" && echo "[$(date)] OK docker-compose бота"
[ -d "$CABINET_SRC" ] && tar -czf "${BACKUP_DIR}/cabinet_src.tar.gz" --exclude='*/node_modules/*' --exclude='*/.git/*' -C "$(dirname $CABINET_SRC)" "$(basename $CABINET_SRC)" && echo "[$(date)] OK кабинет"
[ -d "$BOT_SRC" ] && tar -czf "${BACKUP_DIR}/bot_src.tar.gz" --exclude='*/__pycache__/*' --exclude='*/.git/*' --exclude='*/data/backups/*' -C "$(dirname $BOT_SRC)" "$(basename $BOT_SRC)" && echo "[$(date)] OK бот"

echo "timestamp=$TIMESTAMP" > "${BACKUP_DIR}/manifest.txt"
echo "hostname=$(hostname)" >> "${BACKUP_DIR}/manifest.txt"
echo "panel_image=$(docker inspect remnawave --format '{{.Config.Image}}' 2>/dev/null || echo unknown)" >> "${BACKUP_DIR}/manifest.txt"
echo "panel_version=$(docker inspect remnawave --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo unknown)" >> "${BACKUP_DIR}/manifest.txt"
ls -1dt "${BACKUP_ROOT}"/20* 2>/dev/null | tail -n +$((KEEP_LOCAL + 1)) | xargs -r rm -rf
echo "[$(date)] Бэкап завершён: $BACKUP_DIR"

# Автоотправка на удалённые хосты из конфига Backup Manager
CONFIG_FILE="${CONFIG_FILE:-/root/remnawave-backup-manager/data/config.json}"
if [ -f "$CONFIG_FILE" ]; then
    HOSTS=$(python3 -c "
import json
cfg = json.load(open('$CONFIG_FILE'))
for h in cfg.get('remote_hosts', []):
    print(h['user'] + '@' + h['host'] + ':' + str(h.get('port',22)) + ':' + h['dir'])
" 2>/dev/null)
    if [ -n "$HOSTS" ]; then
        echo "[$(date)] Автоотправка на удалённые хосты..."
        while IFS=: read -r USERHOST PORT DIR; do
            echo "[$(date)] → rsync на $USERHOST..."
            rsync -az -e "ssh -p $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
                "$BACKUP_DIR/" "$USERHOST:$DIR/$(basename $BACKUP_DIR)/" \
                && echo "[$(date)] OK отправлен на $USERHOST" \
                || echo "[$(date)] ОШИБКА отправки на $USERHOST"
        done <<< "$HOSTS"
    fi
fi
