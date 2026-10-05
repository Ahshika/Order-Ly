// ignore_for_file: invalid_use_of_visible_for_testing_member
// بيرسم الشاشات الأساسية ببيانات تجريبية ويحفظها كصور PNG للمراجعة (من غير سيرفر ولا بيانات حقيقية).
// التشغيل:  flutter test test_visual --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/core/app_config.dart';
import 'package:orderly/src/core/cafe_models.dart';
import 'package:orderly/src/core/models.dart';
import 'package:orderly/src/core/providers.dart';
import 'package:orderly/src/core/session.dart';
import 'package:orderly/src/core/shop.dart';
import 'package:orderly/src/core/theme.dart';
import 'package:orderly/src/features/check/check_screen.dart';
import 'package:orderly/src/features/home/home_shell.dart';
import 'package:orderly/src/features/inventory/inventory_screen.dart';
import 'package:orderly/src/features/inventory/recipe_editor.dart';
import 'package:orderly/src/features/kds/kds_screen.dart';
import 'package:orderly/src/features/orders/orders_screen.dart';
import 'package:orderly/src/features/register/register_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSession extends SessionController {
  _FakeSession(this.role);
  final Role role;

  @override
  Future<Session> build() async => Session(
        SessionStatus.ready,
        api: ApiClient('http://fake'),
        info: ServerInfo(serverId: 'x', setupDone: true, version: '1.0.0', api: 1, shopName: 'كافيه الندى', branchName: 'الفرع الرئيسي'),
        user: AppUser(id: 'u1', name: 'أحمد حسن', username: 'ahmed', role: role, active: true),
      );
}

String _ago(int minutes) => DateTime.now().subtract(Duration(minutes: minutes)).toUtc().toIso8601String();

final _menu = MenuData({
  'stations': [
    {'id': 'bar', 'name': 'البار'},
    {'id': 'kit', 'name': 'المطبخ'},
  ],
  'categories': [
    {'id': 'hot', 'name': 'مشروبات ساخنة', 'stationId': 'bar'},
    {'id': 'cold', 'name': 'مشروبات ساقعة', 'stationId': 'bar'},
    {'id': 'sweet', 'name': 'حلويات', 'stationId': 'kit'},
  ],
  'items': [
    for (final (i, n, p) in [('latte', 'لاتيه', 6000), ('capp', 'كابتشينو', 5500), ('esp', 'إسبريسو', 3500), ('mocha', 'موكا', 6500), ('flat', 'فلات وايت', 6000), ('tea', 'شاي بالنعناع', 2500)])
      {'id': i, 'categoryId': 'hot', 'name': n, 'priceCents': p, 'groupIds': ['size']},
    {'id': 'iced', 'categoryId': 'cold', 'name': 'آيس لاتيه', 'priceCents': 6500, 'promoPriceCents': 5200},
    {'id': 'cake', 'categoryId': 'sweet', 'name': 'تشيز كيك', 'priceCents': 8500, 'soldOut': true},
  ],
  'modifierGroups': [
    {'id': 'size', 'name': 'الحجم', 'minSelect': 1, 'maxSelect': 1, 'options': [{'id': 'm', 'name': 'وسط', 'priceCents': 0, 'isDefault': true}, {'id': 'l', 'name': 'كبير', 'priceCents': 1500}]},
  ],
});

Json _line(String id, String name, int qty, int price, String status, {List<String> mods = const [], String? note, String? guest}) => {
      'id': id, 'orderId': 'o', 'name': name, 'qty': qty, 'unitPriceCents': price, 'status': status, 'stationId': 'bar',
      'modifiers': [for (final m in mods) {'name': m}], 'note': note, 'guest': guest,
    };

final _floor = FloorData({
  'areas': [
    {'id': 'a1', 'name': 'الصالة'},
    {'id': 'a2', 'name': 'التراس'},
  ],
  'tables': [
    for (var i = 1; i <= 14; i++)
      {
        'id': 't$i',
        'areaId': i <= 10 ? 'a1' : 'a2',
        'name': '$i',
        'seats': 4,
        'check': const {1, 3, 4, 7, 9, 12}.contains(i)
            ? {'id': 'c$i', 'number': 100 + i, 'totalCents': 8000 + i * 3700, 'paidCents': 0, 'guests': 2 + i % 3, 'openedAt': _ago(10 + i * 7), 'billRequested': i == 7}
            : null,
        'pendingOrders': i == 3 ? 1 : 0,
        'calls': i == 9 ? ['waiter'] : <String>[],
        'pendingPayments': i == 4 ? 1 : 0,
        'readyOrders': i == 12 ? 1 : 0,
      },
  ],
  'others': [
    {'id': 'x1', 'number': 120, 'type': 'takeaway', 'customerName': 'منى', 'totalCents': 12500, 'paidCents': 0, 'openedAt': _ago(4)},
    {'id': 'x2', 'number': 121, 'type': 'delivery', 'customerName': 'كريم', 'totalCents': 24000, 'paidCents': 24000, 'openedAt': _ago(22)},
  ],
});

final _check = CheckDetail({
  'check': {
    'id': 'c3', 'number': 103, 'type': 'dine_in', 'status': 'open', 'tableName': '3', 'guests': 3,
    'subtotalCents': 23000, 'serviceBp': 1200, 'serviceCents': 2760, 'taxBp': 0, 'taxCents': 0, 'totalCents': 25760, 'paidCents': 0, 'openedAt': _ago(35),
  },
  'orders': [
    {
      'id': 'o1', 'number': 41, 'source': 'cashier', 'status': 'ready', 'createdAt': _ago(30),
      'items': [_line('l1', 'لاتيه', 2, 7500, 'ready', mods: ['كبير', 'سكر خفيف'], guest: 'سلمى'), _line('l2', 'تشيز كيك', 1, 8000, 'ready')],
    },
    {
      'id': 'o2', 'number': 44, 'source': 'qr', 'status': 'pending', 'guestName': 'عمر', 'guestPhone': '01012345678', 'tableName': '3', 'payMethodName': 'فودافون كاش', 'createdAt': _ago(1),
      'items': [_line('l3', 'آيس لاتيه', 1, 5200, 'new', mods: ['وسط'], note: 'تلج قليل')],
    },
  ],
  'payments': [
    {'id': 'p1', 'checkId': 'c3', 'amountCents': 5200, 'methodKind': 'wallet', 'methodName': 'فودافون كاش', 'status': 'pending', 'source': 'qr', 'createdAt': _ago(1)},
  ],
  'calls': [],
});

final _kds = [
  OrderInfo({
    'id': 'k1', 'number': 45, 'source': 'qr', 'status': 'accepted', 'tableName': '3', 'guestName': 'سلمى', 'guestPhone': '01098765432', 'createdAt': _ago(3), 'acceptedAt': _ago(3),
    'items': [_line('a', 'لاتيه', 2, 6000, 'preparing', mods: ['كبير', 'لبن شوفان'], note: 'سكر خفيف'), _line('b', 'إسبريسو', 1, 3500, 'new')],
  }),
  OrderInfo({
    'id': 'k2', 'number': 43, 'source': 'waiter', 'status': 'accepted', 'tableName': '9', 'createdAt': _ago(11), 'acceptedAt': _ago(10),
    'items': [_line('c', 'كابتشينو', 3, 5500, 'new', mods: ['وسط'])],
  }),
  OrderInfo({
    'id': 'k3', 'number': 40, 'source': 'cashier', 'status': 'accepted', 'checkType': 'takeaway', 'customerName': 'منى', 'createdAt': _ago(18), 'acceptedAt': _ago(17),
    'note': 'تيك أواي - في شنطة',
    'items': [_line('d', 'آيس لاتيه', 1, 6500, 'ready'), _line('e', 'موكا', 1, 6500, 'new', mods: ['كبير'])],
  }),
];

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    await loader.load();
  }

  await load('Cairo', 'assets/fonts/Cairo-Variable.ttf');
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter';
  await load('MaterialIcons', '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
}

Future<void> _shot(WidgetTester tester, String name, Widget home, Size size, {Brightness brightness = Brightness.light, Role role = Role.owner}) async {
  SharedPreferences.setMockInitialValues({});
  final config = await AppConfig.load();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [
      appConfigProvider.overrideWithValue(config),
      sessionProvider.overrideWith(() => _FakeSession(role)),
      shopProvider.overrideWith((ref) async => ShopProfile({'name': 'كافيه الندى', 'settings': {'serviceBp': 1200, 'loyaltyEnabled': true}})),
      menuProvider.overrideWith((ref) async => _menu),
      floorProvider.overrideWith((ref) async => _floor),
      liveProvider.overrideWith((ref) async => LiveCounts({'pendingOrders': 1, 'openCalls': 1, 'pendingPayments': 1, 'readyOrders': 1, 'registerOpen': true})),
      checkProvider.overrideWith((ref, id) async => _check),
      kdsProvider.overrideWith((ref, s) async => _kds),
      ordersProvider.overrideWith((ref, s) async => s == 'pending' ? [_check.orders[1]] : _kds),
      pendingPaymentsProvider.overrideWith((ref) async => _check.payments),
      callsProvider.overrideWith((ref) async => [ServiceCall({'id': 'cl', 'type': 'waiter', 'tableName': '9', 'createdAt': _ago(2)})]),
      payMethodsProvider.overrideWith((ref) async => [
            PayMethod({'id': 'cash', 'name': 'كاش', 'kind': 'cash'}),
            PayMethod({'id': 'w', 'name': 'فودافون كاش', 'kind': 'wallet', 'account': '01012345678'}),
          ]),
      registerProvider.overrideWith((ref) async => {
            'session': {
              'id': 's', 'openedAt': _ago(400), 'openedBy': 'سارة', 'openingCashCents': 50000, 'expectedCashCents': 512000, 'salesCents': 742000, 'checksClosed': 38,
              'byMethod': {'cash': 462000, 'wallet': 160000, 'instapay': 120000},
            },
            'moves': [
              {'id': 'm1', 'type': 'sale', 'amountCents': 25760, 'method': 'cash', 'note': 'حساب #103 • كاش', 'userName': 'سارة', 'createdAt': _ago(3)},
              {'id': 'm2', 'type': 'expense', 'amountCents': -15000, 'method': 'cash', 'category': 'خامات', 'note': 'لبن', 'userName': 'سارة', 'createdAt': _ago(60)},
            ],
            'openChecks': 6,
          }),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar', 'EG'),
      supportedLocales: const [Locale('ar', 'EG')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(brightness),
      home: Consumer(builder: (context, ref, _) => ref.watch(sessionProvider).hasValue ? home : const SizedBox()),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  debugPrint('MENU $name: ${find.text('لاتيه').evaluate().length}');
  final err = tester.takeException();
  if (err != null) debugPrint('EXC $name: $err');
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(_loadFonts);
  const desktop = Size(1366, 768);
  const phone = Size(400, 860);

  testWidgets('floor desktop', (t) => _shot(t, 'floor_desktop', const HomeShell(), desktop));
  testWidgets('floor phone (waiter)', (t) => _shot(t, 'floor_phone', const HomeShell(), phone, role: Role.waiter));
  testWidgets('check desktop', (t) => _shot(t, 'check_desktop', const CheckScreen(checkId: 'c3'), desktop));
  testWidgets('check phone dark', (t) => _shot(t, 'check_phone_dark', const CheckScreen(checkId: 'c3'), phone, brightness: Brightness.dark));
  testWidgets('kds', (t) => _shot(t, 'kds_desktop', const KdsScreen(), desktop));
  testWidgets('orders', (t) => _shot(t, 'orders_desktop', const OrdersScreen(), desktop));
  testWidgets('add stock', (t) async {
    await _shot(t, 'add_stock', Scaffold(body: Center(child: AddStockDialog(ingredient: Ingredient({'id': 'i', 'name': 'لبن', 'unit': 'ml', 'qty': 4000, 'unitCost': 3.5, 'lowStock': 1000})))), const Size(700, 520));
  });
  testWidgets('register', (t) => _shot(t, 'register_desktop', const RegisterScreen(), desktop));
}
