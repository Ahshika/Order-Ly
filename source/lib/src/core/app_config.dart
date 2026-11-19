import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

enum AppMode { server, client }

/// إعدادات الجهاز نفسه (مش إعدادات الكافيه): الجهاز ده سيرفر ولا متصل بسيرفر، وعنوان السيرفر، والتوكن.
class AppConfig {
  AppConfig._(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppConfig> load() async {
    final config = AppConfig._(await SharedPreferences.getInstance());
    if (config._prefs.getString(_kDeviceId) == null) {
      await config._prefs.setString(_kDeviceId, const Uuid().v4());
    }
    return config;
  }

  static const _kMode = 'mode';
  static const _kServerUrl = 'server_url';
  static const _kToken = 'token';
  static const _kDeviceId = 'device_id';
  static const _kThemeMode = 'theme_mode';
  static const _kPrinterUrl = 'receipt_printer_url';
  static const _kPrinterName = 'receipt_printer_name';
  static const _kPrintStations = 'print_stations';
  static const _kKdsStation = 'kds_station';
  static const _kAlerts = 'alerts_sound';

  AppMode? get mode => switch (_prefs.getString(_kMode)) {
        'server' => AppMode.server,
        'client' => AppMode.client,
        _ => null,
      };

  Future<void> setMode(AppMode? mode) =>
      mode == null ? _prefs.remove(_kMode) : _prefs.setString(_kMode, mode.name);

  String? get serverUrl => _prefs.getString(_kServerUrl);
  Future<void> setServerUrl(String? url) =>
      url == null ? _prefs.remove(_kServerUrl) : _prefs.setString(_kServerUrl, url);

  String? get token => _prefs.getString(_kToken);
  Future<void> setToken(String? token) =>
      token == null ? _prefs.remove(_kToken) : _prefs.setString(_kToken, token);

  String get deviceId => _prefs.getString(_kDeviceId)!;

  String get deviceName {
    final os = Platform.isWindows ? 'Windows' : Platform.isAndroid ? 'Android' : Platform.operatingSystem;
    return '$os - ${Platform.localHostname}';
  }

  /// 'system' أو 'light' أو 'dark'
  String get themeMode => _prefs.getString(_kThemeMode) ?? 'system';
  Future<void> setThemeMode(String value) => _prefs.setString(_kThemeMode, value);

  static bool get canHostServer => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

extension DeviceSettings on AppConfig {
  /// الطابعة اللي الوصولات بتتطبع عليها على طول من الجهاز ده (من غير ما يسأل كل مرة).
  String? get receiptPrinterUrl => _prefs.getString(AppConfig._kPrinterUrl);
  String? get receiptPrinterName => _prefs.getString(AppConfig._kPrinterName);
  Future<void> setReceiptPrinter(String? url, String? name) async {
    if (url == null) {
      await _prefs.remove(AppConfig._kPrinterUrl);
      await _prefs.remove(AppConfig._kPrinterName);
    } else {
      await _prefs.setString(AppConfig._kPrinterUrl, url);
      await _prefs.setString(AppConfig._kPrinterName, name ?? url);
    }
  }

  /// محطات الطباعة اللي الجهاز ده مسؤول عنها: {stationId: {url, name}}.
  /// 'receipt' = الحسابات والفواتير، والباقي أماكن التحضير (البار، المطبخ...).
  Map<String, ({String url, String name})> get printStations {
    final raw = _prefs.getString(AppConfig._kPrintStations);
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, (url: (v as Map)['url'] as String, name: v['name'] as String)));
    } catch (_) {
      return {};
    }
  }

  Future<void> setPrintStation(String stationId, String? url, String? name) async {
    final current = {for (final e in printStations.entries) e.key: {'url': e.value.url, 'name': e.value.name}};
    if (url == null) {
      current.remove(stationId);
    } else {
      current[stationId] = {'url': url, 'name': name ?? url};
    }
    await _prefs.setString(AppConfig._kPrintStations, jsonEncode(current));
  }

  /// شاشة البار/المطبخ على الجهاز ده بتعرض أنهي مكان ('' = الكل).
  String get kdsStation => _prefs.getString(AppConfig._kKdsStation) ?? '';
  Future<void> setKdsStation(String v) => _prefs.setString(AppConfig._kKdsStation, v);

  /// صوت الإشعارات على الجهاز ده.
  bool get alertSound => _prefs.getBool(AppConfig._kAlerts) ?? true;
  Future<void> setAlertSound(bool v) => _prefs.setBool(AppConfig._kAlerts, v);

  /// الإشعارات شغالة على الجهاز ده؟
  bool get notificationsOn => _prefs.getBool('notify_on') ?? true;
  Future<void> setNotificationsOn(bool v) => _prefs.setBool('notify_on', v);

  /// أنواع الإشعارات اللي اتقفلت على الجهاز ده (مثلاً الكاشير مش عايز "طلب جاهز").
  Set<String> get mutedKinds => (_prefs.getStringList('notify_muted') ?? const []).toSet();
  Future<void> setKindMuted(String kind, bool muted) {
    final s = mutedKinds;
    muted ? s.add(kind) : s.remove(kind);
    return _prefs.setStringList('notify_muted', s.toList());
  }

  /// أندرويد: يفضل متصل والموبايل مقفول عشان الإشعارات توصل (بيبان إشعار ثابت "Order Ly شغال").
  bool get notifyInBackground => _prefs.getBool('notify_background') ?? true;
  Future<void> setNotifyInBackground(bool v) => _prefs.setBool('notify_background', v);

  /// علّمنا إننا طلبنا إذن الإشعارات قبل كده (عشان مانسألش كل مرة).
  bool get askedNotifyPermission => _prefs.getBool('notify_asked') ?? false;
  Future<void> setAskedNotifyPermission() => _prefs.setBool('notify_asked', true);
}
