package net.zherdyev.phonekit;

import java.io.IOException;
import java.net.Socket;

/** TLS 1.3 для беспроводной отладки Android 11+: клиент с сертификатом нашего ключа ADB и экспорт ключевого материала (RFC 5705). */
public interface Tls {
  /** Поверх уже открытого сокета; рукопожатие выполнено. */
  Socket client(Socket raw, String host, int port, AdbKey key) throws IOException;
  /** Для тестов: серверная сторона (требует сертификат клиента). */
  Socket server(Socket raw, AdbKey key) throws IOException;
  byte[] exportKeyingMaterial(Socket tls, String label, byte[] context, int length) throws IOException;
  /** Сертификат собеседника (ключ RSA) — нужен тестовому серверу, чтобы узнать ключ клиента. */
  java.security.PublicKey peerKey(Socket tls) throws IOException;
}
