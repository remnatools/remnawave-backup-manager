# Remnawave Backup Manager

Веб-интерфейс для резервного копирования [Remnawave](https://github.com/remnawave) VPN-панели с [BEDOLAGA ботом](https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot) и [BEDOLAGA кабинетом](https://github.com/BEDOLAGA-DEV/bedolaga-cabinet).

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
- Работает **без nginx** — HTTPS напрямую через uvicorn + SSL

<div align="center">
  <img width="30%" alt="бэкапы" src="https://github.com/user-attachments/assets/032e84f5-da51-4bff-85ad-ecead1eca77b" />
  <img width="30%" alt="настройки" src="https://github.com/user-attachments/assets/fb6b14e8-0e27-4746-997b-6a5ed5560ed1" />
  <img width="30%" alt="ssh" src="https://github.com/user-attachments/assets/50c430fb-32d6-40d5-8c69-709c37a1b333" />
</div>

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
curl -fsSL https://raw.githubusercontent.com/remnatools/remnawave-backup-manager/main/install.sh -o install.sh
chmod +x install.sh && ./install.sh
```

Скрипт автоматически:
- Установит Docker и acme.sh
- Создаст Docker сеть
- Клонирует репо
- Запросит логин, пароль и домен
- Выпустит SSL сертификат (RSA 2048)
- Запустит контейнер

После установки интерфейс доступен на `https://your-domain.com:8090`.

### Ручная установка

**1. Установить Docker и acme.sh**

```bash
curl -fsSL https://get.docker.com | sh
curl https://get.acme.sh | sh && source ~/.bashrc
```

**2. Создать Docker сеть**

```bash
docker network create remnawave-network
```

**3. Клонировать репо**

```bash
git clone https://github.com/remnatools/remnawave-backup-manager.git ~/remnawave-backup-manager
cd ~/remnawave-backup-manager
```

**4. Создать `.env`**

```bash
cp .env.example .env
nano .env   # задать ADMIN_USER и ADMIN_PASS
```

**5. Выпустить SSL сертификат**

> ⚠️ Используйте `--keylength 2048` (RSA) — uvicorn не поддерживает EC ключи

```bash
mkdir -p ~/remnawave-backup-manager/app/ssl

~/.acme.sh/acme.sh --issue -d backup.your-domain.com \
  --standalone --server letsencrypt \
  --keylength 2048 \
  --key-file ~/remnawave-backup-manager/app/ssl/privkey.key \
  --fullchain-file ~/remnawave-backup-manager/app/ssl/fullchain.pem
```

**6. Открыть порт в firewall**

```bash
ufw allow 8090/tcp
```

**7. Создать лог-файл и запустить**

```bash
touch /var/log/remnawave_backup.log
docker compose up -d --build
```

Интерфейс доступен на `https://backup.your-domain.com:8090`.

### После запуска

1. Войдите в интерфейс по логину и паролю из `.env`
2. Вкладка **SSH** → сгенерируйте ключ → установите на резервные серверы
3. **Настройки** → добавьте удалённые хосты для rsync
4. Нажмите **Запустить бэкап** для проверки

### Опционально: убрать порт из URL через nginx

Если на сервере уже установлена Remnawave панель с nginx и вы хотите доступ без порта (`https://backup.your-domain.com`), добавьте server block в ваш `nginx.conf`:

```nginx
server {
    server_name backup.your-domain.com;
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    location / {
        proxy_pass https://127.0.0.1:8090;
        proxy_ssl_verify off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300;
        client_max_body_size 10m;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate     "/etc/nginx/ssl/backup.fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/backup.privkey.key";
}
```

Не забудьте смонтировать сертификаты в nginx docker-compose.yml и перезапустить nginx.

## Конфигурация

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
Сервер с панелью
├── backup-manager         — порт 8090, HTTPS напрямую (uvicorn + SSL)
│   └── app/ssl/           — SSL сертификат (acme.sh, RSA 2048)
├── backup.sh              — скрипт бэкапа
└── /root/remnawave-backups/
    └── 20260804_103517/   ← rsync → резервные серверы автоматически
```

## Структура репо

```
remnawave-backup-manager/
├── app/
│   ├── main.py              # FastAPI приложение
│   └── ssl/                 # SSL сертификаты (генерируются при установке)
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
