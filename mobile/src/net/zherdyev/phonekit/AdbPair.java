package net.zherdyev.phonekit;

import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Сопряжение «по коду» беспроводной отладки Android 11+ (как «adb pair IP:порт код», AOSP adb/pairing_connection):
 * TLS 1.3 -> пароль = код + 64 байта экспортированного ключевого материала TLS -> SPAKE2 -> HKDF -> AES-128-GCM ->
 * обмен PeerInfo (мы шлём свой публичный ключ ADB, магнитола — свой GUID). После этого магнитола доверяет нашему ключу.
 */
public final class AdbPair {
  private AdbPair() {}

  static final int PEER_INFO_SIZE = 8192;
  static final int TYPE_SPAKE2 = 0, TYPE_PEER_INFO = 1;
  static final String EKM_LABEL = "adb-label\0";

  /** Неверный код сопряжения (или окно на магнитоле уже закрыто). */
  public static final class WrongCode extends IOException { WrongCode() { super("wrong pairing code"); } }

  /** Возвращает GUID магнитолы (например «adb-1234ABCD-xyz»). */
  public static String pair(String host, int port, String code, AdbKey key, Tls tls) throws IOException {
    Socket raw = new Socket();
    raw.setTcpNoDelay(true);
    raw.connect(new InetSocketAddress(host, port), 5000);
    raw.setSoTimeout(20000);
    Socket s = null;
    try {
      s = tls.client(raw, host, port, key);
      byte[] ekm = tls.exportKeyingMaterial(s, EKM_LABEL, null, 64);
      byte[] pw = concat(code.trim().getBytes("US-ASCII"), ekm);
      Spake2 sp = Spake2.client();
      Session ses = new Session(s);
      ses.write(TYPE_SPAKE2, sp.generate(pw, null));
      byte[] their = ses.read(TYPE_SPAKE2);
      byte[] km = sp.process(their);
      if (km == null) throw new WrongCode();
      Gcm gcm = new Gcm(km);
      ses.write(TYPE_PEER_INFO, gcm.encrypt(peerInfo(0, key.adbPublicKey("phone-kit@phone"))));
      byte[] enc;
      try { enc = ses.read(TYPE_PEER_INFO); } catch (EOFException e) { throw new WrongCode(); }
      byte[] info = gcm.decrypt(enc);
      if (info == null || info.length != PEER_INFO_SIZE) throw new WrongCode();
      int end = 1;
      while (end < info.length && info[end] != 0) end++;
      return new String(info, 1, end - 1, "UTF-8");
    } catch (GeneralSecurityException e) {
      throw new IOException(e.toString(), e);
    } catch (Exception e) {
      if (e instanceof IOException) throw (IOException) e;
      throw new IOException(e.toString(), e);
    } finally {
      try { if (s != null) s.close(); else raw.close(); } catch (IOException ignored) {}
    }
  }

  static byte[] peerInfo(int type, String data) throws IOException {
    byte[] r = new byte[PEER_INFO_SIZE];
    r[0] = (byte) type;
    byte[] d = data.getBytes("UTF-8");
    if (d.length > PEER_INFO_SIZE - 2) throw new IOException("peer info too long");
    System.arraycopy(d, 0, r, 1, d.length);
    return r;
  }

  static byte[] concat(byte[] a, byte[] b) {
    byte[] r = new byte[a.length + b.length];
    System.arraycopy(a, 0, r, 0, a.length);
    System.arraycopy(b, 0, r, a.length, b.length);
    return r;
  }

  /** Пакеты сопряжения: версия (1), тип (1), длина (4, big-endian), данные. */
  static final class Session {
    final DataInputStream in;
    final OutputStream out;
    Session(Socket s) throws IOException { in = new DataInputStream(s.getInputStream()); out = s.getOutputStream(); }
    void write(int type, byte[] payload) throws IOException {
      ByteBuffer b = ByteBuffer.allocate(6 + payload.length);
      b.put((byte) 1).put((byte) type).putInt(payload.length).put(payload);
      out.write(b.array());
      out.flush();
    }
    byte[] read(int expectType) throws IOException {
      byte[] h = new byte[6];
      in.readFully(h);
      if (h[0] != 1) throw new IOException("pairing header version " + h[0]);
      if (h[1] != expectType) throw new IOException("pairing packet type " + h[1] + ", expected " + expectType);
      int len = ByteBuffer.wrap(h, 2, 4).getInt();
      if (len <= 0 || len > PEER_INFO_SIZE * 2) throw new IOException("pairing payload size " + len);
      byte[] p = new byte[len];
      in.readFully(p);
      return p;
    }
  }

  /** AES-128-GCM с ключом HKDF-SHA256(km, info «adb pairing_auth aes-128-gcm key»), nonce = счётчик (8 байт LE) + 4 нуля. */
  static final class Gcm {
    final SecretKeySpec k;
    long enc = 0, dec = 0;
    Gcm(byte[] keyMaterial) throws GeneralSecurityException {
      k = new SecretKeySpec(hkdf(keyMaterial, "adb pairing_auth aes-128-gcm key".getBytes(), 16), "AES");
    }
    static byte[] nonce(long n) { byte[] r = new byte[12]; for (int i = 0; i < 8; i++) { r[i] = (byte) (n & 0xff); n >>>= 8; } return r; }
    byte[] encrypt(byte[] data) throws GeneralSecurityException {
      Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
      c.init(Cipher.ENCRYPT_MODE, k, new GCMParameterSpec(128, nonce(enc++)));
      return c.doFinal(data);
    }
    byte[] decrypt(byte[] data) {
      try {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, k, new GCMParameterSpec(128, nonce(dec++)));
        return c.doFinal(data);
      } catch (GeneralSecurityException e) { return null; }
    }
  }

  static byte[] hkdf(byte[] ikm, byte[] info, int len) throws GeneralSecurityException {
    Mac mac = Mac.getInstance("HmacSHA256");
    mac.init(new SecretKeySpec(new byte[32], "HmacSHA256"));
    byte[] prk = mac.doFinal(ikm);
    mac.init(new SecretKeySpec(prk, "HmacSHA256"));
    byte[] out = new byte[len];
    byte[] t = new byte[0];
    int pos = 0;
    for (int i = 1; pos < len; i++) {
      mac.update(t);
      mac.update(info);
      mac.update((byte) i);
      t = mac.doFinal();
      int n = Math.min(t.length, len - pos);
      System.arraycopy(t, 0, out, pos, n);
      pos += n;
    }
    return out;
  }

  /** Отпечаток для экрана (как в списке «Сопряжённые устройства» не показывается — только для отчёта). */
  static String sha256(byte[] b) throws GeneralSecurityException {
    StringBuilder sb = new StringBuilder();
    for (byte x : MessageDigest.getInstance("SHA-256").digest(b)) sb.append(String.format("%02x", x & 0xff));
    return sb.toString();
  }
}
