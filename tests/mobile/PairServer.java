package net.zherdyev.phonekit;

import java.io.File;
import java.io.FileOutputStream;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Подставной сервер сопряжения (роль магнитолы, SPAKE2 «bob»): для проверки нашего клиента и — главное — для проверки
 * совместимости с настоящим «adb pair» из Android SDK (BoringSSL). Ключ клиента дописывается в файл ключей (формат adb_keys).
 * java PairServer ПОРТ КОД ФАЙЛ_КЛЮЧЕЙ [conscrypt|plain] [раз]
 */
public final class PairServer {
  public static void main(String[] a) throws Exception {
    int port = Integer.parseInt(a[0]);
    String code = a[1];
    File keys = new File(a[2]);
    Tls tls = TestTls.pick(a.length > 3 ? a[3] : "conscrypt");
    int times = a.length > 4 ? Integer.parseInt(a[4]) : 1;
    AdbKey srvKey = AdbKey.loadOrCreate(new File(System.getProperty("java.io.tmpdir"), "phonekit_pairserver_key"));
    ServerSocket ss = new ServerSocket(port);
    System.out.println("LISTEN " + port);
    for (int n = 0; n < times; n++) {
      Socket raw = ss.accept();
      raw.setSoTimeout(20000);
      try {
        Socket s = tls.server(raw, srvKey);
        byte[] ekm = tls.exportKeyingMaterial(s, AdbPair.EKM_LABEL, null, 64);
        Spake2 sp = Spake2.server();
        AdbPair.Session ses = new AdbPair.Session(s);
        ses.write(AdbPair.TYPE_SPAKE2, sp.generate(AdbPair.concat(code.getBytes("US-ASCII"), ekm), null));
        byte[] km = sp.process(ses.read(AdbPair.TYPE_SPAKE2));
        AdbPair.Gcm gcm = new AdbPair.Gcm(km);
        byte[] info = gcm.decrypt(ses.read(AdbPair.TYPE_PEER_INFO));
        if (info == null) { System.out.println("PAIR FAIL wrong code"); s.close(); continue; }
        ses.write(AdbPair.TYPE_PEER_INFO, gcm.encrypt(AdbPair.peerInfo(1, "adb-FAKEUNIT-test")));
        int end = 1;
        while (end < info.length && info[end] != 0) end++;
        String pub = new String(info, 1, end - 1, "UTF-8").trim();
        FileOutputStream o = new FileOutputStream(keys, true);
        o.write((pub + "\n").getBytes("UTF-8"));
        o.close();
        System.out.println("PAIRED type=" + info[0] + " name=" + pub.substring(pub.lastIndexOf(' ') + 1));
        s.close();
      } catch (Exception e) {
        System.out.println("PAIR FAIL " + e);
        raw.close();
      }
    }
    ss.close();
  }
}
