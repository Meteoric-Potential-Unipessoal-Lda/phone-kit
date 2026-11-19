package net.zherdyev.phonekit;

import java.math.BigInteger;

/**
 * Точки кривой edwards25519 (как в BoringSSL / ed25519.py): сложение, умножение на целое (без приведения по модулю l —
 * это важно для совместимости SPAKE2 с adb), кодирование 32 байта (y, старший бит — знак x).
 * Скорость не важна: в сопряжении всего несколько умножений.
 */
final class Ed25519 {
  private Ed25519() {}

  static final BigInteger P = BigInteger.ONE.shiftLeft(255).subtract(BigInteger.valueOf(19));
  static final BigInteger L = BigInteger.ONE.shiftLeft(252).add(new BigInteger("27742317777372353535851937790883648493"));
  static final BigInteger D = BigInteger.valueOf(-121665).multiply(BigInteger.valueOf(121666).modInverse(P)).mod(P);
  static final BigInteger D2 = D.shiftLeft(1).mod(P);
  static final BigInteger I = BigInteger.valueOf(2).modPow(P.subtract(BigInteger.ONE).shiftRight(2), P);
  static final BigInteger TWO = BigInteger.valueOf(2);

  /** Точка в расширенных координатах (X:Y:Z:T), x = X/Z, y = Y/Z, xy = T/Z. */
  static final class Pt {
    final BigInteger X, Y, Z, T;
    Pt(BigInteger x, BigInteger y, BigInteger z, BigInteger t) { X = x; Y = y; Z = z; T = t; }
  }

  static final Pt ZERO = new Pt(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO);
  static final Pt B;
  static {
    BigInteger by = BigInteger.valueOf(4).multiply(BigInteger.valueOf(5).modInverse(P)).mod(P);
    BigInteger bx = xrecover(by);
    if (bx.testBit(0)) bx = P.subtract(bx);
    B = affine(bx, by);
  }

  static Pt affine(BigInteger x, BigInteger y) { return new Pt(x, y, BigInteger.ONE, x.multiply(y).mod(P)); }

  static BigInteger xrecover(BigInteger y) {
    BigInteger y2 = y.multiply(y);
    BigInteger xx = y2.subtract(BigInteger.ONE).multiply(D.multiply(y2).add(BigInteger.ONE).modInverse(P)).mod(P);
    BigInteger x = xx.modPow(P.add(BigInteger.valueOf(3)).shiftRight(3), P);
    if (!x.multiply(x).subtract(xx).mod(P).equals(BigInteger.ZERO)) x = x.multiply(I).mod(P);
    return x;
  }

  // RFC 8032 (a = -1), расширенные координаты
  static Pt add(Pt p, Pt q) {
    BigInteger a = p.Y.subtract(p.X).multiply(q.Y.subtract(q.X)).mod(P);
    BigInteger b = p.Y.add(p.X).multiply(q.Y.add(q.X)).mod(P);
    BigInteger c = p.T.multiply(D2).multiply(q.T).mod(P);
    BigInteger d = p.Z.multiply(TWO).multiply(q.Z).mod(P);
    BigInteger e = b.subtract(a), f = d.subtract(c), g = d.add(c), h = b.add(a);
    return new Pt(e.multiply(f).mod(P), g.multiply(h).mod(P), f.multiply(g).mod(P), e.multiply(h).mod(P));
  }

  static Pt neg(Pt p) { return new Pt(P.subtract(p.X).mod(P), p.Y, p.Z, P.subtract(p.T).mod(P)); }

  /** k·p для любого неотрицательного целого k (без приведения по l). */
  static Pt mul(BigInteger k, Pt p) {
    Pt r = ZERO;
    for (int i = k.bitLength() - 1; i >= 0; i--) {
      r = add(r, r);
      if (k.testBit(i)) r = add(r, p);
    }
    return r;
  }

  static byte[] encode(Pt p) {
    BigInteger zi = p.Z.modInverse(P);
    BigInteger x = p.X.multiply(zi).mod(P), y = p.Y.multiply(zi).mod(P);
    byte[] out = le(y, 32);
    if (x.testBit(0)) out[31] |= (byte) 0x80;
    return out;
  }

  /** Раскодировать точку; null — не на кривой (как x25519_ge_frombytes_vartime). */
  static Pt decode(byte[] s) {
    if (s.length != 32) return null;
    byte[] c = s.clone();
    boolean sign = (c[31] & 0x80) != 0;
    c[31] &= 0x7f;
    BigInteger y = fromLe(c);
    if (y.compareTo(P) >= 0) return null;
    BigInteger y2 = y.multiply(y);
    BigInteger u = y2.subtract(BigInteger.ONE).mod(P), v = D.multiply(y2).add(BigInteger.ONE).mod(P);
    BigInteger xx = u.multiply(v.modInverse(P)).mod(P);
    BigInteger x = xx.modPow(P.add(BigInteger.valueOf(3)).shiftRight(3), P);
    if (!x.multiply(x).subtract(xx).mod(P).equals(BigInteger.ZERO)) {
      x = x.multiply(I).mod(P);
      if (!x.multiply(x).subtract(xx).mod(P).equals(BigInteger.ZERO)) return null;
    }
    if (x.signum() == 0 && sign) return null;
    if (x.testBit(0) != sign) x = P.subtract(x);
    return affine(x, y);
  }

  static byte[] le(BigInteger v, int len) {
    byte[] be = v.toByteArray();
    byte[] out = new byte[len];
    for (int i = 0; i < be.length && i < len; i++) out[i] = be[be.length - 1 - i];
    return out;
  }

  static BigInteger fromLe(byte[] b) {
    byte[] be = new byte[b.length + 1];
    for (int i = 0; i < b.length; i++) be[be.length - 1 - i] = b[i];
    return new BigInteger(be);
  }

  static byte[] hex(String h) {
    byte[] r = new byte[h.length() / 2];
    for (int i = 0; i < r.length; i++) r[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
    return r;
  }
}
