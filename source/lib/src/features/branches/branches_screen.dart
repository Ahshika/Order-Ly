import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/business_day.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// بيانات الفروع بتتقرا من النت، فممكن تاخد وقت أطول من باقي الشاشات.
const _branchesTimeout = Duration(seconds: 40);

final branchesProvider = FutureProvider.autoDispose<Json>((ref) async {
  refreshOn(ref, 'branches');
  return apiOf(ref).send('GET', '/api/branches', timeout: _branchesTimeout);
});
/// الفروع: الفرع الرئيسي بيشوف شغل كل الفروع، والفرع التاني بيتربط بيه بكود.
class BranchesScreen extends ConsumerStatefulWidget {
  const BranchesScreen({super.key});

  @override
  ConsumerState<BranchesScreen> createState() => _BranchesScreenState();
}

class _BranchesScreenState extends ConsumerState<BranchesScreen> {
  Timer? _refresh;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // الفروع بتبعت ملخصها كل دقيقة، فمفيش داعي نسأل أكتر من كل نص دقيقة
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) => ref.invalidate(branchesProvider));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _act(String path, [Map<String, Object?>? body, String? done]) async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider).value!.api!.send('POST', path, body: body ?? const {}, timeout: _branchesTimeout);
      ref.invalidate(branchesProvider);
      if (mounted && done != null) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// زرار التحديث: السيرفر بيقرا من النت على طول بدل النسخة اللي حافظها من ثواني.
  Future<void> _refreshNow() async {
    try {
      await ref.read(sessionProvider).value!.api!.send('GET', '/api/branches', query: {'fresh': '1'}, timeout: _branchesTimeout);
    } catch (_) {
      // الخطأ هيظهر في الشاشة نفسها بعد التحميل
    }
    ref.invalidate(branchesProvider);
  }

  Future<void> _join() async {
    final code = await askText(context, 'ربط الفرع ده بالفرع الرئيسي', label: 'كود الربط (من شاشة الفروع على الفرع الرئيسي)');
    if (code == null) return;
    await _act('/api/branches/join', {'code': code}, 'اتبعت طلب الربط. الفرع الرئيسي لازم يوافق عليه');
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(branchesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('الفروع'),
        actions: [
          if (_busy) const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          IconButton(tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded), onPressed: _refreshNow),
        ],
      ),
      body: AsyncBody<Json>(
        value: data,
        onRetry: () => ref.invalidate(branchesProvider),
        builder: (d) => switch (d['role']) {
          'main' => _MainView(data: d, busy: _busy, onAct: _act),
          'pending' => _Panel(children: [
              _Info(
                icon: Icons.hourglass_top_rounded,
                title: 'مستني موافقة الفرع الرئيسي',
                text: 'اتبعت طلب ربط بالكود ${d['code']}. صاحب الكافيه يفتح "الفروع" على الفرع الرئيسي ويوافق، والشاشة دي هتتحدّث لوحدها.',
              ),
              if (d['error'] != null) ErrorBanner('آخر مشكلة: ${d['error']}'),
              OutlinedButton(onPressed: _busy ? null : () => _act('/api/branches/leave', null, 'اتلغى طلب الربط'), child: const Text('إلغاء الطلب')),
            ]),
          'member' => _Panel(children: [
              _Info(
                icon: Icons.link_rounded,
                title: 'الفرع ده مربوط${(d['mainName'] as String? ?? '').isEmpty ? '' : ' بـ ${d['mainName']}'}',
                text: 'ملخص شغل الفرع ده (المبيعات، والحسابات المفتوحة، والدرج) بيتبعت للفرع الرئيسي كل دقيقة لو فيه نت. '
                    'المنيو والحسابات والموظفين بتوع الفرع ده زي ما هم.',
              ),
              if (parseDate(d['lastPush']) case final at?) Text('آخر مرة اتبعت: ${timeAgo(at)}', textAlign: TextAlign.center),
              if (d['error'] != null) ErrorBanner('آخر مشكلة: ${d['error']}'),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        if (await confirmDialog(context, 'الفرع الرئيسي مش هيشوف شغل الفرع ده تاني. متأكد؟', ok: 'فصل', danger: true)) {
                          await _act('/api/branches/leave', null, 'الفرع اتفصل');
                        }
                      },
                child: const Text('فصل الفرع ده'),
              ),
            ]),
          _ => _Panel(children: [
              if (d['rejected'] == true) const ErrorBanner('الفرع الرئيسي رفض طلب الربط. اتأكد من الكود وابعت تاني لو محتاج.'),
              if (d['removed'] == true) const ErrorBanner('الفرع الرئيسي فصل الفرع ده.'),
              const _Info(
                icon: Icons.store_mall_directory_rounded,
                title: 'عندك أكتر من فرع؟',
                text: 'اربط الفروع ببعض عشان تشوف شغلهم كلهم من الفرع الرئيسي: مبيعات النهارده، والحسابات المفتوحة، والدرج، والأصناف الأكتر بيعاً.\n'
                    'كل فرع لازم يكون عليه البرنامج على كمبيوتر الكاشير بتاعه (سيرفر لوحده)، ومحتاج نت.\n'
                    'الموبايلات والتابلتات اللي في نفس الكافيه مش فروع: دي بتتوصل بسيرفر الكافيه من "الاتصال بسيرفر الكافيه".',
              ),
              if (d['cloud'] != true)
                const ErrorBanner('الربط بالنت مقفول على الجهاز ده.')
              else ...[
                FilledButton.icon(
                  onPressed: _busy ? null : () => _act('/api/branches/create', null, 'الفرع ده بقى الفرع الرئيسي'),
                  icon: const Icon(Icons.hub_rounded),
                  label: const Text('ده الفرع الرئيسي: اعمل كود ربط'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _join,
                  icon: const Icon(Icons.add_link_rounded),
                  label: const Text('اربط الفرع ده بفرع رئيسي'),
                ),
              ],
            ]),
        },
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 12), child: c)],
            ),
          ),
        ),
      );
}

class _Info extends StatelessWidget {
  const _Info({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(title, style: t.titleLarge?.bold, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(text, style: t.bodyMedium, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

typedef _Act = Future<void> Function(String path, [Map<String, Object?>? body, String? done]);

/// الفرع الرئيسي: إجمالي كل الفروع، وكود الربط، وطلبات الربط، وكارت لكل فرع.
class _MainView extends StatelessWidget {
  const _MainView({required this.data, required this.busy, required this.onAct});
  final Json data;
  final bool busy;
  final _Act onAct;

  @override
  Widget build(BuildContext context) {
    final branches = (data['branches'] as List).cast<Json>();
    final requests = (data['requests'] as List).cast<Json>();
    int sum(String section, String key) =>
        branches.fold(0, (s, b) => s + ((((b['summary'] as Json?)?[section] as Json?)?[key] as int?) ?? 0));
    final online = branches.where((b) => b['online'] == true).length;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 700;
    final cardWidth = narrow ? double.infinity : 380.0;
    // على الموبايل: كارتين جنب بعض
    final statWidth = narrow ? (width - 32 - 12) / 2 : 220.0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (data['stale'] == true) const Padding(padding: EdgeInsets.only(bottom: 8), child: ErrorBanner('مفيش نت دلوقتي: الأرقام دي من آخر مرة اتقرت')),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _Stat('مبيعات النهارده (كل الفروع)', money(sum('today', 't')), '${sum('today', 'n')} حساب', width: statWidth),
          _Stat('الشهر ده', money(sum('month', 't')), '${sum('month', 'n')} حساب', width: statWidth),
          _Stat('حسابات مفتوحة دلوقتي', '${sum('open', 'n')}', money(sum('open', 't')), width: statWidth),
          _Stat('الفروع المتصلة', '$online من ${branches.length}', 'الاشتراك: ${data['used']} من ${data['limit']}', width: statWidth),
        ]),
        const SizedBox(height: 12),
        _CodeCard(code: data['code'] as String, narrow: narrow),
        if (requests.isNotEmpty) ...[
          const SectionTitle('طلبات ربط جديدة'),
          for (final r in requests)
            Card(
              child: ListTile(
                leading: const Icon(Icons.add_business_rounded),
                title: Text('${r['branch']}'),
                subtitle: Text(['${r['name']}', if (parseDate(r['at']) case final at?) timeAgo(at)].join(' • ')),
                trailing: Wrap(spacing: 8, children: [
                  TextButton(
                    onPressed: busy ? null : () => onAct('/api/branches/reject', {'uid': r['uid']}, 'اترفض الطلب'),
                    child: const Text('رفض'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : () => onAct('/api/branches/approve', {'uid': r['uid']}, 'الفرع اتربط'),
                    child: const Text('موافقة'),
                  ),
                ]),
              ),
            ),
        ],
        const SectionTitle('الفروع'),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final b in branches) SizedBox(width: cardWidth, child: _BranchCard(branch: b, busy: busy, onAct: onAct)),
        ]),
        const SizedBox(height: 24),
        Center(
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: busy
                ? null
                : () async {
                    if (await confirmDialog(context, 'كل الفروع هتتفصل، وكود الربط هيتمسح. البيانات اللي في كل فرع مش هتتمسح. متأكد؟', ok: 'مسح الربط', danger: true)) {
                      await onAct('/api/branches/leave', null, 'الربط اتمسح');
                    }
                  },
            icon: const Icon(Icons.link_off_rounded),
            label: const Text('مسح ربط الفروع'),
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.sub, {required this.width});
  final String label;
  final String value;
  final String sub;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.bodySmall),
            const SizedBox(height: 4),
            Text(value, style: t.titleLarge?.bold),
            Text(sub, style: t.bodySmall),
          ]),
        ),
      ),
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code, required this.narrow});
  final String code;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('كود ربط فرع جديد', style: t.titleSmall?.bold),
      Text('على كمبيوتر الفرع الجديد افتح "الفروع"، واختار "اربط الفرع ده بفرع رئيسي"، واكتب الكود ده. هيوصلك هنا طلب توافق عليه.', style: t.bodySmall),
    ]);
    final copy = Row(mainAxisSize: MainAxisSize.min, children: [
      SelectableText(code, textDirection: TextDirection.ltr, style: t.titleMedium?.bold.copyWith(letterSpacing: 1.5)),
      IconButton(
        tooltip: 'نسخ',
        icon: const Icon(Icons.copy_rounded, size: 18),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: code));
          showMessage(context, 'اتنسخ الكود');
        },
      ),
    ]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: narrow
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [const Icon(Icons.key_rounded), const SizedBox(width: 12), Expanded(child: text)]),
                const SizedBox(height: 8),
                Center(child: copy),
              ])
            : Row(children: [const Icon(Icons.key_rounded), const SizedBox(width: 12), Expanded(child: text), copy]),
      ),
    );
  }
}

class _BranchCard extends StatelessWidget {
  const _BranchCard({required this.branch, required this.busy, required this.onAct});
  final Json branch;
  final bool busy;
  final _Act onAct;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final s = branch['summary'] as Json?;
    final me = branch['me'] == true;
    final online = branch['online'] == true;
    final at = parseDate(branch['at']);
    final title = (s?['branch'] ?? branch['branch'] ?? '') as String;
    final shop = (s?['name'] ?? branch['name'] ?? '') as String;

    Widget chip(IconData icon, String text, {Color? color}) => Chip(
          visualDensity: VisualDensity.compact,
          avatar: Icon(icon, size: 16, color: color),
          label: Text(text, style: TextStyle(color: color, fontSize: 12)),
        );

    final reg = s?['reg'] as Json?;
    final open = s?['open'] as Json?;
    final lic = s?['lic'] as Json?;
    final top = (s?['top'] as List? ?? const []).cast<Json>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.circle, size: 10, color: online ? const Color(0xFF16A34A) : scheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title.isEmpty ? shop : title, style: t.titleMedium?.bold),
                Text(
                  [
                    if (me) 'الفرع ده (الرئيسي)' else if (shop.isNotEmpty && title.isNotEmpty) shop,
                    if (!me) online ? 'متصل' : at == null ? 'لسه مابعتش بيانات' : 'مش متصل • آخر تحديث ${timeAgo(at)}',
                  ].join(' • '),
                  style: t.bodySmall,
                ),
              ]),
            ),
            if (!me)
              PopupMenuButton<String>(
                enabled: !busy,
                onSelected: (_) async {
                  if (await confirmDialog(context, 'الفرع "$title" هيتفصل ومش هتشوف شغله. البيانات اللي فيه مش هتتمسح. متأكد؟', ok: 'فصل', danger: true)) {
                    await onAct('/api/branches/remove', {'uid': branch['uid']}, 'الفرع اتفصل');
                  }
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('فصل الفرع'))],
              ),
          ]),
          if (s == null)
            const Padding(padding: EdgeInsets.only(top: 12), child: Text('لسه مابعتش ملخص. اتأكد إن البرنامج مفتوح على كمبيوتر الفرع وفيه نت.'))
          else ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _Figure('النهارده', s['today'] as Json?)),
              Expanded(child: _Figure('امبارح', s['yesterday'] as Json?)),
              Expanded(child: _Figure('الشهر ده', s['month'] as Json?)),
            ]),
            const SizedBox(height: 10),
            _WeekBars((s['days'] as List? ?? const []).whereType<int>().toList(), today: BusinessDay.parseKey(s['bd'])),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              reg == null
                  ? chip(Icons.lock_clock_rounded, 'الدرج مقفول', color: scheme.error)
                  : chip(Icons.point_of_sale_rounded, 'الدرج مفتوح${reg['by'] == null ? '' : ' • ${reg['by']}'} • كاش ${money(reg['cash'] as int? ?? 0)}'),
              if (open != null) chip(Icons.receipt_long_rounded, '${open['n']} حساب مفتوح • ${money(open['t'] as int? ?? 0)}'),
              if (open != null && (open['tables'] as int? ?? 0) > 0) chip(Icons.table_restaurant_rounded, 'ترابيزات مشغولة ${open['busy']} من ${open['tables']}'),
              if ((s['qr'] as int? ?? 0) > 0) chip(Icons.qr_code_rounded, '${s['qr']} طلب QR مستني', color: const Color(0xFFD97706)),
              if ((s['kds'] as int? ?? 0) > 0) chip(Icons.soup_kitchen_rounded, '${s['kds']} طلب بيتحضر'),
              if ((s['pays'] as int? ?? 0) > 0) chip(Icons.account_balance_wallet_rounded, '${s['pays']} تحويل مستني', color: const Color(0xFFD97706)),
              if ((s['calls'] as int? ?? 0) > 0) chip(Icons.front_hand_rounded, '${s['calls']} نداء'),
              if ((s['voids'] as int? ?? 0) > 0) chip(Icons.remove_shopping_cart_rounded, 'إلغاءات النهارده ${money(s['voids'] as int)}'),
              if ((s['low'] as int? ?? 0) > 0) chip(Icons.inventory_2_rounded, '${s['low']} خامة قربت تخلص', color: scheme.error),
              chip(Icons.devices_rounded, '${s['devs'] ?? 0} جهاز شغال'),
              if (lic?['s'] == 'expired' || lic?['s'] == 'tampered')
                chip(Icons.workspace_premium_rounded, 'الاشتراك خلص', color: scheme.error)
              else if (lic?['d'] is int && (lic!['d'] as int) <= 7)
                chip(Icons.workspace_premium_rounded, 'الاشتراك فاضل له ${lic['d']} يوم', color: const Color(0xFFD97706)),
            ]),
            if (top.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('الأكتر بيعاً النهارده', style: t.labelLarge?.semiBold),
              const SizedBox(height: 4),
              for (final i in top) Text('${i['n']} × ${i['q']}', style: t.bodySmall),
            ],
          ],
        ]),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.data);
  final String label;
  final Json? data;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: t.bodySmall),
      Text(money(data?['t'] as int? ?? 0), style: t.titleSmall?.bold),
      Text('${data?['n'] ?? 0} حساب', style: t.bodySmall),
    ]);
  }
}

/// مبيعات آخر 7 أيام (النهارده على الطرف).
class _WeekBars extends StatelessWidget {
  const _WeekBars(this.days, {this.today});
  final List<int> days;

  /// يوم الشغل بتاع الفرع (فرع أقدم مابيبعتوش، فتاريخ الجهاز).
  final DateTime? today;

  String _label(int back, DateTime base) => switch (back) {
        0 => 'النهارده',
        1 => 'امبارح',
        _ => formatDay(DateTime(base.year, base.month, base.day - back)),
      };

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final top = days.fold(0, max);
    final now = DateTime.now();
    final base = today ?? DateTime(now.year, now.month, now.day);
    return Tooltip(
      message: [
        for (var i = 0; i < days.length; i++) '${_label(days.length - 1 - i, base)}: ${money(days[i])}',
      ].join('\n'),
      child: SizedBox(
        height: 36,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < days.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  height: top == 0 ? 2 : max(2, 36 * days[i] / top),
                  decoration: BoxDecoration(
                    color: i == days.length - 1 ? scheme.primary : scheme.primary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
