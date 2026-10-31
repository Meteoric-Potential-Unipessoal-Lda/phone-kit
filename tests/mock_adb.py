#!/usr/bin/env python3
# Подставной adb для тестов phone-kit: эмулирует Samsung Galaxy A10 (MOCK_BRAND=samsung) или Redmi на HyperOS (xiaomi).
# Флаги: MOCK_WIFI (сопряжение по коду 123456), MOCK_NOMDNS, MOCK_OFFLINE, MOCK_BREAK=<пакет> (ломает рабочий стол), MOCK_DNSBROKEN.
# Mock adb for phone-kit tests. Brand via MOCK_BRAND=samsung|xiaomi. State in MOCK_STATE json.
import sys, os, json, shlex, shutil
SD = os.environ.get('MOCK_SDCARD')   # папка на диске вместо /sdcard (пункт 4: find/stat/du/rm/pull/push)
def lp(p): return os.path.join(SD, p[len('/sdcard/'):].lstrip('/')) if p.startswith('/sdcard') else None
def kb(path):
    if os.path.isfile(path): return (os.path.getsize(path) + 1023) // 1024
    t = 0
    for r, ds, fs in os.walk(path):
        for f in fs: t += (os.path.getsize(os.path.join(r, f)) + 1023) // 1024
    return max(t, 4)
def sd_shell(cmd):
    a = shlex.split(cmd)
    if a[:3] == ['du', '-s', '-k']:
        return '\n'.join('%d\t%s' % (kb(lp(x)), x) for x in a[3:] if os.path.exists(lp(x)))
    if a[0] == 'find' and '-exec' in a:
        root = a[1]; base = lp(root); mn = 0
        if '-size' in a: mn = int(a[a.index('-size') + 1].strip('+M')) * 1048576
        out = []
        if os.path.isdir(base):
            for r, ds, fs in os.walk(base):
                for f in fs:
                    full = os.path.join(r, f); sz = os.path.getsize(full)
                    if sz > mn:
                        rel = os.path.relpath(full, base).replace(os.sep, '/')
                        out.append('%d %d %s' % (sz, int(os.path.getmtime(full)), root + ('' if root.endswith('/') else '/') + rel))
        return '\n'.join(out)
    if a[:2] == ['rm', '-rf']:
        for x in a[2:]: shutil.rmtree(lp(x), ignore_errors=True)
        return ''
    if a[:2] == ['rm', '-f']:
        for x in a[2:]:
            if os.path.isfile(lp(x)): os.remove(lp(x))
        return ''
    if a[:2] == ['mkdir', '-p']:
        os.makedirs(lp(a[2]), exist_ok=True); return ''
    if a[:3] == ['df', '-k', '/data']:
        used = sum(kb(os.path.join(SD, d)) for d in os.listdir(SD))
        return 'Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/block/dm-5 30000000 %d %d 50%% /data' % (used, 30000000 - used)
    return None
brand = os.environ.get('MOCK_BRAND', 'samsung')
SF = os.environ.get('MOCK_STATE', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mockstate.json'))
SERIAL = 'R58N123ABC' if brand == 'samsung' else 'a1b2c3d4'
st = {'disabled': ['com.samsung.android.app.watchmanagerstub'] if brand == 'samsung' else [], 'uninst': [], 'settings': {}, 'appops': {}, 'boot': 1}
if os.path.exists(SF):
    st = json.load(open(SF))
def save(): json.dump(st, open(SF, 'w'))

common_sys = ['android', 'com.android.systemui', 'com.android.settings', 'com.android.phone', 'com.android.vending', 'com.google.android.gms',
  'com.google.android.youtube', 'com.google.android.gm', 'com.google.android.feedback', 'com.android.chrome', 'com.google.android.apps.turbo',
  'com.facebook.appmanager', 'com.facebook.services', 'com.facebook.system', 'com.android.bips', 'com.android.egg', 'com.google.android.inputmethod.latin',
  'com.google.android.apps.messaging', 'com.google.android.dialer', 'com.google.android.apps.wellbeing']
if brand == 'samsung':
    sysp = common_sys + ['com.sec.android.app.launcher', 'com.samsung.android.honeyboard', 'com.samsung.android.kgclient', 'com.samsung.android.rubin.app',
      'com.samsung.android.mapsagent', 'com.samsung.android.app.omcagent', 'com.samsung.android.app.spage', 'com.samsung.android.bixby.agent',
      'com.samsung.android.arzone', 'com.samsung.android.game.gos', 'com.samsung.android.app.watchmanagerstub', 'com.samsung.android.fmm',
      'com.sec.android.app.sbrowser', 'com.samsung.android.app.tips', 'com.samsung.android.beaconmanager', 'com.microsoft.skydrive', 'com.osp.app.signin',
      'com.samsung.android.dialer', 'com.samsung.android.messaging']
    props = {'ro.product.model': 'SM-A105FN', 'ro.product.brand': 'samsung', 'ro.product.manufacturer': 'samsung', 'ro.product.device': 'a10',
      'ro.build.version.sdk': '30', 'ro.build.version.release': '11', 'ro.build.version.security_patch': '2023-02-01', 'ro.build.version.oneui': '30100',
      'ro.build.characteristics': 'phone', 'ro.serialno': SERIAL, 'ro.boot.verifiedbootstate': 'green', 'ro.build.fingerprint': 'samsung/a10/a10:11/RP1A/A105FNXXU9CWB1:user/release-keys',
      'persist.radio.imei': '356789012345678'}
    home = 'com.sec.android.app.launcher/com.sec.android.app.launcher.activities.LauncherActivity'
    ime = 'com.samsung.android.honeyboard/.service.HoneyBoardService'
else:
    sysp = common_sys + ['com.miui.home', 'com.miui.msa.global', 'com.miui.analytics', 'com.miui.daemon', 'com.xiaomi.mipicks', 'com.miui.securitycenter',
      'com.lbe.security.miui', 'com.xiaomi.joyose', 'com.miui.powerkeeper', 'com.miui.hybrid', 'com.miui.player', 'com.mi.globalbrowser', 'com.miui.yellowpage',
      'com.xiaomi.xmsf', 'com.miui.android.fashiongallery']
    props = {'ro.product.model': '23053RN02Y', 'ro.product.brand': 'Redmi', 'ro.product.manufacturer': 'Xiaomi', 'ro.product.device': 'heat',
      'ro.build.version.sdk': '34', 'ro.build.version.release': '14', 'ro.build.version.security_patch': '2025-09-01', 'ro.mi.os.version.name': 'OS1.0',
      'ro.mi.os.version.incremental': 'OS1.0.5.0.UMTEUXM', 'ro.build.characteristics': 'default', 'ro.serialno': SERIAL, 'ro.boot.verifiedbootstate': 'green',
      'ro.build.fingerprint': 'Redmi/heat/heat:14/UP1A/OS1.0.5.0:user/release-keys'}
    home = 'com.miui.home/.launcher.Launcher'
    ime = 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME'
third = {'com.whatsapp': 'com.android.vending', 'org.telegram.messenger': 'com.android.vending', 'com.super.cleaner.booster': 'com.google.android.packageinstaller',
  'com.hidden.spy.svc': 'com.android.packageinstaller', 'com.oldgame.idle': 'com.android.vending', 'org.chromium.webapk.a550a015e23cabaf4_v2': 'com.android.chrome',
  'com.booking': 'null'}
launch = ['com.whatsapp', 'org.telegram.messenger', 'com.super.cleaner.booster', 'com.oldgame.idle', 'org.chromium.webapk.a550a015e23cabaf4_v2', 'com.booking',
  'com.google.android.youtube', 'com.google.android.gm', 'com.android.chrome', 'com.android.settings', 'com.android.vending', 'com.sec.android.app.sbrowser',
  'com.miui.player', 'com.mi.globalbrowser', 'com.xiaomi.mipicks', 'com.google.android.dialer', 'com.google.android.apps.messaging']
allp = sysp + list(third)

def installed(): return [p for p in allp if p not in st['uninst']]
def plist(ps): return '\n'.join('package:' + p for p in ps)

def shell(cmd):
    if SD:
        r = sd_shell(cmd)
        if r is not None: return r
    a = cmd.split()
    if cmd == 'getprop':
        return '\n'.join('[%s]: [%s]' % kv for kv in props.items()) + '\n[sys.boot_completed]: [1]'
    if a[0] == 'getprop':
        if a[1] == 'sys.boot_completed': return '1' if st['boot'] else ''
        return props.get(a[1], '')
    if cmd == 'cat /proc/meminfo': return 'MemTotal:        1800000 kB\nMemFree:          100000 kB\nMemAvailable:     300000 kB\nSwapTotal:       1500000 kB\nSwapFree:         300000 kB'
    if cmd == 'cat /proc/uptime': return '1300000.5 2000000.1'
    if cmd == 'cat /proc/loadavg': return '6.10 5.80 5.50 2/1500 12345'
    if cmd == 'cat /sys/devices/system/cpu/present': return '0-7'
    if cmd.startswith('cat /sys/devices/system/cpu/cpu'):
        return '1600000' if 'max' in cmd else '900000'
    if cmd == 'df -k /data': return 'Filesystem     1K-blocks     Used Available Use% Mounted on\n/dev/block/dm-5 25000000 22500000 2500000  90% /data'
    if cmd == 'ps -A -o RSS,NAME':
        return 'RSS NAME\n250000 system_server\n180000 com.android.systemui\n120000 com.samsung.android.rubin.app\n90000 com.oldgame.idle\n60000 com.hidden.spy.svc\n150000 com.whatsapp\n70000 com.miui.msa.global\n500000 com.android.chrome'
    if cmd.startswith('pidof'): return '1234'
    if cmd == 'dumpsys cpuinfo': return 'Load: 6.1 / 5.8 / 5.5\nCPU usage from 1000ms\n  25% 1000/system_server: 10% user + 15% kernel\n  12% 2000/com.android.chrome: 8% user\n45% TOTAL: 30% user + 15% kernel'
    if cmd == 'dumpsys battery': return 'Current Battery Service state:\n  AC powered: false\n  USB powered: true\n  level: 64\n  temperature: 412\n  health: 2'
    if cmd == 'dumpsys thermalservice': return 'IsStatusOverride: false\nThermal Status: 1\nCurrent temperatures from HAL:\n\tTemperature{mValue=41.2, mType=2, mName=battery, mStatus=0}\n\tTemperature{mValue=55.0, mType=0, mName=cpu0, mStatus=1}\nCurrent cooling devices from HAL:'
    if cmd == 'dumpsys diskstats':
        return 'Latency: 2ms [512B Data Write]\nData-Free: 2500000K / 25000000K total = 10% free\nApp Package Names: ["com.whatsapp","com.android.chrome","com.oldgame.idle"]\nApp Sizes: [60000000,200000000,500000000]\nApp Data Sizes: [3000000000,400000000,50000000]\nCache Sizes: [500000000,700000000,10000000]\nPhotos Size: 6000000000\nVideos Size: 3500000000\nAudio Size: 200000000\nDownloads Size: 1500000000\nApp Size: 4000000000\nApp Data Size: 5000000000\nApp Cache Size: 1200000000\nSystem Size: 9000000000\nOther Size: 800000000'
    if cmd == 'pm list packages -U':
        return 'package:com.google.android.youtube uid:10150\npackage:com.whatsapp uid:10200\npackage:com.android.chrome uid:10099'
    if cmd == 'dumpsys batterystats':
        return ('Battery History:\n  ...\nStatistics since last charge:\n  System starts: 3, currently on battery: true\n  Time on battery: 5h 12m 3s 0ms (100.0%) realtime, 2h 1m uptime\n\n'
                '  Estimated power use (mAh):\n    Capacity: 5000, Computed drain: 1500, actual drain: 1400-1500\n    Screen: 400\n'
                '    Uid u0a150: 420.5 ( cpu=100 wake=5 )\n    Uid 1000: 300\n    Uid u0a200: 120.1\n    Uid u0a99: 60\n\n'
                '  All kernel wake locks:\n    Uid u0a150: 999\n')
    if a[:4] == ['du', '-s', '-k', '/sdcard/Android/media/com.whatsapp/WhatsApp/Media']:
        return '2500000\t/sdcard/Android/media/com.whatsapp/WhatsApp/Media\n1300000\t/sdcard/Telegram\n8000000\t/sdcard/DCIM\n1200000\t/sdcard/Download'
    if a[:3] == ['pm', 'list', 'packages']:
        fl = ''.join(x.strip('-') for x in a[3:])
        inst = installed()
        if 'u' in fl: base = allp
        else: base = inst
        if 's' in fl: base = [p for p in base if p in sysp]
        if '3' in fl: base = [p for p in base if p in third]
        if 'd' in fl: base = [p for p in base if p in st['disabled']]
        if 'i' in fl: return '\n'.join('package:%s  installer=%s' % (p, third.get(p, 'null')) for p in base)
        return plist(base)
    if cmd == 'pm list users': return 'Users:\n\tUserInfo{0:Владелец:c13} running'
    if cmd == 'pm list features': return 'feature:android.hardware.telephony\nfeature:android.hardware.nfc'
    if a[:2] == ['pm', 'path']: return ('package:/system/app/x.apk' if a[2] in installed() else '')
    if cmd.startswith('cmd package resolve-activity') and 'HOME' in cmd and os.environ.get('MOCK_BREAK') in st['disabled']: return 'android/com.android.internal.app.ResolverActivity'
    if cmd.startswith('cmd package resolve-activity') and 'HOME' in cmd: return 'priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\n' + home
    if cmd.startswith('cmd package resolve-activity') and 'SETTINGS' in cmd: return 'priority=0\ncom.android.settings/.Settings'
    if cmd.startswith('cmd package query-activities') and 'LAUNCHER' in cmd: return '\n'.join(p + '/.Main' for p in launch if p in installed() and p not in st['disabled'])
    if cmd == 'dumpsys role':
        return 'Role Manager:\n  user_id=0\n    roles=[\n      {\n        name=android.app.role.HOME\n        holders=%s\n      }\n      {\n        name=android.app.role.DIALER\n        holders=%s\n      }\n      {\n        name=android.app.role.BROWSER\n        holders=com.android.chrome\n      }\n    ]' % (home.split('/')[0], 'com.samsung.android.dialer' if brand == 'samsung' else 'com.google.android.dialer')
    if cmd == 'settings get secure default_input_method': return ime
    if cmd == 'settings get secure enabled_accessibility_services': return 'com.hidden.spy.svc/com.hidden.spy.svc.Acc'
    if cmd == 'settings get secure enabled_notification_listeners': return 'com.whatsapp/com.whatsapp.Nls:com.hidden.spy.svc/x.N'
    if a[:2] == ['settings', 'get']:
        return st['settings'].get(a[3], {'window_animation_scale': '1.0', 'low_power': '1', 'package_verifier_enable': '1', 'private_dns_mode': 'opportunistic'}.get(a[3], 'null'))
    if a[:2] == ['settings', 'put']: st['settings'][a[3]] = a[4]; save(); return ''
    if a[:2] == ['settings', 'delete']: st['settings'].pop(a[3], None); save(); return 'Deleted 1 rows'
    if cmd == 'dumpsys usagestats':
        return ('In-memory daily stats\n  packages\n    package=com.whatsapp totalTimeUsed="12:01:02" lastTimeUsed="2026-10-28 10:00:00"\n'
          '    package=org.telegram.messenger totalTimeUsed="1:01:02" lastTimeUsed="2026-10-27 10:00:00"\n'
          '    package=com.google.android.youtube totalTimeUsed="3:01:02" lastTimeUsed="2026-10-27 10:00:00"\n'
          '    package=com.android.chrome totalTimeUsed="2:01:02" lastTimeUsed="2026-10-27 10:00:00"\n'
          '    package=com.miui.home totalTimeUsed="2:01:02" lastTimeUsed="2026-10-27 10:00:00"\n'
          '    package=com.sec.android.app.launcher totalTimeUsed="2:01:02" lastTimeUsed="2026-10-27 10:00:00"\n'
          '    package=com.oldgame.idle totalTimeUsed="00:00:30" lastTimeUsed="2026-05-01 10:00:00"\n'
          '    package=com.android.settings totalTimeUsed="00:10:00" lastTimeUsed="2026-10-27 10:00:00"\n')
    if cmd == 'dumpsys device_policy': return 'Enabled Device Admins (User 0, provisioningState: 3):\n  com.hidden.spy.svc/.Adm:\n    ComponentInfo{com.hidden.spy.svc/com.hidden.spy.svc.Adm}\n'
    if cmd.startswith('cmd appops query-op'):
        if 'SYSTEM_ALERT_WINDOW' in cmd: return 'com.hidden.spy.svc\ncom.whatsapp'
        return 'com.super.cleaner.booster'
    if a[:2] == ['cmd', 'appops'] and a[2] == 'get':
        m = st['appops'].get(a[3]); return ('RUN_ANY_IN_BACKGROUND: %s' % m) if m else 'No operations.'
    if a[:2] == ['cmd', 'appops'] and a[2] == 'set': st['appops'][a[3]] = a[5]; save(); return ''
    if cmd == 'dumpsys connectivity' and os.environ.get('MOCK_DNSBROKEN') and st['settings'].get('private_dns_mode') == 'hostname': return 'Active default network: 100 PRIVATE_DNS_BROKEN'
    if cmd == 'dumpsys connectivity': return 'Active default network: 100\n  NetworkAgentInfo{network{100}  ni{WIFI CONNECTED} ... VALIDATED}'
    if cmd == 'dumpsys wifi': return ''
    if cmd.startswith('logcat'): return '--------- beginning of crash\nE AndroidRuntime: Process: com.sec.android.app.launcher, PID: 1\nE AndroidRuntime: java.lang.OutOfMemoryError: Failed to allocate Bitmap 11816x11816\nE AndroidRuntime: Process: com.sec.android.app.launcher, PID: 2'
    if a[:2] == ['pm', 'disable-user']:
        p = a[-1]
        if brand == 'xiaomi' and p == 'com.miui.msa.global':
            return 'Exception occurred while executing: java.lang.SecurityException: Cannot disable system packages'
        if p not in st['disabled']: st['disabled'].append(p)
        save(); return 'Package %s new state: disabled-user' % p
    if a[:2] == ['pm', 'enable']:
        p = a[-1]
        if p in st['disabled']: st['disabled'].remove(p)
        save(); return 'Package %s new state: enabled' % p
    if a[:2] == ['pm', 'uninstall']:
        p = a[-1]
        if p not in st['uninst']: st['uninst'].append(p)
        save(); return 'Success'
    if 'install-existing' in cmd:
        p = a[-1]
        if p in st['uninst']: st['uninst'].remove(p)
        save(); return 'Package %s installed for user: 0' % p
    if cmd.startswith('pm trim-caches'): return ''
    if cmd in ('svc power reboot', 'reboot'):
        if os.environ.get('MOCK_WIFI'): st['paired'] = 0; save()   # как Xiaomi: после перезагрузки беспроводная отладка выключена
        return ''
    return '/system/bin/sh: unknown mock: ' + cmd

args = sys.argv[1:]
if args and args[0] == '-s': args = args[2:]
if not args: sys.exit(0)
c = args[0]
if c in ('start-server', 'kill-server', 'reconnect'): sys.exit(0)
if c == 'version': print('Android Debug Bridge version 1.0.41 (mock)'); sys.exit(0)
WS = '192.168.1.113:41235'
if os.environ.get('MOCK_WIFI'):
    if c == 'devices':
        print('List of devices attached'); 
        if st.get('paired'): print('adb-%s-AbCd._adb-tls-connect._tcp\tdevice' % SERIAL)
        sys.exit(0)
    if c == 'mdns':
        print('List of discovered mdns services')
        if not os.environ.get('MOCK_NOMDNS'): print('adb-%s-AbCd\t_adb-tls-pairing._tcp\t192.168.1.113:37123' % SERIAL)
        if os.environ.get('MOCK_MDNSJUNK'): print('adb-OLD-ZzZz\t_adb-tls-pairing._tcp\t10.148.34.2:36')   # мусор из кэша mDNS (как у Леонида)
        sys.exit(0)
    if c == 'pair':
        if args[2] == '123456': st['paired'] = 1; save(); print('Successfully paired to %s [guid=adb-%s-AbCd]' % (args[1], SERIAL))
        elif args[1].endswith(':41235'): print('error: protocol fault (couldn\'t read status message): Success')
        else: print('Failed: Wrong password or connection was dropped.')
        sys.exit(0)
if c == 'devices': print('List of devices attached\n%s\t%s\n' % (SERIAL, 'offline' if os.environ.get('MOCK_OFFLINE') else 'device')); sys.exit(0)
if c == 'mdns': print('List of discovered mdns services'); sys.exit(0)
if c == 'shell':
    print(shell(' '.join(args[1:]))); sys.exit(0)
if c == 'pull' and SD:
    srcs = [x for x in args[1:-1] if x != '-a']; dst = args[-1]; n = 0
    for x in srcs:
        if os.path.isfile(lp(x)):
            if os.path.basename(x).startswith('BROKEN'):   # имитация обрыва: файл скопировался не целиком
                open(os.path.join(dst, os.path.basename(x)), 'wb').write(b'x'); continue
            shutil.copy2(lp(x), os.path.join(dst, os.path.basename(x))); n += 1
    print('%s: %d files pulled, 0 skipped.' % (srcs[0] if srcs else '', n)); sys.exit(0)
if c == 'push' and SD:
    srcs = args[1:-1]; dst = args[-1]; n = 0
    for x in srcs: shutil.copy2(x, os.path.join(lp(dst), os.path.basename(x))); n += 1
    print('%d files pushed, 0 skipped.' % n); sys.exit(0)
print('mock: unknown ' + ' '.join(args)); sys.exit(1)
