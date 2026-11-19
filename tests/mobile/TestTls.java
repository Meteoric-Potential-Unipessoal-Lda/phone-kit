package net.zherdyev.phonekit;

import java.io.IOException;
import java.net.Socket;
import java.security.PublicKey;

/** Для тестов без Conscrypt: «plain» — без шифрования, экспорт ключа = нули (проверяет SPAKE2/HKDF/GCM/пакеты);
 *  «jdk» — TLS 1.3 из Java (клиент к TLS-порту adbd без экспорта ключа). */
final class TestTls {
  static Tls plain() {
    return new Tls() {
      public Socket client(Socket raw, String host, int port, AdbKey key) { return raw; }
      public Socket server(Socket raw, AdbKey key) { return raw; }
      public byte[] exportKeyingMaterial(Socket s, String label, byte[] c, int len) { return new byte[len]; }
      public PublicKey peerKey(Socket s) { return null; }
    };
  }

  static Tls jdk() {
    return new Tls() {
      public Socket client(Socket raw, String host, int port, AdbKey key) throws IOException {
        try {
          final java.security.cert.X509Certificate[] chain = { key.certificate() };
          javax.net.ssl.KeyManagerFactory kmf = javax.net.ssl.KeyManagerFactory.getInstance("SunX509");
          java.security.KeyStore ks = java.security.KeyStore.getInstance("PKCS12");
          ks.load(null, null);
          ks.setKeyEntry("adb", key.priv, new char[0], chain);
          kmf.init(ks, new char[0]);
          javax.net.ssl.TrustManager tm = new javax.net.ssl.X509TrustManager() {
            public void checkClientTrusted(java.security.cert.X509Certificate[] c, String a) {}
            public void checkServerTrusted(java.security.cert.X509Certificate[] c, String a) {}
            public java.security.cert.X509Certificate[] getAcceptedIssuers() { return new java.security.cert.X509Certificate[0]; }
          };
          final javax.net.ssl.X509KeyManager base = (javax.net.ssl.X509KeyManager) kmf.getKeyManagers()[0];
          javax.net.ssl.X509KeyManager km = new javax.net.ssl.X509ExtendedKeyManager() {
            public String[] getClientAliases(String t, java.security.Principal[] i) { return new String[] { "adb" }; }
            public String chooseClientAlias(String[] t, java.security.Principal[] i, Socket s) { return "adb"; }
            public String[] getServerAliases(String t, java.security.Principal[] i) { return null; }
            public String chooseServerAlias(String t, java.security.Principal[] i, Socket s) { return null; }
            public java.security.cert.X509Certificate[] getCertificateChain(String a) { return base.getCertificateChain(a); }
            public java.security.PrivateKey getPrivateKey(String a) { return base.getPrivateKey(a); }
          };
          javax.net.ssl.SSLContext ctx = javax.net.ssl.SSLContext.getInstance("TLSv1.3");
          ctx.init(new javax.net.ssl.KeyManager[] { km }, new javax.net.ssl.TrustManager[] { tm }, null);
          javax.net.ssl.SSLSocket s = (javax.net.ssl.SSLSocket) ctx.getSocketFactory().createSocket(raw, host, port, true);
          s.setEnabledProtocols(new String[] { "TLSv1.3" });
          s.startHandshake();
          return s;
        } catch (IOException e) { throw e; } catch (Exception e) { throw new IOException(e.toString(), e); }
      }
      public Socket server(Socket raw, AdbKey key) throws IOException { throw new IOException("jdk: no server"); }
      public byte[] exportKeyingMaterial(Socket s, String l, byte[] c, int len) throws IOException { throw new IOException("jdk: no EKM"); }
      public PublicKey peerKey(Socket s) throws IOException { throw new IOException("jdk: no peer key"); }
    };
  }

  static Tls pick(String name) {
    if (name == null || name.equals("conscrypt")) return new ConscryptTls();
    if (name.equals("plain")) return plain();
    if (name.equals("jdk")) return jdk();
    throw new IllegalArgumentException(name);
  }
}
