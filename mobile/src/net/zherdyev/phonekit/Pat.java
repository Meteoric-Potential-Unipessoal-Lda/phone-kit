// СГЕНЕРИРОВАНО dev/gen_mobile_patterns.py из phonekit.ps1 — не править руками.
// Правила защиты и белый список команд записи — те же, что у набора на ноутбуке.
package net.zherdyev.phonekit;

import java.util.regex.Pattern;

final class Pat {
  private Pat() {}
  // PowerShell -match не различает регистр
  static Pattern ci(String p) { return Pattern.compile(p, Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE); }
  static final Pattern AskPattern = ci("assistant|voice|speech|hotword|bixby|music|video|youtube|netflix|spotify|browser|chrome|maps|photo|notes|memo|recorder|calculator|weather|email|mail|(^|[._])gm$|drive|docs|office|onedrive|skydrive|outlook|teams|cloud|share|sharing|mirror|cast|health|fit|watch|wear|buds|game|store|market|radio|(^|[._])fm([._]|$)|scanner|translate|lens|keep|meet|tachyon|duo|facebook\\.(katana|orca|lite)|instagram|tiktok|amazon|prime|kids|book|reader|print|scan|compass|tv|remote|auto|wallpaper|widget|pay|wallet|rcs|enhanceservice|vvm|voicemail|firewall|block|spam|sound|audio|equali|dolby|magnif|one ?hand|accessory|beansmgr|peripheral|easysetup|stplatform|continuity|mcfds|mdx|nearby|halfsheet|(^|[._ ])key|uwb|secure wi-fi|smartcall|universalswitch|accesscontrol|detector|color adjust|app\\.color|earphone|headset|brightness|hearing|handwriting|popupui|minimode|tracker|(^|[._])mt$|(^|[._])dsm([._]|$)|daemonapp|crane|call\\+|(^|[._ ])v?sim|softsim|coreapps|deviceid|authservice|quicktool|fps|devicesecurity|theme|font|icon|search|backup|restore|tasks|bard|gemini|exchange|ar\\.core|augmented|(^|[._])tag$|nfc|(^|[._])qr([._]|$)|phrase|privacy|carlink|carwith|smarthome|connect|boost|sysopt|trust|(^|[._ ])pass([._ ]|$)|find ?my|(^|[._])adm$|backdrop|screensaver|scone|5g|lte|network|location|dex|hs20|passpoint|hotspot|sms|secur|them(e|ing)|biometric|fingerprint|authenticat|soter|ifaa");
  static final Pattern AutoPattern = ci("(^|\\W)ads?(\\W|$)|advert|adservice|analytic|telemetry|tracking|spyware|collect|statistic|(^|\\W)metrics?(\\W|$)|recommend|partner|stub|promo|facebook|netflix|booking|linkedin|yahoo|flipboard|empty package|useless|discontinued|(^|\\W)test|debug|hidden|diagnos|logging|logger|log collect|bug ?report|feedback|easter egg|china|chinese|korea|japan|verizon|t-mobile|sprint|preload|retail demo|tips|tutorial|user guide|user manual|ar zone|ar emoji|ar doodle|deco pic|sticker|news|shop|ecomm|community|forum|loan|(^|\\W)vr(\\W|$)|daydream|cardboard|yellow ?page|customi[sz]ation|visit in|(^|[._])msa([._]|$)|miui daemon|onetrack|vipaccount|o2o|youpin|mirecycle|quick apps|hybrid|app vault|minusscreen|taplus|carousel");
  static final Pattern KeepBgPattern = ci("photo|gallery|drive|cloud|music|spotify|podcast|radio|navi|maps|fit|sleep|whatsapp|telegram|viber|signal|messenger|orca|skype|zoom|teams|slack|discord|wechat|kakao|line\\.android|bank|pay|wallet|money|finance|card|auth|otp|2fa|alarm|clock|calendar|kid|family|parent|life360|findmy|tracker|health|medic|vpn|keyboard|launcher|sms|dialer|call|contacts|mail|outlook|gmail|sync|backup|antivirus|security");
  static final Pattern CleanerPattern = ci("clean|booster|boost|speed(up|er)|junk|cooler|cpu\\.?cool|battery\\.?(saver|doctor)|antivirus|virus|optimi[sz]er|ram\\.?(clean|boost)|fast\\.?charg");
  static final Pattern StoreInstallers = ci("^(com\\.android\\.vending|com\\.xiaomi\\.discover|com\\.sec\\.android\\.app\\.samsungapps|com\\.xiaomi\\.(mipicks|market)|com\\.huawei\\.appmarket|com\\.hihonor\\.appmarket|com\\.heytap\\.market|com\\.oppo\\.market|com\\.bbk\\.appstore|com\\.amazon\\.venezia|com\\.google\\.android\\.feedback|ru\\.vk\\.store|org\\.fdroid\\.\\w+|com\\.looker\\.droidify|com\\.machiav3lli\\.fdroid|com\\.aurora\\.store|dev\\.imranr\\.obtainium|com\\.transsion\\.\\w*store\\w*|com\\.motorola\\.\\w+)$");
  static final Pattern FileInstallers = ci("packageinstaller");
  static final Pattern PreloadInstallers = ci("preload|preinstall|^android$|omcagent|carrier|^com\\.(samsung|sec|miui|xiaomi|oplus|coloros|heytap|huawei|hihonor)\\.");
  static final Pattern KnownSideload = ci("^com\\.(samsung|sec|miui|xiaomi|oplus|coloros|heytap|huawei|hihonor)\\.|bank|sber|tinkoff|tbank|alfabank|vtb|gazprom|raiffeisen|sovcom|pochta|ozon|wildberries|avito|yandex|^ru\\.vk\\.|^com\\.vkontakte|oneme|gosuslugi|happ|v2ray|nekobox|hiddify|outline|wireguard|vpn|cleanzer|zherdyev|telegram|^com\\.aefyr\\.sai");
  static final Pattern NotCleaner = ci("asmr|game|makeover|tycoon|simulator|idle");
  static final Pattern[] PROTECTED = {
    ci("^android$"),
    ci("^com\\.android\\.(systemui|settings|phone|server\\..*|providers\\..*|shell|bluetooth|nfc|packageinstaller|permissioncontroller|inputdevices|externalstorage|webview|networkstack.*|keychain|location\\.fused|se|captiveportallogin|certinstaller|documentsui|vpndialogs|wallpaperbackup|backupconfirm|proxyhandler|sharedstoragebackup|dynsystem|localtransport|statementservice|mms\\.service|cellbroadcast.*|emergency|incallui|dialer|contacts|mtp|carrierconfig|stk|ons|simappdialog|launcher3?|deskclock|calendar|vending|intentresolver|devicelockcontroller|healthconnect.*|adservices.*|rkpdapp|virtualmachine.*|credentialmanager|safetycenter.*|apex.*|modulemetadata|wifi.*|tethering.*|uwb.*|media(provider)?(\\..*)?|camera2?)$"),
    ci("^com\\.google\\.android\\.(gms(\\..*)?|gsf(\\..*)?|webview|ext\\..*|packageinstaller|permissioncontroller|inputmethod\\..*|configupdater|networkstack.*|modulemetadata|overlay\\..*|captiveportallogin|dialer|contacts|apps\\.messaging|deskclock|calendar|apps\\.restore|apps\\.kids\\..*|apps\\.safetyhub|apps\\.work\\..*|partnersetup|setupwizard|onetimeinitializer|apps\\.turbo|apps\\.wellbeing|syncadapters\\..*|backuptransport|apps\\.nbu\\.files|rkpdapp|healthconnect.*|adservices.*|providers\\..*|tts|apps\\.carrier\\..*|ims|euicc.*|cellbroadcast.*)$"),
    ci("inputmethod|keyboard|honeyboard|latinime|(^|[._])ime([._]|$)|swiftkey|launcher|quickstep|systemui|settings|setupwizard|provision"),
    ci("telephony|telecom|dialer|incallui|contacts|(^|[._])(mms|sms|messaging|ims|imsservice|epdg|volte|vowifi|wfc|euicc|carrier\\w*|cellbroadcast\\w*|emergency|stk|simsetting\\w*)([._]|$)|networkui"),
    ci("bluetooth|nfc|wifi|networkstack|connectivity|tethering|timezone|location|gnss|(^|[._])gps([._]|$)"),
    ci("camera|gallery|biometric|fingerprint|(^|[._])face(?!book)|bio\\.face|smartface|wallet|(^|[._])s?pay(fw|ment)?([._]|$)|samsungpass|dkey"),
    ci("supervision|familylink|parentalcare|kidshome|kidsinstaller|(^|[._])kids([._]|$)|wellbeing|(^|[._])forest([._]|$)"),
    ci("knox|klmsagent|ucs\\.agent|kgclient|securefolder|secur(ity)?center|safecenter|securitycore|securityadd|systemmanager|phonemanager|permission|authfw|rampart|applock|^com\\.osp\\.app\\.signin$|mobileservice|^com\\.samsung\\.android\\.scs$|^com\\.xiaomi\\.(account|finddevice|xmsf)$|^com\\.lbe\\.security\\.miui$|hwid|hihonor\\.id|findmy(mobile|device)?|finddevice"),
    ci("(^|[._])\\w*(update|upgrade)\\w*([._]|$)|(^|[._])f?ota([._]|$)|wssyncmldm|soagent|omadm|samsungapps|^com\\.xiaomi\\.discover$|\\.gru$|localeoverlay"),
    ci("overlay|resources|miwallpaper|wallpaper(backup|cropper)|dynamiclock|dressroom|aodservice|soundpicker|clipboard|smartcapture|screenshot|accessibility|talkback"),
    ci("hardware|vendor\\.|\\.hal($|\\.)|qualcomm|(^|[._])(qti|qcom|mediatek|mtk|slsi|exynos|unisoc|sprd)([._]|$)|gamedriver|gpudriver|vklayer|thermal|powerkeeper|joyose|(^|[._])game\\.gos$"),
    ci("providers|storage|(^|[._])mtp\\w*|cdfs|documentsui|externalstorage|backup(agent|transport)"),
    ci("(^|[._])spen|aircommand|pentastic|desktopmode|(^|[._])dex([._]|$)|multiwindow|taskbar"),
    ci("clock|alarm|calendar"),
    ci("diagmon|(^|[._])dsms([._]|$)|(^|[._])lool([._]|$)|sm\\.policy|routines|smartsuggestions|brightnessbackup"),
    ci("vpn|proxy|webview|webkit"),
    ci("fido|cmfa|teegris|(^|[._])tui([._]|$)|asksmanager|(^|[._])mdm|enterprise|androidforwork|dmagent|authenticator|(^|[._])odad$|securityhub|greenguard|sskds"),
    ci("nlp$|(^|[._])supl([._]|$)|sarcontrol|(^|[._])sar([._]|$)|smsextra|poweroff|onetimeinitializer|emergency|^com\\.samsung\\.android\\.sm(\\.provider)?$"),
  };
  // -cmatch: с учётом регистра
  static final Pattern[] WRITE = {
    Pattern.compile("^pm disable-user --user 0 [A-Za-z0-9_.]+$"),
    Pattern.compile("^pm enable --user 0 [A-Za-z0-9_.]+$"),
    Pattern.compile("^pm uninstall -k --user 0 [A-Za-z0-9_.]+$"),
    Pattern.compile("^(cmd package|pm) install-existing --user 0 [A-Za-z0-9_.]+$"),
    Pattern.compile("^settings put global (window_animation_scale|transition_animation_scale|animator_duration_scale|private_dns_mode|private_dns_specifier) [A-Za-z0-9_.-]+$"),
    Pattern.compile("^settings delete global (window_animation_scale|transition_animation_scale|animator_duration_scale|private_dns_mode|private_dns_specifier)$"),
    Pattern.compile("^cmd appops set [A-Za-z0-9_.]+ RUN_ANY_IN_BACKGROUND (allow|ignore|default)$"),
    Pattern.compile("^pm trim-caches \\d+G$"),
    Pattern.compile("^svc power reboot$"),
    Pattern.compile("^reboot$"),
  };
  static final Pattern[] READ = {
    Pattern.compile("^getprop$"),
    Pattern.compile("^getprop [A-Za-z0-9_.]+$"),
    Pattern.compile("^cat /proc/(meminfo|uptime|loadavg|version)$"),
    Pattern.compile("^cat /sys/devices/system/cpu/(present|possible)$"),
    Pattern.compile("^cat /sys/devices/system/cpu/cpu\\d+/cpufreq/(cpuinfo_max_freq|scaling_cur_freq)$"),
    Pattern.compile("^df -k /data$"),
    Pattern.compile("^ps -A -o RSS,NAME$"),
    Pattern.compile("^ps -A$"),
    Pattern.compile("^ps$"),
    Pattern.compile("^pidof [A-Za-z0-9_.]+$"),
    Pattern.compile("^dumpsys (cpuinfo|usagestats|wifi|connectivity|accessibility|thermalservice|battery|role|device_policy|diskstats)$"),
    Pattern.compile("^dumpsys activity (activities|recents)$"),
    Pattern.compile("^dumpsys package [A-Za-z0-9_.]+$"),
    Pattern.compile("^pm list packages( -[sde3ui])*$"),
    Pattern.compile("^pm list (users|features)$"),
    Pattern.compile("^pm path [A-Za-z0-9_.]+$"),
    Pattern.compile("^cmd package (resolve-activity|query-activities) --brief -a [A-Za-z0-9_.]+ -c [A-Za-z0-9_.]+$"),
    Pattern.compile("^cmd role get-role-holders [A-Za-z0-9_.]+$"),
    Pattern.compile("^cmd appops query-op --user 0 [A-Z_]+ (allow|ignore|deny|default|foreground)$"),
    Pattern.compile("^cmd appops get [A-Za-z0-9_.]+ [A-Z_]+$"),
    Pattern.compile("^settings get (system|secure|global) [A-Za-z0-9_.]+$"),
    Pattern.compile("^logcat -d -b crash -t \\d+$"),
    Pattern.compile("^wm (size|density)$"),
    Pattern.compile("^dumpsys batterystats$"),
    Pattern.compile("^pm list packages -U$"),
    Pattern.compile("^du -s -k( /sdcard/[A-Za-z0-9_./-]+)+$"),
    Pattern.compile("^find /sdcard(/[A-Za-z0-9_./-]*)? -type f( -size \\+\\d+M)? -exec stat -c '%s %Y %n' \\{\\} \\+$"),
    Pattern.compile("^md5sum( '/sdcard/(?!Android/(data|obb)/)(?![^']*/\\.\\./)[^']+')+$"),
  };
  static final Pattern WRITE_META = Pattern.compile("[;&|<>`$\\\\\"*?]");
}
