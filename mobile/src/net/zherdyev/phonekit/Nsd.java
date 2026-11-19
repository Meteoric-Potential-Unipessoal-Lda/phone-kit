package net.zherdyev.phonekit;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;

import java.util.ArrayList;
import java.util.LinkedList;
import java.util.List;

/**
 * Поиск служб беспроводной отладки Android 11+ по mDNS: телефон объявляет _adb-tls-pairing._tcp (пока открыто
 * окно с кодом) и _adb-tls-connect._tcp (пока включена беспроводная отладка). Возвращает «адрес:порт».
 * Разрешение адресов — по одному (до Android 14 параллельно NsdManager не умеет).
 */
final class Nsd {
  private final NsdManager nsd;
  Nsd(Context c) { nsd = (NsdManager) c.getSystemService(Context.NSD_SERVICE); }

  List<String> find(String type, long ms) {
    final List<String> out = new ArrayList<String>();
    final LinkedList<NsdServiceInfo> found = new LinkedList<NsdServiceInfo>();
    final Object lock = new Object();
    NsdManager.DiscoveryListener dl = new NsdManager.DiscoveryListener() {
      public void onStartDiscoveryFailed(String t, int e) {}
      public void onStopDiscoveryFailed(String t, int e) {}
      public void onDiscoveryStarted(String t) {}
      public void onDiscoveryStopped(String t) {}
      public void onServiceFound(NsdServiceInfo s) { synchronized (lock) { found.add(s); lock.notifyAll(); } }
      public void onServiceLost(NsdServiceInfo s) {}
    };
    try { nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, dl); } catch (Exception e) { return out; }
    long end = System.currentTimeMillis() + ms;
    try {
      while (System.currentTimeMillis() < end) {
        NsdServiceInfo s;
        synchronized (lock) {
          if (found.isEmpty()) { try { lock.wait(Math.max(1, end - System.currentTimeMillis())); } catch (InterruptedException e) { break; } }
          s = found.isEmpty() ? null : found.removeFirst();
        }
        if (s == null) continue;
        String r = resolve(s);
        if (r != null && !out.contains(r)) out.add(r);
        if (!out.isEmpty() && System.currentTimeMillis() > end - ms / 2) break;
      }
    } finally {
      try { nsd.stopServiceDiscovery(dl); } catch (Exception ignored) {}
    }
    return out;
  }

  private String resolve(NsdServiceInfo s) {
    final String[] r = { null };
    final Object lock = new Object();
    final boolean[] done = { false };
    try {
      nsd.resolveService(s, new NsdManager.ResolveListener() {
        public void onResolveFailed(NsdServiceInfo i, int e) { synchronized (lock) { done[0] = true; lock.notifyAll(); } }
        public void onServiceResolved(NsdServiceInfo i) {
          synchronized (lock) {
            // свой же телефон может объявить службу и по IPv6 — берём любой адрес (подключаемся всё равно к 127.0.0.1)
            if (i.getHost() != null) { String h = i.getHost().getHostAddress(); int z = h.indexOf('%'); if (z > 0) h = h.substring(0, z); r[0] = h + ":" + i.getPort(); }
            done[0] = true;
            lock.notifyAll();
          }
        }
      });
    } catch (Exception e) { return null; }
    synchronized (lock) { long end = System.currentTimeMillis() + 4000; while (!done[0] && System.currentTimeMillis() < end) { try { lock.wait(500); } catch (InterruptedException e) { break; } } }
    return r[0];
  }
}
