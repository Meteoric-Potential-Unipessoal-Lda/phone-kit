# Проверка веб-интерфейса без браузера: запускает набор с -Web -NoBrowser на подставном adb,
# отвечает на вопросы через HTTP, как это делает страница, и проверяет события.
# Запуск: python3 tests/webtest.py [pwsh|powershell]   Код выхода 1 — ошибка.
import json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
shell = sys.argv[1] if len(sys.argv) > 1 else 'pwsh'
work = tempfile.mkdtemp()
kit = os.path.join(work, 'kit')
shutil.copytree(ROOT, kit, ignore=shutil.ignore_patterns('.git', 'tests', 'tools', 'reports', 'backups'))
adb = os.path.join(ROOT, 'tests', 'mock_adb.py')
if os.name == 'nt':
    wrap = os.path.join(work, 'adb.cmd')
    open(wrap, 'w').write('@"%s" "%s" %%*\n' % (sys.executable, adb))
    adb = wrap
env = dict(os.environ, MOCK_BRAND='samsung', MOCK_STATE=os.path.join(work, 'state.json'))
# подставной GitHub: «вышла версия 9.9»
import http.server, threading
class Rel(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = json.dumps({'tag_name': 'v9.9', 'html_url': 'https://github.com/Meteoric-Potential-Unipessoal-Lda/phone-kit/releases/tag/v9.9'}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
rel = http.server.HTTPServer(('127.0.0.1', 0), Rel)
threading.Thread(target=rel.serve_forever, daemon=True).start()
upd_url = 'http://127.0.0.1:%d/latest' % rel.server_address[1]
out = open(os.path.join(work, 'out.log'), 'wb')
p = subprocess.Popen([shell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', os.path.join(kit, 'phonekit.ps1'),
                      '-AdbPath', adb, '-Web', '-NoBrowser', '-Lang', 'ru', '-UpdateUrl', upd_url] if os.name == 'nt' else
                     [shell, '-NoProfile', '-File', os.path.join(kit, 'phonekit.ps1'), '-AdbPath', adb, '-Web', '-NoBrowser', '-Lang', 'ru', '-UpdateUrl', upd_url],
                     stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT, env=env)
def fail(msg):
    print('FAIL', msg)
    try: p.kill()
    except Exception: pass
    print(open(os.path.join(work, 'out.log'), 'rb').read().decode('utf-8', 'replace')[-3000:])
    sys.exit(1)
url = None
for _ in range(300):
    time.sleep(0.2)
    m = re.search(rb'(http://127\.0\.0\.1:\d+/\?t=[a-z0-9]+)', open(os.path.join(work, 'out.log'), 'rb').read())
    if m: url = m.group(1).decode(); break
    if p.poll() is not None: break
if not url: fail('no URL in output')
base, token = url.split('/?t=')
def get(path):
    return json.loads(urllib.request.urlopen(base + path + ('&' if '?' in path else '?') + 't=' + token, timeout=10).read().decode('utf-8'))
def post(path, body):
    req = urllib.request.Request(base + path + '?t=' + token, data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=10).read().decode('utf-8'))
html = urllib.request.urlopen(url, timeout=10).read().decode('utf-8')
if 'phone-kit' not in html: fail('page not served')
try:
    urllib.request.urlopen(base + '/api/state?t=wrong', timeout=10); fail('wrong token accepted')
except urllib.error.HTTPError as e:
    if e.code != 403: fail('wrong token: %s' % e.code)
if 'ui_start_t' not in get('/api/lang?code=de'): fail('lang file not served')
seq, events, answered, switched = 0, [], set(), False
deadline = time.time() + 600
while time.time() < deadline:
    st = get('/api/state?since=%d' % seq)
    events += st['events']; seq = st['seq']
    q = st.get('question')
    if q and q['id'] not in answered:
        answered.add(q['id'])
        ex = q.get('extra') or {}
        if ex.get('screen') == 'start':
            post('/api/answer', {'id': q['id'], 'value': '1'})   # диагностика
        elif q['kind'] == 'text':
            post('/api/answer', {'id': q['id'], 'value': 'webtest'})
            post('/api/lang', {'code': 'de'}); switched = True       # дальше — по-немецки
        else:
            post('/api/answer', {'id': q['id'], 'value': ''})
    if st.get('finished'): break
    if p.poll() is not None: fail('kit exited early, code %s' % p.returncode)
    time.sleep(0.3)
else:
    fail('timeout')
types = [e['type'] for e in events]
for t in ('stage', 'device', 'summary', 'report', 'finished', 'update', 'client'):
    if t not in types: fail('no %s event' % t)
summ = [e['data'] for e in events if e['type'] == 'summary'][0]
if not (0 < int(summ['dataPct']) <= 100): fail('summary dataPct %s' % summ['dataPct'])
de = json.load(open(os.path.join(ROOT, 'data', 'lang', 'de.json'), encoding='utf-8'))
prefix = de['m435'].split('{0}')[0].strip()
if not any(e['type'] == 'log' and str(e['data'].get('t', '')).strip().startswith(prefix) for e in events): fail('language switch did not apply (no "%s")' % prefix)
if [e['data'] for e in events if e['type'] == 'update'][0]['version'] != '9.9': fail('update version')
st_sum = [e['data'] for e in events if e['type'] == 'summary'][0]
if not st_sum.get('storage') or not st_sum['storage'].get('tips'): fail('no storage tips in summary')
if not st_sum.get('battery') or not st_sum['battery'].get('apps'): fail('no battery apps in summary')
ch = urllib.request.urlopen(base + '/api/client?t=' + token, timeout=10).read().decode('utf-8')
if 'phone-kit' not in ch or '<html' not in ch: fail('client report not served')
rep = [e['data'] for e in events if e['type'] == 'report'][0]
if not os.path.exists(rep['zip']): fail('report zip missing')
post('/api/close', {})
try: p.wait(timeout=30)
except subprocess.TimeoutExpired: fail('kit did not exit after close')
if p.returncode != 0: fail('exit code %s' % p.returncode)
print('PASS webtest (%s): %d events, report %s' % (shell, len(events), os.path.basename(rep['zip'])))
