import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/server_image.dart';
import 'item_editor.dart';
import 'menu_dialogs.dart';

/// إدارة المنيو (لصاحب الكافيه): الأقسام والأصناف، والإضافات، وأماكن التحضير، والعروض.
class MenuScreen extends ConsumerWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('المنيو'),
            bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
              Tab(text: 'الأقسام والأصناف'),
              Tab(text: 'الإضافات (حجم، سكر...)'),
              Tab(text: 'أماكن التحضير'),
              Tab(text: 'العروض'),
            ]),
          ),
          body: const TabBarView(children: [_ItemsTab(), _GroupsTab(), _StationsTab(), PromotionsTab()]),
        ),
      );
}

class _ItemsTab extends ConsumerStatefulWidget {
  const _ItemsTab();

  @override
  ConsumerState<_ItemsTab> createState() => _ItemsTabState();
}

class _ItemsTabState extends ConsumerState<_ItemsTab> {
  String? _cat;

  Future<void> _api(Future<void> Function() f) async {
    try {
      await f();
      ref.invalidate(menuAllProvider);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    }
  }

  Future<void> _moveCategory(MenuData menu, int i, int dir) async {
    final ids = menu.categories.map((c) => c.id).toList();
    final j = i + dir;
    if (j < 0 || j >= ids.length) return;
    final t = ids[i];
    ids[i] = ids[j];
    ids[j] = t;
    await _api(() => ref.read(sessionProvider).value!.api!.post('/api/menu/sort', {'categories': ids}));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return AsyncBody(
      value: ref.watch(menuAllProvider),
      onRetry: () => ref.invalidate(menuAllProvider),
      builder: (menu) {
        final cats = menu.categories;
        final cat = cats.where((c) => c.id == _cat).firstOrNull ?? cats.firstOrNull;
        final catList = Card(
          child: Column(children: [
            ListTile(
              title: Text('الأقسام', style: Theme.of(context).textTheme.titleMedium?.bold),
              trailing: IconButton.filledTonal(
                tooltip: 'قسم جديد',
                icon: const Icon(Icons.add_rounded),
                onPressed: () async {
                  final saved = await showDialog<bool>(context: context, builder: (_) => CategoryDialog(menu: menu));
                  if (saved == true) ref.invalidate(menuAllProvider);
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: cats.isEmpty
                  ? const EmptyState(icon: Icons.category_outlined, text: 'ابدأ بقسم (مثلاً: مشروبات ساخنة)')
                  : ListView(children: [
                      for (var i = 0; i < cats.length; i++)
                        ListTile(
                          selected: cats[i].id == cat?.id,
                          title: Text(cats[i].name, style: TextStyle(decoration: cats[i].active ? null : TextDecoration.lineThrough)),
                          subtitle: Text('${menu.itemsIn(cats[i].id).where((x) => x.active).length} صنف${menu.station(cats[i].stationId) != null ? ' • ${menu.station(cats[i].stationId)!.name}' : ''}'),
                          onTap: () => setState(() => _cat = cats[i].id),
                          trailing: PopupMenuButton<String>(
                            onSelected: (a) async {
                              if (a == 'edit') {
                                final saved = await showDialog<bool>(context: context, builder: (_) => CategoryDialog(menu: menu, category: cats[i]));
                                if (saved == true) ref.invalidate(menuAllProvider);
                              } else if (a == 'up' || a == 'down') {
                                await _moveCategory(menu, i, a == 'up' ? -1 : 1);
                              } else if (a == 'toggle') {
                                await _api(() => ref.read(sessionProvider).value!.api!.patch('/api/categories/${cats[i].id}', {'active': !cats[i].active}));
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'edit', child: Text('تعديل')),
                              const PopupMenuItem(value: 'up', child: Text('لفوق')),
                              const PopupMenuItem(value: 'down', child: Text('لتحت')),
                              PopupMenuItem(value: 'toggle', child: Text(cats[i].active ? 'إخفاء القسم' : 'إظهار القسم')),
                            ],
                          ),
                        ),
                    ]),
            ),
          ]),
        );
        final items = cat == null ? <MenuItem>[] : menu.itemsIn(cat.id);
        final itemList = Card(
          child: Column(children: [
            ListTile(
              title: Text(cat?.name ?? 'الأصناف', style: Theme.of(context).textTheme.titleMedium?.bold),
              trailing: cat == null
                  ? null
                  : FilledButton.icon(
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('صنف جديد'),
                      onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ItemEditor(menu: menu, categoryId: cat.id))),
                    ),
            ),
            const Divider(height: 1),
            Expanded(
              child: items.isEmpty
                  ? const EmptyState(icon: Icons.local_cafe_outlined, text: 'مفيش أصناف في القسم ده')
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final it = items[i];
                        final cost = it.unitCost;
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: it.imageId != null ? ServerImage(it.imageId!) : Container(color: Theme.of(context).colorScheme.primaryContainer, child: const Icon(Icons.local_cafe_outlined)),
                            ),
                          ),
                          title: Text(it.name, style: TextStyle(decoration: it.active ? null : TextDecoration.lineThrough)),
                          subtitle: Text([
                            money(it.priceCents),
                            if (cost > 0) 'تكلفة ${money(cost)} • ربح ${((it.priceCents - cost) * 100 / (it.priceCents == 0 ? 1 : it.priceCents)).round()}%',
                            if (!it.showInQr) 'مش ظاهر للعميل',
                            if (it.soldOut) 'خامة خلصت',
                          ].join(' • ')),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            Tooltip(
                              message: 'متاح دلوقتي',
                              child: Switch(
                                value: it.available,
                                onChanged: (v) => _api(() => ref.read(sessionProvider).value!.api!.post('/api/items/${it.id}/availability', {'available': v})),
                              ),
                            ),
                            const Icon(Icons.chevron_left_rounded),
                          ]),
                          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ItemEditor(menu: menu, item: it))),
                        );
                      },
                    ),
            ),
          ]),
        );
        if (wide) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 300, child: catList),
              const SizedBox(width: 12),
              Expanded(child: itemList),
            ]),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: [SizedBox(height: 260, child: catList), const SizedBox(height: 8), Expanded(child: itemList)]),
        );
      },
    );
  }
}

class _GroupsTab extends ConsumerWidget {
  const _GroupsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody(
        value: ref.watch(menuAllProvider),
        builder: (menu) => ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
            child: const ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text('مجموعات الإضافات بتتعمل مرة واحدة وتتربط بأي صنف'),
              subtitle: Text('مثلاً: "الحجم" (إجباري: صغير / وسط / كبير +15)، "السكر" (من غير / خفيف / عادي / زيادة)، "إضافات" (شوت إسبريسو +10، لبن شوفان +12)'),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              onPressed: () async {
                if (await showDialog<bool>(context: context, builder: (_) => const GroupDialog()) == true) ref.invalidate(menuAllProvider);
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('مجموعة جديدة'),
            ),
          ),
          const SizedBox(height: 8),
          for (final g in menu.groups)
            Card(
              child: ListTile(
                title: Text(g.name, style: TextStyle(decoration: g.active ? null : TextDecoration.lineThrough).semiBold),
                subtitle: Text('${g.rule} • ${g.options.where((o) => o.active).map((o) => o.priceCents == 0 ? o.name : '${o.name} (${money(o.priceCents)})').join('، ')}'),
                trailing: Text('${menu.items.where((i) => i.groupIds.contains(g.id)).length} صنف'),
                onTap: () async {
                  if (await showDialog<bool>(context: context, builder: (_) => GroupDialog(group: g)) == true) ref.invalidate(menuAllProvider);
                },
              ),
            ),
        ]),
      );
}

class _StationsTab extends ConsumerWidget {
  const _StationsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> save(String? id, Map<String, Object?> body) async {
      try {
        final api = ref.read(sessionProvider).value!.api!;
        id == null ? await api.post('/api/stations', body) : await api.patch('/api/stations/$id', body);
        ref.invalidate(menuAllProvider);
      } catch (e) {
        if (context.mounted) showMessage(context, errorText(e), error: true);
      }
    }

    return AsyncBody(
      value: ref.watch(menuAllProvider),
      builder: (menu) => ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
          child: const ListTile(
            leading: Icon(Icons.info_outline_rounded),
            title: Text('كل قسم في المنيو بيتحضر في مكان (البار، المطبخ، الشيشة...)'),
            subtitle: Text('الطلب بيتقسم لوحده: كل مكان بيطلعله تيكت على طابعته أو شاشته بالأصناف بتاعته بس.'),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            onPressed: () async {
              final name = await askText(context, 'مكان تحضير جديد', label: 'الاسم (مثلاً: الشيشة)');
              if (name != null) await save(null, {'name': name});
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('مكان جديد'),
          ),
        ),
        const SizedBox(height: 8),
        for (final s in menu.stations)
          Card(
            child: ListTile(
              leading: const Icon(Icons.soup_kitchen_outlined),
              title: Text(s.name, style: TextStyle(decoration: s.active ? null : TextDecoration.lineThrough)),
              subtitle: Text('${menu.categories.where((c) => c.stationId == s.id).map((c) => c.name).join('، ')}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    final name = await askText(context, 'تعديل الاسم', initial: s.name);
                    if (name != null) await save(s.id, {'name': name});
                  },
                ),
                Switch(value: s.active, onChanged: (v) => save(s.id, {'active': v})),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// شارة صغيرة للحالة (للاستخدام في شاشات المنيو).
class TinyTag extends StatelessWidget {
  const TinyTag(this.text, {super.key, this.color = brandAccent});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(color: color, fontSize: 11).semiBold),
      );
}
