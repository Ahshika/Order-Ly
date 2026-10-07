part of 'api_server.dart';

/// الحسابات والطلبات: فتح ترابيزة، وإضافة طلبات (من الكاشير أو الويتر أو العميل بالـ QR)،
/// وشاشة البار/المطبخ، والطباعة، ونقل ودمج وتقسيم الحساب، والقفل.
extension _CheckRoutes on OrderlyServer {
  void _registerCheckRoutes(Router r) {
    r.get('/api/checks', _authed(_listChecks, only: floorRoles));
    r.post('/api/checks', _authed(_openCheckRoute, only: floorRoles));
    r.get('/api/checks/<id>', _authed((req, u) => _checkJson(req.params['id']!), only: floorRoles));
    r.patch('/api/checks/<id>', _authed(_updateCheck, only: floorRoles));
    r.post('/api/checks/<id>/orders', _authed(_addOrderRoute, only: floorRoles));
    r.post('/api/checks/<id>/move', _authed(_moveCheck, only: floorRoles));
    r.post('/api/checks/<id>/merge', _authed(_mergeCheck, only: cashRoles));
    r.post('/api/checks/<id>/split', _authed(_splitCheck, only: cashRoles));
    r.post('/api/checks/<id>/close', _authed(_closeCheck, only: cashRoles));
    r.post('/api/checks/<id>/void', _authed(_voidCheck, only: {'owner'}));
    r.post('/api/checks/<id>/reopen', _authed(_reopenCheck, only: {'owner'}));
    r.post('/api/checks/<id>/print', _authed(_printCheck, only: floorRoles));

    r.get('/api/orders', _authed(_listOrders, only: floorRoles));
    r.post('/api/orders/<id>/accept', _authed(_acceptOrderRoute, only: floorRoles));
    r.post('/api/orders/<id>/reject', _authed(_rejectOrderRoute, only: floorRoles));
    r.post('/api/orders/<id>/ready', _authed(_orderReadyRoute));
    r.post('/api/orders/<id>/served', _authed(_orderServedRoute, only: floorRoles));
    r.post('/api/order-items/<id>/status', _authed(_itemStatusRoute));
    r.post('/api/order-items/<id>/void', _authed(_voidItemRoute, only: floorRoles));

    r.get('/api/kds', _authed(_kdsJson));
    r.get('/api/calls', _authed(_listCalls, only: floorRoles));
    r.post('/api/calls/<id>/done', _authed(_callDone, only: floorRoles));

    r.get('/api/print/claim', _authed(_claimPrintJobs));
    r.post('/api/print/<id>/result', _authed(_printResult));
    r.get('/api/live', _authed((req, u) => _liveCounts()));
  }

  // ---------------------------------------------------------------- helpers

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  Map<String, Object?> _loadCheck(String id, {bool open = false}) {
    final c = db.selectOne('SELECT * FROM checks WHERE id = ?', [id]);
    if (c == null) throw ApiError(404, 'الحساب ده مش موجود');
    if (open && c['status'] != 'open') throw ApiError(400, 'الحساب ده اتقفل');
    return c;
  }

  Map<String, Object?> _loadOrder(String id) {
    final o = db.selectOne('SELECT * FROM orders WHERE id = ?', [id]);
    if (o == null) throw ApiError(404, 'الطلب ده مش موجود');
    return o;
  }

  /// فتح حساب جديد. لو الترابيزة عليها حساب مفتوح بيرجعه هو.
  String _openCheck({
    required String type,
    String? tableId,
    int? guests,
    String? customerName,
    String? customerPhone,
    String? address,
    String? userId,
    String? note,
  }) {
    if (!const {'dine_in', 'takeaway', 'delivery'}.contains(type)) throw ApiError(400, 'نوع الحساب مش صحيح');
    if (type == 'dine_in') {
      if (tableId == null) throw ApiError(400, 'اختار الترابيزة');
      if (db.selectOne('SELECT id FROM tables WHERE id = ? AND active = 1', [tableId]) == null) throw ApiError(400, 'الترابيزة مش موجودة');
      final existing = db.selectOne("SELECT id FROM checks WHERE table_id = ? AND status = 'open'", [tableId]);
      if (existing != null) return existing['id'] as String;
    } else {
      tableId = null;
    }
    final serviceBp = type == 'dine_in' || _cafeBool('serviceOnTakeaway') ? _cafeInt('serviceBp') : 0;
    final id = _uuid.v4();
    final now = nowIso();
    final number = db.selectOne('SELECT COALESCE(MAX(number), 0) + 1 AS n FROM checks')!['n'] as int;
    db.execute(
      'INSERT INTO checks(id, number, type, table_id, guests, customer_name, customer_phone, address, waiter_id, service_bp, tax_bp, '
      'note, opened_by, opened_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [id, number, type, tableId, guests, customerName, customerPhone, address, userId, serviceBp, _cafeInt('taxBp'), note, userId, now, now],
    );
    return id;
  }

  /// بيحسب إجمالي الحساب من الأصناف والخصم والخدمة والضريبة والدفعات.
  void _recalcCheck(String checkId) {
    final c = db.selectOne('SELECT * FROM checks WHERE id = ?', [checkId]);
    if (c == null) return;
    final subtotal = db.selectOne(
      "SELECT COALESCE(SUM(oi.qty * oi.unit_price_cents), 0) AS s FROM order_items oi JOIN orders o ON o.id = oi.order_id "
      "WHERE oi.check_id = ? AND oi.status <> 'void' AND o.status NOT IN ('pending', 'rejected', 'cancelled')",
      [checkId],
    )!['s'] as int;
    final pointsDiscount = (c['points_used'] as int) * _cafeInt('loyaltyPointValue');
    final discount = min(subtotal, (c['discount_cents'] as int) + pointsDiscount);
    final base = subtotal - discount;
    final service = (base * (c['service_bp'] as int) / 10000).round();
    final tax = ((base + service) * (c['tax_bp'] as int) / 10000).round();
    final total = base + service + tax + (c['delivery_cents'] as int);
    final paid = db.selectOne("SELECT COALESCE(SUM(amount_cents), 0) AS s FROM payments WHERE check_id = ? AND status = 'confirmed'", [checkId])!['s'] as int;
    db.execute(
      'UPDATE checks SET subtotal_cents = ?, service_cents = ?, tax_cents = ?, total_cents = ?, paid_cents = ?, updated_at = ? WHERE id = ?',
      [subtotal, service, tax, total, paid, nowIso(), checkId],
    );
  }

  /// الأصناف المطلوبة: بنتأكد من كل حاجة ونحسب السعر هنا (عمرنا ما بنصدق السعر اللي جاي من العميل).
  List<Map<String, Object?>> _priceLines(List<Map<String, dynamic>> lines, {required bool fromQr}) {
    if (lines.isEmpty) throw ApiError(400, 'الطلب فاضي');
    if (lines.length > 60) throw ApiError(400, 'الطلب كبير جداً');
    final promos = _activePromotions();
    final soldOut = _soldOutItemIds();
    final out = <Map<String, Object?>>[];
    for (final l in lines) {
      final item = db.selectOne(
        'SELECT i.*, c.station_id AS cat_station, c.active AS cat_active FROM items i JOIN categories c ON c.id = i.category_id WHERE i.id = ?',
        [l['itemId']],
      );
      if (item == null || item['active'] != 1 || item['cat_active'] != 1 || (fromQr && item['show_in_qr'] != 1)) {
        throw ApiError(400, 'فيه صنف مش موجود في المنيو');
      }
      if (item['available'] != 1 || soldOut.contains(item['id'])) throw ApiError(409, 'للأسف "${item['name']}" خلص');
      final qty = l['qty'];
      if (qty is! int || qty < 1 || qty > 99) throw ApiError(400, 'الكمية مش صحيحة');

      // الإضافات: لازم تبقى من مجموعات الصنف ده، وبعدد مسموح
      final picked = (l['modifierIds'] as List? ?? const []).whereType<String>().toSet();
      final groups = db.select(
        'SELECT g.* FROM item_modifier_groups ig JOIN modifier_groups g ON g.id = ig.group_id WHERE ig.item_id = ? AND g.active = 1 ORDER BY ig.sort',
        [item['id']],
      );
      final mods = <Map<String, Object?>>[];
      var modsPrice = 0;
      final used = <String>{};
      for (final g in groups) {
        final options = db.select('SELECT * FROM modifier_options WHERE group_id = ? AND active = 1 ORDER BY sort', [g['id']]);
        final chosen = options.where((o) => picked.contains(o['id'])).toList();
        if (chosen.length < (g['min_select'] as int)) throw ApiError(400, 'اختار ${g['name']} لـ ${item['name']}');
        if (chosen.length > (g['max_select'] as int)) throw ApiError(400, 'اختيارات ${g['name']} كتير');
        for (final o in chosen) {
          used.add(o['id'] as String);
          modsPrice += o['price_cents'] as int;
          mods.add({'id': o['id'], 'name': o['name'], 'nameEn': o['name_en'], 'group': g['name'], 'price': o['price_cents']});
        }
      }
      if (used.length != picked.length) throw ApiError(400, 'فيه إضافة مش تبع الصنف ده');

      final promo = _promoFor(promos, item);
      final base = promo == 0 ? item['price_cents'] as int : _applyPromo(item['price_cents'] as int, promo);
      final note = (l['note'] as String? ?? '').trim();
      final guest = (l['guest'] as String? ?? '').trim();
      out.add({
        'item_id': item['id'],
        'name': item['name'],
        'qty': qty,
        'unit_price_cents': max(0, base + modsPrice),
        'modifiers': jsonEncode(mods),
        'note': note.isEmpty ? null : note.substring(0, min(note.length, 200)),
        'guest': guest.isEmpty ? null : guest.substring(0, min(guest.length, 40)),
        'station_id': item['station_id'] ?? item['cat_station'],
      });
    }
    return out;
  }

  /// بيسجل طلب جديد. لو [accept] بيتبعت للبار/المطبخ على طول.
  String _createOrder({
    required String source,
    required List<Map<String, Object?>> priced,
    String? checkId,
    String? tableId,
    String? note,
    String? guestName,
    String? guestPhone,
    String? payMethodId,
    String? cloudId,
    String? clientId,
    String? userId,
    bool accept = true,
  }) {
    final id = _uuid.v4();
    final now = nowIso();
    final day = _today();
    final number = db.selectOne('SELECT COALESCE(MAX(number), 0) + 1 AS n FROM orders WHERE day = ?', [day])!['n'] as int;
    db.execute(
      'INSERT INTO orders(id, check_id, number, day, source, status, table_id, guest_name, guest_phone, note, pay_method_id, cloud_id, client_id, user_id, created_at) '
      "VALUES(?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [id, checkId, number, day, source, tableId, guestName, guestPhone, note, payMethodId, cloudId, clientId, userId, now],
    );
    for (final l in priced) {
      db.execute(
        'INSERT INTO order_items(id, order_id, check_id, item_id, name, qty, unit_price_cents, modifiers, note, station_id, guest, created_at, updated_at) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [_uuid.v4(), id, checkId, l['item_id'], l['name'], l['qty'], l['unit_price_cents'], l['modifiers'], l['note'], l['station_id'], l['guest'], now, now],
      );
    }
    if (accept) _acceptOrder(id, userId);
    return id;
  }

  /// قبول الطلب: بيتربط بحساب (أو يفتح حساب)، والخامات بتتخصم، وبيتطبع في البار/المطبخ.
  void _acceptOrder(String orderId, String? userId) {
    final o = _loadOrder(orderId);
    if (o['status'] != 'pending') throw ApiError(400, 'الطلب ده اتعامل معاه قبل كده');
    var checkId = o['check_id'] as String?;
    if (checkId == null || db.selectOne("SELECT id FROM checks WHERE id = ? AND status = 'open'", [checkId]) == null) {
      checkId = o['table_id'] != null
          ? _openCheck(type: 'dine_in', tableId: o['table_id'] as String, userId: userId)
          : _openCheck(type: 'takeaway', customerName: o['guest_name'] as String?, userId: userId);
    }
    final now = nowIso();
    db.execute("UPDATE orders SET status = 'accepted', check_id = ?, accepted_at = ?, accepted_by = ? WHERE id = ?", [checkId, now, userId, orderId]);
    db.execute('UPDATE order_items SET check_id = ? WHERE order_id = ?', [checkId, orderId]);
    _consumeStock(orderId, userId);
    _recalcCheck(checkId);
    _queueKitchenTickets(orderId);
  }

  void _rejectOrder(String orderId, String reason, String? userId) {
    final o = _loadOrder(orderId);
    if (o['status'] != 'pending') throw ApiError(400, 'الطلب ده اتعامل معاه قبل كده');
    final now = nowIso();
    db.execute("UPDATE orders SET status = 'rejected', reject_reason = ?, accepted_by = ?, accepted_at = ? WHERE id = ?", [reason, userId, now, orderId]);
    db.execute("UPDATE order_items SET status = 'void', void_reason = ? WHERE order_id = ?", [reason, orderId]);
    if (o['cloud_id'] != null) {
      // لو العميل كان رافع صورة تحويل مع الطلب، الكاشير لازم يرجّعله الفلوس
      db.execute("UPDATE payments SET status = 'rejected', reject_reason = ?, reviewed_by = ?, reviewed_at = ? WHERE cloud_id = ? AND status = 'pending'",
          ['الطلب اترفض: $reason', userId, now, o['cloud_id']]);
    }
    // الحساب اللي اتفتح عشان الطلب ده بس بيتقفل
    final checkId = o['check_id'] as String?;
    if (checkId != null &&
        db.selectOne("SELECT id FROM orders WHERE check_id = ? AND status NOT IN ('rejected', 'cancelled')", [checkId]) == null &&
        db.selectOne("SELECT id FROM payments WHERE check_id = ? AND status <> 'rejected'", [checkId]) == null) {
      db.execute("UPDATE checks SET status = 'void', void_reason = ?, closed_at = ?, closed_by = ?, updated_at = ? WHERE id = ? AND status = 'open'",
          ['طلب QR اترفض', now, userId, now, checkId]);
      db.execute("UPDATE service_calls SET status = 'done', done_at = ? WHERE check_id = ? AND status = 'open'", [now, checkId]);
    }
    if (checkId != null) _recalcCheck(checkId);
  }

  /// حالة الطلب بتتحسب من أصنافه: جاهز لما كل الأصناف تجهز، واتقدم لما كلها تتقدم.
  void _refreshOrderStatus(String orderId) {
    final o = _loadOrder(orderId);
    if (!const {'accepted', 'ready', 'served'}.contains(o['status'])) return;
    final rows = db.select("SELECT status FROM order_items WHERE order_id = ? AND status <> 'void'", [orderId]);
    final now = nowIso();
    if (rows.isEmpty || rows.every((r) => r['status'] == 'served')) {
      db.execute("UPDATE orders SET status = 'served', served_at = COALESCE(served_at, ?), ready_at = COALESCE(ready_at, ?) WHERE id = ?", [now, now, orderId]);
    } else if (rows.every((r) => r['status'] == 'ready' || r['status'] == 'served')) {
      db.execute("UPDATE orders SET status = 'ready', ready_at = COALESCE(ready_at, ?) WHERE id = ?", [now, orderId]);
    } else {
      db.execute("UPDATE orders SET status = 'accepted' WHERE id = ?", [orderId]);
    }
  }

  void _changed({bool orders = true}) {
    _broadcast('checks');
    _broadcast('tables');
    if (orders) {
      _broadcast('orders');
      _broadcast('kds');
    }
  }

  // ---------------------------------------------------------------- checks

  Object? _listChecks(Request req, AuthUser u) {
    final q = req.url.queryParameters;
    final status = q['status'] ?? 'open';
    final where = <String>[];
    final params = <Object?>[];
    if (status != 'all') {
      where.add('c.status = ?');
      params.add(status);
    }
    if (q['from'] != null) {
      where.add('COALESCE(c.closed_at, c.opened_at) >= ?');
      params.add(q['from']);
    }
    if (q['to'] != null) {
      where.add('COALESCE(c.closed_at, c.opened_at) < ?');
      params.add(q['to']);
    }
    if (q['q'] != null && q['q']!.trim().isNotEmpty) {
      final s = q['q']!.trim();
      where.add('(CAST(c.number AS TEXT) = ? OR c.customer_name LIKE ? OR c.customer_phone LIKE ? OR t.name = ?)');
      params.addAll([s, '%$s%', '%$s%', s]);
    }
    final rows = db.select(
      'SELECT c.*, t.name AS table_name, us.name AS closed_by_name FROM checks c LEFT JOIN tables t ON t.id = c.table_id '
      'LEFT JOIN users us ON us.id = c.closed_by ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
      'ORDER BY c.number DESC LIMIT ${status == 'open' ? 500 : 300}',
      params,
    );
    return {'checks': rows.map(_checkSummary).toList()};
  }

  Map<String, Object?> _checkSummary(Map<String, Object?> c) => {
        'id': c['id'],
        'number': c['number'],
        'type': c['type'],
        'status': c['status'],
        'tableId': c['table_id'],
        'tableName': c['table_name'],
        'guests': c['guests'],
        'customerName': c['customer_name'],
        'customerPhone': c['customer_phone'],
        'address': c['address'],
        'subtotalCents': c['subtotal_cents'],
        'discountCents': c['discount_cents'],
        'discountNote': c['discount_note'],
        'pointsUsed': c['points_used'],
        'serviceBp': c['service_bp'],
        'serviceCents': c['service_cents'],
        'taxBp': c['tax_bp'],
        'taxCents': c['tax_cents'],
        'deliveryCents': c['delivery_cents'],
        'totalCents': c['total_cents'],
        'paidCents': c['paid_cents'],
        'note': c['note'],
        'billRequested': c['bill_requested'] == 1,
        'customerId': c['customer_id'],
        'openedAt': c['opened_at'],
        'closedAt': c['closed_at'],
        'closedByName': c['closed_by_name'],
        'voidReason': c['void_reason'],
      };

  Map<String, Object?> _orderItemJson(Map<String, Object?> i) => {
        'id': i['id'],
        'orderId': i['order_id'],
        'itemId': i['item_id'],
        'name': i['name'],
        'qty': i['qty'],
        'unitPriceCents': i['unit_price_cents'],
        'modifiers': jsonDecode(i['modifiers'] as String),
        'note': i['note'],
        'guest': i['guest'],
        'stationId': i['station_id'],
        'status': i['status'],
        'voidReason': i['void_reason'],
      };

  /// [joined] = الصف جاي فيه table_name و pm_name و pm_kind جاهزين (شاشة المطبخ) فمش محتاجين نسأل تاني.
  Map<String, Object?> _orderJson(Map<String, Object?> o, {bool withItems = true, bool joined = false}) {
    final pm = joined
        ? {'name': o['pm_name'], 'kind': o['pm_kind']}
        : o['pay_method_id'] == null
            ? null
            : db.selectOne('SELECT name, kind FROM pay_methods WHERE id = ?', [o['pay_method_id']]);
    final t = joined ? {'name': o['table_name']} : o['table_id'] == null ? null : db.selectOne('SELECT name FROM tables WHERE id = ?', [o['table_id']]);
    return {
      'id': o['id'],
      'checkId': o['check_id'],
      'number': o['number'],
      'source': o['source'],
      'status': o['status'],
      'tableId': o['table_id'],
      'tableName': t?['name'],
      'guestName': o['guest_name'],
      'guestPhone': o['guest_phone'],
      'note': o['note'],
      'payMethodName': pm?['name'],
      'payMethodKind': pm?['kind'],
      'rejectReason': o['reject_reason'],
      'createdAt': o['created_at'],
      'acceptedAt': o['accepted_at'],
      'readyAt': o['ready_at'],
      if (withItems)
        'items': db.select('SELECT * FROM order_items WHERE order_id = ? ORDER BY rowid', [o['id']]).map(_orderItemJson).toList(),
      // صور التحويل اللي العميل رفعها مع الطلب
      'payments': o['cloud_id'] == null
          ? const []
          : db.select('SELECT * FROM payments WHERE cloud_id = ?', [o['cloud_id']]).map(_paymentJson).toList(),
    };
  }

  Map<String, Object?> _checkJson(String id) {
    final c = db.selectOne(
      'SELECT c.*, t.name AS table_name, us.name AS closed_by_name FROM checks c LEFT JOIN tables t ON t.id = c.table_id '
      'LEFT JOIN users us ON us.id = c.closed_by WHERE c.id = ?',
      [id],
    );
    if (c == null) throw ApiError(404, 'الحساب ده مش موجود');
    final customer = c['customer_id'] == null ? null : db.selectOne('SELECT * FROM customers WHERE id = ?', [c['customer_id']]);
    return {
      'check': _checkSummary(c),
      'orders': db.select('SELECT * FROM orders WHERE check_id = ? ORDER BY created_at', [id]).map((o) => _orderJson(o)).toList(),
      'payments': db.select('SELECT * FROM payments WHERE check_id = ? ORDER BY created_at', [id]).map(_paymentJson).toList(),
      'calls': db.select("SELECT * FROM service_calls WHERE check_id = ? AND status = 'open'", [id]).map(_callJson).toList(),
      'customer': customer == null ? null : _customerJson(customer),
    };
  }

  Future<Object?> _openCheckRoute(Request req, AuthUser u) async {
    await _requireLicense();
    final body = await _body(req);
    final id = db.transaction(() => _openCheck(
          type: body['type'] as String? ?? 'dine_in',
          tableId: body['tableId'] as String?,
          guests: body['guests'] as int?,
          customerName: _optionalText(body, 'customerName'),
          customerPhone: _optionalText(body, 'customerPhone'),
          address: _optionalText(body, 'address'),
          note: _optionalText(body, 'note'),
          userId: u.id,
        ));
    _recalcCheck(id);
    _changed(orders: false);
    return _checkJson(id);
  }

  Future<Object?> _updateCheck(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!, open: true);
    final body = await _body(req);
    db.transaction(() {
      if (body['guests'] is int) db.execute('UPDATE checks SET guests = ? WHERE id = ?', [(body['guests'] as int).clamp(0, 200), c['id']]);
      for (final e in const {'customerName': 'customer_name', 'customerPhone': 'customer_phone', 'address': 'address', 'note': 'note'}.entries) {
        if (body.containsKey(e.key)) db.execute('UPDATE checks SET ${e.value} = ? WHERE id = ?', [_optionalText(body, e.key), c['id']]);
      }
      if (body.containsKey('discountCents')) {
        if (u.role != 'owner' && (u.role != 'cashier' || !_cafeBool('cashierCanDiscount'))) throw ApiError(403, 'الخصم لصاحب الكافيه بس');
        final d = body['discountCents'];
        if (d is! int || d < 0) throw ApiError(400, 'الخصم مش صحيح');
        db.execute('UPDATE checks SET discount_cents = ?, discount_note = ? WHERE id = ?', [d, _optionalText(body, 'discountNote'), c['id']]);
        _audit(u.id, 'check.discount', 'check', c['id'] as String, '#${c['number']}: ${money(d)}');
      }
      if (body['deliveryCents'] is int) db.execute('UPDATE checks SET delivery_cents = ? WHERE id = ?', [(body['deliveryCents'] as int).clamp(0, 100000000), c['id']]);
      if (body['service'] is bool) {
        if (!cashRoles.contains(u.role)) throw ApiError(403, 'مش مسموحلك');
        db.execute('UPDATE checks SET service_bp = ? WHERE id = ?', [body['service'] == true ? _cafeInt('serviceBp') : 0, c['id']]);
      }
      if (body.containsKey('type') && const {'dine_in', 'takeaway', 'delivery'}.contains(body['type'])) {
        db.execute('UPDATE checks SET type = ? WHERE id = ?', [body['type'], c['id']]);
      }
      if (body.containsKey('billRequested')) db.execute('UPDATE checks SET bill_requested = ? WHERE id = ?', [body['billRequested'] == true ? 1 : 0, c['id']]);
    });
    _recalcCheck(c['id'] as String);
    _changed(orders: false);
    return _checkJson(c['id'] as String);
  }

  Future<Object?> _addOrderRoute(Request req, AuthUser u) async {
    await _requireLicense();
    final c = _loadCheck(req.params['id']!, open: true);
    final body = await _body(req);
    final lines = (body['lines'] as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final orderId = db.transaction(() => _createOrder(
          source: u.role == 'waiter' ? 'waiter' : 'cashier',
          priced: _priceLines(lines, fromQr: false),
          checkId: c['id'] as String,
          tableId: c['table_id'] as String?,
          note: _optionalText(body, 'note'),
          userId: u.id,
        ));
    _changed();
    return {'orderId': orderId, ..._checkJson(c['id'] as String)};
  }

  Future<Object?> _moveCheck(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!, open: true);
    final body = await _body(req);
    final tableId = body['tableId'] as String?;
    if (tableId == null || db.selectOne('SELECT id FROM tables WHERE id = ? AND active = 1', [tableId]) == null) throw ApiError(400, 'اختار الترابيزة');
    if (db.selectOne("SELECT id FROM checks WHERE table_id = ? AND status = 'open' AND id <> ?", [tableId, c['id']]) != null) {
      throw ApiError(409, 'الترابيزة دي عليها حساب مفتوح. استخدم "دمج" بدل النقل');
    }
    db.transaction(() {
      db.execute("UPDATE checks SET table_id = ?, type = 'dine_in', updated_at = ? WHERE id = ?", [tableId, nowIso(), c['id']]);
      db.execute("UPDATE orders SET table_id = ? WHERE check_id = ?", [tableId, c['id']]);
      db.execute("UPDATE service_calls SET table_id = ? WHERE check_id = ? AND status = 'open'", [tableId, c['id']]);
    });
    _audit(u.id, 'check.move', 'check', c['id'] as String, '#${c['number']}');
    _changed();
    return _checkJson(c['id'] as String);
  }

  /// دمج حساب ده جوه حساب تاني (مثلاً ترابيزتين اتجمعوا).
  Future<Object?> _mergeCheck(Request req, AuthUser u) async {
    final from = _loadCheck(req.params['id']!, open: true);
    final body = await _body(req);
    final into = _loadCheck(body['intoCheckId'] as String? ?? '', open: true);
    if (from['id'] == into['id']) throw ApiError(400, 'اختار حساب تاني');
    db.transaction(() {
      for (final t in ['orders', 'order_items', 'payments', 'service_calls']) {
        db.execute('UPDATE $t SET check_id = ? WHERE check_id = ?', [into['id'], from['id']]);
      }
      db.execute("UPDATE orders SET table_id = ? WHERE check_id = ?", [into['table_id'], into['id']]);
      db.execute(
        "UPDATE checks SET discount_cents = discount_cents + ?, status = 'void', void_reason = ?, closed_at = ?, closed_by = ?, updated_at = ? WHERE id = ?",
        [0, 'اتدمج في حساب #${into['number']}', nowIso(), u.id, nowIso(), from['id']],
      );
      db.execute('UPDATE checks SET discount_cents = discount_cents + ? WHERE id = ?', [from['discount_cents'], into['id']]);
    });
    _recalcCheck(from['id'] as String);
    _recalcCheck(into['id'] as String);
    _audit(u.id, 'check.merge', 'check', into['id'] as String, '#${from['number']} ← #${into['number']}');
    _changed();
    return _checkJson(into['id'] as String);
  }

  /// تقسيم الحساب: الأصناف المختارة بتطلع في حساب جديد (عشان كل واحد يدفع اللي عليه).
  Future<Object?> _splitCheck(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!, open: true);
    final body = await _body(req);
    final lines = (body['lines'] as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    if (lines.isEmpty) throw ApiError(400, 'اختار الأصناف اللي هتتقسم');
    final newId = db.transaction(() {
      final tableName = c['table_id'] == null ? null : db.selectOne('SELECT name FROM tables WHERE id = ?', [c['table_id']])?['name'];
      final newId = _openCheck(
        type: c['type'] == 'dine_in' ? 'takeaway' : c['type'] as String,
        customerName: _optionalText(body, 'name') ?? (tableName != null ? 'من ترابيزة $tableName' : 'من حساب #${c['number']}'),
        userId: u.id,
        note: 'متقسم من حساب #${c['number']}',
      );
      // الحساب المتقسم بياخد نفس الخدمة والضريبة بتوع الأصلي
      db.execute('UPDATE checks SET type = ?, service_bp = ?, tax_bp = ? WHERE id = ?', [c['type'], c['service_bp'], c['tax_bp'], newId]);
      var moved = 0;
      for (final l in lines) {
        final line = db.selectOne("SELECT * FROM order_items WHERE id = ? AND check_id = ? AND status <> 'void'", [l['id'], c['id']]);
        if (line == null) throw ApiError(400, 'فيه صنف مش في الحساب ده');
        final qty = l['qty'] is int ? (l['qty'] as int).clamp(1, line['qty'] as int) : line['qty'] as int;
        if (qty == line['qty']) {
          db.execute('UPDATE order_items SET check_id = ? WHERE id = ?', [newId, line['id']]);
        } else {
          db.execute('UPDATE order_items SET qty = qty - ? WHERE id = ?', [qty, line['id']]);
          db.execute(
            'INSERT INTO order_items(id, order_id, check_id, item_id, name, qty, unit_price_cents, cost_cents, modifiers, note, station_id, guest, status, created_at, updated_at) '
            'SELECT ?, order_id, ?, item_id, name, ?, unit_price_cents, cost_cents, modifiers, note, station_id, guest, status, created_at, ? FROM order_items WHERE id = ?',
            [_uuid.v4(), newId, qty, nowIso(), line['id']],
          );
        }
        moved++;
      }
      if (moved == 0) throw ApiError(400, 'اختار الأصناف اللي هتتقسم');
      return newId;
    });
    _recalcCheck(c['id'] as String);
    _recalcCheck(newId);
    _audit(u.id, 'check.split', 'check', c['id'] as String, '#${c['number']}');
    _changed(orders: false);
    return _checkJson(newId);
  }

  /// بيتأكد إن الحساب ينفع يتقفل. [paying] = مبلغ لسه هيتدفع دلوقتي مع القفل.
  void _ensureClosable(Map<String, Object?> check, {int paying = 0}) {
    final due = (check['total_cents'] as int) - (check['paid_cents'] as int) - paying;
    if (due > 0) {
      throw ApiError(400, paying > 0 ? 'الحساب ماتقفلش ومفيش فلوس اتسجلت: الباقي بقى ${money(due + paying)} (غالباً اتضاف طلب جديد)' : 'لسه فاضل ${money(due)} على الحساب');
    }
    if (db.selectOne("SELECT id FROM payments WHERE check_id = ? AND status = 'pending'", [check['id']]) != null) {
      throw ApiError(400, 'فيه تحويل مستني تأكيد. أكّده أو ارفضه الأول');
    }
    if (db.selectOne("SELECT id FROM orders WHERE check_id = ? AND status = 'pending'", [check['id']]) != null) {
      throw ApiError(400, 'فيه طلب لسه مستني موافقة على الحساب ده');
    }
  }

  Future<Object?> _closeCheck(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!, open: true);
    _recalcCheck(c['id'] as String);
    final fresh = _loadCheck(c['id'] as String);
    _ensureClosable(fresh);
    db.transaction(() {
      final now = nowIso();
      db.execute(
        "UPDATE checks SET status = 'closed', closed_at = ?, closed_by = ?, bill_requested = 0, session_id = COALESCE(session_id, ?), updated_at = ? WHERE id = ?",
        [now, u.id, _openRegisterId(), now, c['id']],
      );
      // الأصناف اللي لسه في البار بتعتبر اتقدمت
      db.execute("UPDATE order_items SET status = 'served' WHERE check_id = ? AND status IN ('new', 'preparing', 'ready')", [c['id']]);
      db.execute("UPDATE orders SET status = 'served', served_at = COALESCE(served_at, ?) WHERE check_id = ? AND status IN ('accepted', 'ready')", [now, c['id']]);
      db.execute("UPDATE service_calls SET status = 'done', done_by = ?, done_at = ? WHERE check_id = ? AND status = 'open'", [u.id, now, c['id']]);
      _earnPoints(c['id'] as String);
    });
    _audit(u.id, 'check.close', 'check', c['id'] as String, '#${c['number']} ${money(fresh['total_cents'] as int)}');
    _changed();
    _broadcast('calls');
    return _checkJson(c['id'] as String);
  }

  Future<Object?> _voidCheck(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!, open: true);
    final body = await _body(req);
    final reason = _requiredText(body, 'reason', 'سبب الإلغاء');
    if (db.selectOne("SELECT id FROM payments WHERE check_id = ? AND status = 'confirmed'", [c['id']]) != null) {
      throw ApiError(400, 'الحساب عليه دفعات. رجّعها الأول قبل الإلغاء');
    }
    db.transaction(() {
      for (final line in db.select("SELECT * FROM order_items WHERE check_id = ? AND status = 'new'", [c['id']])) {
        _returnStock(line, u.id);
      }
      db.execute("UPDATE order_items SET status = 'void', void_reason = ?, voided_by = ? WHERE check_id = ? AND status <> 'void'", [reason, u.id, c['id']]);
      db.execute("UPDATE orders SET status = 'cancelled' WHERE check_id = ? AND status IN ('pending', 'accepted', 'ready')", [c['id']]);
      db.execute("UPDATE checks SET status = 'void', void_reason = ?, closed_at = ?, closed_by = ? WHERE id = ?", [reason, nowIso(), u.id, c['id']]);
      db.execute("UPDATE service_calls SET status = 'done', done_at = ? WHERE check_id = ? AND status = 'open'", [nowIso(), c['id']]);
    });
    _recalcCheck(c['id'] as String);
    _audit(u.id, 'check.void', 'check', c['id'] as String, '#${c['number']}: $reason');
    _changed();
    return _checkJson(c['id'] as String);
  }

  Future<Object?> _reopenCheck(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!);
    if (c['status'] != 'closed') throw ApiError(400, 'الحساب ده مش مقفول');
    if (c['table_id'] != null && db.selectOne("SELECT id FROM checks WHERE table_id = ? AND status = 'open'", [c['table_id']]) != null) {
      throw ApiError(409, 'الترابيزة عليها حساب تاني مفتوح دلوقتي');
    }
    db.transaction(() {
      _unearnPoints(c['id'] as String);
      db.execute("UPDATE checks SET status = 'open', closed_at = NULL, closed_by = NULL, updated_at = ? WHERE id = ?", [nowIso(), c['id']]);
    });
    _audit(u.id, 'check.reopen', 'check', c['id'] as String, '#${c['number']}');
    _changed(orders: false);
    return _checkJson(c['id'] as String);
  }

  Future<Object?> _printCheck(Request req, AuthUser u) async {
    final c = _loadCheck(req.params['id']!);
    final body = await _body(req);
    final kind = body['kind'] == 'receipt' ? 'receipt' : 'bill';
    _queuePrint(null, kind, c['id'] as String, {'checkId': c['id']});
    return {'ok': true};
  }

  // ---------------------------------------------------------------- orders

  Object? _listOrders(Request req, AuthUser u) {
    final status = req.url.queryParameters['status'] ?? 'pending';
    final rows = status == 'active'
        ? db.select("SELECT * FROM orders WHERE status IN ('pending', 'accepted', 'ready') ORDER BY created_at")
        : db.select('SELECT * FROM orders WHERE status = ? ORDER BY created_at DESC LIMIT 200', [status]);
    return {'orders': rows.map((o) => _orderJson(o)).toList()};
  }

  Object? _acceptOrderRoute(Request req, AuthUser u) {
    final o = _loadOrder(req.params['id']!);
    db.transaction(() => _acceptOrder(o['id'] as String, u.id));
    _audit(u.id, 'order.accept', 'order', o['id'] as String, '#${o['number']}');
    _changed();
    _broadcast('payments');
    return _orderJson(_loadOrder(o['id'] as String));
  }

  Future<Object?> _rejectOrderRoute(Request req, AuthUser u) async {
    final o = _loadOrder(req.params['id']!);
    final body = await _body(req);
    final reason = _optionalText(body, 'reason') ?? 'الطلب اترفض';
    db.transaction(() => _rejectOrder(o['id'] as String, reason, u.id));
    _audit(u.id, 'order.reject', 'order', o['id'] as String, '#${o['number']}: $reason');
    _changed();
    _broadcast('payments');
    return _orderJson(_loadOrder(o['id'] as String));
  }

  /// البار/المطبخ بيعلّم أصناف الطلب جاهزة (كلها، أو اللي في مكان تحضير واحد).
  Future<Object?> _orderReadyRoute(Request req, AuthUser u) async {
    final o = _loadOrder(req.params['id']!);
    final body = await _body(req);
    final station = body['stationId'] as String?;
    db.transaction(() {
      db.execute(
        "UPDATE order_items SET status = 'ready', updated_at = ? WHERE order_id = ? AND status IN ('new', 'preparing')${station == null ? '' : ' AND station_id IS ?'}",
        [nowIso(), o['id'], ?station],
      );
      _refreshOrderStatus(o['id'] as String);
    });
    _changed();
    return {'ok': true};
  }

  Object? _orderServedRoute(Request req, AuthUser u) {
    final o = _loadOrder(req.params['id']!);
    db.transaction(() {
      db.execute("UPDATE order_items SET status = 'served', updated_at = ? WHERE order_id = ? AND status <> 'void'", [nowIso(), o['id']]);
      _refreshOrderStatus(o['id'] as String);
    });
    _changed();
    return {'ok': true};
  }

  Future<Object?> _itemStatusRoute(Request req, AuthUser u) async {
    final line = db.selectOne('SELECT * FROM order_items WHERE id = ?', [req.params['id']]);
    if (line == null) throw ApiError(404, 'الصنف ده مش موجود');
    final body = await _body(req);
    final status = body['status'];
    if (!const {'new', 'preparing', 'ready', 'served'}.contains(status)) throw ApiError(400, 'الحالة مش صحيحة');
    if (line['status'] == 'void') throw ApiError(400, 'الصنف ده اتلغى');
    db.transaction(() {
      db.execute('UPDATE order_items SET status = ?, updated_at = ? WHERE id = ?', [status, nowIso(), line['id']]);
      _refreshOrderStatus(line['order_id'] as String);
    });
    _changed();
    return {'ok': true};
  }

  Future<Object?> _voidItemRoute(Request req, AuthUser u) async {
    final line = db.selectOne('SELECT * FROM order_items WHERE id = ?', [req.params['id']]);
    if (line == null) throw ApiError(404, 'الصنف ده مش موجود');
    if (line['status'] == 'void') throw ApiError(400, 'الصنف ده اتلغى بالفعل');
    final c = line['check_id'] == null ? null : _loadCheck(line['check_id'] as String, open: true);
    final body = await _body(req);
    final reason = _requiredText(body, 'reason', 'سبب الإلغاء');
    // الإلغاء بعد ما الصنف اتبعت للبار: للكاشير، أو للمالك بس لو الكافيه عايز كده
    if (u.role == 'waiter' && line['status'] != 'new') throw ApiError(403, 'الصنف اتحضر، الإلغاء من الكاشير');
    if (_cafeBool('voidNeedsOwner') && !u.isOwner && line['status'] != 'new') throw ApiError(403, 'إلغاء صنف اتحضر محتاج صاحب الكافيه');
    final qty = body['qty'] is int ? (body['qty'] as int).clamp(1, line['qty'] as int) : line['qty'] as int;
    db.transaction(() {
      var target = line;
      if (qty < (line['qty'] as int)) {
        // إلغاء جزء من الكمية: بنفصل الجزء الملغي في سطر لوحده
        final newId = _uuid.v4();
        db.execute('UPDATE order_items SET qty = qty - ? WHERE id = ?', [qty, line['id']]);
        db.execute(
          'INSERT INTO order_items(id, order_id, check_id, item_id, name, qty, unit_price_cents, cost_cents, modifiers, note, station_id, guest, status, created_at, updated_at) '
          'SELECT ?, order_id, check_id, item_id, name, ?, unit_price_cents, cost_cents, modifiers, note, station_id, guest, status, created_at, ? FROM order_items WHERE id = ?',
          [newId, qty, nowIso(), line['id']],
        );
        target = db.selectOne('SELECT * FROM order_items WHERE id = ?', [newId])!;
      }
      if (target['status'] == 'new') _returnStock(target, u.id);
      db.execute("UPDATE order_items SET status = 'void', void_reason = ?, voided_by = ?, updated_at = ? WHERE id = ?", [reason, u.id, nowIso(), target['id']]);
      _refreshOrderStatus(line['order_id'] as String);
      if (line['status'] != 'new' || line['station_id'] != null) {
        _queuePrint(line['station_id'] as String?, 'void', line['order_id'] as String, {
          'orderNumber': _loadOrder(line['order_id'] as String)['number'],
          'tableName': c?['table_id'] == null ? null : db.selectOne('SELECT name FROM tables WHERE id = ?', [c!['table_id']])?['name'],
          'items': [
            {'name': line['name'], 'qty': qty, 'modifiers': jsonDecode(line['modifiers'] as String)},
          ],
          'reason': reason,
        });
      }
    });
    if (c != null) _recalcCheck(c['id'] as String);
    _audit(u.id, 'order.void_item', 'order_item', line['id'] as String, '${line['name']} × $qty: $reason');
    _changed();
    return c == null ? {'ok': true} : _checkJson(c['id'] as String);
  }

  // ---------------------------------------------------------------- KDS (شاشة البار / المطبخ)

  /// شاشة البار/المطبخ: الطلبات والأصناف بسؤالين بس مهما كان عدد الطلبات
  /// (قبل كده كان فيه 4 أسئلة لكل طلب، وكانت بتاخد 5 ثواني في اختبار الضغط).
  Object? _kdsJson(Request req, AuthUser u) {
    final station = req.url.queryParameters['station'];
    final hasStation = station != null && station.isNotEmpty;
    const live = "('new', 'preparing', 'ready')";
    final stationFilter = hasStation ? ' AND oi.station_id IS ?' : '';
    final orders = db.select(
      'SELECT o.*, c.type AS check_type, c.customer_name AS check_customer, t.name AS table_name, pm.name AS pm_name, pm.kind AS pm_kind '
      'FROM orders o LEFT JOIN checks c ON c.id = o.check_id LEFT JOIN tables t ON t.id = o.table_id LEFT JOIN pay_methods pm ON pm.id = o.pay_method_id '
      "WHERE o.status IN ('accepted', 'ready') AND EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.id AND oi.status IN $live$stationFilter) "
      'ORDER BY o.accepted_at LIMIT $kdsLimit',
      [if (hasStation) station],
    );
    final byOrder = <String, List<Map<String, Object?>>>{};
    if (orders.isNotEmpty) {
      final ids = orders.map((o) => o['id']).toList();
      final items = db.select(
        'SELECT * FROM order_items oi WHERE oi.order_id IN (${List.filled(ids.length, '?').join(', ')}) AND oi.status IN $live$stationFilter ORDER BY rowid',
        [...ids, if (hasStation) station],
      );
      for (final it in items) {
        byOrder.putIfAbsent(it['order_id'] as String, () => []).add(it);
      }
    }
    return {
      'orders': orders
          .map((o) => {
                ..._orderJson(o, withItems: false, joined: true),
                'checkType': o['check_type'],
                'customerName': o['check_customer'],
                'items': (byOrder[o['id']] ?? const []).map(_orderItemJson).toList(),
              })
          .toList(),
    };
  }

  // ---------------------------------------------------------------- service calls

  Map<String, Object?> _callJson(Map<String, Object?> c) {
    final t = c['table_id'] == null ? null : db.selectOne('SELECT name FROM tables WHERE id = ?', [c['table_id']]);
    final pm = c['pay_method_id'] == null ? null : db.selectOne('SELECT name FROM pay_methods WHERE id = ?', [c['pay_method_id']]);
    return {
      'id': c['id'],
      'type': c['type'],
      'tableId': c['table_id'],
      'tableName': t?['name'],
      'checkId': c['check_id'],
      'note': c['note'],
      'payMethodName': pm?['name'],
      'createdAt': c['created_at'],
    };
  }

  Object? _listCalls(Request req, AuthUser u) =>
      {'calls': db.select("SELECT * FROM service_calls WHERE status = 'open' ORDER BY created_at").map(_callJson).toList()};

  Object? _callDone(Request req, AuthUser u) {
    final c = db.selectOne('SELECT * FROM service_calls WHERE id = ?', [req.params['id']]);
    if (c == null) throw ApiError(404, 'النداء ده مش موجود');
    db.execute("UPDATE service_calls SET status = 'done', done_by = ?, done_at = ? WHERE id = ?", [u.id, nowIso(), c['id']]);
    _broadcast('calls');
    _broadcast('tables');
    return {'ok': true};
  }

  /// أرقام سريعة لشريط التنبيهات (طلبات مستنية، نداءات، تحويلات).
  Map<String, Object?> _liveCounts() => {
        'pendingOrders': db.selectOne("SELECT COUNT(*) AS c FROM orders WHERE status = 'pending'")!['c'],
        'readyOrders': db.selectOne("SELECT COUNT(*) AS c FROM orders WHERE status = 'ready'")!['c'],
        'openCalls': db.selectOne("SELECT COUNT(*) AS c FROM service_calls WHERE status = 'open'")!['c'],
        'pendingPayments': db.selectOne("SELECT COUNT(*) AS c FROM payments WHERE status = 'pending'")!['c'],
        'registerOpen': _openRegisterId() != null,
      };

  // ---------------------------------------------------------------- printing

  void _queuePrint(String? stationId, String kind, String? refId, Map<String, Object?> payload) {
    db.execute(
      'INSERT INTO print_jobs(id, station_id, kind, ref_id, payload, created_at) VALUES(?, ?, ?, ?, ?, ?)',
      [_uuid.v4(), stationId, kind, refId, jsonEncode(payload), nowIso()],
    );
    _broadcast('print');
  }

  /// تيكت لكل مكان تحضير فيه أصناف من الطلب.
  void _queueKitchenTickets(String orderId) {
    final o = _loadOrder(orderId);
    final check = o['check_id'] == null ? null : db.selectOne('SELECT * FROM checks WHERE id = ?', [o['check_id']]);
    final tableName = o['table_id'] == null ? null : db.selectOne('SELECT name FROM tables WHERE id = ?', [o['table_id']])?['name'];
    final byStation = <String?, List<Map<String, Object?>>>{};
    for (final i in db.select("SELECT * FROM order_items WHERE order_id = ? AND status <> 'void' ORDER BY rowid", [orderId])) {
      byStation.putIfAbsent(i['station_id'] as String?, () => []).add(i);
    }
    final waiter = o['user_id'] == null ? null : db.selectOne('SELECT name FROM users WHERE id = ?', [o['user_id']])?['name'];
    for (final e in byStation.entries) {
      if (e.key == null) continue; // أصناف من غير مكان تحضير (زي المياه) مش محتاجة تيكت
      final station = db.selectOne('SELECT name FROM stations WHERE id = ?', [e.key]);
      _queuePrint(e.key, 'ticket', orderId, {
        'stationName': station?['name'],
        'orderNumber': o['number'],
        'checkNumber': check?['number'],
        'type': check?['type'],
        'tableName': tableName,
        'customerName': o['guest_name'] ?? check?['customer_name'],
        'customerPhone': o['guest_phone'] ?? check?['customer_phone'],
        'source': o['source'],
        'waiter': waiter,
        'note': o['note'],
        'createdAt': o['created_at'],
        'items': e.value.map((i) => {'name': i['name'], 'qty': i['qty'], 'modifiers': jsonDecode(i['modifiers'] as String), 'note': i['note'], 'guest': i['guest']}).toList(),
      });
    }
  }

  /// جهاز الطباعة بياخد الشغل بتاع الأماكن اللي هو مسؤول عنها ('receipt' = الحسابات والفواتير).
  Object? _claimPrintJobs(Request req, AuthUser u) {
    final q = req.url.queryParameters;
    final stations = (q['stations'] ?? '').split(',').where((s) => s.isNotEmpty).toList();
    if (stations.isEmpty) return {'jobs': const []};
    final device = q['device'] ?? u.id;
    final receipt = stations.remove('receipt');
    final stale = DateTime.now().toUtc().subtract(const Duration(minutes: 2)).toIso8601String();
    final conds = <String>[
      if (stations.isNotEmpty) 'station_id IN (${List.filled(stations.length, '?').join(',')})',
      if (receipt) 'station_id IS NULL',
    ];
    final rows = db.transaction(() {
      final rows = db.select(
        "SELECT * FROM print_jobs WHERE (status = 'queued' OR (status = 'printing' AND claimed_at < ?)) AND (${conds.join(' OR ')}) "
        'ORDER BY created_at LIMIT 10',
        [stale, ...stations],
      );
      for (final j in rows) {
        db.execute("UPDATE print_jobs SET status = 'printing', claimed_by = ?, claimed_at = ? WHERE id = ?", [device, nowIso(), j['id']]);
      }
      return rows;
    });
    return {
      'jobs': rows
          .map((j) => {'id': j['id'], 'stationId': j['station_id'], 'kind': j['kind'], 'refId': j['ref_id'], 'payload': jsonDecode(j['payload'] as String), 'createdAt': j['created_at']})
          .toList(),
    };
  }

  Future<Object?> _printResult(Request req, AuthUser u) async {
    final body = await _body(req);
    final ok = body['ok'] == true;
    db.execute(
      'UPDATE print_jobs SET status = ?, error = ?, printed_at = ? WHERE id = ?',
      [ok ? 'done' : 'failed', ok ? null : (body['error'] as String? ?? 'الطباعة فشلت'), ok ? nowIso() : null, req.params['id']],
    );
    if (!ok) _broadcast('print_failed');
    return {'ok': true};
  }

  void _cleanupPrintJobs() {
    final old = DateTime.now().toUtc().subtract(const Duration(days: 3)).toIso8601String();
    db.execute("DELETE FROM print_jobs WHERE created_at < ? AND status IN ('done', 'failed')", [old]);
    // الشغل اللي محدش طبعه في يوم بيتلغي (عشان لو طابعة اتشغلت بكرة ما تطبعش طلبات قديمة)
    db.execute("UPDATE print_jobs SET status = 'failed', error = 'محدش طبعه' WHERE status = 'queued' AND created_at < ?",
        [DateTime.now().toUtc().subtract(const Duration(hours: 12)).toIso8601String()]);
  }
}
