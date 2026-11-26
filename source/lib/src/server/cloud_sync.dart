part of 'api_server.dart';

/// الربط مع منيو العملاء على النت (Firebase Realtime Database).
///
/// - الكافيه بيبعت: بياناته وطرق الدفع، والمنيو وصوره، وأكواد الترابيزات،
///   وحالة كل طلب وحساب كل ترابيزة (عشان العميل يتابع من موبايله).
/// - العميل بيكتب في inbox/{cafe}: طلب، نداء ويتر، طلب حساب، دفع (ومعاه صورة التحويل في proof/{cafe})، تقييم.
///   الكمبيوتر بيسمع على inbox لحظياً (Server-Sent Events)، ولو الاتصال وقع بيرجع يقرا كل شوية.
///
/// كل كافيه ليه حساب Firebase خاص بيه بيتعمل أوتوماتيك أول مرة، وقواعد قاعدة البيانات
/// بتمنع أي كافيه يقرا أو يعدّل بيانات كافيه تاني. لو مفيش نت، الكافيه بيشتغل عادي بالويتر.
class CloudSync {
  CloudSync(this.server);

  final OrderlyServer server;

  /// الاتصال بيفضل مفتوح دقيقتين (المزامنة كل دقيقة): كل اتصال جديد بيكلّف حوالي 3.5 كيلو تشفير على حساب Firebase.
  final http.Client _http = IOClient(HttpClient()..idleTimeout = const Duration(minutes: 2));
  http.Client? _streamClient;
  Timer? _pushTimer;
  Timer? _pollTimer;
  Timer? _reconnect;
  bool _busy = false;
  bool _stopped = false;
  bool _pending = false;
  bool live = false;
  final Set<String> _dirty = {'shop', 'menu', 'tables', 'checks'};

  /// آخر حاجة اتبعتت لكل مسار (عشان ما نبعتش نفس البيانات تاني).
  final Map<String, String> _sent = {};
  final Set<String> _processing = {};

  String? _idToken;
  DateTime _idTokenExpiry = DateTime(2000);
  String? _uid;

  /// الفروع (routes_branches.dart): آخر قراية للربط، وآخر مرة الملخص اتبعت، وآخر تأكد إن الفرع لسه مربوط.
  (DateTime, Map<String, Object?>)? _chainCache;
  DateTime? _chainSyncedAt;
  DateTime? _membershipCheckedAt;

  /// المالك (routes_owner.dart): آخر مرة قايمة الفروع اتكتبت، والإشعارات اللي طالعة من آخر تقارير.
  DateTime? _ownerShopsAt;
  List<(String, Map<String, Object?>)> _ownerEvents = const [];

  AppDb get db => server.db;
  FirebaseEndpoints? _endpoints;
  FirebaseEndpoints get _fb => _endpoints ?? server.firebase ?? FirebaseEndpoints.live;

  void start() {
    if (_fb.apiKey.isEmpty) return;
    // كل دقيقة: العروض اللي بتبدأ وتخلص بالساعة، وإن الكافيه لسه شغال
    _pushTimer = Timer.periodic(const Duration(minutes: 1), (_) => kick('tick'));
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!live) _pollInbox();
    });
    Timer(const Duration(seconds: 2), () async {
      _endpoints = await server._resolveFirebase();
      await _run();
      _listen();
    });
  }

  void stop() {
    _stopped = true;
    _pushTimer?.cancel();
    _pollTimer?.cancel();
    _reconnect?.cancel();
    _streamClient?.close();
    _http.close();
  }

  /// كود تفعيل جديد ممكن يكون فيه مشروع Firebase تاني: المزامنة بتنقل عليه.
  Future<void> reloadProject() async {
    final next = await server._resolveFirebase();
    if (next.rtdb == _fb.rtdb && next.apiKey == _fb.apiKey) return;
    _endpoints = next;
    _idToken = null;
    _streamClient?.close(); // الاستماع بيرجع يتصل لوحده على المشروع الجديد
    await runNow();
  }

  Future<void> runNow() async {
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _dirty.addAll(['shop', 'menu', 'tables', 'checks']);
    _sent.clear();
    _chainSyncedAt = null;
    _membershipCheckedAt = null;
    await _run();
    await _pollInbox();
  }

  /// بعد أي تعديل بنبعت بسرعة (ونجمّع التعديلات اللي ورا بعض في مرة واحدة).
  void kick(String topic) {
    _dirty.add(topic);
    if (_pending) return;
    _pending = true;
    Timer(const Duration(milliseconds: 600), () {
      _pending = false;
      _run();
    });
  }

  Future<void> _run() async {
    if (_stopped) return;
    if (_busy) {
      Timer(const Duration(seconds: 1), _run);
      return;
    }
    if (db.selectOne('SELECT id FROM shop LIMIT 1') == null) return;
    _busy = true;
    final topics = {..._dirty};
    _dirty.clear();
    try {
      await _pushCafe(topics);
      await _pushReports(topics);
    } finally {
      _busy = false;
    }
    // الفروع لوحدها: لو الفرع الرئيسي رفض الكتابة، منيو العملاء مايتأثرش
    if (!_stopped && _idToken != null) await _syncChain();
    if (!_stopped && _idToken != null) await _syncOwner();
  }

  /// المنيو والترابيزات ومتابعة العملاء. لو الكتابة فشلت (النت قطع لحظة)، اللي اتعلّم "اتبعت" بيرجع يتبعت في الدورة الجاية.
  Future<void> _pushCafe(Set<String> topics) async {
    final sentBefore = Map.of(_sent);
    try {
      await _token();
      final updates = <String, Object?>{};
      if (topics.contains('shop')) _logoCache = null;
      await _prepareLogo();
      _addPub(updates);
      if (topics.intersection({'menu', 'tick', 'shop', 'stock'}).isNotEmpty) await _addMenu(updates);
      if (topics.contains('tables') || topics.contains('shop')) await _addTables(updates);
      _addTracking(updates);
      await _patch(updates);
      db.setSetting('cloud_last_sync', nowIso());
      db.setSetting('cloud_last_error', '');
    } catch (e) {
      _sent
        ..clear()
        ..addAll(sentBefore);
      _dirty.addAll(topics);
      db.setSetting('cloud_last_error', _errorText(e));
    }
  }

  /// تقارير المالك في كتابة لوحدها: Firebase بيرفض الكتابة كلها لو جزء منها اترفض،
  /// فأي مشكلة في التقارير ماتوقفش منيو العملاء ومتابعة الطلبات.
  Future<void> _pushReports(Set<String> topics) async {
    if (_uid == null || _idToken == null || _stopped) return;
    final sentBefore = Map.of(_sent);
    try {
      final reports = <String, Object?>{};
      final reportDay = _addReports(reports, topics);
      await _patch(reports);
      db.setSetting('report_last_day', reportDay);
      await _notifyOwner(_ownerEvents);
      db.setSetting('report_last_error', '');
    } catch (e) {
      _sent
        ..clear()
        ..addAll(sentBefore);
      if (topics.contains('register')) _dirty.add('register');
      db.setSetting('report_last_error', _errorText(e));
    }
  }

  String _errorText(Object e) =>
      e is SocketException || e is TimeoutException || e is http.ClientException ? 'مفيش نت' : '$e';

  // ---------------------------------------------------------------- auth

  /// الحساب والكافيه على Firebase بيتعملوا من الأول: المحل اتنقل لمشروع تاني، أو حسابه اتمسح من Firebase.
  /// كود الكافيه بيتغير، فلينكات الـ QR بتتغير (الشاشة بتقول للمالك يطبعها تاني).
  void _resetIdentity() {
    // كان فيه كود كافيه قبل كده، يعني فيه QR مطبوع بقى قديم
    if (db.setting('cloud_uid') != null) db.setSetting('cloud_qr_reprint', nowIso());
    db.execute(
      "DELETE FROM settings WHERE key IN ('cloud_email', 'cloud_password', 'cloud_refresh_token', 'cloud_uid', 'cloud_imgs', 'cloud_table_keys', 'cloud_track_clients')",
    );
    _idToken = null;
    _uid = null;
    _sent.clear();
    _dirty.addAll(['shop', 'menu', 'tables', 'checks']);
    // ربط الفروع كان على المشروع القديم
    if ((db.setting('chain_role') ?? '').isNotEmpty) server._setChain(null);
  }

  Future<String> _token() async {
    // نسخ قبل كده كانت على المشروع الأساسي بس (مفيش cloud_db)
    if ((db.setting('cloud_db') ?? rtdbUrl) != _fb.rtdb) {
      _resetIdentity();
      db.setSetting('cloud_db', _fb.rtdb);
    }
    if (_idToken != null && DateTime.now().isBefore(_idTokenExpiry)) return _idToken!;
    final refresh = db.setting('cloud_refresh_token');
    if (refresh != null && refresh.isNotEmpty) {
      final res = await _http.post(
        Uri.parse('${_fb.token}/v1/token?key=${_fb.apiKey}'),
        body: {'grant_type': 'refresh_token', 'refresh_token': refresh},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        return _saveAuth(j['id_token'] as String, j['refresh_token'] as String, j['user_id'] as String, j['expires_in']);
      }
    }
    var email = db.setting('cloud_email');
    var password = db.setting('cloud_password');
    var endpoint = 'signInWithPassword';
    if (email == null || password == null) {
      email = 'cafe-${db.setting('server_id')}@cafes.orderly.app';
      password = randomToken();
      db.setSetting('cloud_email', email);
      db.setSetting('cloud_password', password);
      endpoint = 'signUp';
    }
    final res = await _http
        .post(
          Uri.parse('${_fb.auth}/v1/accounts:$endpoint?key=${_fb.apiKey}'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password, 'returnSecureToken': true}),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      // الحساب مش موجود على Firebase (اتمسح من الكونسول): حساب جديد، وكل حاجة تتبعت تاني
      if (endpoint == 'signInWithPassword' && RegExp('EMAIL_NOT_FOUND|INVALID_LOGIN_CREDENTIALS|INVALID_PASSWORD|USER_DISABLED').hasMatch(res.body)) {
        _resetIdentity();
        return _token();
      }
      throw Exception('Firebase auth ${res.statusCode}: ${res.body}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return _saveAuth(j['idToken'] as String, j['refreshToken'] as String, j['localId'] as String, j['expiresIn']);
  }

  String _saveAuth(String idToken, String refreshToken, String uid, Object? expiresIn) {
    final first = db.setting('cloud_uid') == null;
    db.setSetting('cloud_refresh_token', refreshToken);
    db.setSetting('cloud_uid', uid);
    _uid = uid;
    _idToken = idToken;
    final seconds = int.tryParse('$expiresIn') ?? 3600;
    _idTokenExpiry = DateTime.now().add(Duration(seconds: seconds - 120));
    // أول مرة الكافيه يتسجل: لينكات الـ QR بقت جاهزة
    if (first) server._broadcast('tables');
    return idToken;
  }

  Uri _url(String path, [Map<String, String>? query]) =>
      Uri.parse('${_fb.rtdb}/$path.json').replace(queryParameters: {'auth': _idToken!, ...?query});

  /// كتابة من غير ما Firebase يرجّع اللي اتكتب (print=silent): الرد 204 فاضي بدل نسخة كاملة بتتحسب تنزيل.
  Uri _writeUrl(String path) => _url(path, const {'print': 'silent'});

  static bool _ok(int status) => status == 200 || status == 204;

  Future<void> _patch(Map<String, Object?> updates) async {
    if (updates.isEmpty) return;
    final res = await _http.patch(_writeUrl(''), body: jsonEncode(updates), headers: {'content-type': 'application/json'}).timeout(const Duration(seconds: 30));
    if (!_ok(res.statusCode)) throw RtdbError(res.statusCode, res.body);
  }

  Future<void> _delete(String path) async {
    final res = await _http.delete(_writeUrl(path)).timeout(const Duration(seconds: 20));
    if (!_ok(res.statusCode)) throw RtdbError(res.statusCode, res.body);
  }

  /// بيضيف المسار للتحديث لو اتغير عن آخر مرة اتبعت.
  void _put(Map<String, Object?> updates, String path, Object? value) {
    final encoded = jsonEncode(value);
    if (_sent[path] == encoded) return;
    _sent[path] = encoded;
    updates[path] = value;
  }

  // ---------------------------------------------------------------- push: الكافيه والمنيو

  bool get _acceptingOrders =>
      server._cafeBool('qrEnabled') && (!server._cafeBool('qrNeedsOpenRegister') || server._openRegisterId() != null);

  void _addPub(Map<String, Object?> updates) {
    final shop = server._shopJson();
    final s = server._cafe;
    final off = <String, bool>{
      for (final r in db.select('SELECT id FROM items WHERE active = 1 AND available = 0')) r['id'] as String: true,
      for (final id in server._soldOutItemIds()) id: true,
    };
    final pub = {
      'name': shop['name'],
      'branch': shop['branchName'],
      'phone': shop['phone'],
      'address': shop['address'],
      // اللوجو لوحده في cafes/{uid}/logo (pub بيتقري كل دقيقة)، وهنا رقم نسخته بس عشان الصفحة تعرف إنه اتغير
      'lv': _smallLogo() == null ? null : sha256Hex(_smallLogo()!).substring(0, 12),
      'welcome': s['qrWelcome'],
      'wifi': (s['wifiName'] as String? ?? '').isEmpty ? null : {'n': s['wifiName'], 'p': s['wifiPassword']},
      'langs': s['menuLanguages'],
      // الكافيه بيستقبل طلبات دلوقتي؟ (الصفحة بتقول للعميل لو مقفول)
      'open': _acceptingOrders,
      // الصفحة بتطلب الاسم والموبايل إجباري
      'contact': s['qrRequireContact'] != false,
      'svc': s['serviceBp'],
      'tax': s['taxBp'],
      'svcTk': s['serviceOnTakeaway'],
      'loyalty': s['loyaltyEnabled'] == true ? {'earn': s['loyaltyEarnCents'], 'value': s['loyaltyPointValue']} : null,
      'pay': db.select("SELECT * FROM pay_methods WHERE active = 1 AND show_in_qr = 1 ORDER BY sort, rowid").map((m) => {
            'id': m['id'],
            'n': m['name'],
            'k': m['kind'],
            'acc': m['account'],
            'link': m['link'],
            'ins': m['instructions'],
            'proof': m['needs_proof'] == 1,
          }).toList(),
      'off': off.isEmpty ? null : off,
    };
    _put(updates, 'cafes/$_uid/pub', pub);
    _put(updates, 'cafes/$_uid/logo', _smallLogo());
    // نبضة كل 5 دقايق: الصفحة بتعرف منها إن كمبيوتر الكافيه شغال
    final last = DateTime.tryParse(_sent['seen-at'] ?? '');
    if (last == null || DateTime.now().difference(last).inMinutes >= 5) {
      _sent['seen-at'] = DateTime.now().toIso8601String();
      updates['cafes/$_uid/seen'] = {'.sv': 'timestamp'};
    }
  }

  /// أطول ضلع لصورة الصنف على النت: الكارت 92px والموبايلات 2x، يعني 184px كفاية، والصورة الكبيرة في شاشة الصنف مقبولة.
  static const _thumbSide = 240;

  String? _logoCache;
  String? _smallLogo() => _logoCache == null || _logoCache!.isEmpty ? null : _logoCache;

  Future<void> _prepareLogo() async {
    if (_logoCache != null) return;
    final f = File(p.join(server.dataDir, 'logo.png'));
    if (!f.existsSync()) {
      _logoCache = '';
      return;
    }
    final bytes = f.readAsBytesSync();
    _logoCache = await smallLogoInBackground(bytes);
  }

  Future<void> _addMenu(Map<String, Object?> updates) async {
    final m = server._menuJson();
    final now = DateTime.now();
    final menu = {
      'cats': (m['categories'] as List).cast<Map<String, Object?>>().map((c) => {'id': c['id'], 'n': c['name'], 'ne': c['nameEn'], 'h': c['hours']}).toList(),
      'items': (m['items'] as List).cast<Map<String, Object?>>().where((i) => i['showInQr'] == true).map((i) => {
            'id': i['id'],
            'c': i['categoryId'],
            'n': i['name'],
            'ne': i['nameEn'],
            'd': i['description'],
            'de': i['descriptionEn'],
            'p': i['priceCents'],
            'pp': i['promoPriceCents'],
            'img': i['imageId'],
            'tags': (i['tags'] as List).isEmpty ? null : i['tags'],
            'up': (i['upsell'] as List).isEmpty ? null : i['upsell'],
            'g': (i['groupIds'] as List).isEmpty ? null : i['groupIds'],
          }).toList(),
      'groups': (m['modifierGroups'] as List).cast<Map<String, Object?>>().map((g) => {
            'id': g['id'],
            'n': g['name'],
            'ne': g['nameEn'],
            'min': g['minSelect'],
            'max': g['maxSelect'],
            'o': (g['options'] as List).cast<Map<String, Object?>>().map((o) => {'id': o['id'], 'n': o['name'], 'ne': o['nameEn'], 'p': o['priceCents'], 'def': o['isDefault']}).toList(),
          }).toList(),
    };
    final encoded = jsonEncode(menu);
    // رقم نسخة المنيو: الصفحة بتحتفظ بالمنيو عند العميل ومش بتنزّله تاني إلا لو اتغير
    final version = sha256Hex(encoded).substring(0, 12);
    if (_sent['cafes/$_uid/menu'] != encoded) {
      _sent['cafes/$_uid/menu'] = encoded;
      updates['cafes/$_uid/menu'] = {...menu, 'v': version, 'at': now.toUtc().toIso8601String()};
      updates['cafes/$_uid/mv'] = version;
    }

    // صور الأصناف: نسخة صغيرة لكل صورة، بتتبعت مرة واحدة بس.
    // لو مقاس النسخة اتغير (نسخة أقدم من البرنامج كانت بتبعت أكبر) بتتبعت كلها تاني مرة واحدة.
    final wanted = {for (final i in menu['items'] as List) if ((i as Map)['img'] != null) i['img'] as String};
    if (db.setting('cloud_img_size') != '$_thumbSide') {
      db.setSetting('cloud_imgs', '[]');
      db.setSetting('cloud_img_size', '$_thumbSide');
    }
    final sentImgs = ((jsonDecode(db.setting('cloud_imgs') ?? '[]') as List).cast<String>()).toSet();
    for (final id in wanted.difference(sentImgs).take(15)) {
      final f = File(p.join(server._filesDir.path, id));
      if (!f.existsSync()) continue;
      final bytes = f.readAsBytesSync();
      final thumb = await shrinkInBackground(bytes, _thumbSide, 60);
      if (thumb == null) continue;
      updates['img/$_uid/$id'] = base64.encode(thumb);
      sentImgs.add(id);
    }
    for (final id in sentImgs.difference(wanted).toList()) {
      updates['img/$_uid/$id'] = null;
      sentImgs.remove(id);
    }
    db.setSetting('cloud_imgs', jsonEncode(sentImgs.toList()));
    if (wanted.difference(sentImgs).isNotEmpty) _dirty.add('menu'); // الباقي في الدورة الجاية
  }

  Future<void> _addTables(Map<String, Object?> updates) async {
    final tables = <String, Object?>{
      for (final t in db.select('SELECT t.*, a.name AS area FROM tables t LEFT JOIN areas a ON a.id = t.area_id WHERE t.active = 1'))
        t['qr_key'] as String: {'id': t['id'], 'n': t['name'], 'a': t['area']},
      server._takeawayKey: {'id': 'takeaway', 'n': 'تيك أواي', 'tk': true},
    };
    // الأكواد القديمة (ترابيزة اتقفلت أو كودها اتغير) لازم تتمسح من النت
    final old = ((jsonDecode(db.setting('cloud_table_keys') ?? '[]') as List).cast<String>()).toSet();
    for (final k in old.difference(tables.keys.toSet())) {
      updates['cafes/$_uid/tables/$k'] = null;
      updates['trackt/$_uid/$k'] = null;
      _sent.remove('trackt/$_uid/$k');
    }
    for (final e in tables.entries) {
      _put(updates, 'cafes/$_uid/tables/${e.key}', e.value);
    }
    db.setSetting('cloud_table_keys', jsonEncode(tables.keys.toList()));
  }

  // ---------------------------------------------------------------- push: متابعة العميل

  static const _statusAr = {
    'pending': 'مستني موافقة الكافيه',
    'accepted': 'بيتحضر',
    'ready': 'جاهز',
    'served': 'اتقدم',
    'rejected': 'اترفض',
    'cancelled': 'اتلغى',
  };

  /// حساب كل ترابيزة (trackt/{cafe}/{key}) وطلبات كل عميل (trackc/{cafe}/{client}).
  void _addTracking(Map<String, Object?> updates) {
    final since = DateTime.now().toUtc().subtract(const Duration(hours: 3)).toIso8601String();
    for (final t in db.select('SELECT * FROM tables WHERE active = 1')) {
      final open = db.selectOne("SELECT * FROM checks WHERE table_id = ? AND status = 'open'", [t['id']]);
      final recent = open ?? db.selectOne("SELECT * FROM checks WHERE table_id = ? AND status = 'closed' AND closed_at > ? ORDER BY closed_at DESC LIMIT 1", [t['id'], since]);
      _put(updates, 'trackt/$_uid/${t['qr_key']}', recent == null ? null : _billDoc(recent));
    }

    final clients = db.select(
      "SELECT DISTINCT client_id FROM orders WHERE client_id IS NOT NULL AND created_at > ?",
      [since],
    );
    // العميل اللي آخر طلب ليه عدّى عليه 3 ساعات: متابعته بتتمسح من النت (كانت بتفضل للأبد)
    final current = {for (final c in clients) c['client_id'] as String};
    final previous = ((jsonDecode(db.setting('cloud_track_clients') ?? '[]') as List).cast<String>()).toSet();
    for (final gone in previous.difference(current)) {
      updates['trackc/$_uid/$gone'] = null;
      _sent.remove('trackc/$_uid/$gone');
    }
    db.setSetting('cloud_track_clients', jsonEncode(current.toList()));
    for (final c in clients) {
      final clientId = c['client_id'] as String;
      final orders = db.select('SELECT * FROM orders WHERE client_id = ? AND created_at > ? ORDER BY created_at', [clientId, since]);
      final doc = <String, Object?>{};
      for (final o in orders) {
        final total = db.selectOne("SELECT COALESCE(SUM(qty * unit_price_cents), 0) AS s FROM order_items WHERE order_id = ? AND (status <> 'void' OR ? = 'rejected')", [o['id'], o['status']])!['s'];
        final check = o['check_id'] == null ? null : db.selectOne('SELECT number, type, status, total_cents, paid_cents FROM checks WHERE id = ?', [o['check_id']]);
        doc[o['cloud_id'] as String? ?? o['id'] as String] = {
          'n': o['number'],
          's': o['status'],
          'sl': _statusAr[o['status']],
          'r': o['reject_reason'],
          't': total,
          'at': o['created_at'],
          // التيك أواي: العميل بيشوف حسابه هو بس
          if (check != null && check['type'] != 'dine_in') 'bill': {'n': check['number'], 'total': check['total_cents'], 'paid': check['paid_cents'], 'closed': check['status'] != 'open'},
        };
      }
      final pays = db.select("SELECT p.cloud_id, p.status, p.reject_reason, p.amount_cents FROM payments p WHERE p.cloud_id IS NOT NULL AND p.created_at > ? AND p.payer = ?", [since, clientId]);
      // حساب ترابيزة العميل جوه متابعته هو: الصفحة بتفتح اتصال واحد بس بدل اتنين (الكتابة ببلاش، والتنزيل واحد)
      final table = db.selectOne(
        "SELECT c.*, t.qr_key FROM orders o JOIN checks c ON c.id = o.check_id JOIN tables t ON t.id = c.table_id "
        "WHERE o.client_id = ? AND o.created_at > ? AND c.type = 'dine_in' ORDER BY o.created_at DESC LIMIT 1",
        [clientId, since],
      );
      _put(updates, 'trackc/$_uid/$clientId', {
        // v2: فيه tb، والصفحة مش محتاجة تسمع على trackt
        'v': 2,
        'tb': table == null ? null : {'k': table['qr_key'], ..._billDoc(table)},
        'orders': doc.isEmpty ? null : doc,
        'pays': pays.isEmpty ? null : {for (final p in pays) p['cloud_id'] as String: {'s': p['status'], 'r': p['reject_reason'], 'a': p['amount_cents']}},
      });
    }
  }

  // ---------------------------------------------------------------- push: تقارير المالك

  /// تقرير كل يوم شغل (rep/{cafe}/{يوم}/day) وكل وردية اتقفلت (rep/{cafe}/{يوم}/shifts/{id}).
  /// - النهارده: مع كل حركة درج (فتح، مصروف، قفل)، فالمالك بيشوف اليوم لحد آخر تسليم.
  /// - امبارح: كل دورة، بس بيتبعت لو اتغير (التقرير النهائي أول ما اليوم يخلص، وأي تصحيح بعدها).
  /// - لو الكمبيوتر كان مقفول كام يوم، الأيام اللي فاتت بتتبعت (لحد شهر).
  /// بيرجع تاريخ النهارده عشان يتحفظ بعد ما الكتابة تنجح.
  String _addReports(Map<String, Object?> updates, Set<String> topics) {
    final bd = server._bday;
    final today = bd.dateOf(DateTime.now());
    DateTime day(int offset) => DateTime(today.year, today.month, today.day + offset);
    final days = <DateTime>{day(-1)};
    if (topics.contains('register')) days.add(today);
    final last = BusinessDay.parseKey(db.setting('report_last_day'));
    if (last != null) {
      for (var d = DateTime(last.year, last.month, last.day); d.isBefore(day(-1)) && days.length < 32; d = DateTime(d.year, d.month, d.day + 1)) {
        days.add(d);
      }
    }
    // إشعارات المالك: كل يوم خلص (آخر يومين بس لو الكمبيوتر كان مقفول) وكل وردية اتقفلت
    final events = <(String, Map<String, Object?>)>[];
    for (final d in days) {
      final report = server._dayReport(d);
      _putReport(updates, 'rep/$_uid/${BusinessDay.keyOf(d)}/day', report);
      if (d.isBefore(today) && !d.isBefore(day(-2))) events.add(('day:${BusinessDay.keyOf(d)}', dayPushMessage(report, _uid!)));
    }
    final since = DateTime.now().toUtc().subtract(const Duration(hours: 48)).toIso8601String();
    for (final s in db.select('SELECT * FROM register_sessions WHERE closed_at IS NOT NULL AND closed_at > ?', [since])) {
      final r = server._shiftReport(s);
      events.add(('shift:${s['id']}', shiftPushMessage(r, _uid!)));
      _putReport(updates, 'rep/$_uid/${r['date']}/shifts/${s['id']}', r);
    }
    _ownerEvents = events;
    return BusinessDay.keyOf(today);
  }

  void _putReport(Map<String, Object?> updates, String path, Map<String, Object?> report) {
    final j = jsonEncode(report);
    if (_sent[path] == j) return;
    _sent[path] = j;
    updates[path] = {'j': j, 'at': {'.sv': 'timestamp'}};
  }

  Map<String, Object?> _billDoc(Map<String, Object?> c) {
    final items = db.select(
      "SELECT oi.* FROM order_items oi JOIN orders o ON o.id = oi.order_id WHERE oi.check_id = ? AND oi.status <> 'void' AND o.status NOT IN ('pending', 'rejected', 'cancelled') ORDER BY oi.created_at",
      [c['id']],
    );
    final pending = db.selectOne("SELECT COALESCE(SUM(amount_cents), 0) AS s FROM payments WHERE check_id = ? AND status = 'pending'", [c['id']])!['s'];
    return {
      'n': c['number'],
      'closed': c['status'] != 'open',
      'items': items.map((i) => {
            'n': i['name'],
            'q': i['qty'],
            'p': i['unit_price_cents'],
            'm': (jsonDecode(i['modifiers'] as String) as List).map((m) => (m as Map)['name']).join('، '),
            'g': i['guest'],
            's': i['status'],
          }).toList(),
      'sub': c['subtotal_cents'],
      'disc': (c['discount_cents'] as int) + (c['points_used'] as int) * server._cafeInt('loyaltyPointValue'),
      'svc': c['service_cents'],
      'tax': c['tax_cents'],
      'total': c['total_cents'],
      'paid': c['paid_cents'],
      'pend': pending,
      'bill': c['bill_requested'] == 1,
    };
  }

  // ---------------------------------------------------------------- pull: طلبات العملاء

  /// بيسمع على inbox لحظياً. الاتصال بيقع كل ساعة (التوكن بيخلص) أو لو النت قطع، فبيرجع يتصل.
  Future<void> _listen() async {
    if (_stopped) return;
    _reconnect?.cancel();
    _streamClient?.close();
    final client = _streamClient = http.Client();
    try {
      await _token();
      final req = http.Request('GET', _url('inbox/$_uid'))..headers['accept'] = 'text/event-stream';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('RTDB stream ${res.statusCode}');
      live = true;
      server._broadcast('cloud');
      String? event;
      await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          final data = line.substring(5).trim();
          if (event == 'auth_revoked' || event == 'cancel') break;
          if ((event == 'put' || event == 'patch') && data != 'null') _onStreamData(data);
        }
      }
    } catch (_) {
      // هنرجع نتصل تاني
    } finally {
      if (live) {
        live = false;
        server._broadcast('cloud');
      }
      if (!_stopped) _reconnect = Timer(const Duration(seconds: 5), _listen);
    }
  }

  void _onStreamData(String data) {
    try {
      final j = jsonDecode(data) as Map<String, dynamic>;
      final path = j['path'] as String? ?? '/';
      final value = j['data'];
      if (value == null) return;
      if (path == '/') {
        if (value is Map) {
          for (final e in value.entries) {
            _handle(e.key as String, e.value);
          }
        }
      } else {
        // رسالة واحدة جديدة: /{id}
        final id = path.split('/').where((s) => s.isNotEmpty).first;
        if (path.split('/').where((s) => s.isNotEmpty).length == 1) _handle(id, value);
      }
    } catch (_) {}
  }

  Future<void> _pollInbox() async {
    if (_stopped || db.setting('cloud_uid') == null) return;
    try {
      await _token();
      final res = await _http.get(_url('inbox/$_uid')).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.body == 'null') return;
      final all = jsonDecode(res.body);
      if (all is Map) {
        for (final e in all.entries) {
          await _handle(e.key as String, e.value);
        }
      }
    } catch (e) {
      db.setSetting('cloud_last_error', _errorText(e));
    }
  }

  Future<void> _handle(String cloudId, Object? raw) async {
    if (!_processing.add(cloudId)) return;
    try {
      if (raw is Map) {
        final msg = raw.cast<String, dynamic>();
        List<int>? proof;
        if (msg['p'] == true) {
          final raw = await _fetchProof(cloudId);
          if (raw != null) proof = await shrinkInBackground(raw, 1400, 80);
        }
        try {
          server._ingestCloudMessage(cloudId, msg, proof);
        } catch (e) {
          stderr.writeln('cloud message $cloudId: $e');
        }
        if (msg['p'] == true) await _delete('proof/$_uid/$cloudId');
      }
      await _delete('inbox/$_uid/$cloudId');
      kick('orders');
    } catch (e) {
      db.setSetting('cloud_last_error', _errorText(e));
    } finally {
      _processing.remove(cloudId);
    }
  }

  Future<List<int>?> _fetchProof(String cloudId) async {
    // الصورة ممكن توصل بعد الرسالة بشوية
    for (var i = 0; i < 4; i++) {
      final res = await _http.get(_url('proof/$_uid/$cloudId/d')).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200 && res.body != 'null') {
        final s = jsonDecode(res.body) as String;
        return base64.decode(s.contains(',') ? s.substring(s.indexOf(',') + 1) : s);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  /// بيمسح كل بيانات الكافيه من النت، ومعاها حساب الكافيه (للاختبارات بس).
  Future<void> deleteEverything() async {
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _busy = true;
    try {
      await _token();
      final role = db.setting('chain_role') ?? '';
      if (role.isNotEmpty) {
        try {
          await leaveChain(role, _cid);
        } on ApiError {
          // مفيش نت: الاختبار نفسه هيفشل في المسح اللي بعده
        }
      }
      await _patch({for (final root in ['cafes', 'img', 'inbox', 'proof', 'trackt', 'trackc', 'rep', 'own']) '$root/$_uid': null});
      await _http.post(
        Uri.parse('${_fb.auth}/v1/accounts:delete?key=${_fb.apiKey}'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'idToken': _idToken}),
      );
    } finally {
      _busy = false;
    }
  }
}

/// تحويل رسائل العملاء (من الـ QR) لطلبات ونداءات ودفعات.
extension _CloudIngest on OrderlyServer {
  void _ingestCloudMessage(String cloudId, Map<String, dynamic> msg, List<int>? proof) {
    final key = msg['k'] as String? ?? '';
    final clientId = (msg['c'] as String? ?? '').trim();
    if (clientId.isEmpty || clientId.length > 64) return;
    Map<String, dynamic> body;
    try {
      body = (jsonDecode(msg['j'] as String? ?? '{}') as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final table = db.selectOne('SELECT * FROM tables WHERE qr_key = ? AND active = 1', [key]);
    final takeaway = key == _takeawayKey;
    if (table == null && !takeaway) return;
    final at = msg['at'] is int ? DateTime.fromMillisecondsSinceEpoch(msg['at'] as int) : DateTime.now();

    switch (msg['t']) {
      case 'order':
        _ingestOrder(cloudId, clientId, table, body, at, proof);
      case 'call':
        if (table == null || DateTime.now().difference(at).inMinutes > 30) return;
        _ingestCall(cloudId, table, body);
      case 'pay':
        _ingestPayment(cloudId, clientId, table, body, proof);
      case 'fb':
        final rating = body['r'];
        if (rating is! int || rating < 1 || rating > 5) return;
        final comment = _text(body['cm']);
        final check = db.selectOne('SELECT id FROM checks WHERE id IN (SELECT check_id FROM orders WHERE client_id = ?) ORDER BY opened_at DESC LIMIT 1', [clientId]);
        db.execute('INSERT OR IGNORE INTO feedback(id, check_id, table_id, rating, comment, cloud_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)',
            [_uuid.v4(), check?['id'], table?['id'], rating, comment.isEmpty ? null : comment.substring(0, min(comment.length, 500)), cloudId, nowIso()]);
        _broadcast('feedback');
    }
  }

  /// الطلبات اللي فات عليها أكتر من كده (مثلاً الكمبيوتر كان مقفول) بتترفض.
  static const _staleMinutes = 20;

  /// حدود طلبات الـ QR (ضد إغراق الكاشير بطلبات وهمية من ترابيزة واحدة).
  static const _qrMaxWaitingTable = 6, _qrMaxPer10MinTable = 15;
  static const _qrMaxWaitingTakeaway = 25, _qrMaxPer10MinTakeaway = 60;

  void _ingestOrder(String cloudId, String clientId, Map<String, Object?>? table, Map<String, dynamic> body, DateTime at, List<int>? proof) {
    if (db.selectOne('SELECT id FROM orders WHERE cloud_id = ?', [cloudId]) != null) return;
    final guest = _text(body['name']);
    final phone = _cleanPhone(body['phone']);
    final note = _text(body['note']);
    final lines = (body['items'] is List ? body['items'] as List : const []).whereType<Map>().map((m) {
      final x = m.cast<String, dynamic>();
      return <String, dynamic>{'itemId': x['i'], 'qty': x['q'], 'modifierIds': x['m'], 'note': x['note'], 'guest': guest.isEmpty ? null : guest};
    }).toList();

    // الطلب بيتسجل حتى لو مرفوض، عشان العميل يشوف السبب على موبايله
    void reject(String reason) {
      db.transaction(() {
        final day = _today();
        final number = db.selectOne('SELECT COALESCE(MAX(number), 0) + 1 AS n FROM orders WHERE day = ?', [day])!['n'] as int;
        db.execute(
          'INSERT INTO orders(id, number, day, source, status, table_id, guest_name, guest_phone, note, cloud_id, client_id, reject_reason, created_at) '
          "VALUES(?, ?, ?, 'qr', 'rejected', ?, ?, ?, ?, ?, ?, ?, ?)",
          [_uuid.v4(), number, day, table?['id'], guest.isEmpty ? null : guest, phone, note.isEmpty ? null : note, cloudId, clientId, reason, nowIso()],
        );
      });
      _broadcast('orders');
    }

    if (!_cafeBool('qrEnabled')) return reject('الطلب من الموبايل مقفول دلوقتي. اطلب من الويتر');
    if (_cafeBool('qrNeedsOpenRegister') && _openRegisterId() == null) return reject('الكافيه مش بيستقبل طلبات دلوقتي');
    if (DateTime.now().difference(at).inMinutes > _staleMinutes) return reject('الطلب اتأخر في الوصول. ابعته تاني لو لسه عايزه');
    // حماية من الطلبات الكتير ورا بعض من نفس الموبايل
    final recent = db.selectOne('SELECT COUNT(*) AS c FROM orders WHERE client_id = ? AND created_at > ?',
        [clientId, DateTime.now().toUtc().subtract(const Duration(minutes: 10)).toIso8601String()])!['c'] as int;
    if (recent >= 8) return reject('طلبات كتير في وقت قصير. كلم الويتر');
    // الحد اللي فوق بيعتمد على رقم بيختاره موبايل العميل (ممكن يتغير ويعدّي الحد)، فكمان حد لكل ترابيزة:
    // طلبات كتير مستنية موافقة، أو طلبات كتير في 10 دقايق (حتى لو الترابيزة بتقبل لوحدها)
    final tableId = table?['id'];
    final since = DateTime.now().toUtc().subtract(const Duration(minutes: 10)).toIso8601String();
    final waiting = db.selectOne("SELECT COUNT(*) AS c FROM orders WHERE source = 'qr' AND status = 'pending' AND table_id IS ?", [tableId])!['c'] as int;
    final lately = db.selectOne("SELECT COUNT(*) AS c FROM orders WHERE source = 'qr' AND status <> 'rejected' AND table_id IS ? AND created_at > ?", [tableId, since])!['c'] as int;
    final (maxWaiting, maxLately) = table == null ? (_qrMaxWaitingTakeaway, _qrMaxPer10MinTakeaway) : (_qrMaxWaitingTable, _qrMaxPer10MinTable);
    if (waiting >= maxWaiting || lately >= maxLately) return reject('فيه طلبات كتير على ${table == null ? 'التيك أواي' : 'الترابيزة دي'} دلوقتي. كلم الويتر أو استنى شوية');
    if (_cafeBool('qrRequireContact') && (guest.isEmpty || phone == null)) return reject('اكتب اسمك ورقم موبايلك وابعت الطلب تاني');

    final List<Map<String, Object?>> priced;
    try {
      priced = _priceLines(lines, fromQr: true);
    } on ApiError catch (e) {
      return reject(e.message);
    }

    final pay = body['pay'] is Map ? (body['pay'] as Map).cast<String, dynamic>() : null;
    final method = pay == null ? null : db.selectOne('SELECT * FROM pay_methods WHERE id = ? AND active = 1 AND show_in_qr = 1', [_text(pay['m'])]);

    final autoAccept = table == null
        ? _cafe['qrApproval'] == 'auto'
        : (table['auto_accept'] == null ? _cafe['qrApproval'] == 'auto' : table['auto_accept'] == 1);

    String? orderId;
    int? transferAmount;
    db.transaction(() {
      final checkId = table != null
          ? _openCheck(type: 'dine_in', tableId: table['id'] as String)
          : _openCheck(type: 'takeaway', customerName: guest.isEmpty ? 'تيك أواي (QR)' : guest, customerPhone: phone);
      // العميل بيتسجل برقمه (عشان نقط الولاء)، وبيتربط بالحساب لو الحساب لسه مالوش عميل
      if (phone != null) {
        final norm = _phoneNorm(phone);
        if (norm.length >= 8) {
          final customerId = _upsertCustomer(norm, phone, guest.isEmpty ? null : guest);
          db.execute(
            'UPDATE checks SET customer_id = COALESCE(customer_id, ?), customer_name = COALESCE(customer_name, ?), customer_phone = COALESCE(customer_phone, ?) WHERE id = ?',
            [customerId, guest.isEmpty ? null : guest, phone, checkId],
          );
        }
      }
      orderId = _createOrder(
        source: 'qr',
        priced: priced,
        checkId: checkId,
        tableId: table?['id'] as String?,
        note: note.isEmpty ? null : note.substring(0, min(note.length, 300)),
        guestName: guest.isEmpty ? null : guest.substring(0, min(guest.length, 40)),
        guestPhone: phone,
        payMethodId: method?['id'] as String?,
        cloudId: cloudId,
        clientId: clientId,
        accept: false,
      );
      if (method != null && (method['kind'] == 'instapay' || method['kind'] == 'wallet' || proof != null)) {
        final total = priced.fold<int>(0, (s, l) => s + (l['qty'] as int) * (l['unit_price_cents'] as int));
        final amount = pay!['a'] is int && (pay['a'] as int) > 0 ? min(pay['a'] as int, total * 3) : total;
        _insertCloudPayment(cloudId, clientId, checkId, method, amount, proof, pay['ref']);
        transferAmount = amount;
      }
      if (autoAccept) _acceptOrder(orderId!, null);
    });
    _changed();
    _broadcast('payments');

    final where = _placeName(table?['id'] as String?, customerName: guest.isEmpty ? null : guest);
    final total = priced.fold<int>(0, (s, l) => s + (l['qty'] as int) * (l['unit_price_cents'] as int));
    final count = priced.fold<int>(0, (s, l) => s + (l['qty'] as int));
    _notify('order_new', autoAccept ? 'طلب QR اتقبل لوحده' : 'طلب جديد من موبايل عميل', '$where • $count صنف • ${money(total)}${autoAccept ? '' : ' • مستني موافقتك'}',
        floorRoles,
        goTo: 'orders');
    if (autoAccept) _notifyKitchen(orderId!);
    if (transferAmount != null) {
      _notify('payment', 'تحويل مستني تأكيد', '$where • ${method!['name']} ${money(transferAmount!)}', cashRoles, goTo: 'orders');
    }
  }

  /// نص من رسالة العميل (اللي جاية من النت بأي شكل): أي نوع تاني بيتعامل كأنه فاضي.
  String _text(Object? v) => v is String ? v.trim() : '';

  String? _cleanPhone(Object? v) {
    final s = latinDigits('${v ?? ''}').replaceAll(RegExp(r'[^\d+]'), '');
    return s.length >= 8 && s.length <= 16 ? s : null;
  }

  void _insertCloudPayment(String cloudId, String clientId, String checkId, Map<String, Object?> method, int amount, List<int>? proof, Object? ref) {
    String? fileId;
    if (proof != null) {
      try {
        fileId = _storeJpeg(proof, 'proof', null);
      } catch (_) {}
    }
    final reference = (ref is String ? ref.trim() : '');
    db.execute(
      'INSERT OR IGNORE INTO payments(id, check_id, amount_cents, method_id, method_kind, method_name, status, source, proof_file, reference, payer, cloud_id, created_at) '
      "VALUES(?, ?, ?, ?, ?, ?, 'pending', 'qr', ?, ?, ?, ?, ?)",
      [_uuid.v4(), checkId, amount, method['id'], method['kind'], method['name'], fileId, reference.isEmpty ? null : reference.substring(0, min(reference.length, 60)), clientId, cloudId, nowIso()],
    );
  }

  void _ingestCall(String cloudId, Map<String, Object?> table, Map<String, dynamic> body) {
    final type = body['kind'] == 'bill' ? 'bill' : 'waiter';
    final check = db.selectOne("SELECT * FROM checks WHERE table_id = ? AND status = 'open'", [table['id']]);
    // نداء مكرر من نفس الترابيزة لسه مفتوح: مش محتاجين واحد جديد
    if (db.selectOne("SELECT id FROM service_calls WHERE table_id = ? AND type = ? AND status = 'open'", [table['id'], type]) != null) return;
    final method = body['pm'] is! String ? null : db.selectOne('SELECT id FROM pay_methods WHERE id = ? AND active = 1', [body['pm']]);
    final note = _text(body['note']);
    db.transaction(() {
      db.execute(
        'INSERT OR IGNORE INTO service_calls(id, table_id, check_id, type, note, pay_method_id, cloud_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
        [_uuid.v4(), table['id'], check?['id'], type, note.isEmpty ? null : note.substring(0, min(note.length, 200)), method?['id'], cloudId, nowIso()],
      );
      if (type == 'bill' && check != null) {
        db.execute('UPDATE checks SET bill_requested = 1 WHERE id = ?', [check['id']]);
        _queuePrint(null, 'bill', check['id'] as String, {'checkId': check['id'], 'auto': true});
      }
    });
    _broadcast('calls');
    _broadcast('tables');
    _broadcast('checks');
    _notify('table_call', type == 'bill' ? 'ترابيزة ${table['name']} عايزة الحساب' : 'ترابيزة ${table['name']} بتنادي الويتر',
        note.isEmpty ? 'روح للترابيزة' : note, floorRoles,
        goTo: 'orders');
  }

  void _ingestPayment(String cloudId, String clientId, Map<String, Object?>? table, Map<String, dynamic> body, List<int>? proof) {
    if (db.selectOne('SELECT id FROM payments WHERE cloud_id = ?', [cloudId]) != null) return;
    final method = db.selectOne('SELECT * FROM pay_methods WHERE id = ? AND active = 1 AND show_in_qr = 1', [_text(body['m'])]);
    if (method == null) return;
    final check = table != null
        ? db.selectOne("SELECT * FROM checks WHERE table_id = ? AND status = 'open'", [table['id']])
        : db.selectOne("SELECT c.* FROM checks c JOIN orders o ON o.check_id = c.id WHERE o.client_id = ? AND c.status = 'open' ORDER BY c.opened_at DESC LIMIT 1", [clientId]);
    if (check == null) return;
    final due = (check['total_cents'] as int) - (check['paid_cents'] as int);
    final amount = body['a'] is int && (body['a'] as int) > 0 ? min(body['a'] as int, max(due, 1) * 3) : due;
    if (amount <= 0) return;
    db.transaction(() {
      if (method['kind'] == 'cash' || method['kind'] == 'card') {
        // كاش أو فيزا: الكاشير/الويتر يروح يحصّل
        db.execute(
          "INSERT OR IGNORE INTO service_calls(id, table_id, check_id, type, note, pay_method_id, cloud_id, created_at) VALUES(?, ?, ?, 'bill', ?, ?, ?, ?)",
          [_uuid.v4(), table?['id'], check['id'], 'هيدفع ${money(amount)}', method['id'], cloudId, nowIso()],
        );
        db.execute('UPDATE checks SET bill_requested = 1 WHERE id = ?', [check['id']]);
      } else {
        _insertCloudPayment(cloudId, clientId, check['id'] as String, method, amount, proof, body['ref']);
      }
    });
    _broadcast('payments');
    _broadcast('calls');
    _changed(orders: false);
    final where = _placeName(table?['id'] as String?, customerName: check['customer_name'] as String?);
    if (method['kind'] == 'cash' || method['kind'] == 'card') {
      _notify('table_call', '$where عايزة تدفع ${method['name']}', 'المبلغ ${money(amount)} • روح حصّل', floorRoles, goTo: 'orders');
    } else {
      _notify('payment', 'تحويل مستني تأكيد', '$where • ${method['name']} ${money(amount)}', cashRoles, goTo: 'orders');
    }
  }
}
