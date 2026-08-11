from fastapi import FastAPI, HTTPException, Depends, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import json, os, secrets, shutil, hashlib, subprocess
from pathlib import Path

app = FastAPI()
bearer = HTTPBearer(auto_error=False)

CONFIG_FILE   = "/app/data/config.json"
BACKUP_ROOT   = os.environ.get("BACKUP_ROOT", "/backups")
ADMIN_USER    = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS    = os.environ.get("ADMIN_PASS", "changeme")
BACKUP_SCRIPT = "/app/backup.sh"
SSH_KEY       = "/root/.ssh/id_ed25519"
SSH_PUB       = "/root/.ssh/id_ed25519.pub"
TOKENS_FILE   = "/app/data/tokens.json"
LOG_FILE      = "/var/log/remnawave_backup.log"


# ── auth ─────────────────────────────────────────────────────────────────────

def load_tokens():
    try:
        if os.path.exists(TOKENS_FILE):
            with open(TOKENS_FILE) as f:
                return json.load(f)
    except Exception:
        pass
    return {}

def save_tokens(t):
    os.makedirs(os.path.dirname(TOKENS_FILE), exist_ok=True)
    with open(TOKENS_FILE, "w") as f:
        json.dump(t, f)

def make_token(user):
    return hashlib.sha256(f"{user}{secrets.token_hex(16)}".encode()).hexdigest()

def check_auth(credentials: HTTPAuthorizationCredentials = Depends(bearer)):
    if not credentials:
        raise HTTPException(status_code=401, detail="Unauthorized")
    tokens = load_tokens()
    if credentials.credentials not in tokens:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return tokens[credentials.credentials]


# ── config ────────────────────────────────────────────────────────────────────

LOGO_FILE = "/app/data/logo"  # без расширения, определяем динамически

def get_logo_path():
    for ext in [".png", ".svg", ".jpg", ".webp"]:
        p = f"{LOGO_FILE}{ext}"
        if os.path.exists(p):
            return p
    return None

def get_config():
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            return json.load(f)
    return {
        "remote_hosts":      [],
        "cron_time":         "03:00",
        "keep_local":        7,
        "auto_enabled":      True,
        "auto_send_enabled": True,
        "auto_send_delay":   0,
        "auto_send_time":    "",
        "brand_name":        "ВЛЕС",
    }

def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


# ── helpers ───────────────────────────────────────────────────────────────────

def fmt_size(b):
    for u in ["B", "KB", "MB", "GB"]:
        if b < 1024:
            return f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} GB"

def get_backups():
    backups = []
    p = Path(BACKUP_ROOT)
    if not p.exists():
        return backups
    for d in sorted(p.iterdir(), reverse=True):
        if d.is_dir() and d.name[:4].isdigit():
            size  = sum(f.stat().st_size for f in d.rglob("*") if f.is_file())
            files = [f.name for f in d.iterdir() if f.is_file()]
            backups.append({"name": d.name, "size": size, "size_human": fmt_size(size), "files_count": len(files)})
    return backups

def get_log():
    if os.path.exists(LOG_FILE):
        lines = Path(LOG_FILE).read_text(errors="replace").splitlines()
        return "\n".join(lines[-150:])
    return "Лог пуст"

def ssh_key_exists():
    return os.path.exists(SSH_KEY) and os.path.exists(SSH_PUB)

def get_pub_key():
    if os.path.exists(SSH_PUB):
        return Path(SSH_PUB).read_text().strip()
    return ""

def update_cron(cfg):
    """Обновить crontab под текущий конфиг."""
    # Удаляем старые строки backup
    subprocess.run("crontab -l 2>/dev/null | grep -v backup.sh | crontab -", shell=True)

    lines = []
    if cfg.get("auto_enabled"):
        h, m = cfg["cron_time"].split(":")
        lines.append(f"{m} {h} * * * bash {BACKUP_SCRIPT} >> {LOG_FILE} 2>&1")

    if cfg.get("auto_send_enabled") and cfg.get("auto_send_time"):
        # Отдельный cron для отправки в заданное время
        try:
            sh, sm = cfg["auto_send_time"].split(":")
            lines.append(f"{sm} {sh} * * * bash {BACKUP_SCRIPT} --send-only >> {LOG_FILE} 2>&1")
        except Exception:
            pass

    if lines:
        cron_block = "\n".join(lines)
        subprocess.run(
            f'(crontab -l 2>/dev/null; echo "{cron_block}") | crontab -',
            shell=True,
        )


# ── page render ───────────────────────────────────────────────────────────────

def render_page(backups, cfg, log):
    hosts_html = ""
    for h in cfg.get("remote_hosts", []):
        hosts_html += f'''<div class="host-item">
            <div class="host-row-1">
                <input class="host-label" placeholder="Алиас (напр. IONOS-DE)" value="{h.get('label','')}">
                <button class="btn btn-danger btn-sm" onclick="removeHost(this)">✕</button>
            </div>
            <div class="host-row-2">
                <input class="host-ip" placeholder="IP" value="{h.get('host','')}">
                <input class="host-port" placeholder="22" value="{h.get('port',22)}">
            </div>
            <div class="host-row-3">
                <input class="host-user" placeholder="Пользователь" value="{h.get('user','root')}">
                <input class="host-dir" placeholder="/root/vless4less-backups" value="{h.get('dir','')}">
            </div>
        </div>'''

    backups_html = ""
    for b in backups:
        send_items = ""
        for i, h in enumerate(cfg.get("remote_hosts", [])):
            display = h.get("label", "") or h.get("host", "")
            send_items += f'<div class="send-menu-item" onclick="sendBackup(\'{b["name"]}\', {i})">🖥 {display}</div>'
        if not send_items:
            send_items = '<div class="send-menu-item" style="color:var(--muted)">Нет хостов</div>'
        backups_html += f'''<div class="backup-item" id="item-{b["name"]}">
            <input type="checkbox" class="backup-check" value="{b["name"]}" onchange="toggleSelect(this)">
            <div class="backup-icon">💾</div>
            <div class="backup-info">
                <div class="backup-name">{b["name"]}</div>
                <div class="backup-meta">{b["files_count"]} файлов · {b["size_human"]}</div>
            </div>
            <div class="backup-actions">
                <div class="send-dropdown">
                    <button class="btn btn-success btn-sm" onclick="toggleSendMenu(this, \'{b["name"]}\')">↑</button>
                    <div class="send-menu" id="menu-{b["name"]}">{send_items}</div>
                </div>
                <button class="btn btn-danger btn-sm" onclick="deleteBackup(\'{b["name"]}\', this)">✕</button>
            </div>
        </div>'''

    if not backups_html:
        backups_html = '<div class="empty"><div class="empty-icon">📭</div><div>Бэкапов пока нет</div></div>'

    auto_checked      = "checked" if cfg.get("auto_enabled", True) else ""
    send_checked      = "checked" if cfg.get("auto_send_enabled", True) else ""
    cron_time         = cfg.get("cron_time", "03:00")
    keep_local        = cfg.get("keep_local", 7)
    auto_send_delay   = cfg.get("auto_send_delay", 0)
    auto_send_time    = cfg.get("auto_send_time", "")
    total_size        = fmt_size(sum(b["size"] for b in backups))
    auto_status       = (
        f'<span style="color:var(--accent2)">✓ {cron_time}</span>'
        if cfg.get("auto_enabled")
        else '<span style="color:var(--muted)">Выкл</span>'
    )
    pub_key    = get_pub_key()
    key_exists = "true" if ssh_key_exists() else "false"
    brand_name = cfg.get("brand_name", "ВЛЕС")
    has_logo   = "true" if get_logo_path() else "false"
    logo_bg    = cfg.get("logo_bg", "linear-gradient(135deg,#4f8ef7,#7c4dff)")

    with open("/app/templates/index.html") as f:
        html = f.read()

    html = html.replace("{{BACKUPS}}",           backups_html)
    html = html.replace("{{HOSTS}}",             hosts_html)
    html = html.replace("{{AUTO_CHECKED}}",      auto_checked)
    html = html.replace("{{SEND_CHECKED}}",      send_checked)
    html = html.replace("{{CRON_TIME}}",         cron_time)
    html = html.replace("{{KEEP_LOCAL}}",        str(keep_local))
    html = html.replace("{{AUTO_SEND_DELAY}}",   str(auto_send_delay))
    html = html.replace("{{AUTO_SEND_TIME}}",    auto_send_time)
    html = html.replace("{{BACKUP_COUNT}}",      str(len(backups)))
    html = html.replace("{{TOTAL_SIZE}}",        total_size)
    html = html.replace("{{LOG}}",               log.replace("<", "&lt;").replace(">", "&gt;"))
    html = html.replace("{{AUTO_STATUS}}",       auto_status)
    html = html.replace("{{SSH_PUB_KEY}}",       pub_key.replace("`", "\\`"))
    html = html.replace("{{SSH_KEY_EXISTS}}",    key_exists)
    html = html.replace("{{BRAND_NAME}}",        brand_name)
    html = html.replace("{{HAS_LOGO}}",          has_logo)
    html = html.replace("{{LOGO_BG}}",           logo_bg)
    return html


# ── login page ────────────────────────────────────────────────────────────────

LOGIN_HTML = '''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ВЛЕС — Вход</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #0d0f14; color: #e2e8f0; font-family: -apple-system, sans-serif; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
  .login-box { background: #151820; border: 1px solid #252a3a; border-radius: 16px; padding: 40px; width: 360px; max-width: 94vw; }
  .logo { display: flex; align-items: center; gap: 12px; margin-bottom: 32px; justify-content: center; }
  .logo-icon { width: 40px; height: 40px; background: linear-gradient(135deg, #4f8ef7, #7c4dff); border-radius: 10px; display: flex; align-items: center; justify-content: center; font-size: 20px; }
  .logo-text { font-size: 18px; font-weight: 700; }
  .logo-sub { font-size: 12px; color: #6b7a99; margin-top: 2px; }
  .form-group { margin-bottom: 16px; }
  .form-label { display: block; font-size: 12px; color: #6b7a99; margin-bottom: 6px; font-weight: 500; }
  .form-input { width: 100%; background: #0d0f14; border: 1px solid #252a3a; border-radius: 8px; padding: 10px 14px; color: #e2e8f0; font-size: 14px; }
  .form-input:focus { outline: none; border-color: #4f8ef7; }
  .btn-login { width: 100%; background: #4f8ef7; color: white; border: none; border-radius: 8px; padding: 11px; font-size: 14px; font-weight: 600; cursor: pointer; margin-top: 8px; }
  .btn-login:hover { background: #3a7ae0; }
  .error { color: #e74c3c; font-size: 13px; margin-top: 12px; text-align: center; }
</style>
</head>
<body>
<div class="login-box">
  <div class="logo">
    <div class="logo-icon">🌲</div>
    <div><div class="logo-text">ВЛЕС Backup</div><div class="logo-sub">Менеджер резервных копий</div></div>
  </div>
  <div id="error" class="error" style="display:none">Неверный логин или пароль</div>
  <div class="form-group"><label class="form-label">Логин</label><input class="form-input" type="text" id="username" autofocus></div>
  <div class="form-group"><label class="form-label">Пароль</label><input class="form-input" type="password" id="password"></div>
  <button class="btn-login" onclick="doLogin()">Войти</button>
</div>
<script>
async function doLogin() {
  const u = document.getElementById('username').value;
  const p = document.getElementById('password').value;
  const r = await fetch('/api/login', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({username: u, password: p}) });
  if (r.ok) { const d = await r.json(); localStorage.setItem('auth_token', d.token); window.location.href = '/'; }
  else { document.getElementById('error').style.display = 'block'; }
}
document.addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); });
</script>
</body>
</html>'''


# ── routes ────────────────────────────────────────────────────────────────────

@app.get("/login", response_class=HTMLResponse)
async def login_page():
    cfg = get_config()
    brand = cfg.get("brand_name", "ВЛЕС")
    logo_bg = cfg.get("logo_bg", "linear-gradient(135deg,#4f8ef7,#7c4dff)")
    has_logo = get_logo_path() is not None
    logo_ts = int(os.path.getmtime(get_logo_path())) if has_logo else 0
    logo_html = f'<img src="/api/logo?v={logo_ts}" style="width:100%;height:100%;object-fit:contain;border-radius:10px">' if has_logo else '🌲'

    html = f'''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="icon" href="/favicon.ico?v={os.path.getmtime(get_logo_path()) if has_logo else 0}" type="image/png">
<title>{brand} — Вход</title>
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ background: #0d0f14; color: #e2e8f0; font-family: -apple-system, sans-serif; min-height: 100vh; display: flex; align-items: center; justify-content: center; }}
  .login-box {{ background: #151820; border: 1px solid #252a3a; border-radius: 16px; padding: 40px; width: 360px; max-width: 94vw; }}
  .logo {{ display: flex; align-items: center; gap: 12px; margin-bottom: 32px; justify-content: center; }}
  .logo-icon {{ width: 40px; height: 40px; background: {logo_bg}; border-radius: 10px; display: flex; align-items: center; justify-content: center; font-size: 20px; overflow: hidden; }}
  .logo-text {{ font-size: 18px; font-weight: 700; }}
  .logo-sub {{ font-size: 12px; color: #6b7a99; margin-top: 2px; }}
  .form-group {{ margin-bottom: 16px; }}
  .form-label {{ display: block; font-size: 12px; color: #6b7a99; margin-bottom: 6px; font-weight: 500; }}
  .form-input {{ width: 100%; background: #0d0f14; border: 1px solid #252a3a; border-radius: 8px; padding: 10px 14px; color: #e2e8f0; font-size: 14px; }}
  .form-input:focus {{ outline: none; border-color: #4f8ef7; }}
  .btn-login {{ width: 100%; background: #4f8ef7; color: white; border: none; border-radius: 8px; padding: 11px; font-size: 14px; font-weight: 600; cursor: pointer; margin-top: 8px; }}
  .btn-login:hover {{ background: #3a7ae0; }}
  .error {{ color: #e74c3c; font-size: 13px; margin-top: 12px; text-align: center; }}
</style>
</head>
<body>
<div class="login-box">
  <div class="logo">
    <div class="logo-icon">{logo_html}</div>
    <div><div class="logo-text">{brand} Backup</div><div class="logo-sub">Менеджер резервных копий</div></div>
  </div>
  <div id="error" class="error" style="display:none">Неверный логин или пароль</div>
  <div class="form-group"><label class="form-label">Логин</label><input class="form-input" type="text" id="username" autofocus></div>
  <div class="form-group"><label class="form-label">Пароль</label><input class="form-input" type="password" id="password"></div>
  <button class="btn-login" onclick="doLogin()">Войти</button>
</div>
<script>
async function doLogin() {{
  const u = document.getElementById('username').value;
  const p = document.getElementById('password').value;
  const r = await fetch('/api/login', {{ method: 'POST', headers: {{'Content-Type':'application/json'}}, body: JSON.stringify({{username: u, password: p}}) }});
  if (r.ok) {{ const d = await r.json(); localStorage.setItem('auth_token', d.token); window.location.href = '/'; }}
  else {{ document.getElementById('error').style.display = 'block'; }}
}}
document.addEventListener('keydown', e => {{ if (e.key === 'Enter') doLogin(); }});
</script>
</body>
</html>'''
    return HTMLResponse(html)

@app.post("/api/login")
async def api_login(request: Request):
    body = await request.json()
    if secrets.compare_digest(body.get("username", ""), ADMIN_USER) and \
       secrets.compare_digest(body.get("password", ""), ADMIN_PASS):
        token = make_token(body["username"])
        tokens = load_tokens()
        tokens[token] = body["username"]
        save_tokens(tokens)
        return {"token": token}
    raise HTTPException(status_code=401, detail="Invalid credentials")

@app.get("/logout")
async def logout(credentials: HTTPAuthorizationCredentials = Depends(bearer)):
    if credentials:
        tokens = load_tokens()
        tokens.pop(credentials.credentials, None)
        save_tokens(tokens)
    return RedirectResponse("/login", status_code=302)

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    cfg     = get_config()
    backups = get_backups()
    return HTMLResponse(render_page(backups, cfg, get_log()))

@app.post("/api/backup/run")
async def run_backup(user=Depends(check_auth)):
    # Убедимся что лог-файл существует
    Path(LOG_FILE).touch(exist_ok=True)
    subprocess.Popen(
        ["bash", BACKUP_SCRIPT],
        stdout=open(LOG_FILE, "a"),
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    return {"status": "started", "message": "Бэкап запущен в фоне"}

@app.post("/api/backup/{name}/send")
async def send_backup(name: str, host_idx: int = 0, user=Depends(check_auth)):
    cfg = get_config()
    backup_path = Path(BACKUP_ROOT) / name
    if not backup_path.exists():
        raise HTTPException(404, "Бэкап не найден")
    if host_idx >= len(cfg["remote_hosts"]):
        raise HTTPException(400, "Хост не найден")
    host     = cfg["remote_hosts"][host_idx]
    ssh_opts = f"-o StrictHostKeyChecking=no -p {host.get('port', 22)}"
    mkdir_cmd = f"ssh {ssh_opts} {host['user']}@{host['host']} \"mkdir -p {host['dir']}\""
    cmd = f"{mkdir_cmd} && rsync -az -e 'ssh {ssh_opts}' {backup_path}/ {host['user']}@{host['host']}:{host['dir']}/{name}/"
    Path(LOG_FILE).touch(exist_ok=True)
    subprocess.Popen(cmd, shell=True, stdout=open(LOG_FILE, "a"), stderr=subprocess.STDOUT, start_new_session=True)
    return {"status": "started", "message": f"Отправка на {host['host']} запущена"}

@app.delete("/api/backup/{name}")
async def delete_backup(name: str, user=Depends(check_auth)):
    backup_path = Path(BACKUP_ROOT) / name
    if not backup_path.exists():
        raise HTTPException(404, "Бэкап не найден")
    shutil.rmtree(backup_path)
    return {"status": "ok"}

@app.get("/api/backups")
async def list_backups(user=Depends(check_auth)):
    return get_backups()

@app.get("/api/log")
async def get_log_api(user=Depends(check_auth)):
    return {"log": get_log()}

@app.get("/api/config")
async def get_config_api(user=Depends(check_auth)):
    return get_config()

@app.post("/api/config")
async def save_config_api(request: Request, user=Depends(check_auth)):
    body = await request.json()
    cfg  = get_config()
    if "remote_hosts"      in body: cfg["remote_hosts"]      = body["remote_hosts"]
    if "cron_time"         in body: cfg["cron_time"]         = body["cron_time"]
    if "keep_local"        in body: cfg["keep_local"]        = int(body["keep_local"])
    if "auto_enabled"      in body: cfg["auto_enabled"]      = bool(body["auto_enabled"])
    if "auto_send_enabled" in body: cfg["auto_send_enabled"] = bool(body["auto_send_enabled"])
    if "auto_send_delay"   in body: cfg["auto_send_delay"]   = int(body["auto_send_delay"])
    if "auto_send_time"    in body: cfg["auto_send_time"]    = body["auto_send_time"]
    if "logo_bg"           in body: cfg["logo_bg"]           = body["logo_bg"]
    save_config(cfg)
    update_cron(cfg)
    return {"status": "ok"}


# ── SSH endpoints ─────────────────────────────────────────────────────────────

@app.get("/api/ssh/key")
async def ssh_get_key(user=Depends(check_auth)):
    return {"exists": ssh_key_exists(), "pub_key": get_pub_key()}

@app.post("/api/ssh/generate")
async def ssh_generate_key(user=Depends(check_auth)):
    if ssh_key_exists():
        return {"status": "exists", "pub_key": get_pub_key()}
    os.makedirs("/root/.ssh", mode=0o700, exist_ok=True)
    result = subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-f", SSH_KEY, "-N", "", "-C", "backup-manager@remnawave"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise HTTPException(500, f"Ошибка генерации ключа: {result.stderr}")
    return {"status": "generated", "pub_key": get_pub_key()}

@app.post("/api/ssh/copy-id")
async def ssh_copy_id(request: Request, user=Depends(check_auth)):
    if not ssh_key_exists():
        raise HTTPException(400, "SSH ключ не найден. Сначала сгенерируйте ключ.")
    body     = await request.json()
    host     = body.get("host", "").strip()
    port     = int(body.get("port", 22))
    ssh_user = body.get("ssh_user", "root").strip()
    password = body.get("password", "")
    if not host:     raise HTTPException(400, "Не указан хост")
    if not password: raise HTTPException(400, "Не указан пароль")
    cmd = ["sshpass", "-p", password, "ssh-copy-id", "-i", SSH_PUB,
           "-p", str(port), "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
           f"{ssh_user}@{host}"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise HTTPException(500, f"Ошибка: {result.stderr.strip() or result.stdout.strip()}")
    return {"status": "ok", "message": f"Ключ установлен на {ssh_user}@{host}:{port}"}

@app.post("/api/ssh/test")
async def ssh_test(request: Request, user=Depends(check_auth)):
    body     = await request.json()
    host     = body.get("host", "").strip()
    port     = int(body.get("port", 22))
    ssh_user = body.get("ssh_user", "root").strip()
    if not host: raise HTTPException(400, "Не указан хост")
    cmd = ["ssh", "-i", SSH_KEY, "-p", str(port),
           "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
           f"{ssh_user}@{host}", "echo ok"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    if result.returncode == 0:
        return {"status": "ok", "message": f"Соединение с {host} успешно"}
    raise HTTPException(500, f"Ошибка подключения: {result.stderr.strip()}")


# ── Branding endpoints ────────────────────────────────────────────────────────

from fastapi import UploadFile, File, Form
from fastapi.responses import FileResponse, Response
import mimetypes

@app.get("/api/logo")
async def get_logo():
    """Отдать логотип."""
    logo = get_logo_path()
    if not logo:
        raise HTTPException(404, "Логотип не загружен")
    content = Path(logo).read_bytes()
    mt = mimetypes.guess_type(logo)[0] or "image/png"
    return Response(
        content=content,
        media_type=mt,
        headers={"Cache-Control": "no-cache, no-store, must-revalidate"}
    )

@app.get("/favicon.ico")
async def favicon():
    """Favicon из логотипа."""
    logo = get_logo_path()
    if not logo:
        raise HTTPException(404, "No favicon")
    content = Path(logo).read_bytes()
    mt = mimetypes.guess_type(logo)[0] or "image/png"
    return Response(
        content=content,
        media_type=mt,
        headers={
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache",
            "Expires": "0",
        }
    )

@app.post("/api/branding")
async def save_branding(
    brand_name: str = Form(""),
    logo_bg:    str = Form(""),
    logo: UploadFile = File(None),
    user=Depends(check_auth),
):
    """Сохранить брендинг: название, фон иконки и логотип."""
    cfg = get_config()
    if brand_name:
        cfg["brand_name"] = brand_name.strip()
    if logo_bg:
        cfg["logo_bg"] = logo_bg
    save_config(cfg)

    if logo and logo.filename:
        ext = Path(logo.filename).suffix.lower()
        if ext not in [".png", ".jpg", ".jpeg", ".svg", ".webp"]:
            raise HTTPException(400, "Допустимые форматы: PNG, JPG, SVG, WEBP")
        # Удалить старый логотип
        for old_ext in [".png", ".svg", ".jpg", ".jpeg", ".webp"]:
            old = f"{LOGO_FILE}{old_ext}"
            if os.path.exists(old):
                os.remove(old)
        # Сохранить новый
        logo_path = f"{LOGO_FILE}{ext}"
        content = await logo.read()
        with open(logo_path, "wb") as f:
            f.write(content)

    return {"status": "ok", "brand_name": cfg.get("brand_name", "ВЛЕС"), "has_logo": get_logo_path() is not None}

@app.delete("/api/branding/logo")
async def delete_logo(user=Depends(check_auth)):
    """Удалить логотип, вернуться к emoji."""
    for ext in [".png", ".svg", ".jpg", ".jpeg", ".webp"]:
        p = f"{LOGO_FILE}{ext}"
        if os.path.exists(p):
            os.remove(p)
    return {"status": "ok"}
