package net.zherdyev.phonekit;

/** Base64 без android.util и java.util.Base64 (его нет до Android 8). */
final class B64 {
  private B64() {}
  private static final char[] A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

  static String encode(byte[] d) {
    StringBuilder sb = new StringBuilder((d.length + 2) / 3 * 4);
    for (int i = 0; i < d.length; i += 3) {
      int b0 = d[i] & 0xff, b1 = i + 1 < d.length ? d[i + 1] & 0xff : 0, b2 = i + 2 < d.length ? d[i + 2] & 0xff : 0;
      sb.append(A[b0 >> 2]).append(A[((b0 & 3) << 4) | (b1 >> 4)]);
      sb.append(i + 1 < d.length ? A[((b1 & 15) << 2) | (b2 >> 6)] : '=');
      sb.append(i + 2 < d.length ? A[b2 & 63] : '=');
    }
    return sb.toString();
  }

  static byte[] decode(String s) {
    int[] v = new int[128];
    for (int i = 0; i < 128; i++) v[i] = -1;
    for (int i = 0; i < A.length; i++) v[A[i]] = i;
    java.io.ByteArrayOutputStream o = new java.io.ByteArrayOutputStream(s.length() * 3 / 4);
    int acc = 0, bits = 0;
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if (c == '=') break;
      if (c >= 128 || v[c] < 0) continue;
      acc = (acc << 6) | v[c]; bits += 6;
      if (bits >= 8) { bits -= 8; o.write((acc >> bits) & 0xff); }
    }
    return o.toByteArray();
  }
}
