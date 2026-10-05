part of 'api_server.dart';

const ingredientUnits = {'g', 'ml', 'pcs'};

/// المخزون بالوصفات: كل صنف (وكل إضافة) ليه وصفة بالخامات اللي بيستهلكها.
/// أول ما الطلب يتقبل، الخامات بتتخصم، والصنف اللي خامته خلصت بيبقى "خلصان" في المنيو لوحده.
extension _InventoryRoutes on OrderlyServer {
  void _registerInventoryRoutes(Router r) {
    r.get('/api/ingredients', _authed(_listIngredients, only: cashRoles));
    r.post('/api/ingredients', _authed(_saveIngredient, only: {'owner'}));
    r.patch('/api/ingredients/<id>', _authed(_saveIngredient, only: {'owner'}));
    r.post('/api/ingredients/<id>/adjust', _authed(_adjustIngredient, only: cashRoles));
    r.get('/api/ingredients/<id>/moves', _authed(_ingredientMoves, only: cashRoles));

    r.get('/api/recipes/<kind>/<id>', _authed(_getRecipe, only: cashRoles));
    r.put('/api/recipes/<kind>/<id>', _authed(_setRecipe, only: {'owner'}));

    r.get('/api/suppliers', _authed(_listSuppliers, only: cashRoles));
    r.post('/api/suppliers', _authed(_saveSupplier, only: {'owner'}));
    r.patch('/api/suppliers/<id>', _authed(_saveSupplier, only: {'owner'}));
    r.post('/api/suppliers/<id>/payments', _authed(_paySupplier, only: {'owner'}));

    r.get('/api/purchases', _authed(_listPurchases, only: cashRoles));
    r.post('/api/purchases', _authed(_createPurchase, only: cashRoles));
  }

  // ---------------------------------------------------------------- ingredients

  Map<String, Object?> _ingredientJson(Map<String, Object?> r) => {
        'id': r['id'],
        'name': r['name'],
        'unit': r['unit'],
        'qty': (r['qty'] as num).toDouble(),
        'unitCost': (r['unit_cost'] as num).toDouble(),
        'lowStock': (r['low_stock'] as num).toDouble(),
        'autoHide': r['auto_hide'] == 1,
        'active': r['active'] == 1,
        'usedBy': r['used_by'] ?? 0,
      };

  Object? _listIngredients(Request req, AuthUser u) {
    final rows = db.select(
      'SELECT i.*, (SELECT COUNT(*) FROM recipes r WHERE r.ingredient_id = i.id) AS used_by '
      'FROM ingredients i ORDER BY i.active DESC, i.name',
    );
    final value = rows.where((r) => r['active'] == 1).fold<double>(0, (s, r) => s + (r['qty'] as num) * (r['unit_cost'] as num));
    return {'ingredients': rows.map(_ingredientJson).toList(), 'stockValueCents': value.round()};
  }

  double _num(Object? v, String label, {double min = 0, double max = 100000000}) {
    if (v is! num || v.isNaN || v < min || v > max) throw ApiError(400, '$label مش صحيح');
    return v.toDouble();
  }

  Future<Object?> _saveIngredient(Request req, AuthUser u) async {
    final body = await _body(req);
    var id = req.params['id'];
    final now = nowIso();
    db.transaction(() {
      if (id == null) {
        final unit = body['unit'];
        if (!ingredientUnits.contains(unit)) throw ApiError(400, 'اختار وحدة الخامة');
        id = _uuid.v4();
        final qty = body['qty'] == null ? 0.0 : _num(body['qty'], 'الكمية', min: -1000000);
        db.execute(
          'INSERT INTO ingredients(id, name, unit, qty, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)',
          [id, _requiredText(body, 'name', 'اسم الخامة'), unit, qty, now, now],
        );
        if (qty != 0) _stockMove(id!, qty, 'opening', userId: u.id);
      } else {
        if (db.selectOne('SELECT id FROM ingredients WHERE id = ?', [id]) == null) throw ApiError(404, 'الخامة دي مش موجودة');
        if (body.containsKey('name')) db.execute('UPDATE ingredients SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم الخامة'), id]);
        if (body.containsKey('unit')) {
          if (!ingredientUnits.contains(body['unit'])) throw ApiError(400, 'الوحدة مش صحيحة');
          db.execute('UPDATE ingredients SET unit = ? WHERE id = ?', [body['unit'], id]);
        }
      }
      if (body.containsKey('unitCost')) db.execute('UPDATE ingredients SET unit_cost = ? WHERE id = ?', [_num(body['unitCost'], 'التكلفة'), id]);
      if (body.containsKey('lowStock')) db.execute('UPDATE ingredients SET low_stock = ? WHERE id = ?', [_num(body['lowStock'], 'حد التنبيه'), id]);
      if (body['autoHide'] is bool) db.execute('UPDATE ingredients SET auto_hide = ? WHERE id = ?', [body['autoHide'] == true ? 1 : 0, id]);
      if (body['active'] is bool) db.execute('UPDATE ingredients SET active = ? WHERE id = ?', [body['active'] == true ? 1 : 0, id]);
      db.execute('UPDATE ingredients SET updated_at = ? WHERE id = ?', [now, id]);
    });
    _broadcast('stock');
    _broadcast('menu');
    return {'id': id};
  }

  /// وصل جديد (بيتجمع على الموجود)، أو جرد (الكمية الفعلية)، أو هالك، أو تعديل يدوي.
  Future<Object?> _adjustIngredient(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final ing = db.selectOne('SELECT * FROM ingredients WHERE id = ?', [id]);
    if (ing == null) throw ApiError(404, 'الخامة دي مش موجودة');
    final body = await _body(req);
    final reason = body['reason'];
    if (!const {'receive', 'count', 'waste', 'adjust'}.contains(reason)) throw ApiError(400, 'سبب التعديل مش صحيح');
    final current = (ing['qty'] as num).toDouble();
    final double change;
    if (reason == 'receive') {
      change = _num(body['qty'], 'الكمية', min: 0.0001);
    } else if (reason == 'count') {
      change = _num(body['qty'], 'الكمية') - current;
    } else if (reason == 'waste') {
      change = -_num(body['qty'], 'الكمية', min: 0.0001);
    } else {
      change = _num(body['qty'], 'الكمية', min: -100000000);
    }
    if (change == 0) return {'ok': true};
    final paid = body['costCents'] is int && (body['costCents'] as int) > 0 ? body['costCents'] as int : null;
    db.transaction(() {
      if (reason == 'receive' && paid != null) {
        // تكلفة الوحدة الجديدة = متوسط القديم والجديد
        final oldQty = current < 0 ? 0.0 : current;
        final newCost = (oldQty * (ing['unit_cost'] as num) + paid) / (oldQty + change);
        db.execute('UPDATE ingredients SET unit_cost = ? WHERE id = ?', [newCost, id]);
      }
      db.execute('UPDATE ingredients SET qty = qty + ?, updated_at = ? WHERE id = ?', [change, nowIso(), id]);
      _stockMove(id, change, reason as String,
          note: _optionalText(body, 'note'), userId: u.id, costCents: paid ?? (change.abs() * (ing['unit_cost'] as num)).round());
    });
    _audit(u.id, 'stock.$reason', 'ingredient', id, '${ing['name']}: ${change > 0 ? '+' : ''}${_fmtQty(change)}');
    _broadcast('stock');
    _broadcast('menu');
    return {'ok': true, 'qty': (db.selectOne('SELECT qty FROM ingredients WHERE id = ?', [id])!['qty'] as num).toDouble()};
  }

  String _fmtQty(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  void _stockMove(String ingredientId, double change, String reason, {String? refType, String? refId, String? note, String? userId, int costCents = 0}) {
    final after = (db.selectOne('SELECT qty FROM ingredients WHERE id = ?', [ingredientId])!['qty'] as num).toDouble();
    db.execute(
      'INSERT INTO stock_moves(ingredient_id, qty_change, qty_after, reason, ref_type, ref_id, cost_cents, note, user_id, created_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [ingredientId, change, after, reason, refType, refId, costCents, note, userId, nowIso()],
    );
  }

  Object? _ingredientMoves(Request req, AuthUser u) {
    final rows = db.select(
      'SELECT m.*, us.name AS user_name FROM stock_moves m LEFT JOIN users us ON us.id = m.user_id '
      'WHERE m.ingredient_id = ? ORDER BY m.id DESC LIMIT 200',
      [req.params['id']],
    );
    return {
      'moves': rows
          .map((m) => {
                'change': (m['qty_change'] as num).toDouble(),
                'after': (m['qty_after'] as num).toDouble(),
                'reason': m['reason'],
                'note': m['note'],
                'userName': m['user_name'],
                'createdAt': m['created_at'],
              })
          .toList(),
    };
  }

  // ---------------------------------------------------------------- recipes

  String _recipeColumn(String kind) => switch (kind) {
        'item' => 'item_id',
        'option' => 'option_id',
        _ => throw ApiError(404, 'المسار ده مش موجود'),
      };

  Object? _getRecipe(Request req, AuthUser u) {
    final col = _recipeColumn(req.params['kind']!);
    final rows = db.select(
      'SELECT r.ingredient_id, r.qty, i.name, i.unit, i.unit_cost FROM recipes r JOIN ingredients i ON i.id = r.ingredient_id WHERE r.$col = ? ORDER BY i.name',
      [req.params['id']],
    );
    return {
      'lines': rows
          .map((r) => {'ingredientId': r['ingredient_id'], 'name': r['name'], 'unit': r['unit'], 'qty': (r['qty'] as num).toDouble(), 'costCents': ((r['qty'] as num) * (r['unit_cost'] as num)).round()})
          .toList(),
    };
  }

  Future<Object?> _setRecipe(Request req, AuthUser u) async {
    final col = _recipeColumn(req.params['kind']!);
    final id = req.params['id']!;
    final table = col == 'item_id' ? 'items' : 'modifier_options';
    if (db.selectOne('SELECT id FROM $table WHERE id = ?', [id]) == null) throw ApiError(404, 'مش موجود');
    final body = await _body(req);
    final lines = (body['lines'] as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    db.transaction(() {
      db.execute('DELETE FROM recipes WHERE $col = ?', [id]);
      final seen = <String>{};
      for (final l in lines) {
        final ing = l['ingredientId'];
        if (ing is! String || db.selectOne('SELECT id FROM ingredients WHERE id = ?', [ing]) == null) throw ApiError(400, 'فيه خامة مش موجودة');
        if (!seen.add(ing)) continue;
        final qty = _num(l['qty'], 'كمية الخامة', min: 0.0001, max: 1000000);
        db.execute('INSERT INTO recipes(id, $col, ingredient_id, qty) VALUES(?, ?, ?, ?)', [_uuid.v4(), id, ing, qty]);
      }
    });
    _broadcast('menu');
    return _getRecipe(req, u);
  }

  /// تكلفة الصنف من الوصفة (بالقروش)، أو null لو مالوش وصفة.
  int? _recipeCost(String itemId) {
    final r = db.selectOne(
      'SELECT COUNT(*) AS c, COALESCE(SUM(r.qty * i.unit_cost), 0) AS cost FROM recipes r JOIN ingredients i ON i.id = r.ingredient_id WHERE r.item_id = ?',
      [itemId],
    )!;
    return (r['c'] as int) == 0 ? null : (r['cost'] as num).round();
  }

  /// الأصناف اللي فيه خامة في وصفتها (متعلّم عليها "تخفي الصنف") مش كفاية لواحد.
  Set<String> _soldOutItemIds() => db
      .select(
        'SELECT DISTINCT r.item_id FROM recipes r JOIN ingredients i ON i.id = r.ingredient_id '
        'WHERE r.item_id IS NOT NULL AND i.active = 1 AND i.auto_hide = 1 AND i.qty < r.qty',
      )
      .map((r) => r['item_id'] as String)
      .toSet();

  /// بيخصم خامات أصناف الطلب من المخزون (أول ما الطلب يتقبل)، وبيسجل تكلفة كل صنف.
  void _consumeStock(String orderId, String? userId) {
    final lines = db.select("SELECT * FROM order_items WHERE order_id = ? AND status <> 'void'", [orderId]);
    for (final line in lines) {
      final qty = line['qty'] as int;
      final usage = <String, double>{};
      if (line['item_id'] != null) {
        for (final r in db.select('SELECT ingredient_id, qty FROM recipes WHERE item_id = ?', [line['item_id']])) {
          usage.update(r['ingredient_id'] as String, (v) => v + (r['qty'] as num) * qty, ifAbsent: () => (r['qty'] as num) * qty.toDouble());
        }
      }
      for (final m in (jsonDecode(line['modifiers'] as String) as List).cast<Map<String, dynamic>>()) {
        for (final r in db.select('SELECT ingredient_id, qty FROM recipes WHERE option_id = ?', [m['id']])) {
          usage.update(r['ingredient_id'] as String, (v) => v + (r['qty'] as num) * qty, ifAbsent: () => (r['qty'] as num) * qty.toDouble());
        }
      }
      var cost = 0.0;
      for (final e in usage.entries) {
        final ing = db.selectOne('SELECT unit_cost FROM ingredients WHERE id = ?', [e.key])!;
        cost += e.value * (ing['unit_cost'] as num);
        db.execute('UPDATE ingredients SET qty = qty - ?, updated_at = ? WHERE id = ?', [e.value, nowIso(), e.key]);
        _stockMove(e.key, -e.value, 'sale', refType: 'order', refId: orderId, userId: userId, costCents: (e.value * (ing['unit_cost'] as num)).round());
      }
      // لو الصنف من غير وصفة، بنستخدم التكلفة اليدوي
      final unitCost = usage.isEmpty
          ? (line['item_id'] == null ? 0 : (db.selectOne('SELECT cost_cents FROM items WHERE id = ?', [line['item_id']])?['cost_cents'] as int? ?? 0))
          : (cost / qty).round();
      db.execute('UPDATE order_items SET cost_cents = ? WHERE id = ?', [unitCost, line['id']]);
    }
    if (lines.isNotEmpty) _broadcast('stock');
  }

  /// صنف اتلغى قبل ما يتحضر: الخامات بترجع المخزون.
  void _returnStock(Map<String, Object?> line, String? userId) {
    final qty = line['qty'] as int;
    final usage = <String, double>{};
    void add(String ing, num q) => usage.update(ing, (v) => v + q * qty, ifAbsent: () => q * qty.toDouble());
    if (line['item_id'] != null) {
      for (final r in db.select('SELECT ingredient_id, qty FROM recipes WHERE item_id = ?', [line['item_id']])) {
        add(r['ingredient_id'] as String, r['qty'] as num);
      }
    }
    for (final m in (jsonDecode(line['modifiers'] as String) as List).cast<Map<String, dynamic>>()) {
      for (final r in db.select('SELECT ingredient_id, qty FROM recipes WHERE option_id = ?', [m['id']])) {
        add(r['ingredient_id'] as String, r['qty'] as num);
      }
    }
    for (final e in usage.entries) {
      db.execute('UPDATE ingredients SET qty = qty + ?, updated_at = ? WHERE id = ?', [e.value, nowIso(), e.key]);
      _stockMove(e.key, e.value, 'void', refType: 'order', refId: line['order_id'] as String?, userId: userId);
    }
    if (usage.isNotEmpty) _broadcast('stock');
  }

  // ---------------------------------------------------------------- suppliers & purchases

  Object? _listSuppliers(Request req, AuthUser u) {
    final rows = db.select(
      'SELECT s.*, '
      '(SELECT COALESCE(SUM(total_cents - paid_cents), 0) FROM purchases p WHERE p.supplier_id = s.id) '
      '- (SELECT COALESCE(SUM(amount_cents), 0) FROM supplier_payments sp WHERE sp.supplier_id = s.id) AS due '
      'FROM suppliers s ORDER BY s.active DESC, s.name',
    );
    return {
      'suppliers': rows.map((s) => {'id': s['id'], 'name': s['name'], 'phone': s['phone'], 'notes': s['notes'], 'active': s['active'] == 1, 'dueCents': s['due']}).toList(),
    };
  }

  Future<Object?> _saveSupplier(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = req.params['id'];
    final now = nowIso();
    if (id == null) {
      db.execute('INSERT INTO suppliers(id, name, phone, notes, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)',
          [_uuid.v4(), _requiredText(body, 'name', 'اسم المورد'), _optionalText(body, 'phone'), _optionalText(body, 'notes'), now, now]);
    } else {
      if (db.selectOne('SELECT id FROM suppliers WHERE id = ?', [id]) == null) throw ApiError(404, 'المورد ده مش موجود');
      if (body.containsKey('name')) db.execute('UPDATE suppliers SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم المورد'), id]);
      for (final k in ['phone', 'notes']) {
        if (body.containsKey(k)) db.execute('UPDATE suppliers SET $k = ? WHERE id = ?', [_optionalText(body, k), id]);
      }
      if (body['active'] is bool) db.execute('UPDATE suppliers SET active = ? WHERE id = ?', [body['active'] == true ? 1 : 0, id]);
      db.execute('UPDATE suppliers SET updated_at = ? WHERE id = ?', [now, id]);
    }
    _broadcast('stock');
    return _listSuppliers(req, u);
  }

  Future<Object?> _paySupplier(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final s = db.selectOne('SELECT * FROM suppliers WHERE id = ?', [id]);
    if (s == null) throw ApiError(404, 'المورد ده مش موجود');
    final body = await _body(req);
    final amount = body['amountCents'];
    if (amount is! int || amount <= 0) throw ApiError(400, 'المبلغ مش صحيح');
    db.transaction(() {
      final pid = _uuid.v4();
      db.execute('INSERT INTO supplier_payments(id, supplier_id, amount_cents, note, user_id, created_at) VALUES(?, ?, ?, ?, ?, ?)',
          [pid, id, amount, _optionalText(body, 'note'), u.id, nowIso()]);
      if (body['fromDrawer'] == true) {
        _cashMove(_requireOpenRegister(), 'supplier', -amount, 'cash', category: 'موردين', refType: 'supplier_payment', refId: pid, note: s['name'] as String, userId: u.id);
      }
    });
    _audit(u.id, 'supplier.pay', 'supplier', id, '${s['name']}: ${money(amount)}');
    _broadcast('stock');
    _broadcast('register');
    return _listSuppliers(req, u);
  }

  Object? _listPurchases(Request req, AuthUser u) {
    final rows = db.select(
      'SELECT p.*, s.name AS supplier_name, us.name AS user_name FROM purchases p '
      'LEFT JOIN suppliers s ON s.id = p.supplier_id LEFT JOIN users us ON us.id = p.user_id ORDER BY p.number DESC LIMIT 200',
    );
    return {
      'purchases': rows.map((p) {
        final items = db.select(
          'SELECT pi.*, i.name, i.unit FROM purchase_items pi JOIN ingredients i ON i.id = pi.ingredient_id WHERE pi.purchase_id = ?',
          [p['id']],
        );
        return {
          'id': p['id'],
          'number': p['number'],
          'supplierName': p['supplier_name'],
          'totalCents': p['total_cents'],
          'paidCents': p['paid_cents'],
          'note': p['note'],
          'userName': p['user_name'],
          'createdAt': p['created_at'],
          'items': items.map((i) => {'name': i['name'], 'unit': i['unit'], 'qty': (i['qty'] as num).toDouble(), 'totalCents': i['total_cents']}).toList(),
        };
      }).toList(),
    };
  }

  /// فاتورة شرا خامات: بتزوّد المخزون، وبتحدّث تكلفة الوحدة (متوسط مرجّح).
  Future<Object?> _createPurchase(Request req, AuthUser u) async {
    await _requireLicense();
    final body = await _body(req);
    final supplierId = body['supplierId'] as String?;
    if (supplierId != null && db.selectOne('SELECT id FROM suppliers WHERE id = ?', [supplierId]) == null) throw ApiError(400, 'المورد مش موجود');
    final lines = (body['lines'] as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    if (lines.isEmpty) throw ApiError(400, 'ضيف خامة واحدة على الأقل');
    final paid = body['paidCents'] is int ? body['paidCents'] as int : 0;
    final id = _uuid.v4();
    final number = db.transaction(() {
      final number = (db.selectOne('SELECT COALESCE(MAX(number), 0) + 1 AS n FROM purchases')!['n'] as int);
      var total = 0;
      final now = nowIso();
      db.execute('INSERT INTO purchases(id, number, supplier_id, total_cents, paid_cents, note, user_id, created_at) VALUES(?, ?, ?, 0, 0, ?, ?, ?)',
          [id, number, supplierId, _optionalText(body, 'note'), u.id, now]);
      for (final l in lines) {
        final ing = db.selectOne('SELECT * FROM ingredients WHERE id = ?', [l['ingredientId']]);
        if (ing == null) throw ApiError(400, 'فيه خامة مش موجودة');
        final qty = _num(l['qty'], 'الكمية', min: 0.0001);
        final lineTotal = l['totalCents'];
        if (lineTotal is! int || lineTotal < 0) throw ApiError(400, 'سعر ${ing['name']} مش صحيح');
        total += lineTotal;
        db.execute('INSERT INTO purchase_items(id, purchase_id, ingredient_id, qty, total_cents) VALUES(?, ?, ?, ?, ?)',
            [_uuid.v4(), id, ing['id'], qty, lineTotal]);
        final oldQty = (ing['qty'] as num).toDouble().clamp(0, double.infinity);
        final oldCost = (ing['unit_cost'] as num).toDouble();
        final newCost = (oldQty * oldCost + lineTotal) / (oldQty + qty);
        db.execute('UPDATE ingredients SET qty = qty + ?, unit_cost = ?, updated_at = ? WHERE id = ?', [qty, newCost, now, ing['id']]);
        _stockMove(ing['id'] as String, qty, 'purchase', refType: 'purchase', refId: id, userId: u.id, costCents: lineTotal);
      }
      final paidNow = paid.clamp(0, total);
      db.execute('UPDATE purchases SET total_cents = ?, paid_cents = ? WHERE id = ?', [total, paidNow, id]);
      if (paidNow > 0 && body['fromDrawer'] == true) {
        _cashMove(_requireOpenRegister(), 'purchase', -paidNow, 'cash', category: 'مشتريات', refType: 'purchase', refId: id, note: 'فاتورة شرا #$number', userId: u.id);
      }
      return number;
    });
    _audit(u.id, 'purchase.create', 'purchase', id, '#$number');
    _broadcast('stock');
    _broadcast('menu');
    _broadcast('register');
    return {'id': id, 'number': number};
  }
}
