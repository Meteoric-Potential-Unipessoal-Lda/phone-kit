package net.zherdyev.phonekit;

import java.io.IOException;

/** Shell телефона: через свою же «Беспроводную отладку» (AdbConn), в тестах — через подставной adb. */
public interface Sh {
  String sh(String cmd, int timeoutSec) throws IOException;
}
