import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/guest_contact.dart';
import '../check/check_screen.dart';

/// كل اللي محتاج حد يتصرف فيه: طلبات الـ QR المستنية، والتحويلات، ونداءات الترابيزات، والطلبات الجاهزة للتقديم.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).value!.user!;
    final live = ref.watch(liveProvider).value;
    Tab tab(String label, int n) => Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [Text(label), if (n > 0) ...[const SizedBox(width: 6), CountBadge(n)]]));
    final tabs = [
      (tab('طلبات QR', live?.pendingOrders ?? 0), const _PendingOrders()),
      if (user.handlesCash) (tab('التحويلات', live?.pendingPayments ?? 0), const _PendingPayments()),
      (tab('النداءات', live?.openCalls ?? 0), const _Calls()),
      (tab('جاهز للتقديم', live?.readyOrders ?? 0), const _ReadyOrders()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الطلبات والتنبيهات'),
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) t.$1]),
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2]),
      ),
    );
  }
}

class _PendingOrders extends ConsumerStatefulWidget {
  const _PendingOrders();

  @override
  ConsumerState<_PendingOrders> createState() => _PendingOrdersState();
}

class _PendingOrdersState extends ConsumerState<_PendingOrders> {
  final _busy = <String>{};

  Future<void> _act(OrderInfo o, bool accept) async {
    String? reason;
    if (!accept) {
      reason = await askText(context, 'رفض الطلب #${o.number}', label: 'السبب (العميل هيشوفه على موبايله)', initial: 'الصنف مش متاح دلوقتي');
      if (reason == null) return;
    }
    setState(() => _busy.add(o.id));
    try {
      await ref.read(sessionProvider).value!.api!.post('/api/orders/${o.id}/${accept ? 'accept' : 'reject'}', {'reason': ?reason});
      if (mounted) showMessage(context, accept ? 'اتقبل واتبعت للبار/المطبخ' : 'الطلب اترفض');
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(o.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncBody(
      value: ref.watch(ordersProvider('pending')),
      builder: (orders) {
        if (orders.isEmpty) return const EmptyState(icon: Icons.qr_code_2_rounded, text: 'مفيش طلبات مستنية.\nطلبات العملاء من الـ QR بتظهر هنا لو الموافقة مش أوتوماتيك.');
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: orders.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            final o = orders[i];
            final text = Theme.of(context).textTheme;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const Icon(Icons.qr_code_2_rounded, color: Color(0xFFD97706)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(o.place, style: text.titleMedium?.bold)),
                    Text(timeAgo(o.createdAt), style: text.bodySmall),
                  ]),
                  const SizedBox(height: 8),
                  GuestContact(tableName: o.tableName, name: o.guestName, phone: o.guestPhone),
                  const Divider(),
                  for (final l in o.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 30, child: Text('${l.qty}×', style: const TextStyle().bold)),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(l.name, style: const TextStyle().semiBold),
                            if (l.modifiers.isNotEmpty) Text(l.modsText, style: text.bodySmall),
                            if (l.note != null) Text('ملاحظة: ${l.note}', style: text.bodySmall),
                          ]),
                        ),
                        Text(money(l.totalCents)),
                      ]),
                    ),
                  if (o.note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('ملاحظة الطلب: ${o.note}', style: const TextStyle().semiBold)),
                  const Divider(),
                  Row(children: [
                    Text('الإجمالي ${money(o.totalCents)}', style: text.titleSmall?.bold),
                    const Spacer(),
                    if (o.payMethodName != null) Chip(avatar: const Icon(Icons.payments_outlined, size: 16), label: Text('هيدفع ${o.payMethodName}')),
                  ]),
                  for (final p in o.payments) PendingPaymentCard(payment: p, onChanged: () => ref.invalidate(ordersProvider('pending'))),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: BusyButton(label: 'قبول وإرسال للبار', icon: Icons.check_rounded, busy: _busy.contains(o.id), onPressed: () => _act(o, true)),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(onPressed: _busy.contains(o.id) ? null : () => _act(o, false), child: const Text('رفض')),
                    if (o.checkId != null)
                      IconButton(tooltip: 'افتح الحساب', onPressed: () => openCheck(context, o.checkId!), icon: const Icon(Icons.open_in_new_rounded)),
                  ]),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}

class _PendingPayments extends ConsumerWidget {
  const _PendingPayments();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody(
        value: ref.watch(pendingPaymentsProvider),
        builder: (pays) => pays.isEmpty
            ? const EmptyState(icon: Icons.receipt_rounded, text: 'مفيش تحويلات مستنية تأكيد.\nلما العميل يحوّل InstaPay أو محفظة ويرفع الصورة، هتظهر هنا.')
            : ListView(padding: const EdgeInsets.all(16), children: [
                for (final p in pays)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Stack(children: [
                      PendingPaymentCard(payment: p, showPlace: true, onChanged: () => ref.invalidate(pendingPaymentsProvider)),
                      if (p.checkId != null)
                        PositionedDirectional(
                          end: 4,
                          top: 4,
                          child: IconButton(tooltip: 'افتح الحساب', onPressed: () => openCheck(context, p.checkId!), icon: const Icon(Icons.open_in_new_rounded, size: 20)),
                        ),
                    ]),
                  ),
              ]),
      );
}

class _Calls extends ConsumerWidget {
  const _Calls();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody(
        value: ref.watch(callsProvider),
        builder: (calls) => calls.isEmpty
            ? const EmptyState(icon: Icons.front_hand_outlined, text: 'مفيش ترابيزات بتنادي')
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: calls.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final c = calls[i];
                  final scheme = Theme.of(context).colorScheme;
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: c.type == 'bill' ? const Color(0xFFD97706) : scheme.error,
                        child: Icon(c.type == 'bill' ? Icons.receipt_long_rounded : Icons.front_hand_rounded, color: Colors.white),
                      ),
                      title: Text('ترابيزة ${c.tableName ?? '?'} • ${c.label}', style: const TextStyle().semiBold),
                      subtitle: Text([if (c.note != null) c.note!, timeAgo(c.createdAt)].join(' • ')),
                      trailing: Wrap(spacing: 4, children: [
                        if (c.checkId != null) IconButton(tooltip: 'افتح الحساب', onPressed: () => openCheck(context, c.checkId!), icon: const Icon(Icons.open_in_new_rounded)),
                        FilledButton.tonal(
                          onPressed: () async {
                            try {
                              await ref.read(sessionProvider).value!.api!.post('/api/calls/${c.id}/done');
                            } catch (e) {
                              if (context.mounted) showMessage(context, errorText(e), error: true);
                            }
                          },
                          child: const Text('اتعمل'),
                        ),
                      ]),
                    ),
                  );
                },
              ),
      );
}

class _ReadyOrders extends ConsumerWidget {
  const _ReadyOrders();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody(
        value: ref.watch(ordersProvider('active')),
        builder: (all) {
          final orders = all.where((o) => o.status == 'ready').toList();
          final preparing = all.where((o) => o.status == 'accepted').length;
          if (orders.isEmpty) {
            return EmptyState(icon: Icons.room_service_outlined, text: 'مفيش طلبات جاهزة دلوقتي${preparing > 0 ? '\n($preparing طلب بيتحضر)' : ''}');
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: orders.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final o = orders[i];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(backgroundColor: Color(0xFF16A34A), child: Icon(Icons.room_service_rounded, color: Colors.white)),
                  title: Text('${o.place} • طلب #${o.number}', style: const TextStyle().semiBold),
                  subtitle: Text(o.items.where((l) => !l.isVoid).map((l) => '${l.qty}× ${l.name}').join('، ')),
                  trailing: FilledButton(
                    onPressed: () async {
                      try {
                        await ref.read(sessionProvider).value!.api!.post('/api/orders/${o.id}/served');
                      } catch (e) {
                        if (context.mounted) showMessage(context, errorText(e), error: true);
                      }
                    },
                    child: const Text('اتقدم'),
                  ),
                  onTap: o.checkId == null ? null : () => openCheck(context, o.checkId!),
                ),
              );
            },
          );
        },
      );
}

