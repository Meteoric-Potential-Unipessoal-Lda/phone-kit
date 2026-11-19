package net.zherdyev.phonekit;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/** phone-kit Mobile: чистка этого же телефона через его «Беспроводную отладку». Экраны: сопряжение -> диагностика -> план -> применение -> откат. */
public class MainActivity extends Activity implements SharedPreferences.OnSharedPreferenceChangeListener {
  static final int BG = 0xFF0E1320, CARD = 0xFF182033, TXT = 0xFFE8EEF6, MUTED = 0xFF9AA8BC, ACC = 0xFF4F8BFF, WARN = 0xFFFFB74D, BAD = 0xFFEF5350, OKC = 0xFF81C784;
  static final int MIN_SDK = 30;   // беспроводная отладка — Android 11+

  final Handler ui = new Handler(Looper.getMainLooper());
  SharedPreferences prefs;
  Lang L;
  Data data;
  AdbConn conn;
  Engine eng;
  Engine.Journal journal;
  volatile boolean busy;
  boolean onHome;

  LinearLayout page;
  ScrollView scroll;
  LinearLayout logBox;
  ProgressBar bar;

  // ---------------------------------------------------------------- старт

  @Override
  protected void onCreate(Bundle b) {
    super.onCreate(b);
    prefs = Self.prefs(this);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    if (Build.VERSION.SDK_INT >= 21) getWindow().setStatusBarColor(BG);
    scroll = new ScrollView(this);
    scroll.setBackgroundColor(BG);
    scroll.setFillViewport(true);
    page = new LinearLayout(this);
    page.setOrientation(LinearLayout.VERTICAL);
    int p = dp(16);
    page.setPadding(p, p, p, p);
    scroll.addView(page);
    setContentView(scroll);
    loadLang(prefs.getString("lang", Lang.pick(Locale.getDefault().getLanguage())));
    prefs.registerOnSharedPreferenceChangeListener(this);
    showHome(null);
    new Thread(new Runnable() { public void run() { try { Self.key(MainActivity.this); } catch (Exception ignored) {} } }).start();
  }

  @Override
  public void onSharedPreferenceChanged(SharedPreferences sp, String k) {
    if ("paired".equals(k) && onHome && !busy) ui.post(new Runnable() { public void run() { if (onHome && !busy) showHome(null); } });
  }

  Lang.Source assets() {
    return new Lang.Source() { public InputStream open(String name) throws IOException { return getAssets().open(name); } };
  }

  void loadLang(String code) {
    try {
      L = new Lang(code, assets());
      data = new Data(assets(), code);
    } catch (IOException e) { throw new RuntimeException(e); }
    prefs.edit().putString("lang", code).apply();
  }

  File journalFile(String unit) {
    File d = new File(getFilesDir(), "journals");
    d.mkdirs();
    return new File(d, unit.replaceAll("[^A-Za-z0-9_.-]", "_") + ".tsv");
  }

  @Override
  public void onBackPressed() {
    if (busy) return;
    if (conn != null && eng != null && !onSummary) { showSummary(); return; }
    super.onBackPressed();
  }

  @Override
  protected void onDestroy() {
    prefs.unregisterOnSharedPreferenceChangeListener(this);
    if (conn != null) conn.close();
    super.onDestroy();
  }

  // ---------------------------------------------------------------- главный экран

  void showHome(final String msg) {
    clear();
    onHome = true;
    title(L.t("x000"));
    if (Build.VERSION.SDK_INT < MIN_SDK) {
      text(L.t("x002", Build.VERSION.RELEASE), WARN, 16);
      space(12);
      langPicker();
      footer();
      return;
    }
    text(L.t("x001"), MUTED, 15);
    text(L.t("x003"), MUTED, 13);
    if (msg != null) text(msg, WARN, 15);
    boolean paired = prefs.getBoolean("paired", false);

    LinearLayout c = card();
    TextView h = cardText(c, L.t("x010") + (paired ? "   " + L.t("x014") : ""), paired ? OKC : TXT);
    h.setTypeface(Typeface.DEFAULT_BOLD);
    cardText(c, L.t("x011"), MUTED);
    TextView warn = cardText(c, L.t("x019"), WARN);
    warn.setTypeface(Typeface.DEFAULT_BOLD);
    button(L.t("x013"), false, new View.OnClickListener() { public void onClick(View v) { openDevSettings(); } });
    button(L.t("x012"), !paired, new View.OnClickListener() { public void onClick(View v) { showPairNotification(); } });
    text(L.t("x016"), MUTED, 13);
    LinearLayout row = new LinearLayout(this);
    row.setGravity(Gravity.CENTER_VERTICAL);
    final EditText code = new EditText(this);
    code.setHint(L.t("x017"));
    code.setTextColor(TXT);
    code.setHintTextColor(MUTED);
    code.setSingleLine(true);
    code.setInputType(InputType.TYPE_CLASS_NUMBER);
    row.addView(code, new LinearLayout.LayoutParams(0, -2, 1));
    Button pb = mkButton(L.t("x018"), false);
    pb.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { pairHere(code.getText().toString()); } });
    row.addView(pb, new LinearLayout.LayoutParams(-2, -2));
    page.addView(row, lp(-1, -2, 4));

    space(8);
    button(L.t("x015"), paired, new View.OnClickListener() { public void onClick(View v) { connect(); } });
    button(L.t("x072"), false, new View.OnClickListener() { public void onClick(View v) { showHelp(); } });
    space(12);
    langPicker();
    footer();
  }

  boolean onSummary;

  void footer() {
    try { text(L.t("x071", Self.key(this).fingerprint()), MUTED, 11); } catch (Exception ignored) {}
    text(L.t("x160"), MUTED, 12);
    text("phone-kit Mobile " + Engine.VERSION + " · GPL-3.0 · TLS: Conscrypt (Apache-2.0)", MUTED, 11);
  }

  void openDevSettings() {
    // подсветить пункт «Беспроводная отладка» (ключ настройки в AOSP — toggle_adb_wireless; где не поддерживается — просто откроется раздел)
    Bundle args = new Bundle();
    args.putString(":settings:fragment_args_key", "toggle_adb_wireless");
    try { startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).putExtra(":settings:fragment_args_key", "toggle_adb_wireless").putExtra(":settings:show_fragment_args", args)); }
    catch (Exception e) { try { startActivity(new Intent(Settings.ACTION_DEVICE_INFO_SETTINGS)); } catch (Exception ignored) {} }
  }

  void showPairNotification() {
    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
      requestPermissions(new String[] { "android.permission.POST_NOTIFICATIONS" }, 7);
      return;
    }
    PairReceiver.show(this, L, null, true);
    toastMsg(L.t("x022"));
    openDevSettings();
  }

  @Override
  public void onRequestPermissionsResult(int req, String[] perms, int[] res) {
    if (req != 7) return;
    if (res.length > 0 && res[0] == PackageManager.PERMISSION_GRANTED) showPairNotification();
    else showHome(L.t("x029"));
  }

  void langPicker() {
    LinearLayout row = new LinearLayout(this);
    row.setGravity(Gravity.CENTER_VERTICAL);
    TextView t = new TextView(this);
    t.setText(L.t("x070") + ": ");
    t.setTextColor(MUTED);
    row.addView(t);
    final Spinner sp = new Spinner(this);
    ArrayAdapter<String> ad = new ArrayAdapter<String>(this, android.R.layout.simple_spinner_item, Lang.NAMES) {
      @Override public View getView(int pos, View cv, ViewGroup parent) { TextView v = (TextView) super.getView(pos, cv, parent); v.setTextColor(TXT); return v; }
    };
    ad.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
    sp.setAdapter(ad);
    int cur = 0;
    for (int i = 0; i < Lang.CODES.length; i++) if (Lang.CODES[i].equals(L.code)) cur = i;
    sp.setSelection(cur, false);
    sp.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
      public void onItemSelected(AdapterView<?> a, View v, int pos, long id) {
        if (!Lang.CODES[pos].equals(L.code)) { loadLang(Lang.CODES[pos]); showHome(null); }
      }
      public void onNothingSelected(AdapterView<?> a) {}
    });
    row.addView(sp);
    page.addView(row, lp(-1, -2, 4));
  }

  void showHelp() {
    clear();
    title(L.t("x072"));
    for (String k : new String[] { "x073", "x074", "x075", "x076", "x063" }) text(L.t(k), TXT, 15);
    button(L.t("x057"), true, new View.OnClickListener() { public void onClick(View v) { showHome(null); } });
  }

  // ---------------------------------------------------------------- сопряжение в приложении (разделённый экран)

  void pairHere(String raw) {
    if (busy) return;
    final String code = raw.replaceAll("\\D", "");
    if (!code.matches("^\\d{6}$")) { toastMsg(L.t("x017")); return; }
    busy = true;
    clear();
    onHome = false;
    title(L.t("x010"));
    startLog();
    postMsg(L.t("x024"), MUTED);
    new Thread(new Runnable() {
      public void run() {
        String m;
        try { Self.pair(MainActivity.this, code); m = null; }
        catch (AdbPair.WrongCode e) { m = L.t("x026"); }
        catch (Self.NoService e) { m = L.t("x027"); }
        catch (Throwable e) { m = L.t("x028", String.valueOf(e.getMessage())); }
        busy = false;
        final String msg = m;
        ui.post(new Runnable() { public void run() { showHome(msg); if (msg == null) toastMsg(L.t("x025")); } });
      }
    }).start();
  }

  // ---------------------------------------------------------------- подключение и диагностика

  void connect() {
    if (busy) return;
    busy = true;
    clear();
    onHome = false;
    title(L.t("x000"));
    startLog();
    postMsg(L.t("x030"), MUTED);
    new Thread(new Runnable() {
      public void run() {
        try {
          if (conn != null) conn.close();
          conn = null;
          if (Self.tls() == null) { fail(L.t("x035")); return; }
          conn = Self.connect(MainActivity.this);
          postMsg(L.t("x033", conn.banner.length() > 60 ? conn.banner.substring(0, 60) : conn.banner), OKC);
          diagnose();
        } catch (AdbConn.NotPaired e) { prefs.edit().putBoolean("paired", false).apply(); fail(L.t("x032"));
        } catch (Self.NoService e) { fail(L.t("x031"));
        } catch (java.net.ConnectException e) { fail(L.t("x031"));
        } catch (Throwable e) { android.util.Log.w("PHONEKIT", "connect: " + e, e); fail(L.t("x034", String.valueOf(e.getMessage() == null ? e.toString() : e.getMessage()))); }
      }
    }).start();
  }

  void fail(final String msg) {
    busy = false;
    if (conn != null) conn.close();
    conn = null;
    eng = null;
    ui.post(new Runnable() { public void run() { showHome(msg); } });
  }

  Engine.Log engineLog() {
    return new Engine.Log() {
      public void line(String t, int kind) { postMsg(t, kind == Engine.OK ? OKC : kind == Engine.WARN ? WARN : kind == Engine.BAD ? BAD : MUTED); }
      public void progress(final int done, final int total) { ui.post(new Runnable() { public void run() { if (bar != null) { bar.setMax(total); bar.setProgress(done); } } }); }
    };
  }

  /** В фоновом потоке. */
  void diagnose() throws IOException {
    postMsg(L.t("x036"), TXT);
    eng = new Engine(conn, data, L, engineLog());
    eng.diagnose();
    File jf = journalFile(eng.unitId);
    journal = jf.isFile() ? Engine.Journal.load(jf) : new Engine.Journal(jf);
    busy = false;
    ui.post(new Runnable() { public void run() { showSummary(); } });
  }

  void showSummary() {
    clear();
    onSummary = true;
    final Engine e = eng;
    title(e.P("ro.product.brand") + " " + e.model);
    if (e.skin.length() > 0) text(e.skin, MUTED, 14);
    text(L.t("x041", e.P("ro.build.version.release"), e.sdk, e.before.memAvailMb, e.memTotalMb, e.before.dataFreeMb), TXT, 14);
    LinearLayout c = card();
    if (e.obs.isEmpty()) cardText(c, L.t("x042"), OKC);
    for (String o : e.obs) cardText(c, "• " + o, TXT);
    for (String n : e.notes) cardText(c, "• " + n, MUTED);
    button(L.t("x043"), true, new View.OnClickListener() { public void onClick(View v) { showPlan(); } });
    if (journal != null && !journal.entries.isEmpty())
      button(L.t("x044") + " — " + L.t("x045", journal.created, journal.entries.size()), false, new View.OnClickListener() { public void onClick(View v) { showRollback(); } });
    button(L.t("x046"), false, new View.OnClickListener() { public void onClick(View v) { share(); } });
    button(L.t("x077"), false, new View.OnClickListener() { public void onClick(View v) { copyReport(); } });
    button(L.t("x047"), false, new View.OnClickListener() {
      public void onClick(View v) { if (conn != null) conn.close(); conn = null; eng = null; showHome(L.t("x048")); }
    });
  }

  // ---------------------------------------------------------------- план

  void showPlan() {
    clear();
    final Engine e = eng;
    title(L.t("x043"));
    if (e.items.isEmpty()) { text(L.t("x056"), OKC, 15); button(L.t("x057"), true, back()); return; }
    text(L.t("x058"), MUTED, 13);
    final Button apply = mkButton("", true);
    final Runnable upd = new Runnable() { public void run() { apply.setText(L.t("x050", count(e.items))); } };
    String g = "";
    final List<CheckBox> boxes = new ArrayList<CheckBox>();
    for (final Engine.Item it : e.items) {
      if (!it.group.equals(g)) { g = it.group; TextView h = text(g, ACC, 15); h.setTypeface(Typeface.DEFAULT_BOLD); h.setPadding(0, dp(12), 0, dp(4)); }
      CheckBox cb = new CheckBox(this);
      cb.setText(it.text);
      cb.setTextColor(TXT);
      cb.setTextSize(14);
      cb.setChecked(it.on);
      if (Build.VERSION.SDK_INT >= 21) cb.setButtonTintList(android.content.res.ColorStateList.valueOf(ACC));
      cb.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
        public void onCheckedChanged(CompoundButton b, boolean on) { it.on = on; upd.run(); }
      });
      boxes.add(cb);
      page.addView(cb, lp(-1, -2, 2));
    }
    space(12);
    upd.run();
    apply.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) {
        final List<Engine.Item> sel = new ArrayList<Engine.Item>();
        for (Engine.Item it : e.items) if (it.on) sel.add(it);
        if (sel.isEmpty()) { toastMsg(L.t("x055")); return; }
        new AlertDialog.Builder(MainActivity.this).setMessage(L.t("x052", sel.size()))
          .setPositiveButton(L.t("x053"), new DialogInterface.OnClickListener() { public void onClick(DialogInterface d, int w) { runApply(sel); } })
          .setNegativeButton(L.t("x054"), null).show();
      }
    });
    page.addView(apply, lp(-1, -2, 8));
    button(L.t("x051"), false, new View.OnClickListener() { public void onClick(View v) { for (CheckBox cb : boxes) cb.setChecked(false); } });
    button(L.t("x057"), false, back());
  }

  static int count(List<Engine.Item> l) { int n = 0; for (Engine.Item it : l) if (it.on) n++; return n; }

  View.OnClickListener back() { return new View.OnClickListener() { public void onClick(View v) { showSummary(); } }; }

  void runApply(final List<Engine.Item> sel) {
    busy = true;
    clear();
    title(L.t("x043"));
    text(L.t("x060"), WARN, 14);
    bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
    page.addView(bar, lp(-1, -2, 8));
    startLog();
    new Thread(new Runnable() {
      public void run() {
        try {
          journal = eng.apply(sel, journal);
          busy = false;
          ui.post(new Runnable() { public void run() { showResult(false); } });
        } catch (IOException e) { lost(e); }
      }
    }).start();
  }

  void lost(IOException e) {
    busy = false;
    final String m = L.t("x068", e.getMessage());
    if (conn != null) conn.close();
    conn = null;
    eng = null;
    ui.post(new Runnable() { public void run() { showHome(m); } });
  }

  void showResult(boolean rolledBack) {
    final Engine e = eng;
    space(8);
    LinearLayout c = card();
    if (e.before != null && e.after != null) cardText(c, L.t("x153", e.before.memAvailMb, e.after.memAvailMb, e.before.procs, e.after.procs, e.before.disabled, e.after.disabled), TXT);
    cardText(c, rolledBack ? L.t("x062") : L.t("x061"), rolledBack ? OKC : WARN);
    if (!rolledBack) cardText(c, L.t("x063"), MUTED);
    if (!rolledBack && journal != null && !journal.entries.isEmpty())
      button(L.t("x044"), false, new View.OnClickListener() { public void onClick(View v) { confirmRollback(null); } });
    button(L.t("x046"), false, new View.OnClickListener() { public void onClick(View v) { share(); } });
    button(L.t("x077"), false, new View.OnClickListener() { public void onClick(View v) { copyReport(); } });
    button(L.t("x069"), true, back());
    scrollDown();
  }

  // ---------------------------------------------------------------- откат

  void showRollback() {
    clear();
    title(L.t("x044"));
    final Engine.Journal j = journal;
    if (j == null || j.entries.isEmpty()) { text(L.t("x064"), MUTED, 15); button(L.t("x057"), true, back()); return; }
    text(L.t("x045", j.created, j.entries.size()), MUTED, 14);
    if (j.fingerprint.length() > 0 && !j.fingerprint.equals(eng.fingerprint)) text(L.t("x065", j.fingerprint), WARN, 13);
    final Set<Integer> pick = new HashSet<Integer>();
    final Button go = mkButton("", true);
    final Runnable upd = new Runnable() { public void run() { go.setText(L.t("x066", pick.size())); } };
    for (int i = 0; i < j.entries.size(); i++) {
      final int idx = i;
      pick.add(i);
      CheckBox cb = new CheckBox(this);
      cb.setText((i + 1) + ". " + eng.describe(j.entries.get(i)));
      cb.setTextColor(TXT);
      cb.setChecked(true);
      if (Build.VERSION.SDK_INT >= 21) cb.setButtonTintList(android.content.res.ColorStateList.valueOf(ACC));
      cb.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
        public void onCheckedChanged(CompoundButton b, boolean on) { if (on) pick.add(idx); else pick.remove(idx); upd.run(); }
      });
      page.addView(cb, lp(-1, -2, 2));
    }
    upd.run();
    go.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) {
        if (pick.isEmpty()) { toastMsg(L.t("x055")); return; }
        confirmRollback(pick.size() == j.entries.size() ? null : new HashSet<Integer>(pick));
      }
    });
    page.addView(go, lp(-1, -2, 12));
    button(L.t("x057"), false, back());
  }

  void confirmRollback(final Set<Integer> only) {
    int n = only == null ? journal.entries.size() : only.size();
    new AlertDialog.Builder(this).setMessage(L.t("x067", n))
      .setPositiveButton(L.t("x044"), new DialogInterface.OnClickListener() {
        public void onClick(DialogInterface d, int w) { runRollback(only); }
      })
      .setNegativeButton(L.t("x054"), null).show();
  }

  void runRollback(final Set<Integer> only) {
    busy = true;
    clear();
    title(L.t("x044"));
    startLog();
    new Thread(new Runnable() {
      public void run() {
        try {
          eng.rollback(journal, only);
          busy = false;
          ui.post(new Runnable() { public void run() { showResult(true); } });
        } catch (IOException e) { lost(e); }
      }
    }).start();
  }

  // ---------------------------------------------------------------- отчёт

  void share() {
    Intent i = new Intent(Intent.ACTION_SEND);
    i.setType("text/plain");
    i.putExtra(Intent.EXTRA_SUBJECT, L.t("x150", Engine.VERSION) + " — " + eng.model);
    i.putExtra(Intent.EXTRA_TEXT, eng.reportText(journal));
    // не открылось окно «Поделиться» (так бывает на некоторых Xiaomi) — кладём отчёт в буфер обмена
    try { startActivity(Intent.createChooser(i, L.t("x046"))); } catch (Exception e) { copyReport(); }
  }

  void copyReport() {
    try {
      android.content.ClipboardManager cm = (android.content.ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
      cm.setPrimaryClip(android.content.ClipData.newPlainText(L.t("x150", Engine.VERSION), eng.reportText(journal)));
      toastMsg(L.t("x078"));
    } catch (Exception e) { toastMsg(String.valueOf(e.getMessage())); }
  }

  // ---------------------------------------------------------------- вид

  void clear() { page.removeAllViews(); logBox = null; bar = null; onHome = false; onSummary = false; scroll.scrollTo(0, 0); }

  int dp(int v) { return (int) (v * getResources().getDisplayMetrics().density + 0.5f); }

  LinearLayout.LayoutParams lp(int w, int h, int top) {
    LinearLayout.LayoutParams l = new LinearLayout.LayoutParams(w, h);
    l.topMargin = dp(top);
    return l;
  }

  void title(String s) {
    TextView t = text(s, TXT, 22);
    t.setTypeface(Typeface.DEFAULT_BOLD);
    t.setPadding(0, 0, 0, dp(6));
  }

  TextView text(String s, int color, int sp) {
    TextView t = new TextView(this);
    t.setText(s);
    t.setTextColor(color);
    t.setTextSize(sp);
    t.setLineSpacing(0, 1.15f);
    page.addView(t, lp(-1, -2, 6));
    return t;
  }

  void space(int h) { View v = new View(this); page.addView(v, lp(-1, dp(h), 0)); }

  Button mkButton(String s, boolean primary) {
    Button b = new Button(this);
    b.setText(s);
    b.setAllCaps(false);
    b.setTextSize(16);
    b.setTextColor(primary ? 0xFFFFFFFF : TXT);
    GradientDrawable g = new GradientDrawable();
    g.setCornerRadius(dp(10));
    g.setColor(primary ? ACC : CARD);
    if (!primary) g.setStroke(dp(1), 0xFF2C3A55);
    b.setBackground(g);
    b.setMinHeight(dp(52));
    b.setPadding(dp(14), dp(8), dp(14), dp(8));
    return b;
  }

  Button button(String s, boolean primary, View.OnClickListener l) {
    Button b = mkButton(s, primary);
    b.setOnClickListener(l);
    page.addView(b, lp(-1, -2, 10));
    return b;
  }

  LinearLayout card() {
    LinearLayout c = new LinearLayout(this);
    c.setOrientation(LinearLayout.VERTICAL);
    GradientDrawable g = new GradientDrawable();
    g.setCornerRadius(dp(12));
    g.setColor(CARD);
    c.setBackground(g);
    c.setPadding(dp(14), dp(10), dp(14), dp(12));
    page.addView(c, lp(-1, -2, 12));
    return c;
  }

  TextView cardText(LinearLayout c, String s, int color) {
    TextView t = new TextView(this);
    t.setText(s);
    t.setTextColor(color);
    t.setTextSize(14);
    t.setLineSpacing(0, 1.15f);
    t.setPadding(0, dp(4), 0, 0);
    c.addView(t);
    return t;
  }

  void startLog() {
    logBox = new LinearLayout(this);
    logBox.setOrientation(LinearLayout.VERTICAL);
    page.addView(logBox, lp(-1, -2, 8));
  }

  void postMsg(final String s, final int color) {
    ui.post(new Runnable() {
      public void run() {
        if (logBox == null) return;
        TextView t = new TextView(MainActivity.this);
        t.setText(s);
        t.setTextColor(color);
        t.setTextSize(13);
        logBox.addView(t);
        if (logBox.getChildCount() > 400) logBox.removeViewAt(0);
        scrollDown();
      }
    });
  }

  void scrollDown() { scroll.post(new Runnable() { public void run() { scroll.fullScroll(View.FOCUS_DOWN); } }); }

  void toastMsg(String s) { android.widget.Toast.makeText(this, s, android.widget.Toast.LENGTH_SHORT).show(); }
}
