# Проверка кнопки «Обновить» (самообновление): подставной GitHub отдаёт релиз 9.9 с архивом и SHA-256 в описании.
# 1) неверная контрольная сумма -> ничего не меняется; 2) верная -> файлы заменены, старые в backups/kit-<версия>,
#    набор перезапускается уже версией 9.9 (в том же окне, остаток ввода получает новая версия).
# Запуск: python3 tests/updtest.py [pwsh|powershell]   Код выхода 1 — ошибка.
import hashlib, http.server, io, json, os, re, shutil, subprocess, sys, tempfile, threading, zipfile
try: sys.stdout.reconfigure(encoding='utf-8', errors='replace')   # Windows: консоль cp1252, а вывод по-русски
except Exception: pass
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
shell = sys.argv[1] if len(sys.argv) > 1 else 'pwsh'
cur = re.search(r"\$KitVersion = '([\d.]+)'", open(os.path.join(ROOT, 'phonekit.ps1'), encoding='utf-8-sig').read()).group(1)
work = tempfile.mkdtemp()
adb = os.path.join(ROOT, 'tests', 'mock_adb.py')
if os.name == 'nt':
    wrap = os.path.join(work, 'adb.cmd')
    open(wrap, 'w').write('@"%s" "%s" %%*\n' % (sys.executable, adb))
    adb = wrap

# архив «новой версии»: файлы набора, в phonekit.ps1 версия 9.9, в README.txt метка
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ('.git', '.github', 'tests', 'tools', 'reports', 'backups')]
        for f in files:
            full = os.path.join(base, f); rel = os.path.relpath(full, ROOT).replace(os.sep, '/')
            if rel.startswith('.'): continue
            data = open(full, 'rb').read()
            if rel == 'phonekit.ps1': data = data.replace(("$KitVersion = '%s'" % cur).encode(), b"$KitVersion = '9.9'")
            if rel == 'README.txt': data = data + b'\r\nUPDATE-MARKER-9.9\r\n'
            z.writestr('phone-kit/' + rel, data)
ZIP = buf.getvalue()
SHA = hashlib.sha256(ZIP).hexdigest()
state = {'sha': '0' * 64}

class Rel(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_address[1]
        if self.path.endswith('.zip'):
            b = ZIP; ct = 'application/zip'
        else:
            b = json.dumps({'tag_name': 'v9.9', 'html_url': 'https://github.com/Meteoric-Potential-Unipessoal-Lda/phone-kit/releases/tag/v9.9',
                            'body': '**SHA-256** `phone-kit-9.9.zip`:\n```\n%s\n```' % state['sha'],
                            'assets': [{'name': 'phone-kit-9.9.zip', 'browser_download_url': 'http://127.0.0.1:%d/phone-kit-9.9.zip' % port}]}).encode()
            ct = 'application/json'
        self.send_response(200); self.send_header('Content-Type', ct); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', 0), Rel)
threading.Thread(target=srv.serve_forever, daemon=True).start()
upd = 'http://127.0.0.1:%d/latest' % srv.server_address[1]

fails = 0
def run(name, inp):
    kit = os.path.join(work, 'kit')
    if not os.path.exists(kit):
        shutil.copytree(ROOT, kit, ignore=shutil.ignore_patterns('.git', 'tests', 'tools', 'reports', 'backups'))
    env = dict(os.environ, MOCK_BRAND='samsung', MOCK_STATE=os.path.join(work, 'state.json'))
    args = [shell, '-NoProfile'] + (['-ExecutionPolicy', 'Bypass'] if os.name == 'nt' else []) + \
           ['-File', os.path.join(kit, 'phonekit.ps1'), '-AdbPath', adb, '-Lang', 'ru', '-NoPause', '-UpdateUrl', upd]
    r = subprocess.run(args, input=inp.encode('utf-8'), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=300)
    log = r.stdout.decode('utf-8', 'replace')
    open(os.path.join(work, name + '.log'), 'w', encoding='utf-8').write(log)
    return kit, log
def check(name, ok, what, log=''):
    global fails
    if ok: print('PASS %s: %s' % (name, what))
    else:
        fails += 1; print('FAIL %s: %s' % (name, what)); print(log[-2500:])

# 1) подменённый архив (сумма не та) -> отказ, файлы прежние
kit, log = run('upd_bad', 'u\nq\n')
check('upd_bad', 'контрольная сумма не совпала' in log, 'отказ при неверной SHA-256', log)
ps = open(os.path.join(kit, 'phonekit.ps1'), encoding='utf-8-sig').read()
check('upd_bad', ("$KitVersion = '%s'" % cur) in ps, 'файлы набора не изменились', log)

# 2) верная сумма -> обновление и перезапуск новой версией
state['sha'] = SHA
kit, log = run('upd_ok', 'u\nq\n')
check('upd_ok', 'контрольная сумма SHA-256 совпала' in log, 'SHA-256 совпала', log)
check('upd_ok', 'Набор обновлён до версии 9.9' in log, 'файлы заменены', log)
ps = open(os.path.join(kit, 'phonekit.ps1'), encoding='utf-8-sig').read()
check('upd_ok', "$KitVersion = '9.9'" in ps, 'phonekit.ps1 новой версии', log)
check('upd_ok', b'UPDATE-MARKER-9.9' in open(os.path.join(kit, 'README.txt'), 'rb').read(), 'README.txt новой версии', log)
check('upd_ok', os.path.exists(os.path.join(kit, 'backups', 'kit-' + cur, 'phonekit.ps1')), 'старые файлы в backups/kit-' + cur, log)
check('upd_ok', re.search(r'ТЕЛЕФОН-НАБОР 9\.9|phone-kit 9\.9|набор 9\.9', log, re.I) is not None or log.count('Что делаем?') >= 2, 'перезапуск новой версией', log)
check('upd_ok', 'U) Обновить набор' not in log.split('Перезапускаю набор')[-1], 'после перезапуска обновление не предлагается', log)

if fails: print('=== updtest: ошибок %d, логи: %s' % (fails, work)); sys.exit(1)
print('PASS updtest (%s)' % shell)
