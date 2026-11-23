part of 'api_server.dart';

/// تقرير كل يوم شغل لوحده، وتقرير كل وردية (تسليم درج). بيتبعتوا للمالك على Firebase (cloud_sync.dart)
/// مع كل قفل درج وأول ما اليوم يخلص، وبيتعرضوا هنا للمالك على الشبكة.
///
/// اليوم بيتحسب بوقت كل عملية (business_day.dart)، مش بالوردية: وردية بدأت قبل نهاية اليوم وخلصت بعدها
/// بتظهر في تقرير اليومين، وكل يوم بياخد بيعه هو بس (فمجموع الورديات ممكن مايساويش اليوم، والتقرير بيقول كده).
extension _DayReports on OrderlyServer {
  void _registerDayReportRoutes(Router r) {
    r.get('/api/reports/day', _authed((req, u) {
      final date = BusinessDay.parseKey(req.url.queryParameters['date']) ?? _bday.dateOf(DateTime.now());
      return _dayReport(date);
    }, only: {'owner'}));
    r.get('/api/reports/shift/<id>', _authed((req, u) {
      final s = db.selectOne('SELECT * FROM register_sessions WHERE id = ?', [req.params['id']]);
      if (s == null) throw ApiError(404, 'الوردية دي مش موجودة');
      return _shiftReport(s);
    }, only: {'owner'}));
  }

  static const _reportTop = 20;

  /// كل أرقام يوم شغل واحد. [date] = تاريخ اليوم (من غير ساعة).
  Map<String, Object?> _dayReport(DateTime date) {
    final bd = _bday;
    final (start, end) = bd.rangeOf(date);
    final from = start.toUtc().toIso8601String(), to = end.toUtc().toIso8601String();
    final today = bd.dateOf(DateTime.now());
    const closed = "c.status = 'closed' AND c.closed_at >= ? AND c.closed_at < ?";

    final t = db.selectOne(
      'SELECT COUNT(*) AS n, COALESCE(SUM(subtotal_cents), 0) AS subtotal, COALESCE(SUM(discount_cents), 0) AS discount, '
      'COALESCE(SUM(CASE WHEN discount_cents > 0 THEN 1 ELSE 0 END), 0) AS discounted, '
      'COALESCE(SUM(service_cents), 0) AS service, COALESCE(SUM(tax_cents), 0) AS tax, COALESCE(SUM(delivery_cents), 0) AS delivery, '
      'COALESCE(SUM(total_cents), 0) AS total, COALESCE(SUM(guests), 0) AS guests, COALESCE(SUM(points_used), 0) AS points '
      'FROM checks c WHERE $closed',
      [from, to],
    )!;
    final cost = db.selectOne(
      "SELECT COALESCE(SUM(oi.qty * oi.cost_cents), 0) AS s FROM order_items oi JOIN checks c ON c.id = oi.check_id WHERE $closed AND oi.status <> 'void'",
      [from, to],
    )!['s'] as int;
    final total = t['total'] as int, checks = t['n'] as int;

    final byHour = List<int>.filled(24, 0);
    for (final r in db.select('SELECT closed_at, total_cents FROM checks c WHERE $closed', [from, to])) {
      byHour[DateTime.parse(r['closed_at'] as String).toLocal().hour] += r['total_cents'] as int;
    }

    final expenses = db
        .select(
          "SELECT COALESCE(category, '') AS cat, COUNT(*) AS n, SUM(-amount_cents) AS s FROM cash_moves "
          "WHERE type = 'expense' AND created_at >= ? AND created_at < ? GROUP BY cat ORDER BY s DESC",
          [from, to],
        )
        .map((r) => {'name': (r['cat'] as String).isEmpty ? 'من غير تصنيف' : r['cat'], 'count': r['n'], 'amountCents': r['s']})
        .toList();

    final voids = db.select(
      "SELECT oi.name, oi.qty, oi.qty * oi.unit_price_cents AS amount, oi.void_reason, us.name AS by FROM order_items oi "
      "JOIN orders o ON o.id = oi.order_id LEFT JOIN users us ON us.id = oi.voided_by "
      "WHERE oi.status = 'void' AND o.status <> 'rejected' AND oi.updated_at >= ? AND oi.updated_at < ? ORDER BY amount DESC",
      [from, to],
    );
    final voidedChecks = db.selectOne(
      "SELECT COUNT(*) AS n, COALESCE(SUM(total_cents), 0) AS s FROM checks WHERE status = 'void' AND updated_at >= ? AND updated_at < ?",
      [from, to],
    )!;
    final fb = db.selectOne('SELECT COUNT(*) AS n, AVG(rating) AS avg FROM feedback WHERE created_at >= ? AND created_at < ?', [from, to])!;
    final shifts = db
        .select('SELECT * FROM register_sessions WHERE opened_at < ? AND (closed_at IS NULL OR closed_at >= ?) ORDER BY opened_at', [to, from])
        .map((s) => _shiftLine(s, from, to))
        .toList();

    return {
      'v': 1,
      'date': BusinessDay.keyOf(date),
      'from': from,
      'to': to,
      'hours': {'open': BusinessDay.formatMinutes(bd.open), 'close': BusinessDay.formatMinutes(bd.close)},
      // اليوم خلص (التقرير النهائي)، ولا لسه شغال
      'final': date.isBefore(today),
      'shop': _localNames().shop,
      'branch': _localNames().branch,
      'sales': {
        'checks': checks,
        'totalCents': total,
        'subtotalCents': t['subtotal'],
        'discountCents': t['discount'],
        'discountedChecks': t['discounted'],
        'serviceCents': t['service'],
        'taxCents': t['tax'],
        'deliveryCents': t['delivery'],
        'guests': t['guests'],
        'pointsUsed': t['points'],
        'avgCheckCents': checks == 0 ? 0 : total ~/ checks,
        'costCents': cost,
        'grossProfitCents': (t['subtotal'] as int) - cost,
      },
      'byMethod': db
          .select(
            "SELECT method_name AS name, method_kind AS kind, COUNT(*) AS n, SUM(amount_cents) AS s FROM payments "
            "WHERE status = 'confirmed' AND created_at >= ? AND created_at < ? GROUP BY method_name ORDER BY s DESC",
            [from, to],
          )
          .map((r) => {'name': r['name'], 'kind': r['kind'], 'count': r['n'], 'amountCents': r['s']})
          .toList(),
      'byType': db
          .select('SELECT type, COUNT(*) AS n, SUM(total_cents) AS s FROM checks c WHERE $closed GROUP BY type', [from, to])
          .map((r) => {'type': r['type'], 'count': r['n'], 'amountCents': r['s']})
          .toList(),
      'bySource': db
          .select(
            "SELECT o.source, COUNT(DISTINCT o.id) AS n FROM orders o JOIN checks c ON c.id = o.check_id "
            "WHERE $closed AND o.status NOT IN ('rejected', 'cancelled') GROUP BY o.source",
            [from, to],
          )
          .map((r) => {'source': r['source'], 'orders': r['n']})
          .toList(),
      'byHour': byHour,
      'expenses': {'totalCents': expenses.fold<int>(0, (s, e) => s + (e['amountCents'] as int)), 'byCategory': expenses},
      'voids': {
        'count': voids.length,
        'amountCents': voids.fold<int>(0, (s, v) => s + (v['amount'] as int)),
        'items': voids.take(_reportTop).map((v) => {'name': v['name'], 'qty': v['qty'], 'amountCents': v['amount'], 'reason': v['void_reason'], 'by': v['by']}).toList(),
        'checks': voidedChecks['n'],
        'checksAmountCents': voidedChecks['s'],
      },
      'top': _topItems(from, to, limit: _reportTop).map((i) => {'name': i['name'], 'qty': i['qty'], 'revenueCents': i['revenueCents']}).toList(),
      'feedback': {'count': fb['n'], 'avg': fb['avg'] == null ? null : ((fb['avg'] as num) * 10).round() / 10},
      'shifts': shifts,
      'cash': {
        'expectedCents': shifts.fold<int>(0, (s, x) => s + (x['expectedCashCents'] as int? ?? 0)),
        'countedCents': shifts.fold<int>(0, (s, x) => s + (x['countedCashCents'] as int? ?? 0)),
        'diffCents': shifts.fold<int>(0, (s, x) => s + (x['diffCents'] as int? ?? 0)),
      },
      'open': date.isBefore(today) ? null : db.selectOne("SELECT COUNT(*) AS n, COALESCE(SUM(total_cents), 0) AS t FROM checks WHERE status = 'open'"),
      'lowStock': db.selectOne('SELECT COUNT(*) AS c FROM ingredients WHERE active = 1 AND qty <= low_stock')!['c'],
    };
  }

  /// سطر الوردية جوه تقرير اليوم.
  Map<String, Object?> _shiftLine(Map<String, Object?> s, String dayFrom, String dayTo) {
    final sum = _sessionSummary(s);
    final counted = sum['countedCashCents'] as int?;
    final expected = sum['expectedCashCents'] as int?;
    return {
      'id': s['id'],
      'openedAt': sum['openedAt'],
      'openedBy': sum['openedBy'],
      'closedAt': sum['closedAt'],
      'closedBy': sum['closedBy'],
      'salesCents': sum['salesCents'],
      'checksClosed': sum['checksClosed'],
      'expectedCashCents': expected,
      'countedCashCents': counted,
      'diffCents': counted == null || expected == null ? null : counted - expected,
      // الوردية داخلة على يومين: أرقامها مش كلها في اليوم ده
      'spansDays': (s['opened_at'] as String).compareTo(dayFrom) < 0 || (s['closed_at'] != null && (s['closed_at'] as String).compareTo(dayTo) >= 0),
    };
  }

  /// تقرير وردية (تسليم درج) كامل.
  Map<String, Object?> _shiftReport(Map<String, Object?> s) {
    final sum = _sessionSummary(s);
    final from = s['opened_at'] as String;
    final to = (s['closed_at'] as String?) ?? DateTime.now().toUtc().toIso8601String();
    final counted = sum['countedCashCents'] as int?;
    final expected = sum['expectedCashCents'] as int?;
    final bd = _bday;
    final opened = bd.dateOf(DateTime.parse(from));
    final closedDay = bd.dateOf(DateTime.parse(to));
    return {
      'v': 1,
      'id': s['id'],
      'date': BusinessDay.keyOf(opened),
      'spansDays': opened != closedDay,
      'shop': _localNames().shop,
      'branch': _localNames().branch,
      ...sum,
      'diffCents': counted == null || expected == null ? null : counted - expected,
      'expenses': db
          .select(
            "SELECT m.amount_cents, m.category, m.note, us.name AS by, m.created_at FROM cash_moves m LEFT JOIN users us ON us.id = m.user_id "
            "WHERE m.session_id = ? AND m.type IN ('expense', 'deposit', 'withdraw') ORDER BY m.created_at",
            [s['id']],
          )
          .map((m) => {'amountCents': m['amount_cents'], 'category': m['category'], 'note': m['note'], 'by': m['by'], 'at': m['created_at']})
          .toList(),
      'voids': db
          .select(
            "SELECT oi.name, oi.qty, oi.qty * oi.unit_price_cents AS amount, oi.void_reason, us.name AS by FROM order_items oi "
            "JOIN orders o ON o.id = oi.order_id LEFT JOIN users us ON us.id = oi.voided_by "
            "WHERE oi.status = 'void' AND o.status <> 'rejected' AND oi.updated_at >= ? AND oi.updated_at < ? ORDER BY amount DESC LIMIT $_reportTop",
            [from, to],
          )
          .map((v) => {'name': v['name'], 'qty': v['qty'], 'amountCents': v['amount'], 'reason': v['void_reason'], 'by': v['by']})
          .toList(),
      'top': db
          .select(
            "SELECT oi.name, SUM(oi.qty) AS qty, SUM(oi.qty * oi.unit_price_cents) AS revenue FROM order_items oi JOIN checks c ON c.id = oi.check_id "
            "WHERE c.session_id = ? AND c.status = 'closed' AND oi.status <> 'void' GROUP BY COALESCE(oi.item_id, oi.name) ORDER BY qty DESC LIMIT $_reportTop",
            [s['id']],
          )
          .map((i) => {'name': i['name'], 'qty': i['qty'], 'revenueCents': i['revenue']})
          .toList(),
    };
  }
}
