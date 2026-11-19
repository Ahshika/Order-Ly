import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/widgets/toast.dart';

/// الرسالة الصغيرة اللي بتدخل من اليمين (بدل الشريط اللي كان بياخد عرض الشاشة تحت).
void main() {
  late BuildContext ctx;

  Future<void> app(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar', 'EG'),
      supportedLocales: const [Locale('ar', 'EG')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })),
    ));
  }

  Rect boxOf(WidgetTester tester, String text) => tester.getRect(find.ancestor(of: find.text(text), matching: find.byType(Material)).first);

  testWidgets('desktop: on the right, narrow, hides by itself', (tester) async {
    await app(tester, const Size(1400, 900));
    showToast(ctx, 'اتحفظ', kind: ToastKind.success);
    await tester.pumpAndSettle();
    final r = boxOf(tester, 'اتحفظ');
    expect(r.right, closeTo(1400 - 16, 1), reason: 'stuck to the right edge even though the app is RTL');
    expect(r.width, lessThanOrEqualTo(340));
    expect(r.top, lessThan(100), reason: 'top, not the bottom of the screen');
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('اتحفظ'), findsNothing, reason: 'must disappear by itself');
  });

  testWidgets('phone: leaves room on the left, errors stay a bit longer', (tester) async {
    await app(tester, const Size(390, 844));
    showToast(ctx, 'حصلت مشكلة', kind: ToastKind.error);
    await tester.pumpAndSettle();
    final r = boxOf(tester, 'حصلت مشكلة');
    expect(r.width, lessThanOrEqualTo(390 - 32));
    expect(r.right, closeTo(390 - 16, 1));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('حصلت مشكلة'), findsOneWidget, reason: 'errors stay 5 s');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('حصلت مشكلة'), findsNothing);
  });

  testWidgets('many at once: at most 3, stacked; the same text is not repeated; tap closes', (tester) async {
    await app(tester, const Size(1400, 900));
    for (final m in ['أول', 'تاني', 'تالت', 'رابع']) {
      showToast(ctx, m);
      await tester.pump(const Duration(milliseconds: 50));
    }
    showToast(ctx, 'رابع');
    await tester.pumpAndSettle();
    expect(find.text('أول'), findsNothing, reason: 'oldest leaves when a 4th arrives');
    expect(find.text('رابع'), findsOneWidget);
    final tops = ['تاني', 'تالت', 'رابع'].map((m) => boxOf(tester, m).top).toList();
    expect(tops.toSet().length, 3, reason: 'stacked, not on top of each other');
    await tester.tap(find.text('تاني'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('تاني'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('action button runs and closes the toast', (tester) async {
    await app(tester, const Size(1400, 900));
    var opened = false;
    showToast(ctx, 'طلب جديد', kind: ToastKind.alert, actionLabel: 'افتح', onAction: () => opened = true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('افتح'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened, isTrue);
    expect(find.text('طلب جديد'), findsNothing);
  });
}
