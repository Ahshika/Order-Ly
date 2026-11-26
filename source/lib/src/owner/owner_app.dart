import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/file_save.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart' show EmptyState, ErrorBanner, showMessage;
import 'day_report_pdf.dart';
import 'day_report_view.dart';
import 'owner_cloud.dart';
import 'owner_push.dart';

/// أبلكيشن المالك (نسخة ويب على Firebase Hosting تحت /owner، للأيفون وأندرويد): تقارير كل الفروع يوم بيوم،
/// وPDF لكل يوم، وإشعارات مع كل قفل وردية وكل يوم بيخلص. البيانات من Firebase بس (مش محتاج يبقى في الكافيه).
String ownerError(Object e) => e is OwnerCloudException ? e.message : 'حصل خطأ: $e';

const _prefsKey = 'owner_link';
const _deviceKey = 'owner_device';

final ownerLinkProvider = AsyncNotifierProvider<OwnerLinkController, OwnerLink?>(OwnerLinkController.new);

class OwnerLinkController extends AsyncNotifier<OwnerLink?> {
  @override
  Future<OwnerLink?> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
    if (raw == null) return null;
    try {
      return OwnerLink.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(OwnerLink link) async {
    await (await SharedPreferences.getInstance()).setString(_prefsKey, jsonEncode(link.toJson()));
    state = AsyncData(link);
  }

  Future<void> clear() async {
    await (await SharedPreferences.getInstance()).remove(_prefsKey);
    state = const AsyncData(null);
  }
}

final ownerCloudProvider = Provider<OwnerCloud?>((ref) {
  final link = ref.watch(ownerLinkProvider).value;
  if (link == null) return null;
  return OwnerCloud(link)..onRefresh = (l) => ref.read(ownerLinkProvider.notifier).save(l);
});

OwnerCloud _cloud(Ref ref) => ref.watch(ownerCloudProvider) ?? (throw OwnerCloudException('سجّل دخول الأول'));

/// الفروع اللي الفرع الرئيسي سمح للمالك يشوفها.
final _shopsProvider = FutureProvider.autoDispose<List<(String, String, String)>>((ref) async {
  final cloud = _cloud(ref);
  final raw = await cloud.get('own/${cloud.link.main}/shops');
  if (raw is! Map) return const [];
  return [for (final e in raw.entries) ('${e.key}', '${(e.value as Map)['name'] ?? ''}', '${(e.value as Map)['branch'] ?? ''}')]..sort((a, b) => a.$3.compareTo(b.$3));
});

/// الفرع دلوقتي (live/{uid}): الملخص ووقت آخر تحديث، أو null لو لسه مابعتش.
final _liveProvider = FutureProvider.autoDispose.family<(Map<String, dynamic>, DateTime)?, String>((ref, shop) async {
  final raw = await _cloud(ref).get('live/$shop');
  if (raw is! Map || raw['j'] is! String) return null;
  return (jsonDecode(raw['j'] as String) as Map<String, dynamic>, DateTime.fromMillisecondsSinceEpoch(raw['at'] as int? ?? 0));
});

/// أيام الفرع اللي ليها تقارير (أحدث يوم الأول).
final _daysProvider = FutureProvider.autoDispose.family<List<String>, String>((ref, shop) async {
  final raw = await _cloud(ref).get('rep/$shop', shallow: true);
  return raw is Map ? (raw.keys.map((k) => '$k').toList()..sort((a, b) => b.compareTo(a))) : const [];
});

/// تقرير يوم + تقارير ورديته.
final _dayProvider = FutureProvider.autoDispose.family<(Map<String, dynamic>, List<Map<String, dynamic>>), (String, String)>((ref, key) async {
  final raw = await _cloud(ref).get('rep/${key.$1}/${key.$2}');
  if (raw is! Map || raw['day'] is! Map) throw OwnerCloudException('مفيش تقرير لليوم ده');
  Map<String, dynamic> decode(Object? v) => jsonDecode('${(v as Map)['j']}') as Map<String, dynamic>;
  final shifts = raw['shifts'] is Map ? [for (final v in (raw['shifts'] as Map).values) decode(v)] : <Map<String, dynamic>>[];
  shifts.sort((a, b) => '${a['openedAt']}'.compareTo('${b['openedAt']}'));
  return (decode(raw['day']), shifts);
});

class OwnerApp extends StatelessWidget {
  const OwnerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Order Ly المالك',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar', 'EG'),
        supportedLocales: const [Locale('ar', 'EG'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const _OwnerGate(),
      );
}

class _OwnerGate extends ConsumerWidget {
  const _OwnerGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(ownerLinkProvider);
    if (link.isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final invite = OwnerInvite.fromUri(Uri.base);
    final current = link.value;
    if (invite != null && (current == null || current.main != invite.main)) return OwnerJoinScreen(invite: invite);
    if (current == null) return const _NoLinkScreen();
    return const OwnerHomeScreen();
  }
}

class _NoLinkScreen extends StatelessWidget {
  const _NoLinkScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: EmptyState(
              icon: Icons.qr_code_2_rounded,
              text: 'افتح Order Ly على كمبيوتر الفرع الرئيسي: الإعدادات › المالك من بره › "اعمل كود"، وصوّر الـ QR بموبايلك.',
            ),
          ),
        ),
      );
}

/// المالك فتح لينك الـ QR: حساب جديد (أو دخول)، وبعدين طلب ربط بالكود، ومستني الفرع الرئيسي يوافق (لوحده في ثواني).
class OwnerJoinScreen extends ConsumerStatefulWidget {
  const OwnerJoinScreen({super.key, required this.invite});
  final OwnerInvite invite;

  @override
  ConsumerState<OwnerJoinScreen> createState() => _OwnerJoinScreenState();
}

class _OwnerJoinScreenState extends ConsumerState<OwnerJoinScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _create = true;
  bool _busy = false;
  String? _error;
  String? _status;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final inv = widget.invite;
    if (_name.text.trim().isEmpty) return setState(() => _error = 'اكتب اسمك');
    setState(() {
      _busy = true;
      _error = null;
      _status = 'بيسجّل الدخول...';
    });
    try {
      final (uid, refresh, idToken) = await OwnerCloud.authenticate(inv.apiKey, _email.text, _password.text, create: _create);
      final link = OwnerLink(apiKey: inv.apiKey, dbHost: inv.dbHost, main: inv.main, ownerUid: uid, email: _email.text.trim(), refreshToken: refresh);
      final cloud = OwnerCloud(link)..useToken(idToken);
      setState(() => _status = 'بيبعت طلب الربط للفرع الرئيسي...');
      try {
        await cloud.put('own/${inv.main}/claim/$uid', {'c': inv.code, 'name': _name.text.trim(), 'email': link.email, 'at': {'.sv': 'timestamp'}});
      } on OwnerCloudException {
        // ممكن يكون مربوط قبل كده (من موبايل تاني): بنشوف
        if (await cloud.get('own/${inv.main}/ok/$uid') == null) {
          throw OwnerCloudException('الكود خلص أو اتستخدم قبل كده. اعمل كود جديد من الكمبيوتر وصوّره تاني');
        }
      }
      setState(() => _status = 'مستني الفرع الرئيسي يوافق (الكمبيوتر لازم يكون شغال وعليه نت)...');
      final until = DateTime.now().add(const Duration(minutes: 3));
      while (await cloud.get('own/${inv.main}/ok/$uid') == null) {
        if (DateTime.now().isAfter(until)) throw OwnerCloudException('الفرع الرئيسي ماردّش. اتأكد إن كمبيوتر الكاشير شغال وعليه نت وجرّب تاني');
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      await ref.read(ownerLinkProvider.notifier).save(link);
    } on OwnerCloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = ownerError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('ربط المالك')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Text('هتشوف تقارير كل الفروع يوم بيوم من أي مكان، ويوصلك إشعار مع كل قفل وردية.', style: text.bodyMedium),
            if (pushSupport() == PushSupport.needsHomeScreen) ...[
              const SizedBox(height: 12),
              const ErrorBanner('على الأيفون: ضيف الصفحة دي للشاشة الرئيسية الأول (زرار المشاركة › إضافة إلى الشاشة الرئيسية)، '
                  'وافتحها من الأيقونة وكمّل من هناك، عشان الإشعارات تشتغل.'),
            ],
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('حساب جديد')), ButtonSegment(value: false, label: Text('عندي حساب'))],
              selected: {_create},
              onSelectionChanged: (v) => setState(() => _create = v.first),
            ),
            const SizedBox(height: 12),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'اسمك', prefixIcon: Icon(Icons.person_rounded))),
            const SizedBox(height: 10),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'الإيميل', prefixIcon: Icon(Icons.alternate_email_rounded)),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'كلمة السر (6 حروف على الأقل)', prefixIcon: Icon(Icons.lock_rounded)),
            ),
            const SizedBox(height: 16),
            if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: ErrorBanner(_error!)),
            if (_busy && _status != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_status!, style: text.bodySmall)),
            FilledButton(onPressed: _busy ? null : _join, child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('اربطني')),
          ]),
        ),
      ),
    );
  }
}

class OwnerHomeScreen extends ConsumerStatefulWidget {
  const OwnerHomeScreen({super.key});

  @override
  ConsumerState<OwnerHomeScreen> createState() => _OwnerHomeScreenState();
}

class _OwnerHomeScreenState extends ConsumerState<OwnerHomeScreen> {
  bool _opened = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // الفروع وهي شغالة بتتحدث كل 30 ثانية طول ما الأبلكيشن قدام المالك (مش في الخلفية)
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) ref.invalidate(_liveProvider);
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // الإشعار بيفتح الأبلكيشن على تقرير اليوم (./?shop=...&date=...)
    if (_opened) return;
    _opened = true;
    final q = Uri.base.queryParameters;
    final shop = q['shop'], date = q['date'];
    if (shop != null && date != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DayReportScreen(shop: shop, date: date, title: '')));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final shops = ref.watch(_shopsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('تقارير المحل'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'out') await ref.read(ownerLinkProvider.notifier).clear();
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'out', child: Text('خروج من الحساب ده'))],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(_shopsProvider.future),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const _PushCard(),
          const SizedBox(height: 12),
          ...shops.when(
            loading: () => [const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [ErrorBanner(ownerError(e)), TextButton(onPressed: () => ref.invalidate(_shopsProvider), child: const Text('جرّب تاني'))],
            data: (list) => list.isEmpty
                ? [const EmptyState(icon: Icons.storefront_rounded, text: 'لسه مفيش فروع')]
                : [
                    for (final (uid, name, branch) in list) _LiveCard(shop: uid, title: branch.isEmpty ? name : branch),
                  ],
          ),
        ]),
      ),
    );
  }
}

/// تشغيل الإشعارات على الموبايل ده.
class _PushCard extends ConsumerStatefulWidget {
  const _PushCard();

  @override
  ConsumerState<_PushCard> createState() => _PushCardState();
}

class _PushCardState extends ConsumerState<_PushCard> {
  bool _busy = false;
  bool _done = false;

  Future<void> _enable() async {
    final cloud = ref.read(ownerCloudProvider);
    if (cloud == null) return;
    setState(() => _busy = true);
    try {
      final vapid = await cloud.get('own/${cloud.link.main}/vapid/pub');
      if (vapid is! String) throw OwnerCloudException('الفرع الرئيسي لسه ماجهزش الإشعارات. افتح البرنامج على الكمبيوتر وجرّب بعد دقيقة');
      final sub = await subscribePush(vapid);
      final prefs = await SharedPreferences.getInstance();
      var device = prefs.getString(_deviceKey);
      if (device == null) {
        final r = Random.secure();
        device = List.generate(16, (_) => 'abcdefghijkmnopqrstuvwxyz23456789'[r.nextInt(33)]).join();
        await prefs.setString(_deviceKey, device);
      }
      await cloud.put('own/${cloud.link.main}/push/${cloud.link.ownerUid}/$device', {'s': sub, 'at': {'.sv': 'timestamp'}});
      setState(() => _done = true);
      if (mounted) showMessage(context, 'الإشعارات اشتغلت على الموبايل ده');
    } on OwnerCloudException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } catch (e) {
      if (mounted) showMessage(context, 'الإشعارات ما اشتغلتش: لازم توافق على الإذن ($e)', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final support = pushSupport();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(_done ? Icons.notifications_active_rounded : Icons.notifications_none_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Text(switch (support) {
              PushSupport.supported => _done ? 'الإشعارات شغالة على الموبايل ده' : 'إشعار مع كل قفل وردية وكل يوم بيخلص',
              PushSupport.needsHomeScreen => 'على الأيفون: ضيف الصفحة للشاشة الرئيسية (المشاركة › إضافة إلى الشاشة الرئيسية) وافتحها من الأيقونة عشان الإشعارات',
              PushSupport.unsupported => 'المتصفح ده مابيدعمش الإشعارات. افتح الأبلكيشن عشان تشوف التقارير',
            }),
          ),
          if (support == PushSupport.supported && !_done)
            FilledButton(onPressed: _busy ? null : _enable, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('شغّلها')),
        ]),
      ),
    );
  }
}

/// كارت الفرع: النهارده لحد دلوقتي، والمفتوح، والدرج، واللي مستني. الضغط بيفتح التقارير بالأيام.
class _LiveCard extends ConsumerWidget {
  const _LiveCard({required this.shop, required this.title});
  final String shop;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(_liveProvider(shop));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final data = live.value;
    final s = data?.$1;
    // الفرع بيبعت نبضة كل 5 دقايق: لو عدّى 10 من غير جديد يبقى الكمبيوتر مقفول أو مفيش نت
    final online = data != null && DateTime.now().difference(data.$2) < const Duration(minutes: 10);
    Map<String, dynamic> m(String k) => (s?[k] as Map?)?.cast<String, dynamic>() ?? const {};
    final today = m('today'), open = m('open'), reg = s?['reg'] as Map?;
    final waiting = [
      if ((s?['qr'] ?? 0) != 0) '${s!['qr']} طلب QR',
      if ((s?['pays'] ?? 0) != 0) '${s!['pays']} تحويل',
      if ((s?['calls'] ?? 0) != 0) '${s!['calls']} نداء',
    ];
    return Card(
      // زرار لقارئ الشاشة (VoiceOver): "فرع ... • النهارده ..."
      child: Semantics(
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _DaysScreen(shop: shop, title: title))),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.storefront_rounded),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
                if (data != null)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(online ? 'شغال' : 'مش متصل من ${formatTime(data.$2)}'),
                    backgroundColor: online ? scheme.primaryContainer : scheme.errorContainer,
                  ),
                const Icon(Icons.chevron_left_rounded),
              ]),
              const SizedBox(height: 8),
              if (live.hasError && data == null) Text(ownerError(live.error!), style: TextStyle(color: scheme.error)),
              if (live.isLoading && data == null) const LinearProgressIndicator(),
              if (!live.isLoading && !live.hasError && data == null) Text('لسه مفيش بيانات من الفرع ده', style: text.bodySmall),
              if (s != null) ...[
                Text('النهارده: ${money(today['t'] as int? ?? 0)} • ${today['n'] ?? 0} حساب', style: text.titleSmall),
                const SizedBox(height: 4),
                Text('مفتوح دلوقتي: ${open['n'] ?? 0} حساب (${money(open['t'] as int? ?? 0)}) • ${open['busy'] ?? 0} من ${open['tables'] ?? 0} ترابيزة'),
                Text(reg == null ? 'الدرج مقفول' : 'الدرج مفتوح مع ${reg['by'] ?? ''} • المتوقع فيه ${money(reg['cash'] as int? ?? 0)}'),
                if (waiting.isNotEmpty) Text('مستني: ${waiting.join(' • ')}', style: TextStyle(color: scheme.tertiary, fontWeight: FontWeight.bold)),
                if ((s['voids'] ?? 0) != 0) Text('اتلغى النهارده: ${money(s['voids'] as int)}', style: text.bodySmall),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _DaysScreen extends ConsumerWidget {
  const _DaysScreen({required this.shop, required this.title});
  final String shop;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(_daysProvider(shop));
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: days.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: ErrorBanner(ownerError(e)))),
        data: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.event_note_rounded, text: 'لسه مفيش تقارير للفرع ده. أول تقرير بيوصل مع أول قفل درج')
            : ListView(children: [
                for (final d in list)
                  ListTile(
                    leading: const Icon(Icons.event_note_rounded),
                    title: Text(d, textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                    trailing: const Icon(Icons.chevron_left_rounded),
                    onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DayReportScreen(shop: shop, date: d, title: title))),
                  ),
              ]),
      ),
    );
  }
}

class DayReportScreen extends ConsumerWidget {
  const DayReportScreen({super.key, required this.shop, required this.date, required this.title});
  final String shop;
  final String date;
  final String title;

  Future<void> _pdf(BuildContext context, Map<String, dynamic> report) async {
    try {
      final bytes = await buildDayReportPdf(report);
      final name = 'تقرير ${report['branch'] ?? report['shop'] ?? ''} ${report['date']}.pdf'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
      await saveOrShareFile(bytes, name, 'application/pdf');
    } catch (e) {
      if (context.mounted) showMessage(context, 'الـ PDF ماطلعش: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final day = ref.watch(_dayProvider((shop, date)));
    final text = Theme.of(context).textTheme;
    final report = day.value?.$1;
    return Scaffold(
      appBar: AppBar(
        title: Text(title.isEmpty ? '${report?['branch'] ?? ''} • $date' : '$title • $date'),
        actions: [if (report != null) IconButton(tooltip: 'PDF', icon: const Icon(Icons.picture_as_pdf_rounded), onPressed: () => _pdf(context, report))],
      ),
      body: day.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: ErrorBanner(ownerError(e)))),
        data: (d) => RefreshIndicator(
          onRefresh: () => ref.refresh(_dayProvider((shop, date)).future),
          child: ListView(padding: const EdgeInsets.all(12), children: [
            if (d.$1['final'] != true)
              const Padding(padding: EdgeInsets.only(bottom: 8), child: ErrorBanner('اليوم ده لسه شغال: ده آخر تقرير اتبعت مع آخر حركة درج')),
            for (final sec in dayReportSections(d.$1))
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(sec.title, style: text.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                    const SizedBox(height: 6),
                    for (final (label, value) in sec.rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(child: Text(label)),
                          const SizedBox(width: 8),
                          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
                        ]),
                      ),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
