package net.zherdyev.phonekit;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;

import java.io.IOException;
import java.io.InputStream;
import java.util.Locale;

/**
 * Код сопряжения вводится прямо в уведомление (как у Shizuku): окно «Подключить устройство с помощью кода»
 * в Настройках закрывается, если уйти из Настроек, а шторка его не закрывает.
 */
public class PairReceiver extends BroadcastReceiver {
  static final String CH = "pair", KEY = "code", ACTION = "net.zherdyev.phonekit.PAIR";
  static final int ID = 1;

  static Lang lang(final Context c) {
    String code = Self.prefs(c).getString("lang", Lang.pick(Locale.getDefault().getLanguage()));
    try {
      return new Lang(code, new Lang.Source() { public InputStream open(String n) throws IOException { return c.getAssets().open(n); } });
    } catch (IOException e) { throw new RuntimeException(e); }
  }

  /** Показать (или обновить) уведомление с полем для кода. msg — строка состояния (ошибка / «сопрягаю…»), null — подсказка. */
  static void show(Context c, Lang L, String msg, boolean input) {
    NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
    if (Build.VERSION.SDK_INT >= 26) {
      NotificationChannel ch = new NotificationChannel(CH, L.t("x020"), NotificationManager.IMPORTANCE_HIGH);
      ch.setSound(null, null);
      nm.createNotificationChannel(ch);
    }
    Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(c, CH) : new Notification.Builder(c);
    String text = msg != null ? msg : L.t("x022");
    b.setSmallIcon(R.drawable.ic_stat).setContentTitle(L.t("x021")).setContentText(text)
      .setStyle(new Notification.BigTextStyle().bigText(text)).setOnlyAlertOnce(true).setAutoCancel(!input);
    Intent open = new Intent(c, MainActivity.class).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    int imm = Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0;
    b.setContentIntent(PendingIntent.getActivity(c, 0, open, imm | PendingIntent.FLAG_UPDATE_CURRENT));
    if (input) {
      Intent i = new Intent(c, PairReceiver.class).setAction(ACTION);
      // ввод из уведомления дописывается в Intent — PendingIntent обязан быть изменяемым (Android 12+)
      int mut = Build.VERSION.SDK_INT >= 31 ? 0x02000000 /* FLAG_MUTABLE */ : 0;
      PendingIntent pi = PendingIntent.getBroadcast(c, 1, i, mut | PendingIntent.FLAG_UPDATE_CURRENT);
      RemoteInput ri = new RemoteInput.Builder(KEY).setLabel(L.t("x017")).build();
      Notification.Action a = new Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(c, R.drawable.ic_stat), L.t("x023"), pi)
        .addRemoteInput(ri).build();
      b.addAction(a);
    }
    nm.notify(ID, b.build());
  }

  @Override
  public void onReceive(final Context c, Intent intent) {
    Bundle r = RemoteInput.getResultsFromIntent(intent);
    CharSequence cs = r == null ? null : r.getCharSequence(KEY);
    final String code = cs == null ? "" : cs.toString().replaceAll("\\D", "");
    final Lang L = lang(c);
    if (!code.matches("^\\d{6}$")) { show(c, L, L.t("x026"), true); return; }
    show(c, L, L.t("x024"), false);
    final PendingResult pr = goAsync();
    new Thread(new Runnable() {
      public void run() {
        try {
          Self.pair(c, code);
          show(c, L, L.t("x025"), false);
        } catch (AdbPair.WrongCode e) { show(c, L, L.t("x026"), true);
        } catch (Self.NoService e) { show(c, L, L.t("x027"), true);
        } catch (Throwable e) { android.util.Log.w("PHONEKIT", "pair: " + e, e); show(c, L, L.t("x028", e.getMessage() == null ? e.toString() : e.getMessage()), true);
        } finally { pr.finish(); }
      }
    }).start();
  }
}
