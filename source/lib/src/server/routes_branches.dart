part of 'api_server.dart';

/// الفروع: كذا كافيه (كل فرع على كمبيوتره وبقاعدة بياناته) تحت صاحب واحد.
///
/// - الفرع الرئيسي بيعمل "كود ربط". الفرع التاني بيكتب الكود فبيوصل للرئيسي طلب ربط، والرئيسي يوافق أو يرفض.
/// - كل فرع مربوط بيبعت ملخص شغله (المبيعات، الحسابات المفتوحة، الدرج...) على Firebase كل دقيقة لو اتغير،
///   والفرع الرئيسي بس اللي يقدر يقراه (chains/{كود} في firebase/database.rules.json).
/// - مفيش حاجة تانية بتتنقل بين الفروع: المنيو والحسابات والموظفين كل فرع لوحده.
///
/// حالة الجهاز في settings: chain_role (main / pending / member أو فاضي) وchain_id (الكود من غير شَرط).

const _chainAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const _chainCodeLength = 12;

/// الفرع بيتعرض "مش متصل" لو مابعتش ملخص من الوقت ده (بيبعت نبضة كل 5 دقايق حتى لو مفيش جديد).
const branchOfflineAfter = Duration(minutes: 10);

/// الكود زي ما المستخدم كتبه (بشَرط أو مسافات أو حروف صغيرة) ← الكود نفسه، أو null لو مش صحيح.
String? normalizeChainCode(String input) {
  final s = input.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
  if (s.length != _chainCodeLength || s.split('').any((c) => !_chainAlphabet.contains(c))) return null;
  return s;
}

String formatChainCode(String id) => '${id.substring(0, 4)}-${id.substring(4, 8)}-${id.substring(8)}';

String _newChainId() {
  final rnd = Random.secure();
  return [for (var i = 0; i < _chainCodeLength; i++) _chainAlphabet[rnd.nextInt(_chainAlphabet.length)]].join();
}

final _firebaseUidRe = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

extension _BranchRoutes on OrderlyServer {
  void _registerBranchRoutes(Router r) {
    r.get('/api/branches', _authed(_branchesStatus, only: {'owner'}));
    r.post('/api/branches/create', _authed(_createChain, only: {'owner'}));
    r.post('/api/branches/join', _authed(_joinChain, only: {'owner'}));
    r.post('/api/branches/approve', _authed((req, u) => _answerJoinRequest(req, u, approve: true), only: {'owner'}));
    r.post('/api/branches/reject', _authed((req, u) => _answerJoinRequest(req, u, approve: false), only: {'owner'}));
    r.post('/api/branches/remove', _authed(_removeBranch, only: {'owner'}));
    r.post('/api/branches/leave', _authed(_leaveChain, only: {'owner'}));
  }

  String? get _chainRole {
    final v = db.setting('chain_role');
    return v == null || v.isEmpty ? null : v;
  }

  String get _chainId => db.setting('chain_id')!;

  CloudSync get _chainCloud => _cloud ?? (throw ApiError(503, 'الربط بالنت مقفول على الجهاز ده'));

  void _setChain(String? role, {String? id, String? mainName}) {
    db.setSetting('chain_role', role ?? '');
    db.setSetting('chain_id', id ?? '');
    db.setSetting('chain_main_name', mainName ?? '');
    db.setSetting('chain_last_error', '');
    db.setSetting('chain_last_push', '');
  }

  Future<int> _branchLimit() async => (await _licenseStatus())['branches'] as int? ?? 1;

  ({String shop, String branch}) _localNames() {
    final shop = db.selectOne('SELECT name FROM shop LIMIT 1');
    final branch = db.selectOne('SELECT name FROM branches WHERE is_local = 1 LIMIT 1');
    return (shop: _clip(shop?['name'], 80), branch: _clip(branch?['name'], 80));
  }

  String _clip(Object? v, int max) {
    final s = v is String ? v.trim() : '';
    return s.length <= max ? s : s.substring(0, max);
  }

  /// ملخص شغل الفرع ده اللي بيتبعت للفرع الرئيسي. الأسماء مختصرة عشان المساحة على Firebase.
  Future<Map<String, Object?>> _branchSummary() async {
    // كله بيوم الشغل: "النهارده" في كافيه بيقفل 3 الفجر هي السهرة كلها
    final now = DateTime.now();
    final bd = _bday;
    final day = bd.dateOf(now);
    DateTime dayStart(int offset) => bd.startOf(DateTime(day.year, day.month, day.day + offset));
    final today = dayStart(0);
    final tomorrow = dayStart(1);
    String iso(DateTime d) => d.toUtc().toIso8601String();

    Map<String, Object?> sales(DateTime from, DateTime to) {
      final s = db.selectOne(
        "SELECT COUNT(*) AS n, COALESCE(SUM(total_cents), 0) AS t FROM checks WHERE status = 'closed' AND closed_at >= ? AND closed_at < ?",
        [iso(from), iso(to)],
      )!;
      return {'n': s['n'], 't': s['t']};
    }

    int count(String sql, [List<Object?> args = const []]) => db.selectOne(sql, args)!['c'] as int;

    final open = db.selectOne("SELECT COUNT(*) AS n, COALESCE(SUM(total_cents), 0) AS t FROM checks WHERE status = 'open'")!;
    final register = db.selectOne('SELECT * FROM register_sessions WHERE closed_at IS NULL ORDER BY opened_at DESC LIMIT 1');
    final shift = register == null ? null : _sessionSummary(register);
    final license = await _licenseStatus();
    final names = _localNames();
    return {
      'v': 1,
      'name': names.shop,
      'branch': names.branch,
      'app': appVersion,
      // تاريخ يوم الشغل (الشاشة بتكتب أسامي الأيام منه)
      'bd': BusinessDay.keyOf(day),
      'today': sales(today, tomorrow),
      'yesterday': sales(dayStart(-1), today),
      'month': sales(bd.startOf(DateTime(day.year, day.month)), tomorrow),
      // مبيعات آخر 7 أيام (الأقدم الأول، والنهارده آخر واحد)
      'days': [for (var i = 6; i >= 0; i--) sales(dayStart(-i), dayStart(-i + 1))['t']],
      'open': {
        'n': open['n'],
        't': open['t'],
        'busy': count("SELECT COUNT(DISTINCT table_id) AS c FROM checks WHERE status = 'open' AND table_id IS NOT NULL"),
        'tables': count('SELECT COUNT(*) AS c FROM tables WHERE active = 1'),
      },
      'reg': shift == null ? null : {'at': shift['openedAt'], 'by': _clip(shift['openedBy'], 40), 'cash': shift['expectedCashCents']},
      'qr': count("SELECT COUNT(*) AS c FROM orders WHERE status = 'pending'"),
      'kds': count("SELECT COUNT(*) AS c FROM orders WHERE status = 'accepted'"),
      'calls': count("SELECT COUNT(*) AS c FROM service_calls WHERE status = 'open'"),
      'pays': count("SELECT COUNT(*) AS c FROM payments WHERE status = 'pending'"),
      'voids': db.selectOne(
        "SELECT COALESCE(SUM(oi.qty * oi.unit_price_cents), 0) AS s FROM order_items oi JOIN orders o ON o.id = oi.order_id "
        "WHERE oi.status = 'void' AND o.status <> 'rejected' AND oi.updated_at >= ?",
        [iso(today)],
      )!['s'],
      'low': count('SELECT COUNT(*) AS c FROM ingredients WHERE active = 1 AND qty <= low_stock'),
      'devs': count('SELECT COUNT(DISTINCT device_id) AS c FROM sessions WHERE device_id IS NOT NULL AND last_seen_at >= ?',
          [iso(now.subtract(const Duration(minutes: 10)))]),
      'top': _topItems(iso(today), iso(tomorrow), limit: 5).map((i) => {'n': _clip(i['name'], 60), 'q': i['qty']}).toList(),
      'lic': {'s': license['state'], 'd': license['daysLeft']},
    };
  }

  Future<Object?> _branchesStatus(Request req, AuthUser u) async {
    final role = _chainRole;
    final base = <String, Object?>{
      'role': role ?? 'none',
      'cloud': _cloud != null,
      'error': (db.setting('chain_last_error') ?? '').isEmpty ? null : db.setting('chain_last_error'),
    };
    switch (role) {
      case null:
        return {...base, 'rejected': db.setting('chain_rejected') == '1', 'removed': db.setting('chain_removed') == '1'};
      case 'pending':
        return {...base, 'code': formatChainCode(_chainId)};
      case 'member':
        return {...base, 'mainName': db.setting('chain_main_name'), 'lastPush': db.setting('chain_last_push')};
    }

    // الفرع الرئيسي: كل الفروع وطلبات الربط. القراية بتتحفظ ثواني (لو كذا جهاز فاتح الشاشة)، و?fresh=1 لزرار التحديث
    final (chain, stale) = await _chainCloud.readChain(fresh: req.url.queryParameters['fresh'] == '1');
    if (chain == null) {
      // الربط اتمسح من على النت (مثلاً من جهاز تاني عليه نفس البيانات)
      _setChain(null);
      return {...base, 'role': 'none', 'rejected': false, 'removed': false};
    }
    final members = _map(chain['members']);
    final pushed = _map(chain['b']);
    final now = DateTime.now();
    Map<String, Object?>? summaryOf(Object? raw) {
      if (raw is! Map || raw['j'] is! String) return null;
      try {
        final j = jsonDecode(raw['j'] as String);
        return j is Map<String, dynamic> ? j : null;
      } catch (_) {
        return null;
      }
    }

    String? timeOf(Object? millis) => millis is int ? DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toIso8601String() : null;

    final others = members.entries.map((e) {
      final m = _map(e.value);
      final b = _map(pushed[e.key]);
      final at = b['at'] is int ? DateTime.fromMillisecondsSinceEpoch(b['at'] as int) : null;
      return <String, Object?>{
        'uid': e.key,
        'me': false,
        'name': m['name'],
        'branch': m['branch'],
        'joinedAt': timeOf(m['at']),
        'summary': summaryOf(b),
        'at': timeOf(b['at']),
        'online': at != null && now.difference(at) < branchOfflineAfter,
      };
    }).toList()
      ..sort((a, b) => '${a['branch']}'.compareTo('${b['branch']}'));
    final names = _localNames();
    final requests = _map(chain['req']).entries.map((e) {
      final r = _map(e.value);
      return {'uid': e.key, 'name': r['name'], 'branch': r['branch'], 'at': timeOf(r['at'])};
    }).toList()
      ..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
    return {
      ...base,
      'code': formatChainCode(_chainId),
      'stale': stale,
      'limit': await _branchLimit(),
      'used': 1 + members.length,
      'branches': [
        {'uid': db.setting('cloud_uid'), 'me': true, 'name': names.shop, 'branch': names.branch, 'summary': await _branchSummary(), 'at': nowIso(), 'online': true},
        ...others,
      ],
      'requests': requests,
    };
  }

  Map<String, Object?> _map(Object? v) => v is Map ? v.map((k, v) => MapEntry('$k', v)) : const {};

  Future<Object?> _createChain(Request req, AuthUser u) async {
    if (_chainRole != null) throw ApiError(400, 'الجهاز ده مربوط بالفعل. افصله الأول من شاشة الفروع');
    final cloud = _chainCloud;
    final id = await cloud.createChain();
    _setChain('main', id: id);
    db.setSetting('chain_rejected', '');
    db.setSetting('chain_removed', '');
    _audit(u.id, 'branch.create', 'branch', id, 'بقى الفرع الرئيسي');
    return _branchesStatus(req, u);
  }

  Future<Object?> _joinChain(Request req, AuthUser u) async {
    final body = await _body(req);
    if (_chainRole != null) throw ApiError(400, 'الجهاز ده مربوط بالفعل. افصله الأول من شاشة الفروع');
    final id = normalizeChainCode(_field<String>(body, 'code') ?? '');
    if (id == null) throw ApiError(400, 'الكود لازم يبقى 12 حرف ورقم زي اللي ظاهر في شاشة الفروع على الفرع الرئيسي');
    final names = _localNames();
    if (names.branch.isEmpty) throw ApiError(400, 'اكتب اسم الفرع الأول من بيانات الكافيه، عشان الفرع الرئيسي يعرفه');
    await _chainCloud.requestJoin(id, names.shop, names.branch);
    _setChain('pending', id: id);
    db.setSetting('chain_rejected', '');
    db.setSetting('chain_removed', '');
    _audit(u.id, 'branch.join', 'branch', id, 'طلب ربط بفرع رئيسي');
    return _branchesStatus(req, u);
  }

  String _branchUid(Map<String, dynamic> body) {
    final uid = _field<String>(body, 'uid') ?? '';
    if (!_firebaseUidRe.hasMatch(uid)) throw ApiError(400, 'الفرع ده مش موجود');
    return uid;
  }

  void _requireMain() {
    if (_chainRole != 'main') throw ApiError(400, 'الجهاز ده مش الفرع الرئيسي');
  }

  Future<Object?> _answerJoinRequest(Request req, AuthUser u, {required bool approve}) async {
    final body = await _body(req);
    final uid = _branchUid(body);
    _requireMain();
    final (chain, stale) = await _chainCloud.readChain(fresh: true);
    if (chain == null || stale) throw ApiError(503, 'مفيش نت دلوقتي. جرّب تاني لما النت يرجع');
    final request = _map(chain['req'])[uid];
    if (request is! Map) throw ApiError(404, 'الطلب ده مش موجود (يمكن الفرع لغاه)');
    final members = _map(chain['members']);
    if (approve && !members.containsKey(uid)) {
      final limit = await _branchLimit();
      if (1 + members.length >= limit) {
        throw ApiError(402, 'الاشتراك بيسمح بـ $limit ${limit == 1 ? 'فرع' : 'فروع'} بس (منهم الفرع ده). كبّر الاشتراك عشان تضيف فرع');
      }
    }
    final name = _clip(request['name'], 80), branch = _clip(request['branch'], 80);
    await _chainCloud.answerJoin(uid, approve: approve, name: name, branch: branch, mainName: _localNames().shop);
    _audit(u.id, approve ? 'branch.approve' : 'branch.reject', 'branch', uid, '$name - $branch');
    return _branchesStatus(req, u);
  }

  Future<Object?> _removeBranch(Request req, AuthUser u) async {
    final body = await _body(req);
    final uid = _branchUid(body);
    _requireMain();
    await _chainCloud.removeMember(uid);
    _audit(u.id, 'branch.remove', 'branch', uid, null);
    return _branchesStatus(req, u);
  }

  /// الفرع يفصل نفسه، أو يلغي طلب الربط. الفرع الرئيسي لو فصل، الربط كله بيتمسح والفروع التانية بتفصل.
  Future<Object?> _leaveChain(Request req, AuthUser u) async {
    final role = _chainRole;
    if (role == null) return _branchesStatus(req, u);
    await _chainCloud.leaveChain(role, _chainId);
    _setChain(null);
    _audit(u.id, 'branch.leave', 'branch', null, role == 'main' ? 'مسح ربط الفروع' : 'فصل الفرع');
    return _branchesStatus(req, u);
  }
}

/// كل كلام الفروع مع Firebase.
extension _ChainSync on CloudSync {
  String get _cid => db.setting('chain_id')!;

  Future<Object?> _getJson(String path) async {
    await _token();
    final res = await _http.get(_url(path)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw RtdbError(res.statusCode, res.body);
    return jsonDecode(res.body);
  }

  /// بيرمي ApiError بالعربي لو مفيش نت، بدل رسالة الاستثناء نفسها.
  Future<T> _online<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ApiError {
      rethrow;
    } on RtdbError catch (e) {
      throw ApiError(502, 'Firebase رفض العملية (${e.status}). جرّب تاني بعد شوية');
    } catch (e) {
      throw ApiError(503, _errorText(e) == 'مفيش نت' ? 'مفيش نت دلوقتي. الربط بين الفروع محتاج نت' : 'مشكلة في الاتصال بالنت: $e');
    }
  }

  Future<String> createChain() => _online(() async {
        await _token();
        // احتمال إن الكود يتكرر صغير جداً، والقواعد بترفض لو الكود متاخد
        for (var i = 0; i < 3; i++) {
          final id = _newChainId();
          try {
            await _patch({'chains/$id/owner': _uid});
            return id;
          } on RtdbError catch (e) {
            if (!e.denied) rethrow;
          }
        }
        throw ApiError(500, 'ماقدرناش نعمل كود. جرّب تاني');
      });

  Future<void> requestJoin(String id, String shop, String branch) => _online(() async {
        await _token();
        try {
          await _patch({
            'chains/$id/req/$_uid': {'name': shop, 'branch': branch, 'at': {'.sv': 'timestamp'}},
          });
        } on RtdbError catch (e) {
          if (e.denied) throw ApiError(400, 'الكود ده مش صحيح. اتأكد منه من شاشة الفروع على الفرع الرئيسي');
          rethrow;
        }
      });

  /// (الربط، قديم؟): لو مفيش نت بيرجع آخر نسخة اتقرت، وstale = true.
  Future<(Map<String, Object?>?, bool)> readChain({bool fresh = false}) async {
    final cached = _chainCache;
    if (!fresh && cached != null && DateTime.now().difference(cached.$1) < const Duration(seconds: 15)) return (cached.$2, false);
    try {
      final raw = await _getJson('chains/$_cid');
      final chain = raw is Map ? raw.map((k, v) => MapEntry('$k', v as Object?)) : null;
      _chainCache = chain == null ? null : (DateTime.now(), chain);
      db.setSetting('chain_last_error', '');
      return (chain, false);
    } catch (e) {
      final text = e is RtdbError && e.denied ? 'الفرع ده مابقاش صاحب الربط' : _errorText(e);
      db.setSetting('chain_last_error', text);
      if (cached != null) return (cached.$2, true);
      throw ApiError(503, text == 'مفيش نت' ? 'مفيش نت دلوقتي. بيانات الفروع محتاجة نت' : text);
    }
  }

  Future<void> answerJoin(String uid, {required bool approve, required String name, required String branch, required String mainName}) =>
      _online(() async {
        await _token();
        await _patch({
          if (approve) 'chains/$_cid/members/$uid': {'at': {'.sv': 'timestamp'}, 'name': name, 'branch': branch, 'main': mainName},
          'chains/$_cid/req/$uid': null,
        });
        _chainCache = null;
      });

  Future<void> removeMember(String uid) => _online(() async {
        await _token();
        await _patch({'chains/$_cid/members/$uid': null, 'chains/$_cid/b/$uid': null});
        _chainCache = null;
      });

  Future<void> leaveChain(String role, String id) => _online(() async {
        await _token();
        try {
          await _patch(switch (role) {
            'main' => {'chains/$id': null},
            'pending' => {'chains/$id/req/$_uid': null},
            _ => {'chains/$id/members/$_uid': null, 'chains/$id/b/$_uid': null},
          });
        } on RtdbError catch (e) {
          // الرئيسي فصل الفرع ده قبل كده (فمابقاش ليه صلاحية يمسح): مفيش حاجة تتمسح
          if (!e.denied) rethrow;
        }
        _chainCache = null;
        _sent.remove('chain-j');
      });

  /// بيتنادى مع كل مزامنة: الفرع اللي مستني موافقة بيشوف اتوافق عليه ولا لأ،
  /// والفرع المربوط بيبعت ملخصه (مرة في الدقيقة بالكتير، ونبضة كل 5 دقايق لو مفيش جديد).
  Future<void> _syncChain() async {
    final role = db.setting('chain_role') ?? '';
    if (role != 'pending' && role != 'member') return;
    final now = DateTime.now();
    if (role == 'member' && _chainSyncedAt != null && now.difference(_chainSyncedAt!) < const Duration(seconds: 55)) return;
    _chainSyncedAt = now;
    final id = _cid;
    try {
      await _token();
      var current = role;
      final checkedAt = _membershipCheckedAt;
      if (role == 'pending' || checkedAt == null || now.difference(checkedAt) >= const Duration(minutes: 5)) {
        final member = await _getJson('chains/$id/members/$_uid');
        _membershipCheckedAt = now;
        if (member is Map) {
          if (role == 'pending') {
            server._setChain('member', id: id, mainName: '${member['main'] ?? ''}');
            current = 'member';
            server._broadcast('branches');
          }
        } else if (role == 'member' || await _getJson('chains/$id/req/$_uid') == null) {
          // اتفصل، أو الطلب اترفض
          server._setChain(null);
          db.setSetting(role == 'member' ? 'chain_removed' : 'chain_rejected', '1');
          _sent.remove('chain-j');
          server._broadcast('branches');
          return;
        }
      }
      if (current != 'member') return;
      final summary = jsonEncode(await server._branchSummary());
      final last = DateTime.tryParse(_sent['chain-at'] ?? '');
      if (_sent['chain-j'] != summary) {
        await _patch({'chains/$id/b/$_uid': {'j': summary, 'at': {'.sv': 'timestamp'}}});
      } else if (last == null || now.difference(last) >= const Duration(minutes: 5)) {
        await _patch({'chains/$id/b/$_uid/at': {'.sv': 'timestamp'}});
      } else {
        return;
      }
      _sent['chain-j'] = summary;
      _sent['chain-at'] = now.toIso8601String();
      db.setSetting('chain_last_push', nowIso());
      db.setSetting('chain_last_error', '');
    } on RtdbError catch (e) {
      // الرئيسي فصل الفرع: الكتابة اترفضت، فنتأكد في المرة الجاية
      if (e.denied) _membershipCheckedAt = null;
      db.setSetting('chain_last_error', e.denied ? 'الفرع الرئيسي مش قابل البيانات' : _errorText(e));
    } catch (e) {
      db.setSetting('chain_last_error', _errorText(e));
    }
  }
}

/// رد Firebase Realtime Database بخطأ. 401 = القواعد رفضت.
class RtdbError implements Exception {
  RtdbError(this.status, this.body);
  final int status;
  final String body;
  bool get denied => status == 401 || status == 403;
  @override
  String toString() => 'RTDB $status: $body';
}
