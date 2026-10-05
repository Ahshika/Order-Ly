import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

const unitLabels = {'g': 'جرام', 'ml': 'مل', 'pcs': 'قطعة'};

class Ingredient {
  Ingredient(Json j)
      : id = j['id'] as String,
        name = j['name'] as String,
        unit = j['unit'] as String,
        qty = (j['qty'] as num).toDouble(),
        unitCost = (j['unitCost'] as num).toDouble(),
        lowStock = (j['lowStock'] as num).toDouble(),
        autoHide = j['autoHide'] as bool? ?? true,
        active = j['active'] as bool? ?? true,
        usedBy = j['usedBy'] as int? ?? 0;
  final String id;
  final String name;
  final String unit;
  final double qty;
  final double unitCost;
  final double lowStock;
  final bool autoHide;
  final bool active;
  final int usedBy;

  bool get low => qty <= lowStock;
  String get unitLabel => unitLabels[unit] ?? unit;
}

String fmtQty(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(v.abs() < 10 ? 2 : 1);

final ingredientsProvider = FutureProvider.autoDispose<({List<Ingredient> list, int valueCents})>((ref) async {
  refreshOn(ref, 'stock');
  final res = await apiOf(ref).get('/api/ingredients');
  return (list: (res['ingredients'] as List).cast<Json>().map(Ingredient.new).toList(), valueCents: res['stockValueCents'] as int? ?? 0);
});

/// تعديل وصفة صنف أو إضافة: سطر لكل خامة بكميتها.
class RecipeEditor extends ConsumerStatefulWidget {
  const RecipeEditor({super.key, required this.kind, required this.id});

  /// 'item' أو 'option'
  final String kind;
  final String id;

  @override
  ConsumerState<RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends ConsumerState<RecipeEditor> {
  List<({String ingredientId, TextEditingController qty})>? _lines;
  bool _busy = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(sessionProvider).value!.api!.get('/api/recipes/${widget.kind}/${widget.id}');
      setState(() => _lines = [
            for (final l in (res['lines'] as List).cast<Json>()) (ingredientId: l['ingredientId'] as String, qty: TextEditingController(text: fmtQty((l['qty'] as num).toDouble()))),
          ]);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    }
  }

  @override
  void dispose() {
    for (final l in _lines ?? const <({String ingredientId, TextEditingController qty})>[]) {
      l.qty.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider).value!.api!.put('/api/recipes/${widget.kind}/${widget.id}', {
        'lines': [
          for (final l in _lines!) {'ingredientId': l.ingredientId, 'qty': double.tryParse(latinDigits(l.qty.text.trim())) ?? 0},
        ],
      });
      ref.invalidate(menuAllProvider);
      setState(() => _dirty = false);
      if (mounted) showMessage(context, 'الوصفة اتحفظت');
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ings = ref.watch(ingredientsProvider).value?.list.where((i) => i.active).toList();
    if (_lines == null || ings == null) return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
    if (ings.isEmpty) return const Text('لسه مفيش خامات. ضيفها من شاشة "المخزون" الأول (بن، لبن، أكواب...).');
    final byId = {for (final i in ings) i.id: i};
    var cost = 0.0;
    for (final l in _lines!) {
      cost += (double.tryParse(latinDigits(l.qty.text)) ?? 0) * (byId[l.ingredientId]?.unitCost ?? 0);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < _lines!.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Expanded(flex: 3, child: Text(byId[_lines![i].ingredientId]?.name ?? '؟', style: const TextStyle().semiBold)),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _lines![i].qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() => _dirty = true),
                decoration: InputDecoration(isDense: true, suffixText: byId[_lines![i].ingredientId]?.unitLabel),
              ),
            ),
            IconButton(
              onPressed: () => setState(() {
                _lines!.removeAt(i).qty.dispose();
                _dirty = true;
              }),
              icon: const Icon(Icons.close_rounded),
            ),
          ]),
        ),
      Row(children: [
        PopupMenuButton<String>(
          tooltip: 'ضيف خامة',
          onSelected: (id) => setState(() {
            _lines!.add((ingredientId: id, qty: TextEditingController()));
            _dirty = true;
          }),
          itemBuilder: (_) => [
            for (final i in ings.where((i) => !_lines!.any((l) => l.ingredientId == i.id))) PopupMenuItem(value: i.id, child: Text('${i.name} (${i.unitLabel})')),
          ],
          child: const Padding(padding: EdgeInsets.all(8), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add_rounded), SizedBox(width: 4), Text('ضيف خامة')])),
        ),
        const Spacer(),
        Text('التكلفة: ${money(cost.round())}', style: const TextStyle().semiBold),
        const SizedBox(width: 12),
        FilledButton.tonal(onPressed: _busy || !_dirty ? null : _save, child: const Text('حفظ الوصفة')),
      ]),
    ]);
  }
}
