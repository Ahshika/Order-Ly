import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

class CategoryDialog extends ConsumerStatefulWidget {
  const CategoryDialog({super.key, required this.menu, this.category});
  final MenuData menu;
  final Category? category;

  @override
  ConsumerState<CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends ConsumerState<CategoryDialog> {
  late final _name = TextEditingController(text: widget.category?.name);
  late final _nameEn = TextEditingController(text: widget.category?.nameEn);
  late String? _station = widget.category?.stationId ?? widget.menu.stations.firstOrNull?.id;
  late bool _timed = widget.category?.hours != null;
  late final _from = TextEditingController(text: widget.category?.hours?.split('-').first ?? '08:00');
  late final _to = TextEditingController(text: widget.category?.hours?.split('-').last ?? '12:00');
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _nameEn, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(sessionProvider).value!.api!;
      final body = {
        'name': _name.text,
        'nameEn': _nameEn.text,
        'stationId': _station,
        'hours': _timed ? '${latinDigits(_from.text.trim())}-${latinDigits(_to.text.trim())}' : null,
      };
      widget.category == null ? await api.post('/api/categories', body) : await api.patch('/api/categories/${widget.category!.id}', body);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.category == null ? 'قسم جديد' : 'تعديل القسم'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم القسم (عربي)')),
            const SizedBox(height: 10),
            TextField(controller: _nameEn, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'Name in English (اختياري)')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              initialValue: _station,
              decoration: const InputDecoration(labelText: 'بيتحضر فين؟'),
              items: [
                const DropdownMenuItem(value: null, child: Text('مش محتاج تحضير (من غير تيكت)')),
                for (final s in widget.menu.stations.where((s) => s.active)) DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _station = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('بيظهر للعميل في مواعيد معينة بس'),
              subtitle: const Text('مثلاً منيو الفطار للصبح بس'),
              value: _timed,
              onChanged: (v) => setState(() => _timed = v),
            ),
            if (_timed)
              Row(children: [
                Expanded(child: TextField(controller: _from, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'من (08:00)'))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _to, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'لحد (12:00)'))),
              ]),
            if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          SizedBox(width: 110, child: BusyButton(label: 'حفظ', busy: _busy, onPressed: _save)),
        ],
      );
}

class _OptionRow {
  _OptionRow({this.id, String name = '', String nameEn = '', int price = 0, this.isDefault = false})
      : name = TextEditingController(text: name),
        nameEn = TextEditingController(text: nameEn),
        price = TextEditingController(text: price == 0 ? '' : moneyInput(price));
  final String? id;
  final TextEditingController name;
  final TextEditingController nameEn;
  final TextEditingController price;
  bool isDefault;

  void dispose() {
    name.dispose();
    nameEn.dispose();
    price.dispose();
  }
}

class GroupDialog extends ConsumerStatefulWidget {
  const GroupDialog({super.key, this.group});
  final ModGroup? group;

  @override
  ConsumerState<GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends ConsumerState<GroupDialog> {
  late final _name = TextEditingController(text: widget.group?.name);
  late final _nameEn = TextEditingController(text: widget.group?.nameEn);
  late int _min = widget.group?.minSelect ?? 0;
  late int _max = widget.group?.maxSelect ?? 1;
  late bool _active = widget.group?.active ?? true;
  late final _options = widget.group == null
      ? [_OptionRow(), _OptionRow()]
      : widget.group!.options.where((o) => o.active).map((o) => _OptionRow(id: o.id, name: o.name, nameEn: o.nameEn ?? '', price: o.priceCents, isDefault: o.isDefault)).toList();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _nameEn.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = {
        'name': _name.text,
        'nameEn': _nameEn.text,
        'minSelect': _min,
        'maxSelect': _max,
        'active': _active,
        'options': [
          for (final o in _options)
            if (o.name.text.trim().isNotEmpty) {'id': o.id, 'name': o.name.text, 'nameEn': o.nameEn.text, 'priceCents': parseMoney(o.price.text) ?? 0, 'isDefault': o.isDefault},
        ],
      };
      final api = ref.read(sessionProvider).value!.api!;
      widget.group == null ? await api.post('/api/modifier-groups', body) : await api.patch('/api/modifier-groups/${widget.group!.id}', body);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.group == null ? 'مجموعة إضافات جديدة' : 'تعديل ${widget.group!.name}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'الاسم (مثلاً: الحجم)'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _nameEn, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'English (Size)'))),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                ChoiceChip(label: const Text('إجباري يختار واحد'), selected: _min == 1 && _max == 1, onSelected: (_) => setState(() {
                    _min = 1;
                    _max = 1;
                  })),
                ChoiceChip(label: const Text('اختياري واحد'), selected: _min == 0 && _max == 1, onSelected: (_) => setState(() {
                    _min = 0;
                    _max = 1;
                  })),
                ChoiceChip(label: const Text('اختياري أكتر من واحد'), selected: _min == 0 && _max > 1, onSelected: (_) => setState(() {
                    _min = 0;
                    _max = 5;
                  })),
              ]),
              if (_max > 1)
                Row(children: [
                  const Text('أكتر عدد: '),
                  IconButton(onPressed: _max > 2 ? () => setState(() => _max--) : null, icon: const Icon(Icons.remove_rounded)),
                  Text('$_max'),
                  IconButton(onPressed: () => setState(() => _max++), icon: const Icon(Icons.add_rounded)),
                ]),
              const SizedBox(height: 8),
              Text('الاختيارات', style: Theme.of(context).textTheme.titleSmall?.bold),
              for (var i = 0; i < _options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Expanded(flex: 3, child: TextField(controller: _options[i].name, decoration: const InputDecoration(labelText: 'الاختيار', isDense: true))),
                    const SizedBox(width: 6),
                    Expanded(flex: 3, child: TextField(controller: _options[i].nameEn, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'English', isDense: true))),
                    const SizedBox(width: 6),
                    Expanded(flex: 2, child: TextField(controller: _options[i].price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '+ سعر', isDense: true))),
                    Tooltip(
                      message: 'متختار لوحده',
                      child: Checkbox(value: _options[i].isDefault, onChanged: (v) => setState(() => _options[i].isDefault = v ?? false)),
                    ),
                    IconButton(onPressed: _options.length > 1 ? () => setState(() => _options.removeAt(i).dispose()) : null, icon: const Icon(Icons.close_rounded)),
                  ]),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(onPressed: () => setState(() => _options.add(_OptionRow())), icon: const Icon(Icons.add_rounded), label: const Text('اختيار كمان')),
              ),
              if (widget.group != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('المجموعة شغالة'), value: _active, onChanged: (v) => setState(() => _active = v)),
              if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          SizedBox(width: 110, child: BusyButton(label: 'حفظ', busy: _busy, onPressed: _save)),
        ],
      );
}

// ---------------------------------------------------------------- العروض (هابي أور)

final _promotionsProvider = FutureProvider.autoDispose<Json>((ref) async {
  refreshOn(ref, 'menu');
  return apiOf(ref).get('/api/promotions');
});

const _days = ['الأحد', 'الاتنين', 'التلات', 'الأربع', 'الخميس', 'الجمعة', 'السبت'];

class PromotionsTab extends ConsumerWidget {
  const PromotionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menu = ref.watch(menuAllProvider).value;
    return AsyncBody(
      value: ref.watch(_promotionsProvider),
      builder: (data) {
        final promos = (data['promotions'] as List).cast<Json>();
        final activeNow = (data['activeNow'] as List).cast<String>();
        return ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
            child: const ListTile(
              leading: Icon(Icons.local_offer_outlined),
              title: Text('عروض بالمواعيد (هابي أور)'),
              subtitle: Text('خصم نسبة على أقسام أو أصناف في أيام وساعات معينة. السعر بيتغير لوحده في الكاشير ومنيو العميل.'),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: menu == null ? null : () => showDialog<void>(context: context, builder: (_) => _PromoDialog(menu: menu)),
              icon: const Icon(Icons.add_rounded),
              label: const Text('عرض جديد'),
            ),
          ),
          const SizedBox(height: 8),
          for (final p in promos)
            Card(
              child: ListTile(
                leading: Icon(Icons.local_offer_rounded, color: activeNow.contains(p['id']) ? const Color(0xFF16A34A) : null),
                title: Text('${p['name']} • ${percent(p['percentBp'] as int)} خصم', style: TextStyle(decoration: p['active'] == true ? null : TextDecoration.lineThrough)),
                subtitle: Text([
                  '${p['timeFrom']} - ${p['timeTo']}',
                  (p['days'] as List).length == 7 ? 'كل يوم' : (p['days'] as List).map((d) => _days[d as int]).join('، '),
                  if (activeNow.contains(p['id'])) 'شغال دلوقتي',
                ].join(' • ')),
                onTap: menu == null ? null : () => showDialog<void>(context: context, builder: (_) => _PromoDialog(menu: menu, promo: p)),
              ),
            ),
        ]);
      },
    );
  }
}

class _PromoDialog extends ConsumerStatefulWidget {
  const _PromoDialog({required this.menu, this.promo});
  final MenuData menu;
  final Json? promo;

  @override
  ConsumerState<_PromoDialog> createState() => _PromoDialogState();
}

class _PromoDialogState extends ConsumerState<_PromoDialog> {
  late final _name = TextEditingController(text: widget.promo?['name'] as String? ?? 'هابي أور');
  late final _percent = TextEditingController(text: widget.promo == null ? '20' : '${(widget.promo!['percentBp'] as int) / 100}'.replaceAll('.0', ''));
  late final _from = TextEditingController(text: widget.promo?['timeFrom'] as String? ?? '15:00');
  late final _to = TextEditingController(text: widget.promo?['timeTo'] as String? ?? '18:00');
  late final Set<int> _dayset = {...((widget.promo?['days'] as List?)?.cast<int>() ?? [0, 1, 2, 3, 4, 5, 6])};
  late final Set<String> _cats = {...((widget.promo?['categoryIds'] as List?)?.cast<String>() ?? const [])};
  late bool _active = widget.promo?['active'] as bool? ?? true;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _percent, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    try {
      final pct = double.tryParse(latinDigits(_percent.text.trim()));
      if (pct == null) throw Exception('النسبة مش صحيحة');
      final body = {
        'name': _name.text,
        'percentBp': (pct * 100).round(),
        'timeFrom': latinDigits(_from.text.trim()),
        'timeTo': latinDigits(_to.text.trim()),
        'days': _dayset.toList(),
        'categoryIds': _cats.toList(),
        'active': _active,
      };
      final api = ref.read(sessionProvider).value!.api!;
      widget.promo == null ? await api.post('/api/promotions', body) : await api.patch('/api/promotions/${widget.promo!['id']}', body);
      ref.invalidate(_promotionsProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = errorText(e).replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.promo == null ? 'عرض جديد' : 'تعديل العرض'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'اسم العرض')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: _percent, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'نسبة الخصم', suffixText: '%'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _from, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'من'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _to, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'لحد'))),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (var d = 0; d < 7; d++)
                  FilterChip(label: Text(_days[d]), selected: _dayset.contains(d), onSelected: (v) => setState(() => v ? _dayset.add(d) : _dayset.remove(d))),
              ]),
              const SizedBox(height: 12),
              Text('على أنهي أقسام؟ (لو مختارتش حاجة يبقى على المنيو كله)', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in widget.menu.categories)
                  FilterChip(label: Text(c.name), selected: _cats.contains(c.id), onSelected: (v) => setState(() => v ? _cats.add(c.id) : _cats.remove(c.id))),
              ]),
              if (widget.promo != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('العرض شغال'), value: _active, onChanged: (v) => setState(() => _active = v)),
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

