import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/guest_contact.dart';
import '../../widgets/server_image.dart';
import '../home/home_shell.dart';
import '../printing/print_service.dart';
import 'item_picker.dart';
import 'payment_dialog.dart';

void openCheck(BuildContext context, String checkId) =>
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CheckScreen(checkId: checkId)));

/// شاشة الحساب: المنيو على جنب، والحساب على الجنب التاني (على الموبايل تبويبين).
class CheckScreen extends ConsumerStatefulWidget {
  const CheckScreen({super.key, required this.checkId});
  final String checkId;

  @override
  ConsumerState<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends ConsumerState<CheckScreen> with SingleTickerProviderStateMixin {
  final _draft = <DraftLine>[];
  final _orderNote = TextEditingController();
  bool _busy = false;
  late final _tabs = TabController(length: 2, vsync: this);

  ApiClient get _api => ref.read(sessionProvider).value!.api!;
  AppUser get _user => ref.read(sessionProvider).value!.user!;

  @override
  void dispose() {
    _tabs.dispose();
    _orderNote.dispose();
    super.dispose();
  }

  void _add(DraftLine line) {
    setState(() {
      final same = _draft.where((d) => d.key == line.key).firstOrNull;
      if (same != null) {
        same.qty += line.qty;
      } else {
        _draft.add(line);
      }
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('اتضاف: ${line.item.name}'), duration: const Duration(milliseconds: 900)));
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(checkProvider(widget.checkId));
      if (done != null && mounted) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
        await _api.post('/api/checks/${widget.checkId}/orders', {
          'lines': _draft.map((d) => d.toJson()).toList(),
          if (_orderNote.text.trim().isNotEmpty) 'note': _orderNote.text.trim(),
        });
        setState(() {
          _draft.clear();
          _orderNote.clear();
        });
      }, done: 'الطلب اتبعت للبار/المطبخ');

  Future<void> _pay(CheckDetail d) async {
    final paidAll = await showDialog<bool>(context: context, builder: (_) => PaymentDialog(detail: d));
    ref.invalidate(checkProvider(widget.checkId));
    if (paidAll == true && mounted) {
      showMessage(context, 'الحساب اتقفل');
      Navigator.pop(context);
    }
  }

  Future<void> _close() async {
    await _run(() => _api.post('/api/checks/${widget.checkId}/close'), done: 'الحساب اتقفل');
    final d = ref.read(checkProvider(widget.checkId)).value;
    if (mounted && d != null && !d.check.isOpen) Navigator.pop(context);
  }

  Future<void> _voidLine(OrderLine l) async {
    final reason = await askText(context, 'إلغاء ${l.name}', label: 'سبب الإلغاء');
    if (reason == null) return;
    int? qty;
    if (l.qty > 1 && mounted) {
      final q = await askText(context, 'هتلغي كام؟', label: 'من ${l.qty}', initial: '${l.qty}', keyboard: TextInputType.number);
      if (q == null) return;
      qty = int.tryParse(latinDigits(q));
    }
    await _run(() => _api.post('/api/order-items/${l.id}/void', {'reason': reason, 'qty': ?qty}), done: 'اتلغى');
  }

  Future<void> _menuAction(String action, CheckDetail d) async {
    final c = d.check;
    switch (action) {
      case 'move':
        final floor = await ref.read(floorProvider.future);
        if (!mounted) return;
        final free = floor.tables.where((t) => !t.busy).toList();
        final t = await _pickTable(free, 'نقل لترابيزة فاضية');
        if (t != null) await _run(() => _api.post('/api/checks/${c.id}/move', {'tableId': t.id}), done: 'اتنقل لترابيزة ${t.name}');
      case 'merge':
        final floor = await ref.read(floorProvider.future);
        if (!mounted) return;
        final busy = floor.tables.where((t) => t.busy && t.check!.id != c.id).toList();
        final t = await _pickTable(busy, 'دمج الحساب ده في ترابيزة');
        if (t == null || !mounted) return;
        if (!await confirmDialog(context, 'الحساب ده كله هيتنقل لترابيزة ${t.name}. متأكد؟')) return;
        await _run(() => _api.post('/api/checks/${c.id}/merge', {'intoCheckId': t.check!.id}), done: 'اتدمج');
        if (mounted) Navigator.pop(context);
      case 'split':
        final picked = await showDialog<List<Map<String, Object>>>(context: context, builder: (_) => _SplitDialog(lines: d.lines));
        if (picked == null || picked.isEmpty) return;
        try {
          final res = await _api.post('/api/checks/${c.id}/split', {'lines': picked});
          ref.invalidate(checkProvider(c.id));
          if (mounted) openCheck(context, (res['check'] as Map)['id'] as String);
        } catch (e) {
          if (mounted) showMessage(context, errorText(e), error: true);
        }
      case 'discount':
        final res = await showDialog<({int cents, String? note})>(context: context, builder: (_) => _DiscountDialog(check: c));
        if (res != null) await _run(() => _api.patch('/api/checks/${c.id}', {'discountCents': res.cents, 'discountNote': res.note}));
      case 'service':
        await _run(() => _api.patch('/api/checks/${c.id}', {'service': c.serviceBp == 0}));
      case 'customer':
        await showDialog<void>(context: context, builder: (_) => _CustomerDialog(detail: d));
        ref.invalidate(checkProvider(c.id));
      case 'note':
        final note = await askText(context, 'ملاحظة على الحساب', initial: c.note, required: false, maxLines: 3);
        if (note != null) await _run(() => _api.patch('/api/checks/${c.id}', {'note': note}));
      case 'guests':
        final g = await askText(context, 'عدد الأفراد', initial: '${c.guests ?? ''}', keyboard: TextInputType.number);
        final n = g == null ? null : int.tryParse(latinDigits(g));
        if (n != null) await _run(() => _api.patch('/api/checks/${c.id}', {'guests': n}));
      case 'delivery':
        final res = await showDialog<Map<String, Object?>>(context: context, builder: (_) => _DeliveryDialog(check: c));
        if (res != null) await _run(() => _api.patch('/api/checks/${c.id}', res));
      case 'print':
        await _api.post('/api/checks/${c.id}/print', {'kind': 'bill'});
        if (mounted) await printCheckHere(context, ref, c.id);
      case 'void':
        final reason = await askText(context, 'إلغاء الحساب كله', label: 'السبب');
        if (reason == null) return;
        await _run(() => _api.post('/api/checks/${c.id}/void', {'reason': reason}), done: 'الحساب اتلغى');
        if (mounted) Navigator.pop(context);
    }
  }

  Future<TableInfo?> _pickTable(List<TableInfo> tables, String title) => showDialog<TableInfo>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 380,
            child: tables.isEmpty
                ? const Text('مفيش ترابيزات متاحة')
                : Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final t in tables) ActionChip(label: Text(t.name), onPressed: () => Navigator.pop(context, t)),
                  ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء'))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(checkProvider(widget.checkId));
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final d = detail.value;
    final title = d == null ? 'الحساب' : '${d.check.title}  #${d.check.number}';
    final canEdit = d?.check.isOpen ?? false;
    final panel = AsyncBody(value: detail, onRetry: () => ref.invalidate(checkProvider(widget.checkId)), builder: _panel);

    final actions = d == null || !d.check.isOpen
        ? const <Widget>[]
        : [
            IconButton(tooltip: 'طباعة الحساب', onPressed: () => _menuAction('print', d), icon: const Icon(Icons.print_rounded)),
            PopupMenuButton<String>(
              onSelected: (a) => _menuAction(a, d),
              itemBuilder: (_) => [
                if (d.check.type == 'dine_in') const PopupMenuItem(value: 'move', child: ListTile(leading: Icon(Icons.swap_horiz_rounded), title: Text('نقل لترابيزة تانية'))),
                if (_user.handlesCash) const PopupMenuItem(value: 'merge', child: ListTile(leading: Icon(Icons.merge_rounded), title: Text('دمج مع ترابيزة'))),
                if (_user.handlesCash) const PopupMenuItem(value: 'split', child: ListTile(leading: Icon(Icons.call_split_rounded), title: Text('تقسيم الحساب'))),
                if (_user.handlesCash) const PopupMenuItem(value: 'discount', child: ListTile(leading: Icon(Icons.percent_rounded), title: Text('خصم'))),
                if (_user.handlesCash)
                  PopupMenuItem(value: 'service', child: ListTile(leading: const Icon(Icons.room_service_outlined), title: Text(d.check.serviceBp == 0 ? 'إضافة الخدمة' : 'شيل الخدمة'))),
                const PopupMenuItem(value: 'customer', child: ListTile(leading: Icon(Icons.loyalty_rounded), title: Text('العميل ونقط الولاء'))),
                if (d.check.type == 'dine_in') const PopupMenuItem(value: 'guests', child: ListTile(leading: Icon(Icons.groups_rounded), title: Text('عدد الأفراد'))),
                if (d.check.type == 'delivery') const PopupMenuItem(value: 'delivery', child: ListTile(leading: Icon(Icons.delivery_dining_rounded), title: Text('بيانات التوصيل'))),
                const PopupMenuItem(value: 'note', child: ListTile(leading: Icon(Icons.sticky_note_2_outlined), title: Text('ملاحظة'))),
                if (_user.isOwner) const PopupMenuItem(value: 'void', child: ListTile(leading: Icon(Icons.delete_forever_rounded, color: Colors.red), title: Text('إلغاء الحساب كله'))),
              ],
            ),
          ];

    if (wide) {
      return Scaffold(
        appBar: AppBar(title: Text(title), actions: actions),
        body: Row(children: [
          if (canEdit) Expanded(child: MenuPicker(onAdd: _add)),
          if (canEdit) const VerticalDivider(width: 1),
          SizedBox(width: canEdit ? 420 : MediaQuery.sizeOf(context).width.clamp(0, 600).toDouble(), child: panel),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: actions,
        bottom: canEdit
            ? TabBar(controller: _tabs, tabs: [
                const Tab(text: 'المنيو'),
                Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [const Text('الحساب'), if (_draft.isNotEmpty) ...[const SizedBox(width: 6), CountBadge(_draft.fold(0, (s, l) => s + l.qty), color: brandAccent)]])),
              ])
            : null,
      ),
      body: canEdit ? TabBarView(controller: _tabs, children: [MenuPicker(onAdd: _add), panel]) : panel,
    );
  }

  Widget _panel(CheckDetail d) {
    final c = d.check;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final draftTotal = _draft.fold(0, (s, l) => s + l.totalCents);
    final pendingPays = d.payments.where((p) => p.status == 'pending').toList();

    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), children: [
          if (!c.isOpen)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ErrorBanner(c.status == 'void' ? 'الحساب ده ملغي${c.voidReason != null ? ': ${c.voidReason}' : ''}' : 'الحساب ده اتقفل ${c.closedAt == null ? '' : formatDateTime(c.closedAt!)}'),
            ),
          if (c.customerName != null || c.customerPhone != null || c.address != null || c.note != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (c.customerName != null || c.customerPhone != null) Text([c.customerName, c.customerPhone].whereType<String>().join(' • '), style: const TextStyle().semiBold),
                  if (c.address != null) Text(c.address!),
                  if (c.note != null) Text('ملاحظة: ${c.note}', style: TextStyle(color: scheme.primary)),
                  if (d.customer != null) Text('نقط الولاء: ${d.customer!.points}', style: text.bodySmall),
                ]),
              ),
            ),
          for (final call in d.calls)
            Card(
              color: scheme.errorContainer,
              child: ListTile(
                leading: Icon(call.type == 'bill' ? Icons.receipt_rounded : Icons.front_hand_rounded, color: scheme.onErrorContainer),
                title: Text(call.label, style: TextStyle(color: scheme.onErrorContainer)),
                subtitle: call.note == null ? null : Text(call.note!, style: TextStyle(color: scheme.onErrorContainer)),
                trailing: TextButton(onPressed: () => _run(() => _api.post('/api/calls/${call.id}/done')), child: const Text('تمام')),
              ),
            ),
          for (final o in d.pendingOrders) _PendingOrderCard(order: o, onAccept: () => _run(() => _api.post('/api/orders/${o.id}/accept'), done: 'الطلب اتقبل واتبعت للبار'), onReject: () async {
                final reason = await askText(context, 'رفض الطلب', label: 'السبب (العميل هيشوفه)', initial: 'الصنف مش متاح دلوقتي');
                if (reason != null) await _run(() => _api.post('/api/orders/${o.id}/reject', {'reason': reason}));
              }),
          for (final p in pendingPays) PendingPaymentCard(payment: p, onChanged: () => ref.invalidate(checkProvider(widget.checkId))),
          for (final o in d.orders.where((o) => o.status != 'pending' && o.status != 'rejected'))
            if (o.items.isNotEmpty) _OrderBlock(order: o, canVoid: c.isOpen, onVoid: _voidLine),
          if (_draft.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('طلب جديد (لسه ما اتبعتش)', style: text.titleSmall?.bold.copyWith(color: brandAccent)),
            for (var i = 0; i < _draft.length; i++)
              Card(
                color: brandAccent.withValues(alpha: 0.08),
                child: ListTile(
                  dense: true,
                  title: Text(_draft[i].item.name, style: const TextStyle().semiBold),
                  subtitle: Text([
                    if (_draft[i].modifiers.isNotEmpty) _draft[i].modifiers.map((m) => m.name).join('، '),
                    if (_draft[i].note != null) 'ملاحظة: ${_draft[i].note}',
                    if (_draft[i].guest != null) 'لـ ${_draft[i].guest}',
                  ].join('\n')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(_draft[i].qty == 1 ? Icons.delete_outline_rounded : Icons.remove_rounded),
                      onPressed: () => setState(() => _draft[i].qty == 1 ? _draft.removeAt(i) : _draft[i].qty--),
                    ),
                    Text('${_draft[i].qty}', style: const TextStyle().bold),
                    IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_rounded), onPressed: () => setState(() => _draft[i].qty++)),
                    SizedBox(width: 74, child: Text(money(_draft[i].totalCents), textAlign: TextAlign.end)),
                  ]),
                ),
              ),
            TextField(controller: _orderNote, decoration: const InputDecoration(labelText: 'ملاحظة على الطلب كله (اختياري)', isDense: true)),
          ],
          if (d.orders.isEmpty && _draft.isEmpty && c.isOpen)
            const Padding(padding: EdgeInsets.only(top: 40), child: EmptyState(icon: Icons.add_shopping_cart_rounded, text: 'اختار الأصناف من المنيو')),
        ]),
      ),
      _Totals(check: c, payments: d.payments),
      if (c.isOpen)
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(children: [
              if (_draft.isNotEmpty)
                Expanded(
                  child: BusyButton(label: 'إرسال الطلب (${money(draftTotal)})', icon: Icons.send_rounded, busy: _busy, onPressed: _send),
                )
              else if (_user.handlesCash) ...[
                Expanded(
                  child: c.dueCents <= 0 && c.totalCents >= 0 && d.lines.isNotEmpty
                      ? BusyButton(label: 'قفل الحساب', icon: Icons.check_circle_rounded, busy: _busy, onPressed: pendingPays.isEmpty ? _close : null)
                      : BusyButton(label: c.dueCents > 0 ? 'دفع ${money(c.dueCents)}' : 'دفع', icon: Icons.payments_rounded, busy: _busy, onPressed: c.dueCents > 0 ? () => _pay(d) : null),
                ),
              ] else
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await _api.post('/api/checks/${c.id}/print', {'kind': 'bill'});
                      if (mounted) showMessage(context, 'الحساب اتبعت لطابعة الكاشير');
                    },
                    icon: const Icon(Icons.receipt_long_rounded),
                    label: const Text('اطبع الحساب عند الكاشير'),
                  ),
                ),
            ]),
          ),
        ),
    ]);
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.check, required this.payments});
  final CheckSummary check;
  final List<PaymentInfo> payments;

  @override
  Widget build(BuildContext context) {
    final c = check;
    final text = Theme.of(context).textTheme;
    Widget row(String l, String v, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Expanded(child: Text(l, style: bold ? text.titleMedium?.bold : text.bodyMedium)),
            Text(v, style: bold ? text.titleMedium?.bold : text.bodyMedium),
          ]),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
      child: Column(children: [
        if (c.subtotalCents != c.totalCents) row('المجموع', money(c.subtotalCents)),
        if (c.discountCents > 0) row('خصم', '- ${money(c.discountCents)}'),
        if (c.pointsUsed > 0) row('نقط ولاء (${c.pointsUsed})', 'متخصومة'),
        if (c.serviceCents > 0) row('خدمة ${percent(c.serviceBp)}', money(c.serviceCents)),
        if (c.taxCents > 0) row('ضريبة ${percent(c.taxBp)}', money(c.taxCents)),
        if (c.deliveryCents > 0) row('توصيل', money(c.deliveryCents)),
        row('الإجمالي', money(c.totalCents), bold: true),
        for (final p in payments.where((p) => p.status == 'confirmed')) row('مدفوع (${p.methodName})', money(p.amountCents)),
        if (c.paidCents > 0 && c.dueCents > 0) row('الباقي', money(c.dueCents), bold: true),
      ]),
    );
  }
}

class _OrderBlock extends StatelessWidget {
  const _OrderBlock({required this.order, required this.canVoid, required this.onVoid});
  final OrderInfo order;
  final bool canVoid;
  final ValueChanged<OrderLine> onVoid;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('طلب #${order.number}', style: text.labelLarge?.bold),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${orderSourceLabels[order.source]} • ${formatTime(order.createdAt)}${order.guestName != null ? ' • ${order.guestName}' : ''}${order.guestPhone != null ? ' • ${order.guestPhone}' : ''}',
              style: text.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          StatusChip(order.status),
        ]),
        if (order.note != null) Text('ملاحظة: ${order.note}', style: text.bodySmall?.copyWith(color: scheme.primary)),
        for (final l in order.items)
          InkWell(
            onTap: canVoid && !l.isVoid ? () => onVoid(l) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 28, child: Text('${l.qty}×', style: const TextStyle().bold)),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.name, style: TextStyle(decoration: l.isVoid ? TextDecoration.lineThrough : null, color: l.isVoid ? scheme.outline : null)),
                    if (l.modifiers.isNotEmpty) Text(l.modsText, style: text.bodySmall),
                    if (l.note != null) Text('ملاحظة: ${l.note}', style: text.bodySmall),
                    if (l.guest != null) Text('لـ ${l.guest}', style: text.bodySmall),
                    if (l.isVoid && l.voidReason != null) Text('ملغي: ${l.voidReason}', style: text.bodySmall?.copyWith(color: scheme.error)),
                  ]),
                ),
                if (!l.isVoid && l.status != 'new')
                  Padding(padding: const EdgeInsets.only(left: 6), child: Text(lineStatusLabels[l.status] ?? '', style: text.bodySmall)),
                Text(money(l.totalCents), style: TextStyle(color: l.isVoid ? scheme.outline : null)),
              ]),
            ),
          ),
        const Divider(),
      ]),
    );
  }
}

class _PendingOrderCard extends StatelessWidget {
  const _PendingOrderCard({required this.order, required this.onAccept, required this.onReject});
  final OrderInfo order;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final amber = const Color(0xFFD97706);
    return Card(
      color: amber.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.qr_code_2_rounded, color: amber),
            const SizedBox(width: 6),
            const Expanded(child: Text('طلب من موبايل العميل')),
            Text(money(order.totalCents), style: const TextStyle().bold),
          ]),
          const SizedBox(height: 6),
          GuestContact(tableName: order.tableName, name: order.guestName, phone: order.guestPhone, dense: true),
          const SizedBox(height: 6),
          for (final l in order.items) Text('${l.qty}× ${l.name}${l.modifiers.isEmpty ? '' : ' (${l.modsText})'}${l.note != null ? ' • ${l.note}' : ''}'),
          if (order.note != null) Text('ملاحظة: ${order.note}'),
          if (order.payMethodName != null) Text('هيدفع: ${order.payMethodName}', style: TextStyle(color: amber).semiBold),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: onAccept, icon: const Icon(Icons.check_rounded), label: const Text('قبول'))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onReject, child: const Text('رفض')),
          ]),
        ]),
      ),
    );
  }
}

/// تحويل (InstaPay / محفظة) العميل رفع صورته ومستني الكاشير يتأكد.
class PendingPaymentCard extends ConsumerStatefulWidget {
  const PendingPaymentCard({super.key, required this.payment, this.onChanged, this.showPlace = false});
  final PaymentInfo payment;
  final VoidCallback? onChanged;
  final bool showPlace;

  @override
  ConsumerState<PendingPaymentCard> createState() => _PendingPaymentCardState();
}

class _PendingPaymentCardState extends ConsumerState<PendingPaymentCard> {
  bool _busy = false;

  Future<void> _act(bool confirm) async {
    final api = ref.read(sessionProvider).value!.api!;
    final p = widget.payment;
    Map<String, Object?> body = {};
    if (confirm) {
      final amount = await askText(context, 'المبلغ اللي وصل فعلاً', initial: moneyInput(p.amountCents), keyboard: TextInputType.number);
      if (amount == null) return;
      final cents = parseMoney(amount);
      if (cents == null || cents <= 0) {
        if (mounted) showMessage(context, 'المبلغ مش صحيح', error: true);
        return;
      }
      body = {'amountCents': cents};
    } else {
      if (!mounted) return;
      final reason = await askText(context, 'رفض التحويل', label: 'السبب (العميل هيشوفه)', initial: 'التحويل ما وصلش');
      if (reason == null) return;
      body = {'reason': reason};
    }
    setState(() => _busy = true);
    try {
      await api.post('/api/payments/${p.id}/${confirm ? 'confirm' : 'reject'}', body);
      widget.onChanged?.call();
      if (mounted) showMessage(context, confirm ? 'الدفعة اتأكدت' : 'التحويل اترفض');
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    const purple = Color(0xFF7C3AED);
    final canConfirm = ref.watch(sessionProvider).value?.user?.handlesCash ?? false;
    return Card(
      color: purple.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (p.proofFileId != null)
            InkWell(
              onTap: () => showImageViewer(context, p.proofFileId!, title: 'صورة التحويل • ${money(p.amountCents)}'),
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: ServerImage(p.proofFileId!, width: 70, height: 100)),
            )
          else
            Container(
              width: 70,
              height: 100,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: purple.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: const Text('من غير صورة', textAlign: TextAlign.center, style: TextStyle(fontSize: 11)),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p.methodName} • ${money(p.amountCents)}', style: const TextStyle(color: purple).bold),
              if (widget.showPlace) Text([if (p.tableName != null) 'ترابيزة ${p.tableName}', if (p.checkNumber != null) 'حساب #${p.checkNumber}'].join(' • ')),
              Text('العميل حوّل ورفع الصورة • ${timeAgo(p.createdAt)}', style: Theme.of(context).textTheme.bodySmall),
              if (p.reference != null) Text('رقم العملية: ${p.reference}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              if (canConfirm)
                Wrap(spacing: 8, children: [
                  FilledButton.tonalIcon(onPressed: _busy ? null : () => _act(true), icon: const Icon(Icons.verified_rounded), label: const Text('الفلوس وصلت')),
                  TextButton(onPressed: _busy ? null : () => _act(false), child: const Text('ما وصلتش')),
                ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.lines});
  final List<OrderLine> lines;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  final _qty = <String, int>{};

  @override
  Widget build(BuildContext context) {
    final guests = widget.lines.map((l) => l.guest).whereType<String>().toSet();
    final total = widget.lines.fold(0, (s, l) => s + (_qty[l.id] ?? 0) * l.unitPriceCents);
    return AlertDialog(
      title: const Text('تقسيم الحساب'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('اختار الأصناف اللي هتطلع في حساب لوحدها (مثلاً اللي هيدفعه شخص واحد):'),
          if (guests.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, children: [
              for (final g in guests)
                ActionChip(
                  avatar: const Icon(Icons.person_rounded, size: 16),
                  label: Text('كل حاجة $g'),
                  onPressed: () => setState(() {
                    for (final l in widget.lines.where((l) => l.guest == g)) {
                      _qty[l.id] = l.qty;
                    }
                  }),
                ),
            ]),
          ],
          const SizedBox(height: 8),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final l in widget.lines)
                ListTile(
                  dense: true,
                  title: Text('${l.name}${l.guest != null ? ' (${l.guest})' : ''}'),
                  subtitle: Text('${l.qty} × ${money(l.unitPriceCents)}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(onPressed: (_qty[l.id] ?? 0) > 0 ? () => setState(() => _qty[l.id] = _qty[l.id]! - 1) : null, icon: const Icon(Icons.remove_rounded)),
                    Text('${_qty[l.id] ?? 0}'),
                    IconButton(onPressed: (_qty[l.id] ?? 0) < l.qty ? () => setState(() => _qty[l.id] = (_qty[l.id] ?? 0) + 1) : null, icon: const Icon(Icons.add_rounded)),
                  ]),
                ),
            ]),
          ),
          Text('الحساب الجديد: ${money(total)} (من غير خدمة وضريبة)', style: const TextStyle().semiBold),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: total == 0
              ? null
              : () => Navigator.pop(context, [
                    for (final e in _qty.entries)
                      if (e.value > 0) {'id': e.key, 'qty': e.value},
                  ]),
          child: const Text('قسّم'),
        ),
      ],
    );
  }
}

class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({required this.check});
  final CheckSummary check;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  late final _amount = TextEditingController(text: widget.check.discountCents == 0 ? '' : moneyInput(widget.check.discountCents));
  late final _note = TextEditingController(text: widget.check.discountNote);

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sub = widget.check.subtotalCents;
    return AlertDialog(
      title: const Text('خصم'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Wrap(spacing: 6, children: [
            for (final pc in [5, 10, 15, 20, 25, 50])
              ActionChip(label: Text('$pc%'), onPressed: () => setState(() => _amount.text = moneyInput((sub * pc / 100).round()))),
          ]),
          const SizedBox(height: 10),
          MoneyField(controller: _amount, label: 'قيمة الخصم'),
          const SizedBox(height: 10),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'السبب (اختياري)')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () {
            final cents = parseMoney(_amount.text);
            if (cents == null) return;
            Navigator.pop(context, (cents: cents, note: _note.text.trim().isEmpty ? null : _note.text.trim()));
          },
          child: const Text('تطبيق'),
        ),
      ],
    );
  }
}

class _DeliveryDialog extends StatefulWidget {
  const _DeliveryDialog({required this.check});
  final CheckSummary check;

  @override
  State<_DeliveryDialog> createState() => _DeliveryDialogState();
}

class _DeliveryDialogState extends State<_DeliveryDialog> {
  late final _name = TextEditingController(text: widget.check.customerName);
  late final _phone = TextEditingController(text: widget.check.customerPhone);
  late final _address = TextEditingController(text: widget.check.address);
  late final _fee = TextEditingController(text: widget.check.deliveryCents == 0 ? '' : moneyInput(widget.check.deliveryCents));

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _fee]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('بيانات التوصيل'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'الاسم')),
            const SizedBox(height: 10),
            TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'الموبايل')),
            const SizedBox(height: 10),
            TextField(controller: _address, maxLines: 2, decoration: const InputDecoration(labelText: 'العنوان')),
            const SizedBox(height: 10),
            MoneyField(controller: _fee, label: 'مصاريف التوصيل'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'customerName': _name.text,
              'customerPhone': _phone.text,
              'address': _address.text,
              'deliveryCents': parseMoney(_fee.text) ?? 0,
            }),
            child: const Text('حفظ'),
          ),
        ],
      );
}

class _CustomerDialog extends ConsumerStatefulWidget {
  const _CustomerDialog({required this.detail});
  final CheckDetail detail;

  @override
  ConsumerState<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends ConsumerState<_CustomerDialog> {
  late final _phone = TextEditingController(text: widget.detail.customer?.phone ?? widget.detail.check.customerPhone);
  late final _name = TextEditingController(text: widget.detail.customer?.name ?? widget.detail.check.customerName);
  late final _points = TextEditingController(text: '${widget.detail.check.pointsUsed}');
  bool _busy = false;
  String? _error;
  late Customer? _customer = widget.detail.customer;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _points.dispose();
    super.dispose();
  }

  Future<void> _go(Future<Map<String, dynamic>> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await f();
      setState(() => _customer = res['customer'] == null ? null : Customer(res['customer'] as Json));
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(sessionProvider).value!.api!;
    final shop = ref.watch(shopProvider).value;
    final id = widget.detail.check.id;
    final loyalty = shop?.loyaltyEnabled ?? false;
    final canRedeem = ref.read(sessionProvider).value!.user!.handlesCash;
    return AlertDialog(
      title: const Text('العميل'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الموبايل', prefixIcon: Icon(Icons.phone_rounded))),
          const SizedBox(height: 10),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'الاسم (اختياري)')),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _busy ? null : () => _go(() => api.post('/api/checks/$id/customer', {'phone': _phone.text, 'name': _name.text})),
            child: const Text('ربط العميل بالحساب'),
          ),
          if (_customer != null) ...[
            const SizedBox(height: 12),
            Text('${_customer!.name ?? _customer!.phone} • زيارات: ${_customer!.visits}', style: const TextStyle().semiBold),
            if (loyalty) Text('النقط: ${_customer!.points} (تساوي ${money(_customer!.pointsValueCents)})'),
            if (loyalty && canRedeem) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: _points, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'نقط تتصرف على الحساب ده', isDense: true))),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _go(() => api.post('/api/checks/$id/redeem', {'points': int.tryParse(latinDigits(_points.text)) ?? 0})),
                  child: const Text('اصرف'),
                ),
              ]),
            ],
          ],
          if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('تمام'))],
    );
  }
}
