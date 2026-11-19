package net.zherdyev.phonekit;

import java.math.BigInteger;
import java.security.MessageDigest;
import java.util.Arrays;

/** Проверки Ed25519/SPAKE2 без сети: точки M и N из BoringSSL, согласие alice/bob, неверный код. */
public final class CryptoTest {
  static int fail = 0;
  static void check(boolean ok, String what) { System.out.println((ok ? "PASS crypto: " : "FAIL crypto: ") + what); if (!ok) fail = 1; }
  static String hex(byte[] b) { StringBuilder sb = new StringBuilder(); for (byte x : b) sb.append(String.format("%02x", x & 0xff)); return sb.toString(); }

  // как genpoint() в комментарии spake25519.cc (ed25519.py: decodepoint + проверка, что точка на кривой)
  static Ed25519.Pt genpoint(String seed) throws Exception {
    byte[] v = MessageDigest.getInstance("SHA-256").digest(seed.getBytes("US-ASCII"));
    while (true) {
      BigInteger y = Ed25519.fromLe(v).clearBit(255);
      BigInteger x = Ed25519.xrecover(y);
      if (x.testBit(0) != ((v[31] & 0x80) != 0)) x = Ed25519.P.subtract(x);
      BigInteger x2 = x.multiply(x), y2 = y.multiply(y);
      boolean on = y2.subtract(x2).subtract(BigInteger.ONE).subtract(Ed25519.D.multiply(x2).multiply(y2)).mod(Ed25519.P).signum() == 0;
      if (on) return Ed25519.affine(x, y);
      v = MessageDigest.getInstance("SHA-256").digest(v);
    }
  }

  public static void main(String[] a) throws Exception {
    check(hex(Ed25519.encode(Ed25519.B)).equals("5866666666666666666666666666666666666666666666666666666666666666"), "базовая точка B");
    check(hex(Ed25519.encode(genpoint("edwards25519 point generation seed (M)"))).equals("5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e"), "M из seed = M BoringSSL");
    check(hex(Ed25519.encode(genpoint("edwards25519 point generation seed (N)"))).equals("10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778"), "N из seed = N BoringSSL");
    BigInteger mx = Spake2.M.X.multiply(Spake2.M.Z.modInverse(Ed25519.P)).mod(Ed25519.P);
    check(mx.toString().equals("31406539342727633121250288103050113562375374900226415211311216773867585644232"), "x точки M");
    check(Ed25519.encode(Ed25519.mul(Ed25519.L, Ed25519.B)).length == 32 && hex(Ed25519.encode(Ed25519.mul(Ed25519.L, Ed25519.B))).equals(hex(Ed25519.encode(Ed25519.ZERO))), "l·B = 0");
    byte[] pw = "123456".getBytes("US-ASCII");
    for (int round = 0; round < 3; round++) {
      Spake2 al = Spake2.client(), bo = Spake2.server();
      byte[] ma = al.generate(pw, null), mb = bo.generate(pw, null);
      byte[] ka = al.process(mb), kb = bo.process(ma);
      check(ka != null && Arrays.equals(ka, kb) && ka.length == 64, "alice и bob получили один ключ (" + round + ")");
    }
    Spake2 al = Spake2.client(), bo = Spake2.server();
    byte[] ma = al.generate(pw, null), mb = bo.generate("654321".getBytes("US-ASCII"), null);
    check(!Arrays.equals(al.process(mb), bo.process(ma)), "неверный код -> разные ключи");
    byte[] bad = new byte[32]; Arrays.fill(bad, (byte) 0xff);
    check(Spake2.client().process(bad) == null, "не точка кривой -> отказ");
    java.security.KeyPairGenerator g = java.security.KeyPairGenerator.getInstance("RSA"); g.initialize(2048);
    java.security.interfaces.RSAPrivateCrtKey kk = (java.security.interfaces.RSAPrivateCrtKey) g.generateKeyPair().getPrivate();
    java.security.spec.RSAPrivateCrtKeySpec cs = AdbKey.crtSpec(kk.getEncoded());
    check(cs.getModulus().equals(kk.getModulus()) && cs.getPrivateExponent().equals(kk.getPrivateExponent()) && cs.getCrtCoefficient().equals(kk.getCrtCoefficient()), "разбор PKCS#8 ключа RSA (CRT)");
    long t = System.currentTimeMillis();
    Spake2 x = Spake2.client(); x.generate(pw, null); x.process(Spake2.server().generate(pw, null));
    System.out.println("SPAKE2 time ms: " + (System.currentTimeMillis() - t));
    System.exit(fail);
  }
}
