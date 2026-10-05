import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../core/cafe_models.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../checks/checks_history_screen.dart';
import '../customers/customers_screen.dart';
import '../floor/floor_screen.dart';
import '../inventory/inventory_screen.dart';
import '../kds/kds_screen.dart';
import '../menu/menu_screen.dart';
import '../orders/orders_screen.dart';
import '../printing/print_service.dart';
import '../register/register_screen.dart';
import '../reports/reports_screen.dart';
import '../settings/settings_screen.dart';
import '../tables/tables_admin_screen.dart';
import '../users/users_screen.dart';

class _Destination {
  const _Destination(this.id, this.label, this.icon, this.selectedIcon, this.builder, {this.roles});

  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() builder;

  /// لو null يبقى متاح لكل الصلاحيات.
  final Set<Role>? roles;
}

const _cash = {Role.owner, Role.cashier};
const _floor = {Role.owner, Role.cashier, Role.waiter};

final _destinations = <_Destination>[
  _Destination('floor', 'الصالة', Icons.table_restaurant_outlined, Icons.table_restaurant_rounded, () => const FloorScreen(), roles: _floor),
  _Destination('orders', 'الطلبات', Icons.notifications_active_outlined, Icons.notifications_active_rounded, () => const OrdersScreen(), roles: _floor),
  _Destination('kds', 'البار والمطبخ', Icons.soup_kitchen_outlined, Icons.soup_kitchen_rounded, () => const KdsScreen(), roles: {Role.owner, Role.cashier, Role.kitchen}),
  _Destination('checks', 'الحسابات', Icons.receipt_long_outlined, Icons.receipt_long_rounded, () => const ChecksHistoryScreen(), roles: _cash),
  _Destination('register', 'الدرج', Icons.point_of_sale_outlined, Icons.point_of_sale_rounded, () => const RegisterScreen(), roles: _cash),
  _Destination('menu', 'المنيو', Icons.restaurant_menu_outlined, Icons.restaurant_menu_rounded, () => const MenuScreen(), roles: {Role.owner}),
  _Destination('tables', 'الترابيزات و QR', Icons.qr_code_2_outlined, Icons.qr_code_2_rounded, () => const TablesAdminScreen(), roles: {Role.owner}),
  _Destination('stock', 'المخزون', Icons.inventory_2_outlined, Icons.inventory_2_rounded, () => const InventoryScreen(), roles: _cash),
  _Destination('customers', 'العملاء', Icons.loyalty_outlined, Icons.loyalty_rounded, () => const CustomersScreen(), roles: _cash),
  _Destination('reports', 'التقارير', Icons.insights_outlined, Icons.insights_rounded, () => const ReportsScreen(), roles: {Role.owner}),
  _Destination('users', 'الموظفين', Icons.badge_outlined, Icons.badge_rounded, () => const UsersScreen(), roles: {Role.owner}),
  _Destination('settings', 'الإعدادات', Icons.settings_outlined, Icons.settings_rounded, () => const SettingsScreen()),
];

/// بيتنادى من أي شاشة عشان يروح لتبويب معين (مثلاً من تنبيه طلب جديد للطلبات).
final shellTabProvider = NotifierProvider<ShellTab, String?>(ShellTab.new);

class ShellTab extends Notifier<String?> {
  @override
  String? build() => null;
  void go(String id) => state = id;
}

/// الهيكل الأساسي بعد الدخول: قائمة جانبية على الشاشات الكبيرة، وشريط تحت على الموبايل.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  void _alert(String message, String? goTo) {
    if (ref.read(appConfigProvider).alertSound) {
      // تنبيه صوتي مكرر عشان يتسمع وسط دوشة الكافيه
      for (var i = 0; i < 3; i++) {
        Timer(Duration(milliseconds: i * 450), () => SystemSound.play(SystemSoundType.alert));
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: goTo == null ? null : SnackBarAction(label: 'افتح', onPressed: () => ref.read(shellTabProvider.notifier).go(goTo)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider).value!.user!;
    // محطة الطباعة (لو الجهاز ده عليه طابعة) بتشتغل طول ما البرنامج مفتوح
    ref.watch(printAgentProvider);
    final items = _destinations.where((d) => d.roles == null || d.roles!.contains(user.role)).toList();

    final live = user.role == Role.kitchen ? null : ref.watch(liveProvider).value;
    ref.listen(liveProvider, (prev, next) {
      final a = prev?.value, b = next.value;
      if (a == null || b == null || user.role == Role.kitchen) return;
      if (b.pendingOrders > a.pendingOrders) _alert('طلب جديد من موبايل عميل مستني موافقتك', 'orders');
      if (b.openCalls > a.openCalls) _alert('ترابيزة بتنادي', 'orders');
      if (b.pendingPayments > a.pendingPayments && user.handlesCash) _alert('عميل حوّل فلوس ورفع صورة التحويل', 'orders');
      if (b.readyOrders > a.readyOrders && user.role == Role.waiter) _alert('فيه طلب جاهز للتقديم', 'orders');
    });
    ref.listen(shellTabProvider, (_, id) {
      final i = items.indexWhere((d) => d.id == id);
      if (i >= 0) setState(() => _index = i);
    });

    final index = _index.clamp(0, items.length - 1);
    final page = KeyedSubtree(key: ValueKey(items[index].id), child: items[index].builder());
    final wide = MediaQuery.sizeOf(context).width >= 840;
    int badge(_Destination d) => d.id == 'orders' ? (live?.attention ?? 0) + (user.role == Role.waiter ? live?.readyOrders ?? 0 : 0) : 0;

    Widget icon(_Destination d, bool selected) {
      final i = Icon(selected ? d.selectedIcon : d.icon);
      final n = badge(d);
      return n > 0 ? Badge(label: Text('$n'), child: i) : i;
    }

    if (!wide) {
      // الموبايل بيشيل 5 أزرار بالكتير تحت؛ الباقي في "المزيد"
      final primary = items.length <= 5 ? items : items.take(4).toList();
      final more = items.length <= 5 ? const <_Destination>[] : items.skip(4).toList();
      final inMore = index >= primary.length;
      return Scaffold(
        body: page,
        bottomNavigationBar: NavigationBar(
          selectedIndex: inMore ? primary.length : index,
          onDestinationSelected: (i) async {
            if (i < primary.length) return setState(() => _index = i);
            final picked = await showModalBottomSheet<int>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (context) => SafeArea(
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (var k = 0; k < more.length; k++)
                      ListTile(
                        leading: Icon(more[k].icon),
                        title: Text(more[k].label),
                        selected: index == primary.length + k,
                        onTap: () => Navigator.pop(context, primary.length + k),
                      ),
                  ]),
                ),
              ),
            );
            if (picked != null) setState(() => _index = picked);
          },
          destinations: [
            for (var k = 0; k < primary.length; k++)
              NavigationDestination(icon: icon(primary[k], false), selectedIcon: icon(primary[k], true), label: primary[k].label),
            if (more.isNotEmpty)
              NavigationDestination(icon: const Icon(Icons.more_horiz_rounded), label: inMore ? items[index].label : 'المزيد'),
          ],
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          Material(
            color: scheme.surfaceContainerLowest,
            child: SizedBox(
              width: 230,
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 22, 20, 16),
                      child: Row(children: [OrderlyLogo(size: 36, showName: false), SizedBox(width: 10), BrandName()]),
                    ),
                    if (live != null && !live.registerOpen && user.handlesCash)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: Material(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.lock_clock_rounded, color: scheme.onErrorContainer),
                            title: Text('الدرج مقفول', style: TextStyle(color: scheme.onErrorContainer).semiBold),
                            subtitle: Text('طلبات الـ QR مش هتتقبل', style: TextStyle(color: scheme.onErrorContainer, fontSize: 12)),
                            onTap: () => setState(() => _index = items.indexWhere((d) => d.id == 'register')),
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (var i = 0; i < items.length; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
                              child: ListTile(
                                dense: true,
                                visualDensity: const VisualDensity(vertical: -1),
                                selected: i == index,
                                selectedTileColor: scheme.primaryContainer,
                                selectedColor: scheme.onPrimaryContainer,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                leading: Icon(i == index ? items[i].selectedIcon : items[i].icon),
                                title: Text(items[i].label, style: (i == index ? const TextStyle().semiBold : const TextStyle()).copyWith(fontSize: 15)),
                                trailing: CountBadge(badge(items[i])),
                                onTap: () => setState(() => _index = i),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _UserFooter(user: user),
                  ],
                ),
              ),
            ),
          ),
          VerticalDivider(width: 1, color: scheme.outlineVariant.withValues(alpha: 0.6)),
          Expanded(child: page),
        ],
      ),
    );
  }
}

class _UserFooter extends ConsumerWidget {
  const _UserFooter({required this.user});
  final AppUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Text(user.name.characters.first, style: TextStyle(color: scheme.onSecondaryContainer)),
        ),
        title: Text(user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(user.role.label),
        trailing: IconButton(
          tooltip: 'خروج',
          icon: const Icon(Icons.logout_rounded),
          onPressed: () => ref.read(sessionProvider.notifier).logout(),
        ),
      ),
    );
  }
}

/// لون حالة الطلب.
Color orderStatusColor(BuildContext context, String status) => switch (status) {
      'pending' => const Color(0xFFD97706),
      'accepted' => Theme.of(context).colorScheme.primary,
      'ready' => const Color(0xFF16A34A),
      'served' => Theme.of(context).colorScheme.outline,
      _ => Theme.of(context).colorScheme.error,
    };

/// شيب صغير لحالة الطلب.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final c = orderStatusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(orderStatusLabels[status] ?? status, style: TextStyle(color: c, fontSize: 12).semiBold),
    );
  }
}
