package net.zherdyev.phonekit;

import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Тексты: языковые файлы набора data/lang/*.json (10 языков, те же сообщения, что на ноутбуке)
 * + свои строки приложения mobile/strings.tsv (key, ru, uk, en, pt, es, fr, it, de, lv, pl). Нет перевода — английский, потом русский.
 */
public final class Lang {
  public static final String[] CODES = { "ru", "uk", "en", "pt", "es", "fr", "it", "de", "lv", "pl" };
  public static final String[] NAMES = { "Русский", "Українська", "English", "Português", "Español", "Français", "Italiano", "Deutsch", "Latviešu", "Polski" };

  public interface Source { InputStream open(String name) throws IOException; }

  public final String code;
  private final Map<String, String> cur, en, ru;

  public Lang(String code, Source src) throws IOException {
    this.code = code;
    Map<String, String> tsv = null;
    en = load(src, "en", tsvCol(src, "en"));
    ru = code.equals("en") ? en : load(src, "ru", tsvCol(src, "ru"));
    cur = code.equals("en") ? en : code.equals("ru") ? ru : load(src, code, tsvCol(src, code));
  }

  private static Map<String, String> tsvCol(Source src, String code) throws IOException {
    Map<String, String> r = new HashMap<String, String>();
    String t = new String(AdbKey.readAll(src.open("strings.tsv")), "UTF-8");
    String[] lines = t.replace("\r", "").split("\n");
    String[] head = lines[0].split("\t", -1);
    int col = -1;
    for (int i = 0; i < head.length; i++) if (head[i].equals(code)) col = i;
    if (col < 0) return r;
    for (int i = 1; i < lines.length; i++) {
      String[] f = lines[i].split("\t", -1);
      if (f.length > col && f[0].length() > 0 && !f[0].startsWith("#") && f[col].length() > 0) r.put(f[0], f[col].replace("\\n", "\n"));
    }
    return r;
  }

  private static Map<String, String> load(Source src, String code, Map<String, String> extra) throws IOException {
    Map<String, String> m;
    try { m = Json.strings(new String(AdbKey.readAll(src.open("lang/" + code + ".json")), "UTF-8")); }
    catch (IOException e) { m = new HashMap<String, String>(); }
    m.putAll(extra);
    return m;
  }

  private static final Pattern ARG = Pattern.compile("\\{(\\d+)(,-?\\d+)?(:[^}]*)?\\}");

  public String t(String key, Object... args) {
    String s = cur.get(key);
    if (s == null) s = en.get(key);
    if (s == null) s = ru.get(key);
    if (s == null) return key;
    if (args.length == 0 && s.indexOf('{') < 0) return s;
    Matcher m = ARG.matcher(s);
    StringBuffer sb = new StringBuffer();
    while (m.find()) {
      int i = Integer.parseInt(m.group(1));
      String v = i < args.length ? String.valueOf(args[i]) : "";
      m.appendReplacement(sb, Matcher.quoteReplacement(v));
    }
    m.appendTail(sb);
    return sb.toString();
  }

  public boolean has(String key) { return cur.containsKey(key) || en.containsKey(key); }

  /** Язык системы телефона, если он есть среди 10; иначе английский. */
  public static String pick(String sys) {
    if (sys != null) for (String c : CODES) if (sys.startsWith(c)) return c;
    if ("be".equals(sys) || "kk".equals(sys)) return "ru";
    return "en";
  }

  /** Минимальный разбор JSON-объекта со строковыми значениями (языковые файлы набора). */
  static final class Json {
    static Map<String, String> strings(String s) throws IOException {
      Map<String, String> r = new HashMap<String, String>();
      int[] p = { 0 };
      skip(s, p);
      if (p[0] < s.length() && s.charAt(p[0]) == '﻿') p[0]++;
      skip(s, p);
      expect(s, p, '{');
      while (true) {
        skip(s, p);
        if (s.charAt(p[0]) == '}') break;
        String k = str(s, p);
        skip(s, p); expect(s, p, ':'); skip(s, p);
        String v = str(s, p);
        r.put(k, v);
        skip(s, p);
        if (s.charAt(p[0]) == ',') { p[0]++; continue; }
        expect(s, p, '}');
        break;
      }
      return r;
    }
    private static void skip(String s, int[] p) { while (p[0] < s.length() && (Character.isWhitespace(s.charAt(p[0])) || s.charAt(p[0]) == '﻿')) p[0]++; }
    private static void expect(String s, int[] p, char c) throws IOException {
      if (p[0] >= s.length() || s.charAt(p[0]) != c) throw new IOException("json: expected " + c + " at " + p[0]);
      p[0]++;
    }
    private static String str(String s, int[] p) throws IOException {
      expect(s, p, '"');
      StringBuilder sb = new StringBuilder();
      while (true) {
        char c = s.charAt(p[0]++);
        if (c == '"') return sb.toString();
        if (c != '\\') { sb.append(c); continue; }
        char e = s.charAt(p[0]++);
        switch (e) {
          case 'n': sb.append('\n'); break;
          case 't': sb.append('\t'); break;
          case 'r': sb.append('\r'); break;
          case 'b': sb.append('\b'); break;
          case 'f': sb.append('\f'); break;
          case 'u': sb.append((char) Integer.parseInt(s.substring(p[0], p[0] + 4), 16)); p[0] += 4; break;
          default: sb.append(e);
        }
      }
    }
  }
}
