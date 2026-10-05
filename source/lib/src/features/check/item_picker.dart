import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/server_image.dart';

/// صنف في السلة قبل ما يتبعت.
class DraftLine {
  DraftLine({required this.item, required this.modifiers, this.qty = 1, this.note, this.guest});
  final MenuItem item;
  final List<ModOption> modifiers;
  int qty;
  String? note;
  String? guest;

  int get unitCents => item.effectivePrice + modifiers.fold<int>(0, (s, m) => s + m.priceCents);
  int get totalCents => unitCents * qty;
  String get key => '${item.id}|${modifiers.map((m) => m.id).join(',')}|${note ?? ''}|${guest ?? ''}';

  Map<String, Object?> toJson() => {
        'itemId': item.id,
        'qty': qty,
        'modifierIds': modifiers.map((m) => m.id).toList(),
        'note': ?note,
        'guest': ?guest,
      };
}

/// المنيو للطلب: بحث، وأقسام، وكروت الأصناف.
class MenuPicker extends ConsumerStatefulWidget {
  const MenuPicker({super.key, required this.onAdd});
  final ValueChanged<DraftLine> onAdd;

  @override
  ConsumerState<MenuPicker> createState() => _MenuPickerState();
}

class _MenuPickerState extends ConsumerState<MenuPicker> {
  String? _category;
  String _q = '';

  Future<void> _tap(MenuData menu, MenuItem item) async {
    if (!item.canOrder) {
      showMessage(context, '"${item.name}" خلص', error: true);
      return;
    }
    final groups = item.groupIds.map(menu.group).whereType<ModGroup>().where((g) => g.options.isNotEmpty).toList();
    if (groups.isEmpty) return widget.onAdd(DraftLine(item: item, modifiers: const []));
    final line = await showDialog<DraftLine>(context: context, builder: (_) => ModifierDialog(item: item, groups: groups));
    if (line != null) widget.onAdd(line);
  }

  @override
  Widget build(BuildContext context) {
    return AsyncBody(
      value: ref.watch(menuProvider),
      onRetry: () => ref.invalidate(menuProvider),
      builder: (menu) {
        if (menu.items.isEmpty) return const EmptyState(icon: Icons.restaurant_menu_rounded, text: 'المنيو فاضي. صاحب الكافيه يضيف الأصناف من شاشة "المنيو".');
        final q = _q.trim().toLowerCase();
        final cat = _category ?? (q.isEmpty ? menu.categories.firstOrNull?.id : null);
        final items = menu.items.where((i) {
          if (q.isNotEmpty) return i.name.toLowerCase().contains(q) || (i.nameEn ?? '').toLowerCase().contains(q);
          return i.categoryId == cat;
        }).toList();
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: const InputDecoration(hintText: 'دوّر على صنف...', prefixIcon: Icon(Icons.search_rounded), isDense: true),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          if (q.isEmpty)
            SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), children: [
                for (final c in menu.categories)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ChoiceChip(label: Text(c.name), selected: c.id == cat, onSelected: (_) => setState(() => _category = c.id)),
                  ),
              ]),
            ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 170, mainAxisExtent: 150, crossAxisSpacing: 8, mainAxisSpacing: 8),
              itemCount: items.length,
              itemBuilder: (_, i) => _ItemCard(item: items[i], onTap: () => _tap(menu, items[i])),
            ),
          ),
        ]);
      },
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.onTap});
  final MenuItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: item.canOrder ? 1 : 0.45,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: item.imageId != null
                  ? ServerImage(item.imageId!)
                  : Container(color: scheme.primaryContainer.withValues(alpha: 0.5), child: Icon(Icons.local_cafe_outlined, color: scheme.primary, size: 32)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle().semiBold),
                Row(children: [
                  Text(money(item.effectivePrice), style: TextStyle(color: scheme.primary, fontSize: 13).bold),
                  if (item.promoPriceCents != null) ...[
                    const SizedBox(width: 4),
                    Text(money(item.priceCents), style: TextStyle(color: scheme.outline, fontSize: 11, decoration: TextDecoration.lineThrough)),
                  ],
                  const Spacer(),
                  if (!item.canOrder) Text('خلص', style: TextStyle(color: scheme.error, fontSize: 12).bold),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// اختيار الإضافات (الحجم، السكر، اللبن...) والكمية والملاحظة.
class ModifierDialog extends StatefulWidget {
  const ModifierDialog({super.key, required this.item, required this.groups});
  final MenuItem item;
  final List<ModGroup> groups;

  @override
  State<ModifierDialog> createState() => _ModifierDialogState();
}

class _ModifierDialogState extends State<ModifierDialog> {
  late final Map<String, Set<String>> _picked = {
    for (final g in widget.groups) g.id: g.options.where((o) => o.isDefault).take(g.maxSelect).map((o) => o.id).toSet(),
  };
  int _qty = 1;
  final _note = TextEditingController();
  final _guest = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    _guest.dispose();
    super.dispose();
  }

  List<ModOption> get _mods => [
        for (final g in widget.groups)
          for (final o in g.options)
            if (_picked[g.id]!.contains(o.id)) o,
      ];

  void _toggle(ModGroup g, ModOption o) {
    setState(() {
      final set = _picked[g.id]!;
      if (g.maxSelect == 1) {
        if (set.contains(o.id) && g.minSelect == 0) {
          set.clear();
        } else {
          set
            ..clear()
            ..add(o.id);
        }
      } else if (set.contains(o.id)) {
        set.remove(o.id);
      } else if (set.length < g.maxSelect) {
        set.add(o.id);
      }
      _error = null;
    });
  }

  void _done() {
    for (final g in widget.groups) {
      if (_picked[g.id]!.length < g.minSelect) return setState(() => _error = 'اختار ${g.name}');
    }
    Navigator.pop(
      context,
      DraftLine(
        item: widget.item,
        modifiers: _mods,
        qty: _qty,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        guest: _guest.text.trim().isEmpty ? null : _guest.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.item.effectivePrice + _mods.fold<int>(0, (s, m) => s + m.priceCents);
    return AlertDialog(
      title: Text(widget.item.name),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            for (final g in widget.groups) ...[
              Row(children: [
                Text(g.name, style: Theme.of(context).textTheme.titleSmall?.bold),
                const SizedBox(width: 8),
                Text(g.rule, style: Theme.of(context).textTheme.bodySmall),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final o in g.options)
                  FilterChip(
                    label: Text(o.priceCents == 0 ? o.name : '${o.name} (${o.priceCents > 0 ? '+' : ''}${money(o.priceCents)})'),
                    selected: _picked[g.id]!.contains(o.id),
                    showCheckmark: g.maxSelect > 1,
                    onSelected: (_) => _toggle(g, o),
                  ),
              ]),
              const SizedBox(height: 14),
            ],
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة للبار (اختياري)', isDense: true)),
            const SizedBox(height: 10),
            TextField(controller: _guest, decoration: const InputDecoration(labelText: 'لمين؟ (عشان تقسيم الحساب - اختياري)', isDense: true)),
            const SizedBox(height: 12),
            Row(children: [
              IconButton.filledTonal(onPressed: _qty > 1 ? () => setState(() => _qty--) : null, icon: const Icon(Icons.remove_rounded)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Text('$_qty', style: Theme.of(context).textTheme.titleLarge?.bold)),
              IconButton.filledTonal(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add_rounded)),
              const Spacer(),
              Text(money(unit * _qty), style: Theme.of(context).textTheme.titleMedium?.bold),
            ]),
            if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton.icon(onPressed: _done, icon: const Icon(Icons.add_shopping_cart_rounded), label: const Text('ضيف')),
      ],
    );
  }
}
