part of 'api_server.dart';

/// المالك من بره (أبلكيشن المالك على الأيفون أو أندرويد): بيشوف تقارير كل الفروع، وبيجيله إشعار مع كل قفل وردية
/// وتقرير كل يوم. كله على Firebase (own/$main في database.rules.json)، وكمبيوتر الكافيه هو اللي بيبعت الإشعارات.
///
/// - الفرع الرئيسي (أو الكافيه اللي مالوش فروع) بيعمل كود لمرة واحدة بيخلص بعد [_ownerCodeLife]، ويظهر QR بلينك
///   أبلكيشن المالك. المالك بيفتح اللينك ويعمل حساب، وبيبعت طلب بالكود، والرئيسي بيوافق لوحده لو الكود صح.
/// - الرئيسي بيكتب الفروع اللي تبعه (own/$main/shops)، وكل فرع بيكتب الرئيسي بتاعه (cafes/$uid/main): القواعد
///   بتدّي المالك يقرا تقارير الفرع بس لو الاتنين متفقين.
/// - مفاتيح الإشعارات (VAPID) بيعملها الرئيسي مرة واحدة: العام للمالك، والخاص للفروع اللي تبعه بس.
const _ownerCodeLife = Duration(minutes: 15);
const _ownerCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// بيبعت إشعار لاشتراك واحد (الاختبارات بتحط واحد وهمي).
typedef PushSender = Future<PushResult> Function(PushSubscriptionData sub, Map<String, Object?> message, P256Keys vapid);

extension _OwnerRoutes on OrderlyServer {
  void _registerOwnerRoutes(Router r) {
    r.get('/api/owner', _authed((req, u) => _ownerStatus(), only: {'owner'}));
    r.post('/api/owner/code', _authed(_newOwnerCode, only: {'owner'}));
    r.post('/api/owner/remove', _authed(_removeOwner, only: {'owner'}));
  }

  /// الجهاز ده هو اللي بيربط المالك؟ (الفرع الرئيسي أو كافيه مالوش فروع)
  bool get _isOwnerHub {
    final role = db.setting('chain_role') ?? '';
    return role != 'member' && role != 'pending';
  }

  Map<String, Object?>? _activeOwnerCode() {
    final raw = db.setting('owner_code');
    if (raw == null || raw.isEmpty) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return DateTime.now().millisecondsSinceEpoch < (j['exp'] as int) ? j : null;
  }

  String _ownerLink(String code) {
    final fb = _cloud!._fb;
    return Uri.parse('$menuSiteUrl/owner/')
        .replace(queryParameters: {'c': code, 'm': db.setting('cloud_uid')!, 'k': fb.apiKey, 'd': Uri.parse(fb.rtdb).host})
        .toString();
  }

  Future<Object?> _ownerStatus() async {
    final cloud = _cloud;
    final uid = db.setting('cloud_uid');
    final base = <String, Object?>{'hub': _isOwnerHub, 'ready': cloud != null && uid != null};
    if (cloud == null || uid == null || !_isOwnerHub) return base;
    final code = _activeOwnerCode();
    List<Map<String, Object?>> owners = const [];
    String? error;
    try {
      final ok = await cloud._getJson('own/$uid/ok');
      owners = [
        if (ok is Map)
          for (final e in ok.entries)
            {'uid': e.key, 'name': (e.value as Map)['name'], 'email': (e.value as Map)['email'], 'at': (e.value as Map)['at']},
      ];
    } catch (e) {
      error = cloud._errorText(e);
    }
    return {
      ...base,
      'owners': owners,
      'error': error,
      'code': code == null ? null : {'code': code['c'], 'exp': DateTime.fromMillisecondsSinceEpoch(code['exp'] as int).toUtc().toIso8601String(), 'link': _ownerLink(code['c'] as String)},
    };
  }

  Future<Object?> _newOwnerCode(Request req, AuthUser u) async {
    final cloud = _cloud;
    if (cloud == null || db.setting('cloud_uid') == null) throw ApiError(503, 'الكمبيوتر ده لسه مااتوصلش بالنت. استنى دقيقة وجرّب تاني');
    if (!_isOwnerHub) throw ApiError(400, 'ربط المالك بيتعمل من الفرع الرئيسي');
    final rnd = Random.secure();
    final code = [for (var i = 0; i < 8; i++) _ownerCodeAlphabet[rnd.nextInt(_ownerCodeAlphabet.length)]].join();
    final exp = DateTime.now().add(_ownerCodeLife).millisecondsSinceEpoch;
    db.setSetting('owner_code', jsonEncode({'c': code, 'exp': exp}));
    await cloud._online(() => cloud._syncOwner(force: true));
    _audit(u.id, 'owner.code', 'owner', null, 'كود ربط المالك');
    return _ownerStatus();
  }

  Future<Object?> _removeOwner(Request req, AuthUser u) async {
    final body = await _body(req);
    final uid = _field<String>(body, 'uid') ?? '';
    if (!_firebaseUidRe.hasMatch(uid)) throw ApiError(400, 'الحساب ده مش موجود');
    final cloud = _cloud ?? (throw ApiError(503, 'مفيش ربط بالنت'));
    final me = db.setting('cloud_uid')!;
    await cloud._online(() => cloud._patch({'own/$me/ok/$uid': null, 'own/$me/push/$uid': null}));
    _audit(u.id, 'owner.remove', 'owner', uid, null);
    return _ownerStatus();
  }
}

/// كل كلام المالك مع Firebase.
extension _OwnerSync on CloudSync {
  /// الرئيسي بتاع الجهاز ده على Firebase (نفسه، أو الرئيسي اللي وافق عليه لو هو فرع).
  String? get _mainUid => server._isOwnerHub ? _uid : db.setting('chain_main_uid');

  /// بيتنادى مع كل مزامنة: كل فرع بيكتب الرئيسي بتاعه، والرئيسي بيكتب مفاتيح الإشعارات والفروع والكود، ويوافق على طلبات المالك.
  Future<void> _syncOwner({bool force = false}) async {
    if (_uid == null) return;
    try {
      final updates = <String, Object?>{};
      final main = _mainUid;
      if (main != null) _put(updates, 'cafes/$_uid/main', main);
      if (server._isOwnerHub) {
        _put(updates, 'own/$_uid/vapid', {'pub': b64url(_vapidKeys().publicKey), 'priv': db.setting('vapid_priv')});
        final now = DateTime.now();
        if (force || _ownerShopsAt == null || now.difference(_ownerShopsAt!) > const Duration(minutes: 10)) {
          _ownerShopsAt = now;
          _put(updates, 'own/$_uid/shops', await _ownerShops());
        }
        final code = server._activeOwnerCode();
        _put(updates, 'own/$_uid/code', code == null ? null : {'c': code['c'], 'exp': code['exp']});
      }
      if (updates.isNotEmpty) await _patch(updates);
      if (server._isOwnerHub && server._activeOwnerCode() != null) await _approveOwnerClaims();
      db.setSetting('owner_last_error', '');
    } on RtdbError catch (e) {
      _sent.removeWhere((k, _) => k.startsWith('own/') || k.startsWith('cafes/$_uid/main'));
      db.setSetting('owner_last_error', '$e');
      if (force) rethrow;
    } catch (e) {
      db.setSetting('owner_last_error', _errorText(e));
      if (force) rethrow;
    }
  }

  P256Keys _vapidKeys() {
    final saved = db.setting('vapid_priv');
    if (saved != null && saved.isNotEmpty) return P256Keys.fromPrivate(unb64url(saved));
    final keys = P256Keys.generate();
    db.setSetting('vapid_priv', b64url(keys.privateKey));
    return keys;
  }

  /// الكافيه ده + الفروع المربوطة بيه (لو هو الرئيسي).
  Future<Map<String, Object?>> _ownerShops() async {
    final names = server._localNames();
    final shops = <String, Object?>{_uid!: {'name': names.shop, 'branch': names.branch}};
    if ((db.setting('chain_role') ?? '') == 'main') {
      final (chain, _) = await readChain();
      final members = chain?['members'];
      if (members is Map) {
        for (final e in members.entries) {
          final m = e.value is Map ? e.value as Map : const {};
          shops['${e.key}'] = {'name': m['name'] ?? '', 'branch': m['branch'] ?? ''};
        }
      }
    }
    return shops;
  }

  /// طلبات ربط بالكود الصح: الرئيسي بيوافق، والكود بيتلغي (لمرة واحدة).
  Future<void> _approveOwnerClaims() async {
    final code = server._activeOwnerCode();
    if (code == null) return;
    final claims = await _getJson('own/$_uid/claim');
    if (claims is! Map) return;
    final updates = <String, Object?>{};
    var approved = 0;
    for (final e in claims.entries) {
      final c = e.value is Map ? e.value as Map : const {};
      updates['own/$_uid/claim/${e.key}'] = null;
      if (c['c'] != code['c'] || !_firebaseUidRe.hasMatch('${e.key}')) continue;
      updates['own/$_uid/ok/${e.key}'] = {'name': c['name'], 'email': c['email'], 'at': {'.sv': 'timestamp'}};
      approved++;
    }
    if (approved > 0) {
      db.setSetting('owner_code', '');
      updates['own/$_uid/code'] = null;
      _sent.remove('own/$_uid/code');
      server._audit(null, 'owner.linked', 'owner', null, '$approved');
      server._broadcast('owner');
    }
    if (updates.isNotEmpty) await _patch(updates);
  }

  // ---------------------------------------------------------------- الفرع وهو شغال

  /// ملخص الفرع دلوقتي (live/{uid}) للمالك: مبيعات النهارده، والحسابات المفتوحة، والترابيزات، والدرج، والطلبات المستنية.
  /// مرة في الدقيقة بالكتير لو اتغير، ونبضة كل 5 دقايق (المالك بيعرف منها إن الفرع شغال).
  Future<void> _pushLive() async {
    if (_uid == null || _idToken == null || _stopped) return;
    final now = DateTime.now();
    final last = DateTime.tryParse(_sent['live-at'] ?? '');
    if (last != null && now.difference(last) < const Duration(seconds: 55)) return;
    try {
      final j = jsonEncode(await server._branchSummary());
      if (_sent['live-j'] == j && last != null && now.difference(last) < const Duration(minutes: 5)) return;
      await _patch({'live/$_uid': {'j': j, 'at': {'.sv': 'timestamp'}}});
      _sent['live-j'] = j;
      _sent['live-at'] = now.toIso8601String();
    } catch (e) {
      db.setSetting('owner_last_error', 'الملخص اللايف: ${_errorText(e)}');
    }
  }

  // ---------------------------------------------------------------- الإشعارات

  Set<String> _pushDone() => ((jsonDecode(db.setting('push_done') ?? '[]') as List).cast<String>()).toSet();

  /// بيبعت إشعار للمالك عن كل وردية اتقفلت وكل يوم خلص (مرة واحدة لكل حاجة، حتى لو الكمبيوتر اتقفل وفتح).
  Future<void> _notifyOwner(List<(String, Map<String, Object?>)> events) async {
    if (events.isEmpty) return;
    final done = _pushDone();
    final fresh = events.where((e) => !done.contains(e.$1)).toList();
    if (fresh.isEmpty) return;
    // بنعلّمهم الأول: لو الإرسال فشل مش هنبعت نفس الإشعار مرتين (الأهم مايتكررش)
    db.setSetting('push_done', jsonEncode([...done, ...fresh.map((e) => e.$1)].reversed.take(300).toList().reversed.toList()));
    final main = _mainUid;
    if (main == null) return;
    try {
      final subs = await _getJson('own/$main/push');
      if (subs is! Map || subs.isEmpty) return;
      final vapid = server._isOwnerHub ? _vapidKeys() : P256Keys.fromPrivate(unb64url('${await _getJson('own/$main/vapid/priv')}'));
      final gone = <String, Object?>{};
      for (final (_, msg) in fresh) {
        for (final owner in subs.entries) {
          if (owner.value is! Map) continue;
          for (final dev in (owner.value as Map).entries) {
            try {
              final s = PushSubscriptionData.fromJson((jsonDecode('${(dev.value as Map)['s']}') as Map).cast<String, dynamic>());
              final result = await server.pushSender(s, msg, vapid);
              if (result == PushResult.gone) gone['own/$main/push/${owner.key}/${dev.key}'] = null;
            } catch (e) {
              db.setSetting('owner_last_error', 'الإشعار ماوصلش: ${_errorText(e)}');
            }
          }
        }
      }
      // الموبايل لغى الإشعارات: الرئيسي بس اللي يقدر يمسح الاشتراك
      if (gone.isNotEmpty && server._isOwnerHub) await _patch(gone);
    } catch (e) {
      db.setSetting('owner_last_error', 'الإشعارات: ${_errorText(e)}');
    }
  }
}

/// نص الإشعار لوردية اتقفلت.
Map<String, Object?> shiftPushMessage(Map<String, Object?> r, String cafeUid) {
  final diff = r['diffCents'] as int?;
  final drawer = diff == null ? '' : diff == 0 ? ' • الدرج مظبوط' : diff > 0 ? ' • الدرج زيادة ${money(diff)}' : ' • الدرج ناقص ${money(-diff)}';
  return {
    'title': 'قفل وردية • ${r['branch'] ?? r['shop'] ?? ''}',
    'body': 'المبيعات ${money(r['salesCents'] as int? ?? 0)} • ${r['checksClosed'] ?? 0} حساب$drawer • ${r['closedBy'] ?? ''}',
    'url': './?shop=$cafeUid&date=${r['date']}',
    'tag': 'shift-${r['id']}',
  };
}

/// نص الإشعار لتقرير يوم خلص.
Map<String, Object?> dayPushMessage(Map<String, Object?> r, String cafeUid) {
  final s = (r['sales'] as Map?) ?? const {};
  return {
    'title': 'تقرير يوم ${r['date']} • ${r['branch'] ?? r['shop'] ?? ''}',
    'body': 'الإجمالي ${money(s['totalCents'] as int? ?? 0)} • ${s['checks'] ?? 0} حساب • متوسط ${money(s['avgCheckCents'] as int? ?? 0)}',
    'url': './?shop=$cafeUid&date=${r['date']}',
    'tag': 'day-${r['date']}-$cafeUid',
  };
}
