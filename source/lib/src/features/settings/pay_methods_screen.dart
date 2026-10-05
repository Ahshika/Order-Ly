import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// طرق الدفع: الكاش والفيزا، وأرقام المحافظ (فودافون كاش، أورانج، اتصالات، WE Pay)، وعنوان InstaPay.
/// العميل بيشوف الأرقام دي في منيو الـ QR، يحوّل، ويرفع صورة التحويل.
class PayMethodsScreen extends ConsumerWidget {
  const PayMethodsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: const Text('طرق الدفع')),
        body: AsyncBody(
          value: ref.watch(payMethodsProvider),
          builder: (methods) => ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
              child: const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('العميل بيختار هيدفع إزاي من موبايله'),
                subtitle: Text('لو اختار محفظة أو InstaPay بيشوف الرقم والمبلغ، يحوّل، ويرفع صورة التحويل، والكاشير يأكد إن الفلوس وصلت.'),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final k in const ['wallet', 'instapay', 'card', 'other'])
                FilledButton.tonalIcon(
                  onPressed: () => showDialog<void>(context: context, builder: (_) => _MethodDialog(kind: k)),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(payKindLabels[k]!),
                ),
            ]),
            const SizedBox(height: 12),
            for (final m in methods)
              Card(
                child: ListTile(
                  leading: CircleAvatar(child: Icon(_icon(m.kind))),
                  title: Text(m.name, style: TextStyle(decoration: m.active ? null : TextDecoration.lineThrough).semiBold),
                  subtitle: Text([
                    payKindLabels[m.kind]!,
                    if (m.account != null) m.account!,
                    if (m.needsProof) 'بيرفع صورة التحويل',
                    m.showInQr ? 'ظاهر للعميل' : 'للكاشير بس',
                  ].join(' • ')),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => showDialog<void>(context: context, builder: (_) => _MethodDialog(kind: m.kind, method: m)),
                ),
              ),
          ]),
        ),
      );

  static IconData _icon(String kind) => switch (kind) {
        'cash' => Icons.payments_rounded,
        'card' => Icons.credit_card_rounded,
        'instapay' => Icons.bolt_rounded,
        'wallet' => Icons.account_balance_wallet_rounded,
        _ => Icons.more_horiz_rounded,
      };
}

class _MethodDialog extends ConsumerStatefulWidget {
  const _MethodDialog({required this.kind, this.method});
  final String kind;
  final PayMethod? method;

  @override
  ConsumerState<_MethodDialog> createState() => _MethodDialogState();
}

class _MethodDialogState extends ConsumerState<_MethodDialog> {
  late final _name = TextEditingController(text: widget.method?.name ?? switch (widget.kind) { 'wallet' => 'فودافون كاش', 'instapay' => 'InstaPay', 'card' => 'فيزا', _ => '' });
  late final _account = TextEditingController(text: widget.method?.account);
  late final _link = TextEditingController(text: widget.method?.link);
  late final _instructions = TextEditingController(text: widget.method?.instructions);
  late bool _needsProof = widget.method?.needsProof ?? (widget.kind == 'wallet' || widget.kind == 'instapay');
  late bool _showInQr = widget.method?.showInQr ?? true;
  late bool _active = widget.method?.active ?? true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _account, _link, _instructions]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    try {
      final api = ref.read(sessionProvider).value!.api!;
      final body = {
        'name': _name.text,
        'kind': widget.kind,
        'account': _account.text,
        'link': _link.text,
        'instructions': _instructions.text,
        'needsProof': _needsProof,
        'showInQr': _showInQr,
        'active': _active,
      };
      widget.method == null ? await api.post('/api/pay-methods', body) : await api.patch('/api/pay-methods/${widget.method!.id}', body);
      ref.invalidate(payMethodsProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final transfer = widget.kind == 'wallet' || widget.kind == 'instapay';
    return AlertDialog(
      title: Text(widget.method == null ? 'إضافة ${payKindLabels[widget.kind]}' : 'تعديل ${widget.method!.name}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.kind == 'wallet')
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final n in const ['فودافون كاش', 'أورانج كاش', 'اتصالات كاش', 'WE Pay'])
                  ActionChip(label: Text(n), onPressed: () => setState(() => _name.text = n)),
              ]),
            const SizedBox(height: 10),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'الاسم اللي العميل هيشوفه')),
            if (transfer) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _account,
                textDirection: TextDirection.ltr,
                keyboardType: widget.kind == 'wallet' ? TextInputType.phone : TextInputType.text,
                decoration: InputDecoration(
                  labelText: widget.kind == 'wallet' ? 'رقم المحفظة' : 'عنوان InstaPay أو رقم الموبايل',
                  hintText: widget.kind == 'wallet' ? '010xxxxxxxx' : 'cafe@instapay',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _link,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(labelText: 'لينك الدفع (اختياري)', hintText: 'https://ipn.eg/S/...'),
              ),
            ],
            const SizedBox(height: 10),
            TextField(controller: _instructions, maxLines: 2, decoration: const InputDecoration(labelText: 'تعليمات للعميل (اختياري)', hintText: 'اكتب رقم الترابيزة في ملاحظة التحويل')),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('العميل يشوفها في منيو الـ QR'), value: _showInQr, onChanged: (v) => setState(() => _showInQr = v)),
            if (transfer)
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('لازم يرفع صورة التحويل'), value: _needsProof, onChanged: (v) => setState(() => _needsProof = v)),
            if (widget.method != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('شغالة'), value: _active, onChanged: (v) => setState(() => _active = v)),
            if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}
