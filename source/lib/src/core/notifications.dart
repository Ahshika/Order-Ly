import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/toast.dart';
import 'app_config.dart';
import 'diagnostics.dart';
import 'realtime.dart';
import 'session.dart';

/// أنواع الإشعارات اللي السيرفر بيبعتها. لكل نوع صوت (assets/sounds و res/raw بنفس الاسم) واسم يظهر في الإعدادات.
const notifyKinds = <String, String>{
  'order_new': 'طلب جديد من موبايل عميل (QR)',
  'table_call': 'ترابيزة بتنادي الويتر أو عايزة الحساب',
  'payment': 'عميل حوّل فلوس ومستني تأكيد',
  'order_ready': 'طلب جاهز للتقديم',
  'kitchen_new': 'طلب جديد للبار/المطبخ',
  'problem': 'مشكلة (الطباعة فشلت)',
};

/// Navigator البرنامج كله: الإشعارات بتطلع رسالتها فوق أي شاشة مفتوحة.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// بيستلم إشعارات السيرفر ويقرر: رسالة على الجنب بصوت (لو البرنامج قدام المستخدم)،
/// ولا إشعار على الموبايل/الكمبيوتر (لو البرنامج في الخلفية أو الشاشة مقفولة).
final notificationCenterProvider = Provider<NotificationCenter>((ref) {
  final center = NotificationCenter(ref);
  ref.listen(realtimeProvider, (_, next) {
    final e = next.value;
    if (e?.topic == 'notify' && e!.data != null) center.handle(e.data!);
  });
  ref.onDispose(center.dispose);
  return center;
});

class NotificationCenter {
  NotificationCenter(this._ref);

  final Ref _ref;
  final _seen = <String>{};
  final _players = <String, AudioPlayer>{};

  /// الشاشة الرئيسية بتسجل هنا إزاي تفتح التبويب (الطلبات، المطبخ...) لما حد يدوس على الإشعار.
  void Function(String goTo)? onOpen;

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static String? _pendingOpen;
  static NotificationCenter? _instance;
  static int _nextId = 1;

  /// مرة واحدة أول ما البرنامج يفتح. لو المكتبة مش شغالة على الجهاز ده (أو فشلت) البرنامج بيكمل عادي بالرسايل جوه بس.
  static Future<void> init() async {
    // الويب: مفيش إشعارات نظام (الأيفون بيوقف الصفحة في الخلفية)، بس تنبيه وصوت والصفحة مفتوحة
    if (kIsWeb || !(Platform.isAndroid || Platform.isWindows)) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_orderly'),
          windows: WindowsInitializationSettings(appName: 'Order Ly', appUserModelId: 'OrderLy.Cafe.POS', guid: '3f0e8a52-7c1d-4b9e-9a6f-2d5c8e1b4a70'),
        ),
        onDidReceiveNotificationResponse: (r) {
          final goTo = r.payload;
          if (goTo == null || goTo.isEmpty) return;
          final open = _instance?.onOpen;
          open == null ? _pendingOpen = goTo : open(goTo);
        },
      );
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        // قناة لكل نوع: أندرويد بيشغّل صوتنا حتى والموبايل مقفول (والمستخدم يقدر يغيّره من إعدادات الموبايل)
        for (final e in notifyKinds.entries) {
          await android.createNotificationChannel(AndroidNotificationChannel(
            'orderly_${e.key}',
            e.value,
            importance: Importance.high,
            sound: RawResourceAndroidNotificationSound(e.key),
          ));
        }
      }
      FlutterForegroundTask.initCommunicationPort();
      _ready = true;
    } catch (e, st) {
      DiagLog.app?.error('الإشعارات ما اشتغلتش: $e', st);
    }
  }

  /// أول مرة: نطلب إذن الإشعارات (أندرويد 13+ بيسأل المستخدم).
  Future<void> askPermissionOnce() async {
    final config = _ref.read(appConfigProvider);
    if (kIsWeb || !Platform.isAndroid || config.askedNotifyPermission) return;
    await config.setAskedNotifyPermission();
    try {
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    } catch (_) {}
  }

  void attach() {
    _instance = this;
    final pending = _pendingOpen;
    if (pending != null && onOpen != null) {
      _pendingOpen = null;
      onOpen!(pending);
    }
  }

  bool get _inForeground => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  void handle(Map<String, dynamic> data) {
    final id = data['id'] as String? ?? '';
    if (!_seen.add(id)) return;
    if (_seen.length > 300) _seen.remove(_seen.first);
    final session = _ref.read(sessionProvider).value;
    final user = session?.user;
    final kind = data['kind'] as String? ?? '';
    final roles = (data['roles'] as List? ?? const []).cast<String>();
    final config = _ref.read(appConfigProvider);
    if (user == null || !roles.contains(user.role.name) || !notifyKinds.containsKey(kind)) return;
    if (!config.notificationsOn || config.mutedKinds.contains(kind)) return;
    show(kind, data['title'] as String? ?? '', data['body'] as String? ?? '', goTo: data['goTo'] as String?);
  }

  /// بيعرض الإشعار (ومستخدمة كمان في زرار "جرّب" في الإعدادات).
  Future<void> show(String kind, String title, String body, {String? goTo, bool forceSystem = false}) async {
    final config = _ref.read(appConfigProvider);
    final foreground = _inForeground && !forceSystem;
    if (foreground) {
      final overlay = rootNavigatorKey.currentState?.overlay;
      if (overlay != null) {
        showToastOn(overlay, body.isEmpty ? title : '$title\n$body',
            kind: kind == 'problem' ? ToastKind.error : ToastKind.alert,
            actionLabel: goTo == null || onOpen == null ? null : 'افتح',
            onAction: goTo == null ? null : () => onOpen?.call(goTo));
      }
      if (config.alertSound) await playSound(kind);
      return;
    }
    // في الخلفية: إشعار على الموبايل/الكمبيوتر
    if (_ready) {
      try {
        await _plugin.show(
          id: _nextId++,
          title: title,
          body: body,
          payload: goTo,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              'orderly_$kind',
              notifyKinds[kind]!,
              importance: Importance.high,
              priority: Priority.high,
              playSound: config.alertSound,
              sound: RawResourceAndroidNotificationSound(kind),
              category: AndroidNotificationCategory.message,
            ),
            // ويندوز مابيشغّلش ملف صوت بتاعنا في الإشعار، فالإشعار ساكت وإحنا بنشغّل الصوت بنفسنا
            windows: WindowsNotificationDetails(audio: WindowsNotificationAudio.silent()),
          ),
        );
      } catch (e) {
        DiagLog.app?.write('NOTIFY', 'الإشعار ماطلعش: $e');
      }
    }
    if (!kIsWeb && Platform.isWindows && config.alertSound) await playSound(kind);
  }

  Future<void> playSound(String kind) async {
    try {
      final player = _players.putIfAbsent(kind, () => AudioPlayer()..setReleaseMode(ReleaseMode.stop));
      await player.stop();
      await player.play(AssetSource('sounds/$kind.wav'), volume: 1);
    } catch (e) {
      DiagLog.app?.write('NOTIFY', 'الصوت ماشتغلش: $e');
    }
  }

  void dispose() {
    for (final p in _players.values) {
      p.dispose();
    }
    if (_instance == this) _instance = null;
  }
}

// ---------------------------------------------------------------- أندرويد: يفضل متصل والموبايل مقفول

/// خدمة أندرويد بتخلي البرنامج شغال (ومتصل بسيرفر الكافيه) والشاشة مقفولة، عشان الإشعارات توصل.
/// أندرويد بيشترط إشعار ثابت طول ما هي شغالة.
class BackgroundConnection {
  static bool _configured = false;

  static Future<void> update({required bool loggedIn, required bool wanted}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (!(loggedIn && wanted)) {
        if (running) await FlutterForegroundTask.stopService();
        return;
      }
      if (running) return;
      if (!_configured) {
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'orderly_keepalive',
            channelName: 'Order Ly متصل بالكافيه',
            channelDescription: 'بيخلي إشعارات الطلبات توصل والموبايل مقفول',
            onlyAlertOnce: true,
          ),
          iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
          foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing(), allowWakeLock: true, allowWifiLock: true),
        );
        _configured = true;
      }
      await FlutterForegroundTask.startService(
        serviceId: 4721,
        serviceTypes: [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'Order Ly شغال',
        notificationText: 'متصل بسيرفر الكافيه • هيوصلك إشعار بأي طلب جديد',
        notificationIcon: const NotificationIcon(metaDataName: 'com.orderly.app.NOTIFICATION_ICON'),
        callback: orderlyKeepAliveCallback,
      );
    } catch (e, st) {
      DiagLog.app?.error('خدمة الإشعارات في الخلفية: $e', st);
    }
  }
}

@pragma('vm:entry-point')
void orderlyKeepAliveCallback() => FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());

/// مابتعملش حاجة: وجودها بس بيمنع أندرويد إنه يوقّف البرنامج، والاتصال والإشعارات شغالين في البرنامج نفسه.
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}
