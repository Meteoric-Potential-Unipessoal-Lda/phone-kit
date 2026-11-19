package net.zherdyev.phonekit;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.interfaces.RSAPrivateCrtKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.RSAPublicKeySpec;
import java.security.interfaces.RSAPublicKey;

/** Ключ ADB телефона: RSA-2048, хранится в папке приложения; публичная часть — в формате adb (adbkey.pub). */
public final class AdbKey {
  final RSAPrivateCrtKey priv;
  final RSAPublicKey pub;

  private AdbKey(RSAPrivateCrtKey priv) throws GeneralSecurityException {
    this.priv = priv;
    this.pub = (RSAPublicKey) KeyFactory.getInstance("RSA").generatePublic(new RSAPublicKeySpec(priv.getModulus(), priv.getPublicExponent()));
  }

  /** Ключ из файла adbkey (PKCS#8: PEM «BEGIN PRIVATE KEY» или DER); нет файла — создаёт новый. */
  public static AdbKey loadOrCreate(File f) throws IOException, GeneralSecurityException {
    if (f.isFile() && f.length() > 0) return load(f);
    KeyPairGenerator g = KeyPairGenerator.getInstance("RSA");
    g.initialize(2048);
    KeyPair kp = g.generateKeyPair();
    byte[] der = kp.getPrivate().getEncoded();
    AdbKey made = kp.getPrivate() instanceof RSAPrivateCrtKey ? new AdbKey((RSAPrivateCrtKey) kp.getPrivate())
      : new AdbKey((RSAPrivateCrtKey) KeyFactory.getInstance("RSA").generatePrivate(crtSpec(der)));
    File tmp = new File(f.getPath() + ".tmp");
    FileOutputStream o = new FileOutputStream(tmp);
    try { o.write(pem(der).getBytes("US-ASCII")); } finally { o.close(); }
    if (!tmp.renameTo(f)) throw new IOException("cannot save " + f);
    return made;
  }

  public static AdbKey load(File f) throws IOException, GeneralSecurityException {
    byte[] raw = readAll(new FileInputStream(f));
    String s = new String(raw, "US-ASCII");
    byte[] der = raw;
    if (s.contains("BEGIN")) {
      if (s.contains("BEGIN RSA PRIVATE KEY")) throw new GeneralSecurityException("PKCS#1 key is not supported, use PKCS#8");
      der = B64.decode(s.replaceAll("-----[^-]+-----", "").replaceAll("\\s", ""));
    }
    java.security.PrivateKey pk = null;
    try { pk = KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(der)); } catch (GeneralSecurityException ignored) {}
    if (pk instanceof RSAPrivateCrtKey) return new AdbKey((RSAPrivateCrtKey) pk);
    // некоторые провайдеры Android отдают ключ без CRT-параметров — разбираем PKCS#8 сами
    return new AdbKey((RSAPrivateCrtKey) KeyFactory.getInstance("RSA").generatePrivate(crtSpec(der)));
  }

  /** PKCS#8 PrivateKeyInfo { 0, AlgId, OCTET STRING { RSAPrivateKey { 0, n, e, d, p, q, dp, dq, qinv } } }. */
  static java.security.spec.RSAPrivateCrtKeySpec crtSpec(byte[] der) throws GeneralSecurityException {
    int[] pos = { 0 };
    enter(der, pos, 0x30);
    skip(der, pos);                     // version
    skip(der, pos);                     // AlgorithmIdentifier
    enter(der, pos, 0x04);
    enter(der, pos, 0x30);
    skip(der, pos);                     // version
    BigInteger[] v = new BigInteger[8];
    for (int i = 0; i < 8; i++) v[i] = integer(der, pos);
    return new java.security.spec.RSAPrivateCrtKeySpec(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
  }

  private static int len(byte[] d, int[] p) throws GeneralSecurityException {
    int b = d[p[0]++] & 0xff;
    if (b < 0x80) return b;
    int n = b & 0x7f, r = 0;
    if (n > 4) throw new GeneralSecurityException("DER length");
    for (int i = 0; i < n; i++) r = (r << 8) | (d[p[0]++] & 0xff);
    return r;
  }
  private static void enter(byte[] d, int[] p, int tag) throws GeneralSecurityException {
    if ((d[p[0]++] & 0xff) != tag) throw new GeneralSecurityException("DER tag " + tag);
    len(d, p);
  }
  private static void skip(byte[] d, int[] p) throws GeneralSecurityException { p[0]++; int l = len(d, p); p[0] += l; }
  private static BigInteger integer(byte[] d, int[] p) throws GeneralSecurityException {
    if ((d[p[0]++] & 0xff) != 0x02) throw new GeneralSecurityException("DER integer");
    int l = len(d, p);
    byte[] b = new byte[l];
    System.arraycopy(d, p[0], b, 0, l);
    p[0] += l;
    return new BigInteger(b);
  }

  static String pem(byte[] der) {
    String b = B64.encode(der);
    StringBuilder sb = new StringBuilder("-----BEGIN PRIVATE KEY-----\n");
    for (int i = 0; i < b.length(); i += 64) sb.append(b, i, Math.min(b.length(), i + 64)).append('\n');
    return sb.append("-----END PRIVATE KEY-----\n").toString();
  }

  // adbd подписывает 20-байтовый токен как готовый SHA-1: RSA_sign(NID_sha1, token)
  private static final byte[] SHA1_PREFIX = { 0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14 };

  public byte[] sign(byte[] token) throws GeneralSecurityException {
    byte[] m = new byte[SHA1_PREFIX.length + token.length];
    System.arraycopy(SHA1_PREFIX, 0, m, 0, SHA1_PREFIX.length);
    System.arraycopy(token, 0, m, SHA1_PREFIX.length, token.length);
    try {
      Signature s = Signature.getInstance("NONEwithRSA");
      s.initSign(priv);
      s.update(m);
      return s.sign();
    } catch (GeneralSecurityException e) {
      // запасной путь (старые Android): PKCS#1 v1.5 тип 1 вручную
      BigInteger n = priv.getModulus();
      int k = (n.bitLength() + 7) / 8;
      byte[] em = new byte[k];
      em[0] = 0; em[1] = 1;
      for (int i = 2; i < k - m.length - 1; i++) em[i] = (byte) 0xff;
      em[k - m.length - 1] = 0;
      System.arraycopy(m, 0, em, k - m.length, m.length);
      byte[] r = new BigInteger(1, em).modPow(priv.getPrivateExponent(), n).toByteArray();
      byte[] out = new byte[k];
      int off = r.length > k ? r.length - k : 0;
      System.arraycopy(r, off, out, k - (r.length - off), r.length - off);
      return out;
    }
  }

  /** Публичный ключ в формате adb: base64(RSAPublicKey из libcrypto_utils) + " имя". */
  public String adbPublicKey(String name) {
    BigInteger n = pub.getModulus();
    int words = 2048 / 32;
    ByteBuffer b = ByteBuffer.allocate(4 + 4 + words * 4 + words * 4 + 4).order(ByteOrder.LITTLE_ENDIAN);
    BigInteger r32 = BigInteger.ONE.shiftLeft(32);
    BigInteger n0inv = r32.subtract(n.mod(r32).modInverse(r32)).mod(r32);
    b.putInt(words);
    b.putInt(n0inv.intValue());
    putWords(b, n, words);
    putWords(b, BigInteger.ONE.shiftLeft(2048).pow(2).mod(n), words);
    b.putInt(pub.getPublicExponent().intValue());
    return B64.encode(b.array()) + " " + name;
  }

  private static void putWords(ByteBuffer b, BigInteger v, int words) {
    BigInteger mask = BigInteger.ONE.shiftLeft(32).subtract(BigInteger.ONE);
    for (int i = 0; i < words; i++) { b.putInt(v.and(mask).intValue()); v = v.shiftRight(32); }
  }

  /** Короткий отпечаток для экрана (как у adb: MD5 публичного ключа не показываем — хватит 8 знаков SHA-256). */
  public String fingerprint() {
    try {
      byte[] d = java.security.MessageDigest.getInstance("SHA-256").digest(pub.getEncoded());
      StringBuilder sb = new StringBuilder();
      for (int i = 0; i < 4; i++) sb.append(String.format("%02X", d[i] & 0xff));
      return sb.toString();
    } catch (GeneralSecurityException e) { return "?"; }
  }

  private java.security.cert.X509Certificate cert;

  /**
   * Самоподписанный сертификат нашего ключа для TLS беспроводной отладки — как у adb (crypto/x509_generator.cpp):
   * v3, серийный 1, C=US, O=Android, CN=Adb, basicConstraints CA:TRUE, keyUsage, SHA256withRSA.
   */
  public synchronized java.security.cert.X509Certificate certificate() throws IOException {
    if (cert != null) return cert;
    try {
      byte[] alg = seq(oid(new int[] { 1, 2, 840, 113549, 1, 1, 11 }), new byte[] { 0x05, 0x00 });
      byte[] name = seq(set(seq(oid(new int[] { 2, 5, 4, 6 }), str(0x13, "US"))),
                        set(seq(oid(new int[] { 2, 5, 4, 10 }), str(0x0c, "Android"))),
                        set(seq(oid(new int[] { 2, 5, 4, 3 }), str(0x0c, "Adb"))));
      // постоянный срок (2020–2049): сертификат одного ключа всегда одинаковый байт в байт
      byte[] validity = seq(str(0x17, "200101000000Z"), str(0x17, "491231235959Z"));
      byte[] bc = seq(oid(new int[] { 2, 5, 29, 19 }), new byte[] { 0x01, 0x01, (byte) 0xff }, tlv(0x04, seq(new byte[] { 0x01, 0x01, (byte) 0xff })));
      byte[] ku = seq(oid(new int[] { 2, 5, 29, 15 }), new byte[] { 0x01, 0x01, (byte) 0xff }, tlv(0x04, new byte[] { 0x03, 0x02, 0x01, (byte) 0x86 }));
      byte[] tbs = seq(tlv(0xa0, new byte[] { 0x02, 0x01, 0x02 }), new byte[] { 0x02, 0x01, 0x01 }, alg, name, validity, name,
                       pub.getEncoded(), tlv(0xa3, seq(bc, ku)));
      java.security.Signature s = java.security.Signature.getInstance("SHA256withRSA");
      s.initSign(priv);
      s.update(tbs);
      byte[] sig = s.sign();
      byte[] bits = new byte[sig.length + 1];
      System.arraycopy(sig, 0, bits, 1, sig.length);
      byte[] der = seq(tbs, alg, tlv(0x03, bits));
      cert = (java.security.cert.X509Certificate) java.security.cert.CertificateFactory.getInstance("X.509")
        .generateCertificate(new java.io.ByteArrayInputStream(der));
      return cert;
    } catch (GeneralSecurityException e) { throw new IOException("certificate: " + e, e); }
  }

  static byte[] tlv(int tag, byte[] v) {
    ByteArrayOutputStream o = new ByteArrayOutputStream();
    o.write(tag);
    int n = v.length;
    if (n < 128) o.write(n);
    else if (n < 256) { o.write(0x81); o.write(n); }
    else if (n < 65536) { o.write(0x82); o.write(n >> 8); o.write(n & 0xff); }
    else { o.write(0x83); o.write(n >> 16); o.write((n >> 8) & 0xff); o.write(n & 0xff); }
    o.write(v, 0, v.length);
    return o.toByteArray();
  }

  static byte[] seq(byte[]... parts) { return tlv(0x30, cat(parts)); }
  static byte[] set(byte[]... parts) { return tlv(0x31, cat(parts)); }

  static byte[] cat(byte[]... parts) {
    ByteArrayOutputStream o = new ByteArrayOutputStream();
    for (byte[] p : parts) o.write(p, 0, p.length);
    return o.toByteArray();
  }

  static byte[] str(int tag, String s) {
    try { return tlv(tag, s.getBytes("UTF-8")); } catch (java.io.UnsupportedEncodingException e) { throw new RuntimeException(e); }
  }

  static byte[] oid(int[] a) {
    ByteArrayOutputStream o = new ByteArrayOutputStream();
    o.write(a[0] * 40 + a[1]);
    for (int i = 2; i < a.length; i++) {
      int v = a[i];
      byte[] tmp = new byte[5];
      int n = 0;
      do { tmp[n++] = (byte) (v & 0x7f); v >>>= 7; } while (v != 0);
      for (int j = n - 1; j >= 0; j--) o.write(tmp[j] | (j > 0 ? 0x80 : 0));
    }
    return tlv(0x06, o.toByteArray());
  }


  static byte[] readAll(InputStream in) throws IOException {
    try {
      ByteArrayOutputStream o = new ByteArrayOutputStream();
      byte[] buf = new byte[8192];
      int n;
      while ((n = in.read(buf)) > 0) o.write(buf, 0, n);
      return o.toByteArray();
    } finally { in.close(); }
  }
}
