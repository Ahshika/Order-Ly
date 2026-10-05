import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';
import 'recipe_editor.dart';

/// المخزون: الخامات (بن، لبن، أكواب...)، والجرد والهالك، وفواتير الشرا، والموردين، ووصفات الإضافات.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ref.watch(sessionProvider).value!.user!.isOwner;
    return DefaultTabController(
      length: owner ? 4 : 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المخزون'),
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            const Tab(text: 'الخامات'),
            const Tab(text: 'فواتير الشرا'),
            if (owner) const Tab(text: 'الموردين'),
            if (owner) const Tab(text: 'وصفات الإضافات'),
          ]),
        ),
        body: TabBarView(children: [
          const _IngredientsTab(),
          const _PurchasesTab(),
          if (owner) const _SuppliersTab(),
          if (owner) const _OptionRecipesTab(),
        ]),
      ),
    );
  }
}

class _IngredientsTab extends ConsumerWidget {
  const _IngredientsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ref.watch(sessionProvider).value!.user!.isOwner;
    return AsyncBody(
      value: ref.watch(ingredientsProvider),
      onRetry: () => ref.invalidate(ingredientsProvider),
      builder: (data) {
        final list = data.list;
        final low = list.where((i) => i.active && i.low).length;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Chip(avatar: const Icon(Icons.inventory_rounded, size: 18), label: Text('قيمة المخزون ${money(data.valueCents)}')),
            if (low > 0) Chip(avatar: Icon(Icons.warning_amber_rounded, size: 18, color: Theme.of(context).colorScheme.error), label: Text('$low خامة قربت تخلص')),
            if (owner)
              FilledButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const _IngredientDialog()),
                icon: const Icon(Icons.add_rounded),
                label: const Text('خامة جديدة'),
              ),
          ]),
          const SizedBox(height: 12),
          if (list.isEmpty)
            const EmptyState(icon: Icons.inventory_2_outlined, text: 'ضيف الخامات (بن بالجرام، لبن بالمل، أكواب بالقطعة...)\nوبعدين اعمل وصفة لكل صنف من شاشة المنيو.'),
          for (final i in list)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: !i.active ? null : i.low ? Theme.of(context).colorScheme.errorContainer : Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(i.low ? Icons.warning_amber_rounded : Icons.inventory_rounded, size: 20),
                ),
                title: Text(i.name, style: TextStyle(decoration: i.active ? null : TextDecoration.lineThrough).semiBold),
                subtitle: Text([
                  'تكلفة الـ${i.unitLabel}: ${(i.unitCost / 100).toStringAsFixed(i.unitCost < 100 ? 3 : 2)} ج.م',
                  if (i.lowStock > 0) 'تنبيه تحت ${fmtQty(i.lowStock)}',
                  'في ${i.usedBy} وصفة',
                ].join(' • ')),
                onTap: i.active ? () => showDialog<void>(context: context, builder: (_) => AddStockDialog(ingredient: i)) : null,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${fmtQty(i.qty)} ${i.unitLabel}', style: Theme.of(context).textTheme.titleMedium?.bold.copyWith(color: i.low ? Theme.of(context).colorScheme.error : null)),
                  PopupMenuButton<String>(
                    onSelected: (a) async {
                      if (a == 'edit') {
                        await showDialog<void>(context: context, builder: (_) => _IngredientDialog(ingredient: i));
                      } else {
                        await showDialog<void>(
                          context: context,
                          builder: (_) => a == 'receive' ? AddStockDialog(ingredient: i) : _AdjustDialog(ingredient: i, reason: a),
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'receive', child: Text('إضافة كمية (وصل جديد)')),
                      const PopupMenuItem(value: 'count', child: Text('جرد (الكمية الفعلية)')),
                      const PopupMenuItem(value: 'waste', child: Text('هالك / اتكب')),
                      if (owner) const PopupMenuItem(value: 'adjust', child: Text('تعديل بالزيادة أو النقص')),
                      if (owner) const PopupMenuItem(value: 'edit', child: Text('تعديل الخامة')),
                    ],
                  ),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}

class _IngredientDialog extends ConsumerStatefulWidget {
  const _IngredientDialog({this.ingredient});
  final Ingredient? ingredient;

  @override
  ConsumerState<_IngredientDialog> createState() => _IngredientDialogState();
}

class _IngredientDialogState extends ConsumerState<_IngredientDialog> {
  late final _name = TextEditingController(text: widget.ingredient?.name);
  late String _unit = widget.ingredient?.unit ?? 'g';
  final _qty = TextEditingController();
  // التكلفة بتتكتب كسعر عبوة: "الكيلو بـ 800 جنيه" أسهل من سعر الجرام
  final _packQty = TextEditingController();
  final _packPrice = TextEditingController();
  late final _low = TextEditingController(text: widget.ingredient == null || widget.ingredient!.lowStock == 0 ? '' : fmtQty(widget.ingredient!.lowStock));
  late bool _autoHide = widget.ingredient?.autoHide ?? true;
  late bool _active = widget.ingredient?.active ?? true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _qty, _packQty, _packPrice, _low]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _d(TextEditingController c) => double.tryParse(latinDigits(c.text.trim()));

  Future<void> _save() async {
    try {
      final packQty = _d(_packQty), packPrice = parseMoney(_packPrice.text);
      final body = {
        'name': _name.text,
        'unit': _unit,
        if (widget.ingredient == null && _d(_qty) != null) 'qty': _d(_qty),
        if (packQty != null && packQty > 0 && packPrice != null && _packPrice.text.isNotEmpty) 'unitCost': packPrice / packQty,
        'lowStock': _d(_low) ?? 0,
        'autoHide': _autoHide,
        'active': _active,
      };
      final api = ref.read(sessionProvider).value!.api!;
      widget.ingredient == null ? await api.post('/api/ingredients', body) : await api.patch('/api/ingredients/${widget.ingredient!.id}', body);
      ref.invalidate(ingredientsProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final unit = unitLabels[_unit]!;
    final big = _unit == 'pcs' ? 'العبوة' : _unit == 'g' ? 'الكيلو = 1000' : 'اللتر = 1000';
    return AlertDialog(
      title: Text(widget.ingredient == null ? 'خامة جديدة' : 'تعديل ${widget.ingredient!.name}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'الاسم (مثلاً: بن إسبريسو)')),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: [for (final e in unitLabels.entries) ButtonSegment(value: e.key, label: Text(e.value))],
              selected: {_unit},
              onSelectionChanged: (s) => setState(() => _unit = s.first),
            ),
            if (widget.ingredient == null) ...[
              const SizedBox(height: 10),
              TextField(controller: _qty, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'الكمية الموجودة دلوقتي', suffixText: unit)),
            ],
            const SizedBox(height: 12),
            Text('التكلفة${widget.ingredient != null ? ' (سيبها فاضية لو مش هتغيرها)' : ''}: ($big $unit)', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: TextField(controller: _packQty, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'كمية', suffixText: unit, hintText: _unit == 'pcs' ? '50' : '1000'))),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('بـ')),
              Expanded(child: MoneyField(controller: _packPrice, label: 'السعر')),
            ]),
            const SizedBox(height: 10),
            TextField(controller: _low, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'نبهني لما يقل عن', suffixText: unit)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('لما تخلص، الأصناف اللي عليها تبقى "خلصان"'),
              value: _autoHide,
              onChanged: (v) => setState(() => _autoHide = v),
            ),
            if (widget.ingredient != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('الخامة شغالة'), value: _active, onChanged: (v) => setState(() => _active = v)),
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

class _AdjustDialog extends ConsumerStatefulWidget {
  const _AdjustDialog({required this.ingredient, required this.reason});
  final Ingredient ingredient;
  final String reason;

  @override
  ConsumerState<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends ConsumerState<_AdjustDialog> {
  final _qty = TextEditingController();
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.ingredient;
    final title = switch (widget.reason) { 'count' => 'جرد ${i.name}', 'waste' => 'هالك ${i.name}', _ => 'تعديل ${i.name}' };
    final label = switch (widget.reason) { 'count' => 'الكمية الفعلية دلوقتي', 'waste' => 'الكمية اللي باظت', _ => 'زيادة (+) أو نقص (-)' };
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('الموجود على السيستم: ${fmtQty(i.qty)} ${i.unitLabel}'),
          const SizedBox(height: 10),
          TextField(controller: _qty, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: InputDecoration(labelText: label, suffixText: i.unitLabel)),
          const SizedBox(height: 10),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة')),
          if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () async {
            final q = double.tryParse(latinDigits(_qty.text.trim()));
            if (q == null) return setState(() => _error = 'اكتب رقم');
            try {
              await ref.read(sessionProvider).value!.api!.post('/api/ingredients/${i.id}/adjust', {'reason': widget.reason, 'qty': q, 'note': _note.text});
              ref.invalidate(ingredientsProvider);
              if (context.mounted) Navigator.pop(context);
            } catch (e) {
              setState(() => _error = errorText(e));
            }
          },
          child: const Text('تسجيل'),
        ),
      ],
    );
  }
}

/// إضافة كمية وصلت: بيظهر الموجود، وتكتب الجديد، والإجمالي بيتحسب قدامك، ولما تحفظ بيتجمعوا.
class AddStockDialog extends ConsumerStatefulWidget {
  const AddStockDialog({super.key, required this.ingredient});
  final Ingredient ingredient;

  @override
  ConsumerState<AddStockDialog> createState() => _AddStockDialogState();
}

class _AddStockDialogState extends ConsumerState<AddStockDialog> {
  final _qty = TextEditingController();
  final _cost = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    super.dispose();
  }

  double? get _added {
    final v = double.tryParse(latinDigits(_qty.text.trim()).replaceAll(',', '.'));
    return v == null || v <= 0 ? null : v;
  }

  Future<void> _save() async {
    final added = _added;
    if (added == null) return setState(() => _error = 'اكتب الكمية اللي وصلت');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cost = parseMoney(_cost.text);
      final res = await ref.read(sessionProvider).value!.api!.post('/api/ingredients/${widget.ingredient.id}/adjust', {
        'reason': 'receive',
        'qty': added,
        if (cost != null && cost > 0) 'costCents': cost,
      });
      ref.invalidate(ingredientsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      showMessage(context, '${widget.ingredient.name}: بقى ${fmtQty((res['qty'] as num).toDouble())} ${widget.ingredient.unitLabel}');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.ingredient;
    final added = _added;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget box(String label, String value, {Color? color}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(color: (color ?? scheme.primary).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              Text(label, style: text.bodySmall),
              Text(value, style: text.titleLarge?.bold.copyWith(color: color ?? scheme.primary), textAlign: TextAlign.center),
            ]),
          ),
        );
    return AlertDialog(
      title: Text('إضافة كمية: ${i.name}'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            box('كان عندك', fmtQty(i.qty), color: scheme.outline),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.add_rounded)),
            box('وصل', added == null ? '—' : fmtQty(added), color: brandAccent),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('=', style: TextStyle(fontSize: 22))),
            box('هيبقى', fmtQty(i.qty + (added ?? 0))),
          ]),
          const SizedBox(height: 4),
          Text('بالـ${i.unitLabel}', style: text.bodySmall, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          TextField(
            controller: _qty,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(labelText: 'الكمية الجديدة اللي وصلت', suffixText: i.unitLabel),
          ),
          const SizedBox(height: 10),
          MoneyField(controller: _cost, label: 'دفعت فيها كام؟ (اختياري، عشان التكلفة تتحدث)'),
          if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('إلغاء')),
        SizedBox(width: 120, child: BusyButton(label: 'حفظ', busy: _busy, onPressed: _save)),
      ],
    );
  }
}

// ---------------------------------------------------------------- المشتريات

final _purchasesProvider = FutureProvider.autoDispose<List<Json>>((ref) async {
  refreshOn(ref, 'stock');
  return ((await apiOf(ref).get('/api/purchases'))['purchases'] as List).cast<Json>();
});

final _suppliersProvider = FutureProvider.autoDispose<List<Json>>((ref) async {
  refreshOn(ref, 'stock');
  return ((await apiOf(ref).get('/api/suppliers'))['suppliers'] as List).cast<Json>();
});

class _PurchasesTab extends ConsumerWidget {
  const _PurchasesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody(
        value: ref.watch(_purchasesProvider),
        builder: (list) => ListView(padding: const EdgeInsets.all(16), children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const _NewPurchaseScreen())),
              icon: const Icon(Icons.add_shopping_cart_rounded),
              label: const Text('فاتورة شرا جديدة'),
            ),
          ),
          const SizedBox(height: 8),
          if (list.isEmpty) const EmptyState(icon: Icons.receipt_outlined, text: 'لما تشتري خامات سجلها هنا: المخزون بيزيد وتكلفة الخامة بتتحدث لوحدها'),
          for (final p in list)
            Card(
              child: ExpansionTile(
                title: Text('#${p['number']} • ${p['supplierName'] ?? 'من غير مورد'} • ${money(p['totalCents'] as int)}'),
                subtitle: Text('${formatDateTime(parseDate(p['createdAt'])!)}${(p['paidCents'] as int) < (p['totalCents'] as int) ? ' • باقي ${money((p['totalCents'] as int) - (p['paidCents'] as int))}' : ''}'),
                children: [
                  for (final i in (p['items'] as List).cast<Json>())
                    ListTile(dense: true, title: Text(i['name'] as String), subtitle: Text('${fmtQty((i['qty'] as num).toDouble())} ${unitLabels[i['unit']]}'), trailing: Text(money(i['totalCents'] as int))),
                ],
              ),
            ),
        ]),
      );
}

class _NewPurchaseScreen extends ConsumerStatefulWidget {
  const _NewPurchaseScreen();

  @override
  ConsumerState<_NewPurchaseScreen> createState() => _NewPurchaseScreenState();
}

class _NewPurchaseScreenState extends ConsumerState<_NewPurchaseScreen> {
  final _lines = <({Ingredient ing, TextEditingController qty, TextEditingController total})>[];
  String? _supplier;
  final _paid = TextEditingController();
  bool _fromDrawer = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final l in _lines) {
      l.qty.dispose();
      l.total.dispose();
    }
    _paid.dispose();
    super.dispose();
  }

  int get _total => _lines.fold(0, (s, l) => s + (parseMoney(l.total.text) ?? 0));

  @override
  Widget build(BuildContext context) {
    final ings = ref.watch(ingredientsProvider).value?.list.where((i) => i.active).toList() ?? const [];
    final suppliers = ref.watch(_suppliersProvider).value ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('فاتورة شرا خامات')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String?>(
          initialValue: _supplier,
          decoration: const InputDecoration(labelText: 'المورد'),
          items: [
            const DropdownMenuItem(value: null, child: Text('من غير مورد')),
            for (final s in suppliers.where((s) => s['active'] == true)) DropdownMenuItem(value: s['id'] as String, child: Text(s['name'] as String)),
          ],
          onChanged: (v) => setState(() => _supplier = v),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < _lines.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(flex: 3, child: Text(_lines[i].ing.name, style: const TextStyle().semiBold)),
              Expanded(flex: 2, child: TextField(controller: _lines[i].qty, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'الكمية', suffixText: _lines[i].ing.unitLabel, isDense: true))),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: TextField(controller: _lines[i].total, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'السعر كله', suffixText: 'ج.م', isDense: true))),
              IconButton(onPressed: () => setState(() => _lines.removeAt(i)), icon: const Icon(Icons.close_rounded)),
            ]),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: PopupMenuButton<Ingredient>(
            onSelected: (ing) => setState(() => _lines.add((ing: ing, qty: TextEditingController(), total: TextEditingController()))),
            itemBuilder: (_) => [for (final i in ings.where((i) => !_lines.any((l) => l.ing.id == i.id))) PopupMenuItem(value: i, child: Text(i.name))],
            child: const Padding(padding: EdgeInsets.all(8), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add_rounded), SizedBox(width: 4), Text('ضيف خامة')])),
          ),
        ),
        const Divider(height: 24),
        Text('الإجمالي: ${money(_total)}', style: Theme.of(context).textTheme.titleMedium?.bold),
        const SizedBox(height: 10),
        MoneyField(controller: _paid, label: 'دفعت كام؟ (فاضي = كله)'),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('المبلغ ده طالع من الدرج'), value: _fromDrawer, onChanged: (v) => setState(() => _fromDrawer = v)),
        if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 10)],
        BusyButton(
          label: 'حفظ الفاتورة',
          busy: _busy,
          onPressed: _lines.isEmpty
              ? null
              : () async {
                  setState(() {
                    _busy = true;
                    _error = null;
                  });
                  try {
                    await ref.read(sessionProvider).value!.api!.post('/api/purchases', {
                      'supplierId': _supplier,
                      'lines': [
                        for (final l in _lines) {'ingredientId': l.ing.id, 'qty': double.tryParse(latinDigits(l.qty.text.trim())) ?? 0, 'totalCents': parseMoney(l.total.text) ?? 0},
                      ],
                      'paidCents': _paid.text.trim().isEmpty ? _total : parseMoney(_paid.text) ?? 0,
                      'fromDrawer': _fromDrawer,
                    });
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    setState(() => _error = errorText(e));
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
        ),
      ]),
    );
  }
}

class _SuppliersTab extends ConsumerWidget {
  const _SuppliersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> edit(Json? s) async {
      final name = await askText(context, s == null ? 'مورد جديد' : 'تعديل المورد', label: 'الاسم', initial: s?['name'] as String?);
      if (name == null || !context.mounted) return;
      final phone = await askText(context, 'التليفون', initial: s?['phone'] as String?, required: false, keyboard: TextInputType.phone);
      try {
        final api = ref.read(sessionProvider).value!.api!;
        final body = {'name': name, 'phone': phone ?? ''};
        s == null ? await api.post('/api/suppliers', body) : await api.patch('/api/suppliers/${s['id']}', body);
        ref.invalidate(_suppliersProvider);
      } catch (e) {
        if (context.mounted) showMessage(context, errorText(e), error: true);
      }
    }

    return AsyncBody(
      value: ref.watch(_suppliersProvider),
      builder: (list) => ListView(padding: const EdgeInsets.all(16), children: [
        Align(alignment: AlignmentDirectional.centerStart, child: FilledButton.icon(onPressed: () => edit(null), icon: const Icon(Icons.add_rounded), label: const Text('مورد جديد'))),
        const SizedBox(height: 8),
        for (final s in list)
          Card(
            child: ListTile(
              title: Text(s['name'] as String),
              subtitle: Text([if (s['phone'] != null) s['phone'], if ((s['dueCents'] as int) > 0) 'ليه عندك ${money(s['dueCents'] as int)}'].join(' • ')),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if ((s['dueCents'] as int) > 0)
                  TextButton(
                    onPressed: () async {
                      final a = await askText(context, 'دفع لـ ${s['name']}', label: 'المبلغ', initial: moneyInput(s['dueCents'] as int), keyboard: TextInputType.number);
                      final cents = a == null ? null : parseMoney(a);
                      if (cents == null || cents <= 0) return;
                      try {
                        await ref.read(sessionProvider).value!.api!.post('/api/suppliers/${s['id']}/payments', {'amountCents': cents, 'fromDrawer': true});
                        ref.invalidate(_suppliersProvider);
                      } catch (e) {
                        if (context.mounted) showMessage(context, errorText(e), error: true);
                      }
                    },
                    child: const Text('دفع'),
                  ),
                IconButton(onPressed: () => edit(s), icon: const Icon(Icons.edit_outlined)),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _OptionRecipesTab extends ConsumerWidget {
  const _OptionRecipesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody(
        value: ref.watch(menuAllProvider),
        builder: (menu) => ListView(padding: const EdgeInsets.all(16), children: [
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text('الإضافات اللي بتستهلك خامات'),
              subtitle: Text('مثلاً "شوت إسبريسو زيادة" بياخد 9 جرام بن، و"حجم كبير" بياخد 100 مل لبن زيادة.'),
            ),
          ),
          for (final g in menu.groups.where((g) => g.active))
            Card(
              child: ExpansionTile(
                title: Text(g.name),
                children: [
                  for (final o in g.options.where((o) => o.active))
                    ExpansionTile(
                      title: Text(o.name),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [RecipeEditor(kind: 'option', id: o.id)],
                    ),
                ],
              ),
            ),
        ]),
      );
}
