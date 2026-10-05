part of 'api_server.dart';

/// تقارير صاحب الكافيه، والعروض بالمواعيد، وتقييمات العملاء.
extension _ReportRoutes on OrderlyServer {
  void _registerReportRoutes(Router r) {
    r.get('/api/reports/summary', _authed(_reportSummary, only: {'owner'}));
    r.get('/api/reports/today', _authed(_reportToday, only: cashRoles));

    r.get('/api/promotions', _authed((req, u) => _promotionsJson(), only: cashRoles));
    r.post('/api/promotions', _authed(_savePromotion, only: {'owner'}));
    r.patch('/api/promotions/<id>', _authed(_savePromotion, only: {'owner'}));

    r.get('/api/feedback', _authed(_listFeedback, only: {'owner'}));
  }

  ({String from, String to}) _range(Request req) {
    final q = req.url.queryParameters;
    final now = DateTime.now();
    final from = DateTime.tryParse(q['from'] ?? '') ?? DateTime(now.year, now.month, now.day);
    final to = DateTime.tryParse(q['to'] ?? '') ?? from.add(const Duration(days: 1));
    if (!to.isAfter(from)) throw ApiError(400, 'الفترة مش صحيحة');
    return (from: from.toUtc().toIso8601String(), to: to.toUtc().toIso8601String());
  }

  /// ملخص سريع لليوم (للكاشير): المبيعات، والحسابات، والأصناف الأكتر.
  Object? _reportToday(Request req, AuthUser u) {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day).toUtc().toIso8601String();
    final to = DateTime(now.year, now.month, now.day + 1).toUtc().toIso8601String();
    final s = db.selectOne(
      "SELECT COUNT(*) AS n, COALESCE(SUM(total_cents), 0) AS total FROM checks WHERE status = 'closed' AND closed_at >= ? AND closed_at < ?",
      [from, to],
    )!;
    return {
      'checks': s['n'],
      'totalCents': s['total'],
      'openChecks': db.selectOne("SELECT COUNT(*) AS c, COALESCE(SUM(total_cents), 0) AS t FROM checks WHERE status = 'open'")!,
      'topItems': _topItems(from, to, limit: 5),
    };
  }

  List<Map<String, Object?>> _topItems(String from, String to, {int limit = 50}) => db
      .select(
        "SELECT oi.item_id, oi.name, SUM(oi.qty) AS qty, SUM(oi.qty * oi.unit_price_cents) AS revenue, SUM(oi.qty * oi.cost_cents) AS cost "
        "FROM order_items oi JOIN checks c ON c.id = oi.check_id "
        "WHERE c.status = 'closed' AND c.closed_at >= ? AND c.closed_at < ? AND oi.status <> 'void' "
        'GROUP BY COALESCE(oi.item_id, oi.name) ORDER BY qty DESC LIMIT ?',
        [from, to, limit],
      )
      .map((r) => {
            'itemId': r['item_id'],
            'name': r['name'],
            'qty': r['qty'],
            'revenueCents': r['revenue'],
            'costCents': r['cost'],
            'profitCents': (r['revenue'] as int) - (r['cost'] as int),
          })
      .toList();

  Object? _reportSummary(Request req, AuthUser u) {
    final range = _range(req);
    final from = range.from, to = range.to;
    const closed = "c.status = 'closed' AND c.closed_at >= ? AND c.closed_at < ?";

    final totals = db.selectOne(
      'SELECT COUNT(*) AS checks, COALESCE(SUM(subtotal_cents), 0) AS subtotal, COALESCE(SUM(discount_cents), 0) AS discount, '
      'COALESCE(SUM(service_cents), 0) AS service, COALESCE(SUM(tax_cents), 0) AS tax, COALESCE(SUM(delivery_cents), 0) AS delivery, '
      'COALESCE(SUM(total_cents), 0) AS total, COALESCE(SUM(guests), 0) AS guests, COALESCE(SUM(points_used), 0) AS points '
      'FROM checks c WHERE $closed',
      [from, to],
    )!;
    final cost = db.selectOne(
      "SELECT COALESCE(SUM(oi.qty * oi.cost_cents), 0) AS cost FROM order_items oi JOIN checks c ON c.id = oi.check_id WHERE $closed AND oi.status <> 'void'",
      [from, to],
    )!['cost'] as int;
    final expenses = db.selectOne(
      "SELECT COALESCE(SUM(-amount_cents), 0) AS s FROM cash_moves WHERE type = 'expense' AND created_at >= ? AND created_at < ?",
      [from, to],
    )!['s'] as int;
    final waste = db.selectOne(
      "SELECT COALESCE(SUM(cost_cents), 0) AS s FROM stock_moves WHERE reason = 'waste' AND created_at >= ? AND created_at < ?",
      [from, to],
    )!['s'] as int;

    final byMethod = db
        .select(
          "SELECT p.method_name AS name, p.method_kind AS kind, COUNT(*) AS n, SUM(p.amount_cents) AS s FROM payments p "
          "WHERE p.status = 'confirmed' AND p.created_at >= ? AND p.created_at < ? GROUP BY p.method_name ORDER BY s DESC",
          [from, to],
        )
        .map((r) => {'name': r['name'], 'kind': r['kind'], 'count': r['n'], 'amountCents': r['s']})
        .toList();

    final byType = db
        .select('SELECT type, COUNT(*) AS n, SUM(total_cents) AS s FROM checks c WHERE $closed GROUP BY type', [from, to])
        .map((r) => {'type': r['type'], 'count': r['n'], 'amountCents': r['s']})
        .toList();

    // ساعات الذروة (بالتوقيت المحلي)
    final byHour = List<int>.filled(24, 0);
    final checksByHour = List<int>.filled(24, 0);
    for (final r in db.select('SELECT opened_at, total_cents FROM checks c WHERE $closed', [from, to])) {
      final h = DateTime.parse(r['opened_at'] as String).toLocal().hour;
      byHour[h] += r['total_cents'] as int;
      checksByHour[h]++;
    }
    final byDay = <String, int>{};
    for (final r in db.select('SELECT closed_at, total_cents FROM checks c WHERE $closed', [from, to])) {
      final d = DateTime.parse(r['closed_at'] as String).toLocal();
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      byDay[key] = (byDay[key] ?? 0) + (r['total_cents'] as int);
    }

    final bySource = db
        .select(
          "SELECT o.source, COUNT(DISTINCT o.id) AS n, COALESCE(SUM(oi.qty * oi.unit_price_cents), 0) AS s FROM orders o "
          "JOIN order_items oi ON oi.order_id = o.id JOIN checks c ON c.id = o.check_id WHERE $closed AND oi.status <> 'void' GROUP BY o.source",
          [from, to],
        )
        .map((r) => {'source': r['source'], 'orders': r['n'], 'amountCents': r['s']})
        .toList();

    final byCategory = db
        .select(
          "SELECT COALESCE(cat.name, 'أخرى') AS name, SUM(oi.qty) AS qty, SUM(oi.qty * oi.unit_price_cents) AS s FROM order_items oi "
          'JOIN checks c ON c.id = oi.check_id LEFT JOIN items i ON i.id = oi.item_id LEFT JOIN categories cat ON cat.id = i.category_id '
          "WHERE $closed AND oi.status <> 'void' GROUP BY cat.id ORDER BY s DESC",
          [from, to],
        )
        .map((r) => {'name': r['name'], 'qty': r['qty'], 'amountCents': r['s']})
        .toList();

    final byStaff = db
        .select(
          "SELECT us.name, us.role, COUNT(DISTINCT o.id) AS orders, COALESCE(SUM(oi.qty * oi.unit_price_cents), 0) AS s FROM orders o "
          "JOIN users us ON us.id = o.user_id JOIN order_items oi ON oi.order_id = o.id JOIN checks c ON c.id = o.check_id "
          "WHERE $closed AND oi.status <> 'void' AND o.source <> 'qr' GROUP BY us.id ORDER BY s DESC",
          [from, to],
        )
        .map((r) => {'name': r['name'], 'role': r['role'], 'orders': r['orders'], 'amountCents': r['s']})
        .toList();

    final voids = db
        .select(
          "SELECT oi.name, oi.qty, oi.unit_price_cents, oi.void_reason, oi.updated_at, us.name AS user_name FROM order_items oi "
          "JOIN orders o ON o.id = oi.order_id LEFT JOIN users us ON us.id = oi.voided_by "
          "WHERE oi.status = 'void' AND o.status NOT IN ('rejected') AND oi.updated_at >= ? AND oi.updated_at < ? ORDER BY oi.updated_at DESC LIMIT 200",
          [from, to],
        )
        .map((r) => {'name': r['name'], 'qty': r['qty'], 'amountCents': (r['qty'] as int) * (r['unit_price_cents'] as int), 'reason': r['void_reason'], 'userName': r['user_name'], 'at': r['updated_at']})
        .toList();

    // سرعة التحضير: من قبول الطلب لحد ما يبقى جاهز (بالدقايق)
    final prep = db.select(
      "SELECT accepted_at, ready_at FROM orders WHERE ready_at IS NOT NULL AND accepted_at IS NOT NULL AND created_at >= ? AND created_at < ?",
      [from, to],
    );
    final prepMinutes = prep.isEmpty
        ? null
        : prep.map((r) => DateTime.parse(r['ready_at'] as String).difference(DateTime.parse(r['accepted_at'] as String)).inSeconds).reduce((a, b) => a + b) / prep.length / 60;
    // متوسط قعدة الترابيزة
    final stays = db.select("SELECT opened_at, closed_at FROM checks c WHERE $closed AND c.type = 'dine_in'", [from, to]);
    final stayMinutes = stays.isEmpty
        ? null
        : stays.map((r) => DateTime.parse(r['closed_at'] as String).difference(DateTime.parse(r['opened_at'] as String)).inMinutes).reduce((a, b) => a + b) / stays.length;

    final qrRejected = db.selectOne("SELECT COUNT(*) AS c FROM orders WHERE source = 'qr' AND status = 'rejected' AND created_at >= ? AND created_at < ?", [from, to])!['c'];
    final rating = db.selectOne('SELECT COUNT(*) AS n, AVG(rating) AS avg FROM feedback WHERE created_at >= ? AND created_at < ?', [from, to])!;

    final items = _topItems(from, to, limit: 500);
    // هندسة المنيو: الأصناف بتتقسم حسب المبيعات والربح للصنف (أعلى أو أقل من المتوسط)
    final engineering = <Map<String, Object?>>[];
    if (items.isNotEmpty) {
      final avgQty = items.fold<int>(0, (s, i) => s + (i['qty'] as int)) / items.length;
      final withMargin = items.where((i) => (i['qty'] as int) > 0).toList();
      final avgMargin = withMargin.fold<double>(0, (s, i) => s + (i['profitCents'] as int) / (i['qty'] as int)) / withMargin.length;
      for (final i in withMargin) {
        final popular = (i['qty'] as int) >= avgQty;
        final profitable = (i['profitCents'] as int) / (i['qty'] as int) >= avgMargin;
        engineering.add({
          'name': i['name'],
          'qty': i['qty'],
          'marginCents': ((i['profitCents'] as int) / (i['qty'] as int)).round(),
          'class': popular && profitable ? 'star' : popular ? 'plowhorse' : profitable ? 'puzzle' : 'dog',
        });
      }
    }

    final revenue = (totals['subtotal'] as int) - (totals['discount'] as int);
    return {
      'from': from,
      'to': to,
      'checks': totals['checks'],
      'guests': totals['guests'],
      'subtotalCents': totals['subtotal'],
      'discountCents': totals['discount'],
      'pointsUsed': totals['points'],
      'serviceCents': totals['service'],
      'taxCents': totals['tax'],
      'deliveryCents': totals['delivery'],
      'totalCents': totals['total'],
      'avgCheckCents': (totals['checks'] as int) == 0 ? 0 : ((totals['total'] as int) / (totals['checks'] as int)).round(),
      'costCents': cost,
      'grossProfitCents': revenue - cost,
      'expensesCents': expenses,
      'wasteCents': waste,
      'netCents': revenue - cost - expenses - waste,
      'byMethod': byMethod,
      'byType': byType,
      'bySource': bySource,
      'byCategory': byCategory,
      'byStaff': byStaff,
      'byHour': byHour,
      'checksByHour': checksByHour,
      'byDay': byDay.entries.map((e) => {'day': e.key, 'amountCents': e.value}).toList(),
      'items': items,
      'engineering': engineering,
      'voids': voids,
      'prepMinutes': prepMinutes,
      'stayMinutes': stayMinutes,
      'qrRejected': qrRejected,
      'ratingCount': rating['n'],
      'ratingAvg': rating['avg'],
      'lowStock': db
          .select('SELECT name, unit, qty, low_stock FROM ingredients WHERE active = 1 AND qty <= low_stock ORDER BY name')
          .map((r) => {'name': r['name'], 'unit': r['unit'], 'qty': (r['qty'] as num).toDouble(), 'lowStock': (r['low_stock'] as num).toDouble()})
          .toList(),
    };
  }

  // ---------------------------------------------------------------- promotions

  Map<String, Object?> _promotionsJson() => {
        'promotions': db.select('SELECT * FROM promotions ORDER BY active DESC, created_at DESC').map((p) => {
              'id': p['id'],
              'name': p['name'],
              'percentBp': p['percent_bp'],
              'days': jsonDecode(p['days'] as String),
              'timeFrom': p['time_from'],
              'timeTo': p['time_to'],
              'categoryIds': jsonDecode(p['category_ids'] as String),
              'itemIds': jsonDecode(p['item_ids'] as String),
              'active': p['active'] == 1,
            }).toList(),
        'activeNow': _activePromotions().map((p) => p['id']).toList(),
      };

  Future<Object?> _savePromotion(Request req, AuthUser u) async {
    final body = await _body(req);
    var id = req.params['id'];
    final timeRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
    db.transaction(() {
      if (id == null) {
        id = _uuid.v4();
        db.execute("INSERT INTO promotions(id, name, percent_bp, time_from, time_to, created_at) VALUES(?, ?, 0, '00:00', '23:59', ?)",
            [id, _requiredText(body, 'name', 'اسم العرض'), nowIso()]);
      } else {
        if (db.selectOne('SELECT id FROM promotions WHERE id = ?', [id]) == null) throw ApiError(404, 'العرض ده مش موجود');
        if (body.containsKey('name')) db.execute('UPDATE promotions SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم العرض'), id]);
      }
      if (body.containsKey('percentBp')) {
        final v = body['percentBp'];
        if (v is! int || v < 100 || v > 9000) throw ApiError(400, 'نسبة الخصم لازم تبقى من 1% لـ 90%');
        db.execute('UPDATE promotions SET percent_bp = ? WHERE id = ?', [v, id]);
      }
      if (body['days'] is List) {
        final days = (body['days'] as List).whereType<int>().where((d) => d >= 0 && d <= 6).toSet().toList()..sort();
        if (days.isEmpty) throw ApiError(400, 'اختار يوم واحد على الأقل');
        db.execute('UPDATE promotions SET days = ? WHERE id = ?', [jsonEncode(days), id]);
      }
      for (final e in const {'timeFrom': 'time_from', 'timeTo': 'time_to'}.entries) {
        if (body.containsKey(e.key)) {
          if (!timeRe.hasMatch('${body[e.key]}')) throw ApiError(400, 'الوقت مش صحيح');
          db.execute('UPDATE promotions SET ${e.value} = ? WHERE id = ?', [body[e.key], id]);
        }
      }
      if (body.containsKey('categoryIds')) db.execute('UPDATE promotions SET category_ids = ? WHERE id = ?', [jsonEncode(_idList(body['categoryIds'], 'categories')), id]);
      if (body.containsKey('itemIds')) db.execute('UPDATE promotions SET item_ids = ? WHERE id = ?', [jsonEncode(_idList(body['itemIds'], 'items')), id]);
      if (body['active'] is bool) db.execute('UPDATE promotions SET active = ? WHERE id = ?', [body['active'] == true ? 1 : 0, id]);
      final p = db.selectOne('SELECT percent_bp FROM promotions WHERE id = ?', [id])!;
      if ((p['percent_bp'] as int) == 0) throw ApiError(400, 'اكتب نسبة الخصم');
    });
    _audit(u.id, 'promotion.save', 'promotion', id, body['name'] as String?);
    _broadcast('menu');
    return _promotionsJson();
  }

  Object? _listFeedback(Request req, AuthUser u) => {
        'feedback': db
            .select('SELECT f.*, t.name AS table_name, c.number AS check_number FROM feedback f LEFT JOIN tables t ON t.id = f.table_id '
                'LEFT JOIN checks c ON c.id = f.check_id ORDER BY f.created_at DESC LIMIT 300')
            .map((f) => {'rating': f['rating'], 'comment': f['comment'], 'tableName': f['table_name'], 'checkNumber': f['check_number'], 'createdAt': f['created_at']})
            .toList(),
      };
}
