import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../widgets/common.dart' show EmptyState, ErrorBanner, showMessage;
import 'owner_app.dart' show ownerCloudProvider, ownerError;
import 'owner_cloud.dart';

/// التحكم من بعيد (routes_remote.dart في السيرفر): الأمر بيتكتب على Firebase، وكمبيوتر الفرع بينفّذه ويرد.
/// لازم الكمبيوتر يكون شغال وعليه نت، والتحكم من بعيد مفتوح عليه.
Future<Object?> sendRemote(WidgetRef ref, String shop, String op, [Map<String, Object?> args = const {}]) async {
  final cloud = ref.read(ownerCloudProvider) ?? (throw OwnerCloudException('سجّل دخول الأول'));
  final r = Random.secure();
  final id = '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${List.generate(8, (_) => 'abcdefghijkmnopqrstuvwxyz23456789'[r.nextInt(33)]).join()}';
  try {
    await cloud.put('cmd/$shop/$id', {'op': op, 'a': jsonEncode(args), 'at': {'.sv': 'timestamp'}, 'by': cloud.link.ownerUid});
  } on OwnerCloudException {
    throw OwnerCloudException('مش مسموح. يمكن الفرع ده مش تبعك، أو الربط اتشال');
  }
  final until = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    Object? reply;
    try {
      reply = await cloud.get('cmdr/$shop/$id');
    } on OwnerCloudException {
      reply = null; // لسه الرد ماتكتبش (القواعد بترفض القراية لحد ما يتكتب باسمك)
    }
    if (reply is Map) {
      final r = jsonDecode('${reply['r']}');
      if (reply['ok'] != true) throw OwnerCloudException('$r');
      return r;
    }
  }
  throw OwnerCloudException('كمبيوتر الفرع ماردّش. اتأكد إنه شغال وعليه نت، وإن "التحكم من بعيد" مفتوح عليه (الإعدادات › المالك من بره)');
}

/// قايمة التحكم من بعيد لفرع.
class RemoteMenuButton extends StatelessWidget {
  const RemoteMenuButton({super.key, required this.shop, required this.title});
  final String shop;
  final String title;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'تحكم من بعيد',
        icon: const Icon(Icons.settings_remote_rounded),
        onSelected: (v) => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => switch (v) {
              'menu' => _RemoteMenuScreen(shop: shop, title: title),
              'checks' => _OpenChecksScreen(shop: shop, title: title),
              _ => _LogScreen(shop: shop, title: title),
            },
          ),
        ),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'menu', child: ListTile(leading: Icon(Icons.restaurant_menu_rounded), title: Text('المنيو والأسعار'))),
          PopupMenuItem(value: 'checks', child: ListTile(leading: Icon(Icons.receipt_long_rounded), title: Text('الحسابات المفتوحة'))),
          PopupMenuItem(value: 'log', child: ListTile(leading: Icon(Icons.history_rounded), title: Text('آخر العمليات'))),
        ],
      );
}

/// شاشة بتجيب حاجة من الكمبيوتر بأمر، وبتعرضها (والسحب لتحت بيعيدها).
abstract class _RemoteListState<W extends ConsumerStatefulWidget> extends ConsumerState<W> {
  String get shop;
  String get op;
  Object? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await sendRemote(ref, shop, op);
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = ownerError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget body(BuildContext context, Map<String, dynamic> data);

  Widget content(BuildContext context) {
    if (_loading && _data == null) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('بيكلّم كمبيوتر الفرع...')]));
    }
    if (_error != null && _data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [ErrorBanner(_error!), const SizedBox(height: 12), OutlinedButton(onPressed: load, child: const Text('جرّب تاني'))]),
        ),
      );
    }
    return RefreshIndicator(onRefresh: load, child: body(context, (_data as Map).cast<String, dynamic>()));
  }
}

class _RemoteMenuScreen extends ConsumerStatefulWidget {
  const _RemoteMenuScreen({required this.shop, required this.title});
  final String shop;
  final String title;

  @override
  ConsumerState<_RemoteMenuScreen> createState() => _RemoteMenuScreenState();
}

class _RemoteMenuScreenState extends _RemoteListState<_RemoteMenuScreen> {
  @override
  String get shop => widget.shop;
  @override
  String get op => 'menu.get';
  String? _busyItem;

  Future<void> _change(String id, String op, Map<String, Object?> args, String done) async {
    setState(() => _busyItem = id);
    try {
      await sendRemote(ref, shop, op, {'id': id, ...args});
      if (mounted) showMessage(context, done);
      await load();
    } catch (e) {
      if (mounted) showMessage(context, ownerError(e), error: true);
    } finally {
      if (mounted) setState(() => _busyItem = null);
    }
  }

  Future<void> _editPrice(Map item) async {
    final c = TextEditingController(text: moneyInput(item['p'] as int));
    final cents = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('سعر ${item['n']}'),
        content: TextField(controller: c, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(suffixText: 'ج.م')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, parseMoney(c.text)), child: const Text('حفظ')),
        ],
      ),
    );
    if (cents == null || cents == item['p']) return;
    await _change(item['id'] as String, 'item.price', {'p': cents}, 'السعر اتغير على الفرع');
  }

  @override
  Widget body(BuildContext context, Map<String, dynamic> data) {
    final items = (data['items'] as List? ?? const []).cast<Map>();
    if (items.isEmpty) return const EmptyState(icon: Icons.restaurant_menu_rounded, text: 'المنيو فاضي');
    String? lastCat;
    return ListView(children: [
      for (final i in items) ...[
        if (i['c'] != lastCat) Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 4), child: Text('${lastCat = i['c'] as String?}', style: Theme.of(context).textTheme.titleSmall)),
        ListTile(
          title: Text('${i['n']}'),
          subtitle: Text(i['av'] == true ? 'متاح' : 'خلص'),
          leading: _busyItem == i['id']
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : Switch(
                  value: i['av'] == true,
                  onChanged: (v) => _change(i['id'] as String, 'item.available', {'av': v}, v ? 'الصنف رجع متاح' : 'الصنف اتقفل (خلص)'),
                ),
          trailing: TextButton(onPressed: _busyItem == null ? () => _editPrice(i) : null, child: Text(money(i['p'] as int))),
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text('المنيو • ${widget.title}')), body: content(context));
}

class _OpenChecksScreen extends ConsumerStatefulWidget {
  const _OpenChecksScreen({required this.shop, required this.title});
  final String shop;
  final String title;

  @override
  ConsumerState<_OpenChecksScreen> createState() => _OpenChecksScreenState();
}

class _OpenChecksScreenState extends _RemoteListState<_OpenChecksScreen> {
  @override
  String get shop => widget.shop;
  @override
  String get op => 'checks.open';

  @override
  Widget body(BuildContext context, Map<String, dynamic> data) {
    final checks = (data['checks'] as List? ?? const []).cast<Map>();
    if (checks.isEmpty) return const EmptyState(icon: Icons.receipt_long_rounded, text: 'مفيش حسابات مفتوحة دلوقتي');
    final total = checks.fold<int>(0, (s, c) => s + (c['t'] as int? ?? 0));
    return ListView(children: [
      Padding(padding: const EdgeInsets.all(16), child: Text('${checks.length} حساب مفتوح • ${money(total)}', style: Theme.of(context).textTheme.titleMedium)),
      for (final c in checks)
        ListTile(
          leading: CircleAvatar(child: Text('${c['n']}')),
          title: Text(c['table'] != null ? 'ترابيزة ${c['table']}' : (c['name'] ?? (c['type'] == 'delivery' ? 'ديليفري' : 'تيك أواي')).toString()),
          subtitle: Text([
            if (c['at'] is String) 'من ${formatTime(DateTime.parse(c['at'] as String).toLocal())}',
            if (c['w'] != null) '${c['w']}',
            if ((c['paid'] ?? 0) != 0) 'اتدفع ${money(c['paid'] as int)}',
          ].join(' • ')),
          trailing: Text(money(c['t'] as int? ?? 0), style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text('المفتوح • ${widget.title}')), body: content(context));
}

class _LogScreen extends ConsumerStatefulWidget {
  const _LogScreen({required this.shop, required this.title});
  final String shop;
  final String title;

  @override
  ConsumerState<_LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends _RemoteListState<_LogScreen> {
  @override
  String get shop => widget.shop;
  @override
  String get op => 'audit.recent';

  @override
  Widget body(BuildContext context, Map<String, dynamic> data) {
    final log = (data['log'] as List? ?? const []).cast<Map>();
    if (log.isEmpty) return const EmptyState(icon: Icons.history_rounded, text: 'السجل فاضي');
    return ListView(children: [
      for (final l in log)
        ListTile(
          dense: true,
          title: Text('${l['d'] ?? l['a']}'),
          subtitle: Text([
            if (l['at'] is String) formatDateTime(DateTime.parse(l['at'] as String).toLocal()),
            '${l['who'] ?? (('${l['a']}').endsWith('.remote') ? 'أبلكيشن المالك' : 'البرنامج')}',
          ].join(' • ')),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text('السجل • ${widget.title}')), body: content(context));
}
