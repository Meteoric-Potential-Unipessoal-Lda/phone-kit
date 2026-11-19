package net.zherdyev.phonekit;

import java.math.BigInteger;
import java.security.MessageDigest;
import java.security.SecureRandom;

/**
 * SPAKE2 над edwards25519, байт в байт как BoringSSL (crypto/curve25519/spake25519.cc), которым пользуется adb при сопряжении
 * «по коду» (Android 11+): клиент — alice («adb pair client\0»), сервер — bob («adb pair server\0»).
 */
final class Spake2 {
  // Точки M и N из spake25519.cc (поле «encoded»)
  static final Ed25519.Pt M = Ed25519.decode(Ed25519.hex("5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e"));
  static final Ed25519.Pt N = Ed25519.decode(Ed25519.hex("10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778"));

  private final boolean alice;
  private final byte[] myName, theirName;
  private BigInteger privateKey, passwordScalar;
  private byte[] passwordHash, myMsg;

  Spake2(boolean alice, byte[] myName, byte[] theirName) { this.alice = alice; this.myName = myName; this.theirName = theirName; }

  static Spake2 client() { return new Spake2(true, name("adb pair client"), name("adb pair server")); }
  static Spake2 server() { return new Spake2(false, name("adb pair server"), name("adb pair client")); }

  /** sizeof("...") в C — с завершающим нулём. */
  static byte[] name(String s) {
    byte[] a = s.getBytes(java.nio.charset.Charset.forName("US-ASCII"));
    byte[] r = new byte[a.length + 1];
    System.arraycopy(a, 0, r, 0, a.length);
    return r;
  }

  /** Наше сообщение (32 байта). random64 — для тестов (null — случайные). */
  byte[] generate(byte[] password, byte[] random64) throws Exception {
    byte[] rnd = random64;
    if (rnd == null) { rnd = new byte[64]; new SecureRandom().nextBytes(rnd); }
    // private = (rnd mod l) * 8
    privateKey = Ed25519.fromLe(rnd).mod(Ed25519.L).shiftLeft(3);
    Ed25519.Pt p = Ed25519.mul(privateKey, Ed25519.B);
    passwordHash = MessageDigest.getInstance("SHA-512").digest(password);
    BigInteger ps = Ed25519.fromLe(passwordHash).mod(Ed25519.L);
    // «хак» BoringSSL: добавить l, 2l, 4l, чтобы скаляр делился на 8
    BigInteger order = Ed25519.L;
    if (ps.testBit(0)) ps = ps.add(order);
    order = order.shiftLeft(1);
    if (ps.testBit(1)) ps = ps.add(order);
    order = order.shiftLeft(1);
    if (ps.testBit(2)) ps = ps.add(order);
    passwordScalar = ps;
    Ed25519.Pt mask = Ed25519.mul(passwordScalar, alice ? M : N);
    myMsg = Ed25519.encode(Ed25519.add(p, mask));
    return myMsg.clone();
  }

  /** Общий ключ (64 байта) по сообщению собеседника; null — сообщение не точка кривой. */
  byte[] process(byte[] theirMsg) throws Exception {
    if (theirMsg.length != 32) return null;
    Ed25519.Pt q = Ed25519.decode(theirMsg);
    if (q == null) return null;
    Ed25519.Pt peersMask = Ed25519.mul(passwordScalar, alice ? N : M);
    Ed25519.Pt qExt = Ed25519.add(q, Ed25519.neg(peersMask));
    byte[] dh = Ed25519.encode(Ed25519.mul(privateKey, qExt));
    MessageDigest sha = MessageDigest.getInstance("SHA-512");
    if (alice) { lp(sha, myName); lp(sha, theirName); lp(sha, myMsg); lp(sha, theirMsg); }
    else { lp(sha, theirName); lp(sha, myName); lp(sha, theirMsg); lp(sha, myMsg); }
    lp(sha, dh);
    lp(sha, passwordHash);
    return sha.digest();
  }

  private static void lp(MessageDigest sha, byte[] d) {
    long l = d.length;
    byte[] len = new byte[8];
    for (int i = 0; i < 8; i++) { len[i] = (byte) (l & 0xff); l >>= 8; }
    sha.update(len);
    sha.update(d);
  }
}
