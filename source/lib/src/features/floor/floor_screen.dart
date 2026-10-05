import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../check/check_screen.dart';
import '../home/home_shell.dart';

/// الصالة: كل الترابيزات بحالتها (فاضية، مشغولة، طالبة الحساب، بتنادي)، والتيك أواي والديليفري المفتوحين.
class FloorScreen extends ConsumerStatefulWidget {
  const FloorScreen({super.key});

  @override
  ConsumerState<FloorScreen> createState() => _FloorScreenState();
}

class _FloorScreenState extends ConsumerState<FloorScreen> {
  String? _area;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // عشان مدة قعدة كل ترابيزة تتحدث
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _openTable(TableInfo t) async {
    if (t.check != null) return openCheck(context, t.check!.id);
    final guests = await showDialog<int>(context: context, builder: (_) => _GuestsDialog(table: t));
    if (guests == null || !mounted) return;
    try {
      final res = await ref.read(sessionProvider).value!.api!.post('/api/checks', {'type': 'dine_in', 'tableId': t.id, if (guests > 0) 'guests': guests});
      if (mounted) openCheck(context, (res['check'] as Map)['id'] as String);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    }
  }

  Future<void> _newOther(String type) async {
    final name = await askText(context, type == 'delivery' ? 'ديليفري جديد' : 'تيك أواي جديد', label: 'اسم العميل (اختياري)', required: false);
    if (name == null || !mounted) return;
    try {
      final res = await ref.read(sessionProvider).value!.api!.post('/api/checks', {'type': type, if (name.isNotEmpty) 'customerName': name});
      if (mounted) openCheck(context, (res['check'] as Map)['id'] as String);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final floor = ref.watch(floorProvider);
    final live = ref.watch(liveProvider).value;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الصالة'),
        actions: [
          if (wide) ...[
            OutlinedButton.icon(onPressed: () => _newOther('takeaway'), icon: const Icon(Icons.shopping_bag_outlined), label: const Text('تيك أواي')),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: () => _newOther('delivery'), icon: const Icon(Icons.delivery_dining_outlined), label: const Text('ديليفري')),
            const SizedBox(width: 16),
          ] else
            PopupMenuButton<String>(
              icon: const Icon(Icons.add_circle_outline_rounded),
              onSelected: _newOther,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'takeaway', child: Text('تيك أواي جديد')),
                PopupMenuItem(value: 'delivery', child: Text('ديليفري جديد')),
              ],
            ),
        ],
      ),
      body: AsyncBody(
        value: floor,
        onRetry: () => ref.invalidate(floorProvider),
        builder: (f) {
          final areas = f.areas;
          final tables = _area == null ? f.tables : f.tables.where((t) => t.areaId == _area).toList();
          final busy = f.tables.where((t) => t.busy).length;
          return RefreshIndicator(
            onRefresh: () => ref.refresh(floorProvider.future),
            child: CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    _Stat(icon: Icons.event_seat_rounded, text: '$busy مشغولة من ${f.tables.length}'),
                    if ((live?.pendingOrders ?? 0) > 0)
                      _AlertChip(icon: Icons.qr_code_2_rounded, text: '${live!.pendingOrders} طلب QR مستني', onTap: () => ref.read(shellTabProvider.notifier).go('orders')),
                    if ((live?.openCalls ?? 0) > 0)
                      _AlertChip(icon: Icons.front_hand_rounded, text: '${live!.openCalls} نداء', onTap: () => ref.read(shellTabProvider.notifier).go('orders')),
                    if ((live?.pendingPayments ?? 0) > 0)
                      _AlertChip(icon: Icons.receipt_rounded, text: '${live!.pendingPayments} تحويل مستني تأكيد', onTap: () => ref.read(shellTabProvider.notifier).go('orders')),
                    if (live != null && !live.registerOpen) _AlertChip(icon: Icons.lock_clock_rounded, text: 'الدرج مقفول', onTap: () => ref.read(shellTabProvider.notifier).go('register')),
                  ]),
                ),
              ),
              if (areas.length > 1)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 46,
                    child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: ChoiceChip(label: const Text('الكل'), selected: _area == null, onSelected: (_) => setState(() => _area = null)),
                      ),
                      for (final a in areas)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: ChoiceChip(label: Text(a.name), selected: _area == a.id, onSelected: (_) => setState(() => _area = a.id)),
                        ),
                    ]),
                  ),
                ),
              if (f.tables.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(icon: Icons.table_restaurant_outlined, text: 'لسه مفيش ترابيزات.\nصاحب الكافيه يضيفها من "الترابيزات و QR".'),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 170, mainAxisExtent: 128, crossAxisSpacing: 10, mainAxisSpacing: 10),
                    delegate: SliverChildBuilderDelegate((_, i) => _TableTile(table: tables[i], onTap: () => _openTable(tables[i])), childCount: tables.length),
                  ),
                ),
              if (f.others.isNotEmpty) ...[
                const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 0), child: SectionTitle('تيك أواي وديليفري مفتوح'))),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  sliver: SliverList.separated(
                    itemCount: f.others.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      final c = f.others[i];
                      return Card(
                        child: ListTile(
                          leading: Icon(c.type == 'delivery' ? Icons.delivery_dining_rounded : Icons.shopping_bag_rounded),
                          title: Text('#${c.number} • ${c.title}'),
                          subtitle: Text(c.openedAt == null ? '' : timeAgo(c.openedAt!)),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(money(c.totalCents), style: const TextStyle().semiBold),
                            if (c.paidCents > 0) Text(c.dueCents <= 0 ? 'مدفوع' : 'باقي ${money(c.dueCents)}', style: Theme.of(context).textTheme.bodySmall),
                          ]),
                          onTap: () => openCheck(context, c.id),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ]),
          );
        },
      ),
    );
  }
}

class _TableTile extends StatelessWidget {
  const _TableTile({required this.table, required this.onTap});
  final TableInfo table;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = table.check;
    final billColor = const Color(0xFFD97706);
    final Color bg, fg;
    if (c == null) {
      bg = scheme.surfaceContainerLowest;
      fg = scheme.onSurface;
    } else if (c.billRequested) {
      bg = billColor.withValues(alpha: 0.16);
      fg = scheme.onSurface;
    } else {
      bg = scheme.primaryContainer;
      fg = scheme.onPrimaryContainer;
    }
    final minutes = c?.openedAt == null ? null : DateTime.now().difference(c!.openedAt!).inMinutes;
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: table.needsAttention ? scheme.error : (c == null ? scheme.outlineVariant : Colors.transparent),
          width: table.needsAttention ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(table.name, style: Theme.of(context).textTheme.titleLarge?.bold.copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (table.pendingOrders > 0) const _Dot(icon: Icons.qr_code_2_rounded, color: Color(0xFFD97706)),
              if (table.calls.contains('waiter')) _Dot(icon: Icons.front_hand_rounded, color: scheme.error),
              if (table.pendingPayments > 0) const _Dot(icon: Icons.receipt_rounded, color: Color(0xFF7C3AED)),
              if (table.readyOrders > 0) const _Dot(icon: Icons.room_service_rounded, color: Color(0xFF16A34A)),
            ]),
            const Spacer(),
            if (c == null)
              Text('فاضية • ${table.seats} كراسي', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.outline, fontSize: 12))
            else ...[
              Text(money(c.totalCents), style: TextStyle(color: fg, fontSize: 16).bold),
              Row(children: [
                Icon(Icons.schedule_rounded, size: 14, color: fg.withValues(alpha: 0.7)),
                const SizedBox(width: 3),
                Text(minutes == null ? '' : minutes < 60 ? '$minutes د' : '${minutes ~/ 60} س ${minutes % 60} د', style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 12)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    c.billRequested ? 'عايز الحساب' : (c.guests ?? 0) > 0 ? '${c.guests} أفراد' : '',
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: c.billRequested ? TextStyle(color: billColor, fontSize: 12).bold : TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 12),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsetsDirectional.only(start: 3),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, size: 13, color: Colors.white),
      );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Chip(avatar: Icon(icon, size: 18), label: Text(text));
}

class _AlertChip extends StatelessWidget {
  const _AlertChip({required this.icon, required this.text, required this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(icon, size: 18, color: scheme.onErrorContainer),
      label: Text(text, style: TextStyle(color: scheme.onErrorContainer).semiBold),
      backgroundColor: scheme.errorContainer,
      side: BorderSide.none,
      onPressed: onTap,
    );
  }
}

class _GuestsDialog extends StatelessWidget {
  const _GuestsDialog({required this.table});
  final TableInfo table;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('فتح ترابيزة ${table.name}'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('عدد الأفراد'),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var n = 1; n <= 8; n++) ActionChip(label: Text('$n'), onPressed: () => Navigator.pop(context, n)),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, 0), child: const Text('افتح من غير عدد')),
        ],
      );
}
