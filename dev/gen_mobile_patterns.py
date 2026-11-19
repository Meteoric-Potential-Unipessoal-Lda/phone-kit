# -*- coding: utf-8 -*-
# Переносит правила защиты и белый список команд из phonekit.ps1 в mobile/src/net/zherdyev/phonekit/Pat.java,
# чтобы набор на ноутбуке и приложение на телефоне решали одинаково (phone-kit Mobile).
# python3 dev/gen_mobile_patterns.py            — записать Pat.java
# python3 dev/gen_mobile_patterns.py --check    — только проверить, что Pat.java совпадает (для CI)
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PS = open(os.path.join(ROOT, 'phonekit.ps1'), encoding='utf-8-sig').read().replace('\r\n', '\n')
OUT = os.path.join(ROOT, 'mobile', 'src', 'net', 'zherdyev', 'phonekit', 'Pat.java')

VARS = {}

def ps_expr(s):
    """Строка PowerShell из '...' (с '' внутри), +, ( ), $Var — в обычную строку."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c in ' +()\t\n': i += 1; continue
        if c == "'":
            j, buf = i + 1, []
            while True:
                if s[j] == "'" and j + 1 < len(s) and s[j + 1] == "'": buf.append("'"); j += 2; continue
                if s[j] == "'": break
                buf.append(s[j]); j += 1
            out.append(''.join(buf)); i = j + 1; continue
        if c == '"':
            # строка в двойных кавычках: у нас в шаблонах нет подстановок переменных ($ только как конец строки регулярки)
            j, buf = i + 1, []
            while True:
                if s[j] == '"' and j + 1 < len(s) and s[j + 1] == '"': buf.append('"'); j += 2; continue
                if s[j] == '"': break
                if s[j] == '$' and j + 1 < len(s) and re.match(r'[A-Za-z_{]', s[j + 1]): raise SystemExit('PS variable inside "..." not supported: ' + s[i:i + 60])
                buf.append(s[j]); j += 1
            out.append(''.join(buf)); i = j + 1; continue
        if c == '$':
            m = re.match(r'\$(\w+)', s[i:]); out.append(VARS[m.group(1)]); i += len(m.group(0)); continue
        raise SystemExit('bad PS expression near: ' + s[i:i + 40])
    return ''.join(out)

def scalar(name):
    m = re.search(r'(?m)^\$' + name + r' = (.+)$', PS)
    if not m: raise SystemExit('not found: $' + name)
    VARS[name] = ps_expr(m.group(1).strip())
    return VARS[name]

def array(name):
    m = re.search(r'(?m)^\$' + name + r' = @\(\n(.*?)\n\)', PS, re.S)
    if not m: raise SystemExit('not found: $' + name)
    r = []
    for l in m.group(1).split('\n'):
        l = l.strip()
        if not l or l.startswith('#'): continue
        # несколько элементов в строке: делим по запятым вне кавычек
        parts, cur, q = [], '', ''
        for ch in l:
            if ch in "'\"" and (not q or q == ch): q = '' if q else ch
            if ch == ',' and not q: parts.append(cur); cur = ''; continue
            cur += ch
        parts.append(cur)
        r += [ps_expr(x) for x in parts if x.strip()]
    return r

def jstr(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

scalar('SettingKeys')
names = ['AskPattern', 'AutoPattern', 'KeepBgPattern', 'CleanerPattern', 'StoreInstallers', 'FileInstallers', 'PreloadInstallers', 'KnownSideload', 'NotCleaner']
vals = {n: scalar(n) for n in names}
prot = array('ProtectedPatterns')
write = array('WritePatterns')
read = array('ReadOnlyPatterns')
m = re.search(r"if \(\$cmd -match '([^']+)'\) \{ return \$false \}", PS)
meta = m.group(1)

lines = ['// СГЕНЕРИРОВАНО dev/gen_mobile_patterns.py из phonekit.ps1 — не править руками.',
         '// Правила защиты и белый список команд записи — те же, что у набора на ноутбуке.',
         'package net.zherdyev.phonekit;', '', 'import java.util.regex.Pattern;', '',
         'final class Pat {', '  private Pat() {}',
         '  // PowerShell -match не различает регистр', '  static Pattern ci(String p) { return Pattern.compile(p, Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE); }']
for n in names:
    v = vals[n]
    if v.startswith('(?i)'): v = v[4:]
    lines.append('  static final Pattern %s = ci(%s);' % (n.upper()[0] + n[1:], jstr(v)))
lines.append('  static final Pattern[] PROTECTED = {')
for p in prot: lines.append('    ci(%s),' % jstr(p))
lines.append('  };')
lines.append('  // -cmatch: с учётом регистра')
lines.append('  static final Pattern[] WRITE = {')
for p in write: lines.append('    Pattern.compile(%s),' % jstr(p))
lines.append('  };')
lines.append('  static final Pattern[] READ = {')
for p in read: lines.append('    Pattern.compile(%s),' % jstr(p))
lines.append('  };')
lines.append('  static final Pattern WRITE_META = Pattern.compile(%s);' % jstr(meta))
lines.append('}')
text = '\n'.join(lines) + '\n'

if '--check' in sys.argv:
    cur = open(OUT, encoding='utf-8').read() if os.path.exists(OUT) else ''
    if cur != text: raise SystemExit('Pat.java отстал от phonekit.ps1: запустите python3 dev/gen_mobile_patterns.py')
    print('Pat.java OK (%d protect, %d write)' % (len(prot), len(write)))
else:
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, 'w', encoding='utf-8', newline='\n').write(text)
    print('written', OUT, len(prot), 'protect', len(write), 'write', len(read), 'read')
