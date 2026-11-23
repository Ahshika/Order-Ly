import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/core/app_config.dart';
import 'src/core/app_info.dart';
import 'src/core/diagnostics.dart';
import 'src/core/notifications.dart';
import 'src/core/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await AppConfig.load();
  await _startDiagnostics();
  await NotificationCenter.init();
  // نسخة الويب: ?a11y=1 في العنوان بيشغّل قارئ الشاشة من الأول (للموظف اللي بيستخدم VoiceOver، والاختبارات)
  if (kIsWeb && Uri.base.queryParameters['a11y'] == '1') SemanticsBinding.instance.ensureSemantics();
  runApp(ProviderScope(
    // الأخطاء بنعرضها للمستخدم بنفسنا، فمش عايزين Riverpod يعيد المحاولة لوحده
    retry: (_, _) => null,
    overrides: [appConfigProvider.overrideWithValue(config)],
    child: const OrderlyApp(),
  ));
}

/// سجل المشاكل ومراقب التعليق (لو حاجة فيهم فشلت، البرنامج بيكمل عادي).
Future<void> _startDiagnostics() async {
  // المتصفح مالوش فولدر للسجل ولا Isolate للمراقب: الأخطاء بتظهر في الـ console بتاعه
  if (kIsWeb) return;
  try {
    final dir = await getApplicationSupportDirectory();
    final log = DiagLog.app = DiagLog.openIn(dir.path, 'app');
    log.write('INFO', 'تشغيل $appName $appVersion على ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log.error(details.exception, details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      log.error(e, st);
      return true;
    };
    WidgetsBinding.instance.addObserver(_Lifecycle());
    // الصور اللي في الذاكرة ما تعدّيش 64 ميجا مهما البرنامج فضل مفتوح
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = 64 << 20
      ..maximumSize = 300;
    await FreezeWatchdog.start(log.path);
  } catch (_) {}
}

/// البرنامج متصغّر أو الموبايل قافل الشاشة: ده مش تعليق.
class _Lifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      FreezeWatchdog.paused(state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached);
}
