#!/usr/bin/env python3
# Подставной adbd по TCP — проверка протокола phone-kit Mobile (AdbConn): CNXN, AUTH (подпись RSA и новый ключ), OPEN shell:, WRTE/OKAY/CLSE.
# Команды shell выполняет tests/mock_adb.py (тот же подставной телефон, что в сценариях набора).
# python3 fake_adbd.py PORT   Окружение:
#   FAKE_KEYS=файл   разрешённые ключи (формат adb_keys: base64 имя), сюда же дописывается ключ после «Разрешить»
#   FAKE_ALLOW=1     на экране магнитолы «нажали Разрешить» (иначе новый ключ не принимается — клиент ждёт и сдаётся)
#   FAKE_TLS=1       ответить STLS, как порт беспроводной отладки Android 11+, и закрыть (клиент без TLS)
#   FAKE_TLSCA=файл  TLS-порт беспроводной отладки: STLS -> TLS 1.3, сертификат клиента должен быть в файле (PEM),
#                    дальше обычный протокол внутри TLS (как adbd Android 11+ после сопряжения)
#   FAKE_MAXDATA=N   размер куска WRTE (по умолчанию 4096 — как у старых adbd, ответ идёт многими кусками)
import os, socket, struct, subprocess, sys, threading, base64, hashlib, ssl, tempfile, datetime

CNXN, AUTH, OPEN, OKAY, CLSE, WRTE, STLS = 0x4e584e43, 0x48545541, 0x4e45504f, 0x59414b4f, 0x45534c43, 0x45545257, 0x534c5453
HERE = os.path.dirname(os.path.abspath(__file__))
MOCK = os.path.join(os.path.dirname(HERE), 'mock_adb.py')
KEYS = os.environ.get('FAKE_KEYS', os.path.join(HERE, 'fake_adb_keys'))
MAXDATA = int(os.environ.get('FAKE_MAXDATA', '4096'))
SHA1_PREFIX = bytes([0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14])
lock = threading.Lock()

def log(*a): print('fake_adbd:', *a, file=sys.stderr, flush=True)

def send(s, cmd, a0, a1, data=b''):
    s.sendall(struct.pack('<6I', cmd, a0, a1, len(data), sum(data) & 0xffffffff, cmd ^ 0xffffffff) + data)

def recv_exact(s, n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError
        b += c
    return b

def read(s):
    cmd, a0, a1, ln, crc, magic = struct.unpack('<6I', recv_exact(s, 24))
    if magic != cmd ^ 0xffffffff: raise ValueError('bad magic')
    data = recv_exact(s, ln) if ln else b''
    if (sum(data) & 0xffffffff) != crc: raise ValueError('bad checksum')   # клиент шлёт версию 0x01000000 — сумма обязательна
    return cmd, a0, a1, data

def parse_pub(line):
    raw = base64.b64decode(line.split()[0])
    words, n0inv = struct.unpack_from('<II', raw, 0)
    n = int.from_bytes(raw[8:8 + words * 4], 'little')
    rr = int.from_bytes(raw[8 + words * 4:8 + words * 8], 'little')
    e, = struct.unpack_from('<I', raw, 8 + words * 8)
    # проверка формата: n0inv = -1/n mod 2^32, rr = 2^(2*bits) mod n
    assert (n * n0inv) % (1 << 32) == (1 << 32) - 1, 'n0inv'
    assert rr == pow(2, 2 * words * 32, n), 'rr'
    return n, e

def verify(line, token, sig):
    try:
        n, e = parse_pub(line)
    except Exception as ex:
        log('bad key', ex); return False
    k = (n.bit_length() + 7) // 8
    m = pow(int.from_bytes(sig, 'big'), e, n).to_bytes(k, 'big')
    em = b'\x00\x01' + b'\xff' * (k - 3 - len(SHA1_PREFIX) - len(token)) + b'\x00' + SHA1_PREFIX + token
    return m == em

def keys():
    if not os.path.exists(KEYS): return []
    return [l.strip() for l in open(KEYS) if l.strip()]

def shell(cmd):
    env = dict(os.environ)
    r = subprocess.run(['python3', MOCK, 'shell', cmd], env=env, capture_output=True)
    return r.stdout + r.stderr

SRV_CTX = None
def tls_ctx():
    global SRV_CTX
    if SRV_CTX: return SRV_CTX
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    nm = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'adbd')])
    now = datetime.datetime.now(datetime.timezone.utc)
    c = x509.CertificateBuilder().subject_name(nm).issuer_name(nm).public_key(k.public_key()).serial_number(1) \
        .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=30)).sign(k, hashes.SHA256())
    d = tempfile.mkdtemp()
    open(d + '/c.pem', 'wb').write(c.public_bytes(serialization.Encoding.PEM))
    open(d + '/k.pem', 'wb').write(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(d + '/c.pem', d + '/k.pem')
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(os.environ['FAKE_TLSCA'])
    SRV_CTX = ctx
    return ctx

def handle(s):
    try:
        cmd, a0, a1, data = read(s)
        if cmd != CNXN: log('expected CNXN'); return
        if os.environ.get('FAKE_TLS'): send(s, STLS, 0x01000000, 0); return
        if os.environ.get('FAKE_TLSCA'):
            send(s, STLS, 0x01000000, 0)
            cmd, a0, a1, data = read(s)
            if cmd != STLS: log('expected STLS from client'); return
            try:
                s = tls_ctx().wrap_socket(s, server_side=True)
            except ssl.SSLError as e:
                log('tls refused:', e.reason); return
            log('tls ok', s.version())
            run_session(s)
            return
        token = os.urandom(20)
        send(s, AUTH, 1, 0, token)
        ok = False
        while not ok:
            cmd, a0, a1, data = read(s)
            if cmd != AUTH: continue
            if a0 == 2:
                if any(verify(k, token, data) for k in keys()): ok = True; break
                token = os.urandom(20); send(s, AUTH, 1, 0, token)
            elif a0 == 3:
                pub = data.rstrip(b'\0').decode()
                parse_pub(pub)   # формат ключа должен быть верным
                if os.environ.get('FAKE_ALLOW'):
                    with lock: open(KEYS, 'a').write(pub + '\n')
                    log('key allowed:', pub.split()[-1]); ok = True
                else:
                    log('key shown, nobody pressed Allow'); threading.Event().wait(60); return
        run_session(s)
    except (EOFError, ConnectionResetError, BrokenPipeError):
        pass
    except Exception as ex:
        log('error', repr(ex))
    finally:
        s.close()

def run_session(s):
    try:
        send(s, CNXN, 0x01000000, MAXDATA, b'device::ro.product.name=fake;ro.product.model=FakeUnit;\0')
        local = 100
        while True:
            cmd, a0, a1, data = read(s)
            if cmd == OPEN:
                svc = data.rstrip(b'\0').decode()
                local += 1
                if not svc.startswith('shell:'): send(s, CLSE, 0, a0); continue
                remote = a0
                send(s, OKAY, local, remote)
                out = shell(svc[6:])
                for i in range(0, len(out), MAXDATA):
                    send(s, WRTE, local, remote, out[i:i + MAXDATA])
                    while True:   # ждём подтверждения куска
                        c2, b0, b1, _ = read(s)
                        if c2 == OKAY and b1 == local: break
                send(s, CLSE, local, remote)
            # OKAY/CLSE от клиента после закрытия — пропускаем
    except (EOFError, ConnectionResetError, BrokenPipeError):
        pass
    except Exception as ex:
        log('error', repr(ex))
    finally:
        s.close()

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 15555
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', port)); srv.listen(8)
    log('listening', port)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == '__main__':
    main()
