package net.zherdyev.phonekit;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Проверка логики phone-kit Mobile на обычной Java (без телефона):
 *   --mock                   телефон = tests/mock_adb.py (MOCK_BRAND и др. из окружения)
 *   --adb HOST:PORT --key F  настоящий протокол ADB (fake_adbd.py), ключ adbkey (PKCS#8)
 *   --mode diag|apply|rollback|both   --kinds anim,disable   --lang ru   --journal файл
 *   --pair HOST:PORT --code 123456   сопряжение «по коду» перед подключением; --tls conscrypt|plain|jdk
 *   --dump-cert файл                  записать сертификат ключа (PEM) — для подставного TLS-порта
 */
public final class Cli {
  static String[] addr(String s) {
    int i = s.lastIndexOf(':');
    return new String[] { s.substring(0, i), s.substring(i + 1) };
  }

  public static void main(String[] a) throws Exception {
    System.setOut(new java.io.PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), true, "UTF-8"));
    String root = new File(".").getCanonicalPath();
    String mode = "diag", kinds = "anim,disable", lang = "ru", adb = null, keyFile = null, journal = null, pair = null, code = null, tlsName = null, dumpCert = null;
    boolean mock = false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].equals("--mock")) mock = true;
      else if (a[i].equals("--adb")) adb = a[++i];
      else if (a[i].equals("--key")) keyFile = a[++i];
      else if (a[i].equals("--mode")) mode = a[++i];
      else if (a[i].equals("--kinds")) kinds = a[++i];
      else if (a[i].equals("--lang")) lang = a[++i];
      else if (a[i].equals("--journal")) journal = a[++i];
      else if (a[i].equals("--root")) root = a[++i];
      else if (a[i].equals("--pair")) pair = a[++i];
      else if (a[i].equals("--code")) code = a[++i];
      else if (a[i].equals("--tls")) tlsName = a[++i];
      else if (a[i].equals("--dump-cert")) dumpCert = a[++i];
    }
    final String R = root;
    Lang.Source src = new Lang.Source() {
      public InputStream open(String name) throws IOException {
        File f = name.equals("strings.tsv") ? new File(R, "mobile/strings.tsv") : new File(R, "data/" + name);
        return new FileInputStream(f);
      }
    };
    Lang L = new Lang(lang, src);
    Data d = new Data(src, lang);
    Sh sh;
    AdbConn conn = null;
    AdbKey k = AdbKey.loadOrCreate(keyFile == null ? new File(System.getProperty("java.io.tmpdir"), "phonekit_test_adbkey") : new File(keyFile));
    if (dumpCert != null) {
      java.io.FileOutputStream o = new java.io.FileOutputStream(dumpCert);
      String b = B64.encode(k.certificate().getEncoded());
      StringBuilder pem = new StringBuilder("-----BEGIN CERTIFICATE-----\n");
      for (int i = 0; i < b.length(); i += 64) pem.append(b, i, Math.min(b.length(), i + 64)).append('\n');
      o.write(pem.append("-----END CERTIFICATE-----\n").toString().getBytes("US-ASCII"));
      o.close();
      System.out.println("CERT " + dumpCert);
      if (adb == null && pair == null) return;
    }
    Tls tls = tlsName == null ? null : TestTls.pick(tlsName);
    if (pair != null) {
      String[] pp = addr(pair);
      String guid = AdbPair.pair(pp[0], Integer.parseInt(pp[1]), code, k, tls == null ? TestTls.pick("conscrypt") : tls);
      System.out.println("PAIRED guid=" + guid);
      if (adb == null) return;
    }
    if (mock) sh = new MockSh(R);
    else {
      String[] hp = addr(adb);
      conn = AdbConn.connect(hp[0], Integer.parseInt(hp[1]), k, 15, new AdbConn.AuthListener() {
        public void onAllowNeeded() { System.out.println("ALLOW?"); }
      }, tls);
      System.out.println("CONNECTED " + conn.banner + " maxdata=" + conn.maxData() + " tls=" + conn.tls);
      sh = conn;
    }
    Engine e = new Engine(sh, d, L, new Engine.Log() {
      public void line(String t, int kind) { System.out.println((kind == Engine.OK ? "OK   " : kind == Engine.WARN ? "WARN " : kind == Engine.BAD ? "BAD  " : "     ") + t); }
      public void progress(int done, int total) { System.out.println("PROGRESS " + done + "/" + total); }
    });
    e.dnsWaitSec = 0;
    e.settleMs = 0;
    e.diagnose();
    System.out.println("SELF-PROTECTED " + e.isProtected(Engine.SELF) + " in-keep=" + e.keepSet.contains(Engine.SELF));
    System.out.println("DEVICE " + e.model + " | sdk=" + e.sdk + " | " + e.skin + " | unit=" + e.unitId);
    for (String o : e.obs) System.out.println("OBS " + o);
    for (String n : e.notes) System.out.println("NOTE " + n);
    for (Engine.Item it : e.items) System.out.println("ITEM [" + (it.on ? "x" : " ") + "] " + it.kind + " " + it.pkg + " | " + it.group + " | " + it.text);
    File jf = new File(journal != null ? journal : new File(System.getProperty("java.io.tmpdir"), "phonekit_test_journal.tsv").getPath());
    if (mode.equals("apply") || mode.equals("both")) {
      List<String> ks = Arrays.asList(kinds.split(","));
      List<Engine.Item> sel = new ArrayList<Engine.Item>();
      for (Engine.Item it : e.items) if (it.on && ks.contains(it.kind)) sel.add(it);
      Engine.Journal j = e.apply(sel, jf.isFile() ? Engine.Journal.load(jf) : new Engine.Journal(jf));
      System.out.println("APPLIED " + j.entries.size());
      for (Engine.Entry x : j.entries) System.out.println("JOURNAL " + e.describe(x));
    }
    if (mode.equals("rollback") || mode.equals("both")) {
      Engine.Journal j = Engine.Journal.load(jf);
      System.out.println("ROLLBACK FROM " + j.entries.size());
      e.rollback(j, null);
      System.out.println("ROLLED BACK, LEFT " + Engine.Journal.load(jf).entries.size());
    }
    System.out.println("REPORT-BEGIN");
    System.out.print(e.reportText(jf.isFile() ? Engine.Journal.load(jf) : null));
    System.out.println("REPORT-END");
    if (conn != null) conn.close();
  }

  /** Подставной телефон: python3 tests/mock_adb.py shell <команда>. */
  static final class MockSh implements Sh {
    final String root;
    MockSh(String root) { this.root = root; }
    public String sh(String cmd, int timeoutSec) throws IOException {
      List<String> c = new ArrayList<String>(Arrays.asList("python3", new File(root, "tests/mock_adb.py").getPath(), "shell", cmd));
      Process p = new ProcessBuilder(c).redirectErrorStream(true).start();
      String o = new String(AdbKey.readAll(p.getInputStream()), "UTF-8");
      try { p.waitFor(); } catch (InterruptedException ignored) {}
      return o.replace("\r", "");
    }
  }
}
