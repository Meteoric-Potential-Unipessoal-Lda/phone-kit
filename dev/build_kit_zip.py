#!/usr/bin/env python3
# Архив релиза набора: python3 dev/build_kit_zip.py out/phone-kit-X.Y.zip
# Внутри папка phone-kit/ с файлами для мастера (без tests/, dev/, mobile/); start.command — с правом запуска (755).
import os, sys, zipfile, glob
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ['phonekit.ps1', 'start.bat', 'start.command', 'prepare.bat', 'README.txt', 'LICENSE', 'ui/index.html',
         'data/ru.tsv', 'data/ads.tsv', 'data/uad.tsv']
FILES += sorted(os.path.relpath(f, ROOT) for f in glob.glob(os.path.join(ROOT, 'data/notes/*.tsv')))
FILES += sorted(os.path.relpath(f, ROOT) for f in glob.glob(os.path.join(ROOT, 'data/lang/*.json')))
out = sys.argv[1]
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in FILES:
        data = open(os.path.join(ROOT, f), 'rb').read()
        zi = zipfile.ZipInfo('phone-kit/' + f.replace(os.sep, '/'), date_time=(2026, 1, 1, 0, 0, 0))
        zi.create_system = 3
        zi.external_attr = (0o100755 if f == 'start.command' else 0o100644) << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, data)
print(len(FILES), 'files ->', out)
