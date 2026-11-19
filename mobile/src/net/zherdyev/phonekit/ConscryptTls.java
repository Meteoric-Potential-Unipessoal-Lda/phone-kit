package net.zherdyev.phonekit;

import java.io.IOException;
import java.net.Socket;
import java.security.Principal;
import java.security.PrivateKey;
import java.security.Provider;
import java.security.PublicKey;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;

import javax.net.ssl.KeyManager;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509ExtendedKeyManager;
import javax.net.ssl.X509ExtendedTrustManager;

import org.conscrypt.Conscrypt;

/**
 * TLS 1.3 на Conscrypt (BoringSSL внутри, как у adb): работает на телефонах с Android 5+ (своя библиотека в APK)
 * и на обычной Java (conscrypt-openjdk-uber) в тестах. Сертификат собеседника не проверяем — так делает и adb;
 * доверие обеспечивает сопряжение по коду (SPAKE2) и список ключей на магнитоле.
 */
public final class ConscryptTls implements Tls {
  private static Provider provider;

  private static synchronized Provider provider() {
    if (provider == null) provider = Conscrypt.newProvider();
    return provider;
  }

  /** Загрузить библиотеку Conscrypt заранее (на телефоне без нужной ABI — UnsatisfiedLinkError). */
  public void check() { provider(); }

  private SSLContext context(final AdbKey key) throws IOException {
    try {
      final X509Certificate cert = key.certificate();
      final X509Certificate[] chain = { cert };
      final PrivateKey pk = key.priv;
      KeyManager km = new X509ExtendedKeyManager() {
        public String[] getClientAliases(String t, Principal[] i) { return new String[] { "adb" }; }
        // список CA сервера (у adbd там отпечатки ключей) не фильтруем — всегда свой сертификат
        public String chooseClientAlias(String[] t, Principal[] i, Socket s) { return "adb"; }
        public String[] getServerAliases(String t, Principal[] i) { return new String[] { "adb" }; }
        public String chooseServerAlias(String t, Principal[] i, Socket s) { return "adb"; }
        public X509Certificate[] getCertificateChain(String a) { return chain; }
        public PrivateKey getPrivateKey(String a) { return pk; }
        @Override public String chooseEngineClientAlias(String[] t, Principal[] i, SSLEngine e) { return "adb"; }
        @Override public String chooseEngineServerAlias(String t, Principal[] i, SSLEngine e) { return "adb"; }
      };
      TrustManager tm = new X509ExtendedTrustManager() {
        public void checkClientTrusted(X509Certificate[] c, String a) throws CertificateException {}
        public void checkServerTrusted(X509Certificate[] c, String a) throws CertificateException {}
        public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        public void checkClientTrusted(X509Certificate[] c, String a, Socket s) {}
        public void checkServerTrusted(X509Certificate[] c, String a, Socket s) {}
        public void checkClientTrusted(X509Certificate[] c, String a, SSLEngine e) {}
        public void checkServerTrusted(X509Certificate[] c, String a, SSLEngine e) {}
      };
      SSLContext ctx = SSLContext.getInstance("TLS", provider());
      ctx.init(new KeyManager[] { km }, new TrustManager[] { tm }, null);
      return ctx;
    } catch (IOException e) { throw e;
    } catch (Exception e) { throw new IOException("TLS init: " + e, e); }
  }

  public Socket client(Socket raw, String host, int port, AdbKey key) throws IOException {
    SSLSocket s = (SSLSocket) context(key).getSocketFactory().createSocket(raw, host, port, true);
    s.setSoTimeout(15000);   // рукопожатие не должно висеть, если магнитола молчит
    s.setUseClientMode(true);
    s.setEnabledProtocols(new String[] { "TLSv1.3" });
    s.startHandshake();
    return s;
  }

  public Socket server(Socket raw, AdbKey key) throws IOException {
    SSLSocket s = (SSLSocket) context(key).getSocketFactory().createSocket(raw, raw.getInetAddress().getHostAddress(), raw.getPort(), true);
    s.setUseClientMode(false);
    s.setNeedClientAuth(true);
    s.setEnabledProtocols(new String[] { "TLSv1.3" });
    s.startHandshake();
    return s;
  }

  public byte[] exportKeyingMaterial(Socket tls, String label, byte[] context, int length) throws IOException {
    return Conscrypt.exportKeyingMaterial((SSLSocket) tls, label, context, length);
  }

  public PublicKey peerKey(Socket tls) throws IOException {
    return ((SSLSocket) tls).getSession().getPeerCertificates()[0].getPublicKey();
  }
}
