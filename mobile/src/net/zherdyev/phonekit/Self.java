package net.zherdyev.phonekit;

import android.content.Context;
import android.content.SharedPreferences;

import java.io.File;
import java.io.IOException;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Подключение телефона к самому себе: «Беспроводная отладка» Android 11+ объявляет по mDNS порт сопряжения и порт подключения.
 * Берём только порты, объявленные этим телефоном (по его адресам), а подключаемся всегда к 127.0.0.1 — к чужому
 * телефону в той же сети так попасть нельзя.
 */
final class Self {
  static final String PAIR = "_adb-tls-pairing._tcp", CONNECT = "_adb-tls-connect._tcp";
  static final String HOST = "127.0.0.1";

  /** Не нашли службу: окно с кодом не открыто / беспроводная отладка выключена. */
  static final class NoService extends IOException { NoService(String t) { super("no " + t); } }

  private static AdbKey key;
  private static Tls tls;
  private static boolean tlsTried;

  static SharedPreferences prefs(Context c) { return c.getSharedPreferences("phonekit", Context.MODE_PRIVATE); }

  static synchronized AdbKey key(Context c) throws Exception {
    if (key == null) key = AdbKey.loadOrCreate(new File(c.getFilesDir(), "adbkey"));
    return key;
  }

  /** Conscrypt (TLS 1.3 + экспорт ключа) из APK; null — не загрузился. */
  static synchronized Tls tls() {
    if (!tlsTried) {
      tlsTried = true;
      try { ConscryptTls t = new ConscryptTls(); t.check(); tls = t; }
      catch (Throwable e) { android.util.Log.w("PHONEKIT", "conscrypt: " + e); tls = null; }
    }
    return tls;
  }

  static Set<String> localIps() {
    Set<String> r = new HashSet<String>();
    try {
      for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces()))
        for (InetAddress a : Collections.list(ni.getInetAddresses())) {
          String h = a.getHostAddress(); int z = h.indexOf('%'); if (z > 0) h = h.substring(0, z);
          r.add(h.toLowerCase(java.util.Locale.US));
        }
    } catch (Exception ignored) {}
    return r;
  }

  /** Порты службы этого телефона: сначала объявленные с его адресов, потом остальные (к 127.0.0.1 чужой порт просто не откроется). */
  static List<Integer> ports(Context c, String type, long ms) {
    List<String> found = new Nsd(c).find(type, ms);
    Set<String> mine = localIps();
    List<Integer> own = new ArrayList<Integer>(), other = new ArrayList<Integer>();
    for (String f : found) {
      int i = f.lastIndexOf(':');
      if (i <= 0) continue;
      int port;
      try { port = Integer.parseInt(f.substring(i + 1)); } catch (NumberFormatException e) { continue; }
      String h = f.substring(0, i).toLowerCase(java.util.Locale.US);
      List<Integer> to = mine.contains(h) ? own : other;
      if (!own.contains(port) && !other.contains(port)) to.add(port);
    }
    own.addAll(other);
    return own;
  }

  /** Сопряжение по 6-значному коду из окна «Подключить устройство с помощью кода». Возвращает GUID. */
  static String pair(Context c, String code) throws Exception {
    Tls t = tls();
    if (t == null) throw new IOException("TLS");
    AdbKey k = key(c);
    List<Integer> ps = ports(c, PAIR, 8000);
    if (ps.isEmpty()) throw new NoService(PAIR);
    IOException last = null;
    for (int p : ps) {
      try {
        String guid = AdbPair.pair(HOST, p, code, k, t);
        prefs(c).edit().putBoolean("paired", true).apply();
        return guid;
      } catch (AdbPair.WrongCode e) { throw e; }
      catch (java.net.ConnectException e) { last = e; }
    }
    throw last != null ? last : new NoService(PAIR);
  }

  /** Подключение к своему adbd по TLS. */
  static AdbConn connect(Context c) throws Exception {
    Tls t = tls();
    if (t == null) throw new IOException("TLS");
    AdbKey k = key(c);
    SharedPreferences sp = prefs(c);
    int lastPort = sp.getInt("port", 0);
    if (lastPort > 0) {
      // прошлый порт: после перезагрузки или выключения отладки он другой — тогда ищем заново
      try { return AdbConn.connect(HOST, lastPort, k, 10, null, t); }
      catch (AdbConn.NotPaired e) { throw e; }
      catch (IOException ignored) {}
    }
    List<Integer> ps = ports(c, CONNECT, 6000);
    if (ps.isEmpty()) throw new NoService(CONNECT);
    IOException last = null;
    for (int p : ps) {
      if (p == lastPort) continue;
      try {
        AdbConn a = AdbConn.connect(HOST, p, k, 10, null, t);
        sp.edit().putInt("port", p).apply();
        return a;
      } catch (java.net.ConnectException e) { last = e; }
      catch (java.net.SocketTimeoutException e) { last = e; }
    }
    throw last != null ? last : new NoService(CONNECT);
  }
}
