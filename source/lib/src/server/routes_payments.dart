part of 'api_server.dart';

/// الفلوس: طرق الدفع (كاش، فيزا، InstaPay، محافظ)، والدفعات وتأكيد صور التحويل،
/// والدرج (فتح الوردية وقفلها والمصاريف)، والعملاء ونقط الولاء.
extension _PaymentRoutes on OrderlyServer {
  void _registerPaymentRoutes(Router r) {
    r.get('/api/pay-methods', _authed((req, u) => _payMethodsJson(all: req.url.queryParameters['all'] == '1')));
    r.post('/api/pay-methods', _authed(_savePayMethod, only: {'owner'}));
    r.patch('/api/pay-methods/<id>', _authed(_savePayMethod, only: {'owner'}));

    r.post('/api/checks/<id>/payments', _authed(_addPayment, only: cashRoles));
    r.get('/api/payments/pending', _authed((req, u) => {
          'payments': db.select("SELECT * FROM payments WHERE status = 'pending' ORDER BY created_at").map(_paymentJson).toList(),
        }, only: cashRoles));
    r.post('/api/payments/<id>/confirm', _authed(_confirmPayment, only: cashRoles));
    r.post('/api/payments/<id>/reject', _authed(_rejectPayment, only: cashRoles));
    r.post('/api/payments/<id>/refund', _authed(_refundPayment, only: {'owner'}));

    r.get('/api/register', _authed(_registerJson, only: cashRoles));
    r.post('/api/register/open', _authed(_openRegister, only: cashRoles));
    r.post('/api/register/close', _authed(_closeRegister, only: cashRoles));
    r.post('/api/register/moves', _authed(_addCashMove, only: cashRoles));
    r.get('/api/register/history', _authed(_registerHistory, only: {'owner'}));

    r.get('/api/customers', _authed(_listCustomers, only: cashRoles));
    r.post('/api/checks/<id>/customer', _authed(_linkCustomer, only: floorRoles));
    r.post('/api/checks/<id>/redeem', _authed(_redeemPoints, only: cashRoles));
  }

  // ---------------------------------------------------------------- pay methods

  Map<String, Object?> _payMethodJson(Map<String, Object?> m) => {
        'id': m['id'],
        'name': m['name'],
        'kind': m['kind'],
        'account': m['account'],
        'link': m['link'],
        'instructions': m['instructions'],
        'needsProof': m['needs_proof'] == 1,
        'showInQr': m['show_in_qr'] == 1,
        'active': m['active'] == 1,
      };

  Map<String, Object?> _payMethodsJson({bool all = false}) => {
        'methods': db.select('SELECT * FROM pay_methods ${all ? '' : 'WHERE active = 1'} ORDER BY sort, rowid').map(_payMethodJson).toList(),
      };

  Future<Object?> _savePayMethod(Request req, AuthUser u) async {
    final body = await _body(req);
    var id = req.params['id'];
    const kinds = {'cash', 'card', 'instapay', 'wallet', 'other'};
    db.transaction(() {
      if (id == null) {
        final kind = body['kind'];
        if (!kinds.contains(kind)) throw ApiError(400, 'اختار نوع طريقة الدفع');
        id = _uuid.v4();
        db.execute(
          'INSERT INTO pay_methods(id, name, kind, needs_proof, sort, created_at) VALUES(?, ?, ?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM pay_methods), ?)',
          [id, _requiredText(body, 'name', 'اسم طريقة الدفع'), kind, kind == 'instapay' || kind == 'wallet' ? 1 : 0, nowIso()],
        );
      } else {
        if (db.selectOne('SELECT id FROM pay_methods WHERE id = ?', [id]) == null) throw ApiError(404, 'طريقة الدفع دي مش موجودة');
        if (body.containsKey('name')) db.execute('UPDATE pay_methods SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم طريقة الدفع'), id]);
      }
      for (final k in ['account', 'link', 'instructions']) {
        if (!body.containsKey(k)) continue;
        final v = _optionalText(body, k);
        if (v != null && v.length > 300) throw ApiError(400, 'النص طويل جداً');
        if (k == 'link' && v != null && !v.startsWith('https://')) throw ApiError(400, 'اللينك لازم يبدأ بـ https://');
        db.execute('UPDATE pay_methods SET $k = ? WHERE id = ?', [v, id]);
      }
      for (final e in const {'needsProof': 'needs_proof', 'showInQr': 'show_in_qr', 'active': 'active'}.entries) {
        if (body[e.key] is bool) db.execute('UPDATE pay_methods SET ${e.value} = ? WHERE id = ?', [body[e.key] == true ? 1 : 0, id]);
      }
      final m = db.selectOne('SELECT * FROM pay_methods WHERE id = ?', [id])!;
      if ((m['kind'] == 'instapay' || m['kind'] == 'wallet') && m['active'] == 1 && m['show_in_qr'] == 1 && m['account'] == null && m['link'] == null) {
        throw ApiError(400, 'اكتب رقم المحفظة أو عنوان InstaPay عشان العميل يعرف يحوّل');
      }
      if (m['kind'] == 'cash' && m['active'] == 0 && db.selectOne("SELECT id FROM pay_methods WHERE kind = 'cash' AND active = 1") == null) {
        throw ApiError(400, 'لازم يفضل فيه طريقة كاش');
      }
    });
    _broadcast('shop');
    return _payMethodsJson(all: true);
  }

  // ---------------------------------------------------------------- payments

  Map<String, Object?> _paymentJson(Map<String, Object?> p) {
    final check = db.selectOne('SELECT c.number, t.name AS table_name FROM checks c LEFT JOIN tables t ON t.id = c.table_id WHERE c.id = ?', [p['check_id']]);
    return {
      'id': p['id'],
      'checkId': p['check_id'],
      'checkNumber': check?['number'],
      'tableName': check?['table_name'],
      'amountCents': p['amount_cents'],
      'methodId': p['method_id'],
      'methodKind': p['method_kind'],
      'methodName': p['method_name'],
      'status': p['status'],
      'source': p['source'],
      'proofFileId': p['proof_file'],
      'reference': p['reference'],
      'payer': p['payer'],
      'rejectReason': p['reject_reason'],
      'createdAt': p['created_at'],
    };
  }

  Map<String, Object?> _loadPayMethod(Object? id) {
    final m = id is String ? db.selectOne('SELECT * FROM pay_methods WHERE id = ?', [id]) : null;
    if (m == null) throw ApiError(400, 'اختار طريقة الدفع');
    return m;
  }

  Future<Object?> _addPayment(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!, open: true);
    final body = await _body(req);
    final m = _loadPayMethod(body['methodId']);
    final amount = body['amountCents'];
    if (amount is! int || amount <= 0) throw ApiError(400, 'المبلغ مش صحيح');
    _recalcCheck(c['id'] as String);
    final fresh = _loadCheck(c['id'] as String);
    final due = (fresh['total_cents'] as int) - (fresh['paid_cents'] as int);
    if (amount > due) throw ApiError(400, 'المبلغ أكبر من الباقي على الحساب (${money(due)})');
    final session = _requireOpenRegister();
    final id = _uuid.v4();
    db.transaction(() {
      db.execute(
        'INSERT INTO payments(id, check_id, amount_cents, method_id, method_kind, method_name, status, source, reference, payer, session_id, user_id, created_at) '
        "VALUES(?, ?, ?, ?, ?, ?, 'confirmed', 'cashier', ?, ?, ?, ?, ?)",
        [id, c['id'], amount, m['id'], m['kind'], m['name'], _optionalText(body, 'reference'), _optionalText(body, 'payer'), session, u.id, nowIso()],
      );
      _cashMove(session, 'sale', amount, m['kind'] as String, refType: 'payment', refId: id, note: 'حساب #${c['number']} • ${m['name']}', userId: u.id);
      _recalcCheck(c['id'] as String);
    });
    _broadcast('payments');
    _broadcast('register');
    _changed(orders: false);
    // لو الحساب اتدفع كله، الكاشير ممكن يطلب القفل على طول
    if (body['close'] == true) return _closeCheck(req.change(body: '{}'), u);
    return _checkJson(c['id'] as String);
  }

  /// الكاشير شاف صورة التحويل واتأكد إن الفلوس وصلت.
  Future<Object?> _confirmPayment(Request req, AuthUser u) async {
    final p = db.selectOne('SELECT * FROM payments WHERE id = ?', [req.params['id']]);
    if (p == null) throw ApiError(404, 'الدفعة دي مش موجودة');
    if (p['status'] != 'pending') throw ApiError(400, 'الدفعة دي اتراجعت قبل كده');
    final body = await _body(req);
    // الكاشير ممكن يعدّل المبلغ لو اللي وصل غير اللي العميل كتبه
    final amount = body['amountCents'] is int && (body['amountCents'] as int) > 0 ? body['amountCents'] as int : p['amount_cents'] as int;
    final session = _requireOpenRegister();
    db.transaction(() {
      db.execute(
        "UPDATE payments SET status = 'confirmed', amount_cents = ?, session_id = ?, reviewed_by = ?, reviewed_at = ? WHERE id = ?",
        [amount, session, u.id, nowIso(), p['id']],
      );
      final check = _loadCheck(p['check_id'] as String);
      _cashMove(session, 'sale', amount, p['method_kind'] as String, refType: 'payment', refId: p['id'] as String, note: 'حساب #${check['number']} • ${p['method_name']} (تحويل)', userId: u.id);
      _recalcCheck(p['check_id'] as String);
    });
    _audit(u.id, 'payment.confirm', 'payment', p['id'] as String, '${p['method_name']} ${money(amount)}');
    _broadcast('payments');
    _broadcast('register');
    _changed(orders: false);
    return _checkJson(p['check_id'] as String);
  }

  Future<Object?> _rejectPayment(Request req, AuthUser u) async {
    final p = db.selectOne('SELECT * FROM payments WHERE id = ?', [req.params['id']]);
    if (p == null) throw ApiError(404, 'الدفعة دي مش موجودة');
    if (p['status'] != 'pending') throw ApiError(400, 'الدفعة دي اتراجعت قبل كده');
    final body = await _body(req);
    final reason = _optionalText(body, 'reason') ?? 'التحويل ما وصلش';
    db.execute("UPDATE payments SET status = 'rejected', reject_reason = ?, reviewed_by = ?, reviewed_at = ? WHERE id = ?", [reason, u.id, nowIso(), p['id']]);
    _audit(u.id, 'payment.reject', 'payment', p['id'] as String, '${p['method_name']} ${money(p['amount_cents'] as int)}: $reason');
    _broadcast('payments');
    _changed(orders: false);
    return _checkJson(p['check_id'] as String);
  }

  /// المالك بيرجّع دفعة اتسجلت غلط (على حساب لسه مفتوح).
  Future<Object?> _refundPayment(Request req, AuthUser u) async {
    final p = db.selectOne('SELECT * FROM payments WHERE id = ?', [req.params['id']]);
    if (p == null) throw ApiError(404, 'الدفعة دي مش موجودة');
    if (p['status'] != 'confirmed') throw ApiError(400, 'الدفعة دي مش متأكدة');
    final check = _loadCheck(p['check_id'] as String, open: true);
    final session = _requireOpenRegister();
    db.transaction(() {
      db.execute("UPDATE payments SET status = 'rejected', reject_reason = 'اترجعت', reviewed_by = ?, reviewed_at = ? WHERE id = ?", [u.id, nowIso(), p['id']]);
      _cashMove(session, 'refund', -(p['amount_cents'] as int), p['method_kind'] as String, refType: 'payment', refId: p['id'] as String, note: 'مرتجع حساب #${check['number']}', userId: u.id);
      _recalcCheck(check['id'] as String);
    });
    _audit(u.id, 'payment.refund', 'payment', p['id'] as String, money(p['amount_cents'] as int));
    _broadcast('payments');
    _broadcast('register');
    _changed(orders: false);
    return _checkJson(check['id'] as String);
  }

  // ---------------------------------------------------------------- register (الدرج / الوردية)

  String? _openRegisterId() => db.selectOne('SELECT id FROM register_sessions WHERE closed_at IS NULL ORDER BY opened_at DESC LIMIT 1')?['id'] as String?;

  String _requireOpenRegister() => _openRegisterId() ?? (throw ApiError(400, 'الدرج مقفول. افتح الوردية الأول من شاشة الدرج'));

  void _cashMove(String sessionId, String type, int amount, String method, {String? category, String? refType, String? refId, String? note, String? userId}) {
    db.execute(
      'INSERT INTO cash_moves(id, session_id, type, amount_cents, method, category, ref_type, ref_id, note, user_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [_uuid.v4(), sessionId, type, amount, method, category, refType, refId, note, userId, nowIso()],
    );
  }

  Map<String, Object?> _sessionSummary(Map<String, Object?> s) {
    final byMethod = <String, int>{};
    for (final r in db.select('SELECT method, SUM(amount_cents) AS s FROM cash_moves WHERE session_id = ? GROUP BY method', [s['id']])) {
      byMethod[r['method'] as String] = r['s'] as int;
    }
    final byType = <String, int>{};
    for (final r in db.select('SELECT type, SUM(amount_cents) AS s FROM cash_moves WHERE session_id = ? GROUP BY type', [s['id']])) {
      byType[r['type'] as String] = r['s'] as int;
    }
    final expectedCash = (s['opening_cash_cents'] as int) + (byMethod['cash'] ?? 0);
    final opener = s['opened_by'] == null ? null : db.selectOne('SELECT name FROM users WHERE id = ?', [s['opened_by']]);
    final closer = s['closed_by'] == null ? null : db.selectOne('SELECT name FROM users WHERE id = ?', [s['closed_by']]);
    return {
      'id': s['id'],
      'openedAt': s['opened_at'],
      'openedBy': opener?['name'],
      'closedAt': s['closed_at'],
      'closedBy': closer?['name'],
      'openingCashCents': s['opening_cash_cents'],
      'expectedCashCents': s['closed_at'] == null ? expectedCash : s['expected_cash_cents'],
      'countedCashCents': s['counted_cash_cents'],
      'keptCashCents': s['kept_cash_cents'],
      'note': s['note'],
      'byMethod': byMethod,
      'byType': byType,
      'salesCents': byType['sale'] ?? 0,
      'checksClosed': db.selectOne("SELECT COUNT(*) AS c FROM checks WHERE session_id = ? AND status = 'closed'", [s['id']])!['c'],
    };
  }

  Object? _registerJson(Request req, AuthUser u) {
    final id = _openRegisterId();
    final last = db.selectOne('SELECT * FROM register_sessions WHERE closed_at IS NOT NULL ORDER BY closed_at DESC LIMIT 1');
    return {
      'session': id == null ? null : _sessionSummary(db.selectOne('SELECT * FROM register_sessions WHERE id = ?', [id])!),
      'moves': id == null
          ? const []
          : db
              .select('SELECT m.*, us.name AS user_name FROM cash_moves m LEFT JOIN users us ON us.id = m.user_id WHERE m.session_id = ? ORDER BY m.created_at DESC LIMIT 300', [id])
              .map((m) => {
                    'id': m['id'],
                    'type': m['type'],
                    'amountCents': m['amount_cents'],
                    'method': m['method'],
                    'category': m['category'],
                    'note': m['note'],
                    'userName': m['user_name'],
                    'createdAt': m['created_at'],
                  })
              .toList(),
      'lastKeptCashCents': last?['kept_cash_cents'],
      'openChecks': db.selectOne("SELECT COUNT(*) AS c FROM checks WHERE status = 'open'")!['c'],
    };
  }

  Future<Object?> _openRegister(Request req, AuthUser u) async {
    await _requireLicense();
    if (_openRegisterId() != null) throw ApiError(400, 'الدرج مفتوح بالفعل');
    final body = await _body(req);
    final opening = body['openingCashCents'] is int ? (body['openingCashCents'] as int).clamp(0, 100000000) : 0;
    final branch = db.selectOne('SELECT id FROM branches WHERE is_local = 1 LIMIT 1')?['id'];
    db.execute('INSERT INTO register_sessions(id, branch_id, opened_by, opened_at, opening_cash_cents) VALUES(?, ?, ?, ?, ?)', [_uuid.v4(), branch, u.id, nowIso(), opening]);
    _audit(u.id, 'register.open', 'register', null, money(opening));
    _broadcast('register');
    _broadcast('shop');
    return _registerJson(req, u);
  }

  Future<Object?> _closeRegister(Request req, AuthUser u) async {
    final id = _requireOpenRegister();
    final body = await _body(req);
    final counted = body['countedCashCents'];
    if (counted is! int || counted < 0) throw ApiError(400, 'اكتب الفلوس اللي في الدرج');
    final kept = body['keptCashCents'] is int ? (body['keptCashCents'] as int).clamp(0, counted) : 0;
    final summary = _sessionSummary(db.selectOne('SELECT * FROM register_sessions WHERE id = ?', [id])!);
    db.execute(
      'UPDATE register_sessions SET closed_by = ?, closed_at = ?, expected_cash_cents = ?, counted_cash_cents = ?, kept_cash_cents = ?, note = ? WHERE id = ?',
      [u.id, nowIso(), summary['expectedCashCents'], counted, kept, _optionalText(body, 'note'), id],
    );
    _audit(u.id, 'register.close', 'register', id, 'المتوقع ${money(summary['expectedCashCents'] as int)} • الفعلي ${money(counted)}');
    _broadcast('register');
    _broadcast('shop');
    return {'closed': _sessionSummary(db.selectOne('SELECT * FROM register_sessions WHERE id = ?', [id])!)};
  }

  /// مصروف، أو إيداع في الدرج، أو سحب منه.
  Future<Object?> _addCashMove(Request req, AuthUser u) async {
    final id = _requireOpenRegister();
    final body = await _body(req);
    final type = body['type'];
    if (!const {'expense', 'deposit', 'withdraw'}.contains(type)) throw ApiError(400, 'نوع الحركة مش صحيح');
    final amount = body['amountCents'];
    if (amount is! int || amount <= 0) throw ApiError(400, 'المبلغ مش صحيح');
    final signed = type == 'deposit' ? amount : -amount;
    _cashMove(id, type as String, signed, 'cash', category: _optionalText(body, 'category'), note: _optionalText(body, 'note'), userId: u.id);
    _audit(u.id, 'register.$type', 'register', id, '${money(amount)} ${body['note'] ?? ''}');
    _broadcast('register');
    return _registerJson(req, u);
  }

  Object? _registerHistory(Request req, AuthUser u) => {
        'sessions': db.select('SELECT * FROM register_sessions ORDER BY opened_at DESC LIMIT 60').map(_sessionSummary).toList(),
      };

  // ---------------------------------------------------------------- customers & loyalty

  String _phoneNorm(String phone) {
    var d = latinDigits(phone).replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('20') && d.length == 12) d = '0${d.substring(2)}';
    return d;
  }

  Map<String, Object?> _customerJson(Map<String, Object?> c) => {
        'id': c['id'],
        'name': c['name'],
        'phone': c['phone'],
        'points': c['points'],
        'visits': c['visits'],
        'spentCents': c['spent_cents'],
        'lastVisitAt': c['last_visit_at'],
        'pointsValueCents': (c['points'] as int) * _cafeInt('loyaltyPointValue'),
      };

  Object? _listCustomers(Request req, AuthUser u) {
    final q = (req.url.queryParameters['q'] ?? '').trim();
    final rows = q.isEmpty
        ? db.select('SELECT * FROM customers ORDER BY last_visit_at DESC LIMIT 300')
        : db.select('SELECT * FROM customers WHERE phone_norm LIKE ? OR name LIKE ? ORDER BY last_visit_at DESC LIMIT 100', ['%${_phoneNorm(q)}%', '%$q%']);
    return {'customers': rows.map(_customerJson).toList()};
  }

  /// بيربط عميل (برقم الموبايل) بالحساب عشان ياخد نقط.
  Future<Object?> _linkCustomer(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!, open: true);
    final body = await _body(req);
    final phone = _requiredText(body, 'phone', 'رقم الموبايل');
    final norm = _phoneNorm(phone);
    if (norm.length < 8 || norm.length > 15) throw ApiError(400, 'رقم الموبايل مش صحيح');
    final customerId = _upsertCustomer(norm, phone, _optionalText(body, 'name'));
    db.execute('UPDATE checks SET customer_id = ?, customer_phone = COALESCE(customer_phone, ?), customer_name = COALESCE(customer_name, ?) WHERE id = ?',
        [customerId, phone, _optionalText(body, 'name'), c['id']]);
    _changed(orders: false);
    return _checkJson(c['id'] as String);
  }

  String _upsertCustomer(String norm, String phone, String? name) {
    final existing = db.selectOne('SELECT * FROM customers WHERE phone_norm = ?', [norm]);
    final now = nowIso();
    if (existing != null) {
      if (name != null && existing['name'] == null) db.execute('UPDATE customers SET name = ?, updated_at = ? WHERE id = ?', [name, now, existing['id']]);
      return existing['id'] as String;
    }
    final id = _uuid.v4();
    db.execute('INSERT INTO customers(id, name, phone, phone_norm, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)', [id, name, phone, norm, now, now]);
    return id;
  }

  Future<Object?> _redeemPoints(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!, open: true);
    if (!_cafeBool('loyaltyEnabled')) throw ApiError(400, 'نقط الولاء مقفولة من الإعدادات');
    if (c['customer_id'] == null) throw ApiError(400, 'اربط العميل برقم موبايله الأول');
    final body = await _body(req);
    final customer = db.selectOne('SELECT * FROM customers WHERE id = ?', [c['customer_id']])!;
    final points = body['points'];
    if (points is! int || points < 0) throw ApiError(400, 'عدد النقط مش صحيح');
    final available = (customer['points'] as int) + (c['points_used'] as int);
    if (points > available) throw ApiError(400, 'العميل معاه $available نقطة بس');
    if (points > 0 && points < _cafeInt('loyaltyMinRedeem')) throw ApiError(400, 'أقل عدد نقط يتصرف ${_cafeInt('loyaltyMinRedeem')}');
    db.transaction(() {
      db.execute('UPDATE customers SET points = ? WHERE id = ?', [available - points, customer['id']]);
      db.execute('UPDATE checks SET points_used = ? WHERE id = ?', [points, c['id']]);
      _recalcCheck(c['id'] as String);
    });
    _changed(orders: false);
    return _checkJson(c['id'] as String);
  }

  void _earnPoints(String checkId) {
    final c = _loadCheck(checkId);
    if (c['customer_id'] == null) return;
    final earned = _cafeBool('loyaltyEnabled') ? (c['total_cents'] as int) ~/ max(1, _cafeInt('loyaltyEarnCents')) : 0;
    db.execute(
      'UPDATE customers SET points = points + ?, visits = visits + 1, spent_cents = spent_cents + ?, last_visit_at = ?, updated_at = ? WHERE id = ?',
      [earned, c['total_cents'], nowIso(), nowIso(), c['customer_id']],
    );
    db.execute('UPDATE checks SET points_earned = ? WHERE id = ?', [earned, checkId]);
  }

  void _unearnPoints(String checkId) {
    final c = _loadCheck(checkId);
    if (c['customer_id'] == null) return;
    db.execute(
      'UPDATE customers SET points = MAX(0, points - ?), visits = MAX(0, visits - 1), spent_cents = MAX(0, spent_cents - ?) WHERE id = ?',
      [c['points_earned'], c['total_cents'], c['customer_id']],
    );
    db.execute('UPDATE checks SET points_earned = 0 WHERE id = ?', [checkId]);
  }
}
