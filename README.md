# Remnawave Backup Manager

Веб-интерфейс для резервного копирования [Remnawave](https://github.com/remnawave) VPN-панели с Bedolaga ботом.

![Python](https://img.shields.io/badge/Python-FastAPI-009688?style=flat-square)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)

## Возможности

- **Веб-интерфейс** — управление из браузера, включая мобильный
- **Полный бэкап** — БД панели и бота, `.env`, `docker-compose.yml`, исходники бота и кабинета
- **Автоотправка по SSH/rsync** — на один или несколько резервных серверов сразу после бэкапа
- **Расписание** — автозапуск по cron в заданное время
- **SSH key management** — генерация ключа и установка на хосты прямо из UI
- **Брендинг** — кастомный логотип, favicon, название
- **Просмотр и управление бэкапами** — список с размерами, удаление по одному
- **Лог операций** — сохраняется вне контейнера

## Что бэкапится

| Файл | Содержимое |
|------|-----------|
| `panel_db.sql` | БД панели Remnawave |
| `bot_db.sql` | БД бота Bedolaga |
| `panel.env` | Конфиг панели |
| `bot.env` | Конфиг бота |
| `panel_compose.yml` | docker-compose панели |
| `bot_compose.yml` | docker-compose бота |
| `bot_src.tar.gz` | Исходники бота |
| `cabinet_src.tar.gz` | Исходники кабинета |
| `manifest.txt` | Версия образа, hostname |

## Установка

### Быстрый старт (одна команда)

```bash
curl -fsSL https://raw.githubusercontent.com/remnatools/remnawave-backup-manager/main/install.sh | bash
```

### Ручная установка

**1. Установить Docker**

```bash
curl -fsSL https://get.docker.com | sh
```

**2. Клонировать репо**

```bash
git clone https://github.com/remnatools/remnawave-backup-manager.git ~/remnawave-backup-manager
cd ~/remnawave-backup-manager
```

**3. Создать `.env`**

```bash
cp .env.example .env
nano .env   # задать ADMIN_USER и ADMIN_PASS
```

**4. Создать лог-файл**

```bash
touch /var/log/remnawave_backup.log
```

**5. Запустить**

```bash
docker compose up -d --build
```

Интерфейс доступен на `http://YOUR_SERVER_IP:8090`.

### Настройка HTTPS (nginx)

Добавьте server block в nginx конфиг:

```nginx
server {
    server_name backup.your-domain.com;
    listen 443 ssl;
    http2 on;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_ignore_client_abort on;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate     /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.key;
}
```

### После запуска

1. Войдите в интерфейс по логину и паролю из `.env`
2. Вкладка **SSH** → сгенерируйте ключ → установите на резервные серверы
3. **Настройки** → добавьте удалённые хосты для rsync
4. Нажмите **Запустить бэкап** для проверки

## Конфигурация

Параметры задаются в `.env`:

```env
ADMIN_USER=admin
ADMIN_PASS=your-password

HOST_BACKUP_ROOT=/root/remnawave-backups
PANEL_DIR=/opt/remnawave
BOT_SRC=/root/remnawave-bedolaga-telegram-bot
CABINET_SRC=/root/bedolaga-cabinet
```

Пути к хостам для rsync настраиваются через веб-интерфейс и хранятся в `data/config.json`.

## Архитектура

```
Основной сервер
├── backup-manager         — порт 8090, за nginx на 443
├── backup.sh              — скрипт бэкапа
└── /root/remnawave-backups/
    └── 20260804_103517/   ← rsync → резервные серверы автоматически
```

## Структура репо

```
remnawave-backup-manager/
├── app/
│   └── main.py              # FastAPI приложение
├── templates/
│   └── index.html           # Веб-интерфейс
├── data/
│   └── config.example.json  # Пример конфига
├── backup.sh                # Скрипт бэкапа
├── install.sh               # Установщик
├── Dockerfile
├── docker-compose.yml
├── .env.example
└── .gitignore
```

## Связанные проекты

- **[Remnawave Restore Manager](https://github.com/remnatools/remnawave-restore-manager)** — веб-wizard для восстановления панели на резервном сервере из бэкапов этого инструмента

## Лицензия

MIT
