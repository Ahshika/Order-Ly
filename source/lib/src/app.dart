import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/notifications.dart';
import 'core/realtime.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_shell.dart';
import 'features/setup/connect_screen.dart';
import 'features/setup/create_shop_screen.dart';
import 'features/setup/status_screens.dart';
import 'features/setup/welcome_screen.dart';

class OrderlyApp extends ConsumerWidget {
  const OrderlyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Order Ly',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar', 'EG'),
      supportedLocales: const [Locale('ar', 'EG'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      // الإشعارات بتطلع رسالتها فوق أي شاشة مفتوحة
      navigatorKey: rootNavigatorKey,
      // شريط "مفيش اتصال" فوق كل الشاشات (حتى شاشة الحساب) لحد ما الاتصال بالسيرفر يرجع
      builder: (context, child) => _OfflineBar(child: child ?? const SizedBox.shrink()),
      home: const _SessionGate(),
    );
  }
}

class _OfflineBar extends ConsumerWidget {
  const _OfflineBar({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(sessionProvider).value?.status == SessionStatus.ready;
    final offline = ready && !ref.watch(serverConnectedProvider);
    final scheme = Theme.of(context).colorScheme;
    const message = 'مفيش اتصال بسيرفر الكافيه. بنحاول نرجع لوحدنا… الطلبات اللي ما اتبعتتش لسه محفوظة على الجهاز ده';
    // شكل الشجرة ثابت (العمود دايماً موجود، والشريط بس اللي بيظهر ويختفي)، عشان الشاشات المفتوحة واللي لسه ما اتبعتش ما يتمسحش
    return Column(
      children: [
        if (offline)
          // liveRegion: قارئ الشاشة بيقول الرسالة أول ما الاتصال يقطع
          Semantics(
            container: true,
            liveRegion: true,
            label: message,
            excludeSemantics: true,
            child: Material(
              color: scheme.errorContainer,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.wifi_off_rounded, color: scheme.onErrorContainer, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(message, style: TextStyle(color: scheme.onErrorContainer, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // الشريط واخد مكان شريط الموبايل اللي فوق، فالشاشة تحته ماتسيبش مسافة تانية
        Expanded(
          child: MediaQuery.removePadding(context: context, removeTop: offline, child: child),
        ),
      ],
    );
  }
}

/// بيختار الشاشة حسب حالة الجهاز: أول تشغيل، أو محتاج سيرفر، أو تسجيل دخول، أو جاهز.
class _SessionGate extends ConsumerWidget {
  const _SessionGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final value = session.value;
    if (value == null || session.isLoading) return const SplashScreen();

    return switch (value.status) {
      SessionStatus.chooseMode => const WelcomeScreen(),
      SessionStatus.needsServer => const ConnectScreen(),
      SessionStatus.serverFailed => ServerFailedScreen(message: value.error ?? ''),
      SessionStatus.unreachable => UnreachableScreen(message: value.error ?? ''),
      SessionStatus.needsSetup => const CreateShopScreen(),
      SessionStatus.needsLogin => const LoginScreen(),
      SessionStatus.ready => const HomeShell(),
    };
  }
}
