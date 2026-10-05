part of 'api_server.dart';

/// المنيو: أماكن التحضير، والأقسام، والأصناف، ومجموعات الإضافات.
/// الحذف هنا "إيقاف" (active = 0) عشان الطلبات القديمة تفضل بأسمائها في التقارير.
extension _MenuRoutes on OrderlyServer {
  void _registerMenuRoutes(Router r) {
    r.get('/api/menu', _authed((req, u) => _menuJson(includeInactive: req.url.queryParameters['all'] == '1')));

    r.post('/api/stations', _authed(_saveStation, only: {'owner'}));
    r.patch('/api/stations/<id>', _authed(_saveStation, only: {'owner'}));

    r.post('/api/categories', _authed(_saveCategory, only: {'owner'}));
    r.patch('/api/categories/<id>', _authed(_saveCategory, only: {'owner'}));

    r.post('/api/items', _authed(_saveItem, only: {'owner'}));
    r.patch('/api/items/<id>', _authed(_saveItem, only: {'owner'}));
    r.put('/api/items/<id>/image', _authed(_setItemImage, only: {'owner'}));
    r.delete('/api/items/<id>/image', _authed((req, u) {
      final item = _loadItem(req.params['id']!);
      db.execute('UPDATE items SET image_id = NULL, updated_at = ? WHERE id = ?', [nowIso(), item['id']]);
      _deleteFile(item['image_id'] as String?);
      _broadcast('menu');
      return {'ok': true};
    }, only: {'owner'}));
    // الكاشير بيقفل صنف خلص ويفتحه تاني
    r.post('/api/items/<id>/availability', _authed(_setAvailability, only: cashRoles));

    r.post('/api/modifier-groups', _authed(_saveGroup, only: {'owner'}));
    r.patch('/api/modifier-groups/<id>', _authed(_saveGroup, only: {'owner'}));

    r.post('/api/menu/sort', _authed(_sortMenu, only: {'owner'}));
  }

  // ---------------------------------------------------------------- read

  Map<String, Object?> _menuJson({bool includeInactive = false}) {
    final active = includeInactive ? '' : 'WHERE active = 1';
    final groupsByItem = <String, List<String>>{};
    for (final g in db.select('SELECT item_id, group_id FROM item_modifier_groups ORDER BY sort')) {
      groupsByItem.putIfAbsent(g['item_id'] as String, () => []).add(g['group_id'] as String);
    }
    final options = <String, List<Map<String, Object?>>>{};
    for (final o in db.select('SELECT * FROM modifier_options ${includeInactive ? '' : 'WHERE active = 1'} ORDER BY sort, rowid')) {
      options.putIfAbsent(o['group_id'] as String, () => []).add({
        'id': o['id'],
        'name': o['name'],
        'nameEn': o['name_en'],
        'priceCents': o['price_cents'],
        'isDefault': o['is_default'] == 1,
        'active': o['active'] == 1,
      });
    }
    final soldOut = _soldOutItemIds();
    final promos = _activePromotions();
    return {
      'stations': db.select('SELECT * FROM stations $active ORDER BY sort, name').map((s) => {
            'id': s['id'],
            'name': s['name'],
            'active': s['active'] == 1,
          }).toList(),
      'categories': db.select('SELECT * FROM categories $active ORDER BY sort, name').map((c) => {
            'id': c['id'],
            'name': c['name'],
            'nameEn': c['name_en'],
            'stationId': c['station_id'],
            'hours': c['hours'],
            'active': c['active'] == 1,
          }).toList(),
      'items': db.select('SELECT * FROM items $active ORDER BY sort, name').map((i) {
        final promo = _promoFor(promos, i);
        return {
          'id': i['id'],
          'categoryId': i['category_id'],
          'name': i['name'],
          'nameEn': i['name_en'],
          'description': i['description'],
          'descriptionEn': i['description_en'],
          'priceCents': i['price_cents'],
          'promoPriceCents': promo == 0 ? null : _applyPromo(i['price_cents'] as int, promo),
          'costCents': i['cost_cents'],
          'recipeCostCents': _recipeCost(i['id'] as String),
          'imageId': i['image_id'],
          'stationId': i['station_id'],
          'tags': jsonDecode(i['tags'] as String),
          'available': i['available'] == 1,
          'soldOut': soldOut.contains(i['id']),
          'showInQr': i['show_in_qr'] == 1,
          'active': i['active'] == 1,
          'upsell': jsonDecode(i['upsell'] as String),
          'groupIds': groupsByItem[i['id']] ?? const [],
        };
      }).toList(),
      'modifierGroups': db.select('SELECT * FROM modifier_groups $active ORDER BY sort, name').map((g) => {
            'id': g['id'],
            'name': g['name'],
            'nameEn': g['name_en'],
            'minSelect': g['min_select'],
            'maxSelect': g['max_select'],
            'active': g['active'] == 1,
            'options': options[g['id']] ?? const [],
          }).toList(),
    };
  }

  Map<String, Object?> _loadItem(String id) {
    final item = db.selectOne('SELECT * FROM items WHERE id = ?', [id]);
    if (item == null) throw ApiError(404, 'الصنف ده مش موجود');
    return item;
  }

  // ---------------------------------------------------------------- write

  String? _validStation(Object? id) {
    if (id == null || id == '') return null;
    if (db.selectOne('SELECT id FROM stations WHERE id = ?', [id]) == null) throw ApiError(400, 'مكان التحضير مش موجود');
    return id as String;
  }

  Future<Object?> _saveStation(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = req.params['id'];
    final now = nowIso();
    if (id == null) {
      final newId = _uuid.v4();
      db.execute('INSERT INTO stations(id, name, sort, created_at) VALUES(?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM stations), ?)',
          [newId, _requiredText(body, 'name', 'اسم المكان'), now]);
    } else {
      if (db.selectOne('SELECT id FROM stations WHERE id = ?', [id]) == null) throw ApiError(404, 'المكان ده مش موجود');
      if (body.containsKey('name')) db.execute('UPDATE stations SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم المكان'), id]);
      if (body['active'] is bool) db.execute('UPDATE stations SET active = ? WHERE id = ?', [body['active'] == true ? 1 : 0, id]);
    }
    _broadcast('menu');
    return _menuJson(includeInactive: true);
  }

  String? _validHours(Object? v) {
    if (v == null || v == '') return null;
    final m = RegExp(r'^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$').firstMatch('$v');
    if (m == null) throw ApiError(400, 'مواعيد القسم لازم تبقى بالشكل ده: 08:00-12:00');
    return '$v';
  }

  Future<Object?> _saveCategory(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = req.params['id'];
    final now = nowIso();
    if (id == null) {
      db.execute(
        'INSERT INTO categories(id, name, name_en, station_id, hours, sort, created_at, updated_at) '
        'VALUES(?, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM categories), ?, ?)',
        [_uuid.v4(), _requiredText(body, 'name', 'اسم القسم'), _optionalText(body, 'nameEn'), _validStation(body['stationId']), _validHours(body['hours']), now, now],
      );
    } else {
      if (db.selectOne('SELECT id FROM categories WHERE id = ?', [id]) == null) throw ApiError(404, 'القسم ده مش موجود');
      db.transaction(() {
        if (body.containsKey('name')) db.execute('UPDATE categories SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم القسم'), id]);
        if (body.containsKey('nameEn')) db.execute('UPDATE categories SET name_en = ? WHERE id = ?', [_optionalText(body, 'nameEn'), id]);
        if (body.containsKey('stationId')) db.execute('UPDATE categories SET station_id = ? WHERE id = ?', [_validStation(body['stationId']), id]);
        if (body.containsKey('hours')) db.execute('UPDATE categories SET hours = ? WHERE id = ?', [_validHours(body['hours']), id]);
        if (body['active'] is bool) db.execute('UPDATE categories SET active = ? WHERE id = ?', [body['active'] == true ? 1 : 0, id]);
        db.execute('UPDATE categories SET updated_at = ? WHERE id = ?', [now, id]);
      });
    }
    _audit(u.id, id == null ? 'menu.category.create' : 'menu.category.update', 'category', id, body['name'] as String?);
    _broadcast('menu');
    return _menuJson(includeInactive: true);
  }

  List<String> _idList(Object? v, String table) {
    if (v is! List) return const [];
    final ids = v.whereType<String>().toSet().toList();
    for (final id in ids) {
      if (db.selectOne('SELECT id FROM $table WHERE id = ?', [id]) == null) throw ApiError(400, 'فيه اختيار مش موجود');
    }
    return ids;
  }

  Future<Object?> _saveItem(Request req, AuthUser u) async {
    final body = await _body(req);
    var id = req.params['id'];
    final now = nowIso();
    int money(String key) {
      final v = body[key];
      if (v is! int || v < 0 || v > 100000000) throw ApiError(400, 'السعر مش صحيح');
      return v;
    }

    String category(Object? v) {
      if (v is! String || db.selectOne('SELECT id FROM categories WHERE id = ?', [v]) == null) throw ApiError(400, 'اختار القسم');
      return v;
    }

    db.transaction(() {
      if (id == null) {
        id = _uuid.v4();
        db.execute(
          'INSERT INTO items(id, category_id, name, price_cents, sort, created_at, updated_at) '
          'VALUES(?, ?, ?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM items), ?, ?)',
          [id, category(body['categoryId']), _requiredText(body, 'name', 'اسم الصنف'), money('priceCents'), now, now],
        );
      } else {
        _loadItem(id!);
        if (body.containsKey('categoryId')) db.execute('UPDATE items SET category_id = ? WHERE id = ?', [category(body['categoryId']), id]);
        if (body.containsKey('name')) db.execute('UPDATE items SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم الصنف'), id]);
        if (body.containsKey('priceCents')) db.execute('UPDATE items SET price_cents = ? WHERE id = ?', [money('priceCents'), id]);
      }
      if (body.containsKey('costCents')) db.execute('UPDATE items SET cost_cents = ? WHERE id = ?', [money('costCents'), id]);
      for (final e in const {'nameEn': 'name_en', 'description': 'description', 'descriptionEn': 'description_en'}.entries) {
        if (body.containsKey(e.key)) {
          final v = _optionalText(body, e.key);
          if (v != null && v.length > 400) throw ApiError(400, 'الوصف طويل جداً');
          db.execute('UPDATE items SET ${e.value} = ? WHERE id = ?', [v, id]);
        }
      }
      if (body.containsKey('stationId')) db.execute('UPDATE items SET station_id = ? WHERE id = ?', [_validStation(body['stationId']), id]);
      for (final e in const {'available': 'available', 'showInQr': 'show_in_qr', 'active': 'active'}.entries) {
        if (body[e.key] is bool) db.execute('UPDATE items SET ${e.value} = ? WHERE id = ?', [body[e.key] == true ? 1 : 0, id]);
      }
      if (body['tags'] is List) {
        final tags = (body['tags'] as List).whereType<String>().where((t) => itemTags.contains(t)).toSet().toList();
        db.execute('UPDATE items SET tags = ? WHERE id = ?', [jsonEncode(tags), id]);
      }
      if (body.containsKey('upsell')) {
        db.execute('UPDATE items SET upsell = ? WHERE id = ?', [jsonEncode(_idList(body['upsell'], 'items').where((x) => x != id).take(4).toList()), id]);
      }
      if (body.containsKey('groupIds')) {
        final groups = _idList(body['groupIds'], 'modifier_groups');
        db.execute('DELETE FROM item_modifier_groups WHERE item_id = ?', [id]);
        for (var i = 0; i < groups.length; i++) {
          db.execute('INSERT INTO item_modifier_groups(item_id, group_id, sort) VALUES(?, ?, ?)', [id, groups[i], i]);
        }
      }
      db.execute('UPDATE items SET updated_at = ? WHERE id = ?', [now, id]);
    });
    _audit(u.id, req.params['id'] == null ? 'menu.item.create' : 'menu.item.update', 'item', id, body['name'] as String? ?? body.keys.join('، '));
    _broadcast('menu');
    return {'id': id, ..._menuJson(includeInactive: true)};
  }

  Future<Object?> _setItemImage(Request req, AuthUser u) async {
    final item = _loadItem(req.params['id']!);
    final body = await _body(req);
    final fileId = await _saveImage(_decodeImageBody(body), 'menu', u.id, maxSide: 720, quality: 78);
    db.execute('UPDATE items SET image_id = ?, updated_at = ? WHERE id = ?', [fileId, nowIso(), item['id']]);
    _deleteFile(item['image_id'] as String?);
    _broadcast('menu');
    return {'imageId': fileId};
  }

  Future<Object?> _setAvailability(Request req, AuthUser u) async {
    final item = _loadItem(req.params['id']!);
    final body = await _body(req);
    final available = body['available'] == true;
    db.execute('UPDATE items SET available = ?, updated_at = ? WHERE id = ?', [available ? 1 : 0, nowIso(), item['id']]);
    _audit(u.id, available ? 'menu.item.available' : 'menu.item.soldout', 'item', item['id'] as String, item['name'] as String);
    _broadcast('menu');
    return {'ok': true};
  }

  Future<Object?> _saveGroup(Request req, AuthUser u) async {
    final body = await _body(req);
    var id = req.params['id'];
    final now = nowIso();
    db.transaction(() {
      if (id == null) {
        id = _uuid.v4();
        db.execute(
          'INSERT INTO modifier_groups(id, name, sort, created_at, updated_at) VALUES(?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM modifier_groups), ?, ?)',
          [id, _requiredText(body, 'name', 'اسم المجموعة'), now, now],
        );
      } else {
        if (db.selectOne('SELECT id FROM modifier_groups WHERE id = ?', [id]) == null) throw ApiError(404, 'المجموعة دي مش موجودة');
        if (body.containsKey('name')) db.execute('UPDATE modifier_groups SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم المجموعة'), id]);
      }
      if (body.containsKey('nameEn')) db.execute('UPDATE modifier_groups SET name_en = ? WHERE id = ?', [_optionalText(body, 'nameEn'), id]);
      if (body['active'] is bool) db.execute('UPDATE modifier_groups SET active = ? WHERE id = ?', [body['active'] == true ? 1 : 0, id]);
      if (body['minSelect'] is int || body['maxSelect'] is int) {
        final g = db.selectOne('SELECT min_select, max_select FROM modifier_groups WHERE id = ?', [id])!;
        final min = (body['minSelect'] as int? ?? g['min_select'] as int).clamp(0, 20);
        final max = (body['maxSelect'] as int? ?? g['max_select'] as int).clamp(1, 20);
        if (min > max) throw ApiError(400, 'أقل عدد اختيارات أكبر من أكتر عدد');
        db.execute('UPDATE modifier_groups SET min_select = ?, max_select = ? WHERE id = ?', [min, max, id]);
      }
      if (body['options'] is List) {
        // الاختيارات اللي اتشالت بتتوقف بس (عشان الوصفات والطلبات القديمة)
        final keep = <String>{};
        var sort = 0;
        for (final raw in (body['options'] as List).whereType<Map>()) {
          final o = raw.cast<String, dynamic>();
          final name = (o['name'] as String? ?? '').trim();
          if (name.isEmpty) continue;
          final price = o['priceCents'] is int ? (o['priceCents'] as int).clamp(-100000000, 100000000) : 0;
          var oid = o['id'] as String?;
          if (oid != null && db.selectOne('SELECT id FROM modifier_options WHERE id = ? AND group_id = ?', [oid, id]) != null) {
            db.execute(
              'UPDATE modifier_options SET name = ?, name_en = ?, price_cents = ?, is_default = ?, sort = ?, active = 1 WHERE id = ?',
              [name, (o['nameEn'] as String?)?.trim(), price, o['isDefault'] == true ? 1 : 0, sort, oid],
            );
          } else {
            oid = _uuid.v4();
            db.execute(
              'INSERT INTO modifier_options(id, group_id, name, name_en, price_cents, is_default, sort) VALUES(?, ?, ?, ?, ?, ?, ?)',
              [oid, id, name, (o['nameEn'] as String?)?.trim(), price, o['isDefault'] == true ? 1 : 0, sort],
            );
          }
          keep.add(oid);
          sort++;
        }
        if (keep.isEmpty) throw ApiError(400, 'لازم المجموعة يبقى فيها اختيار واحد على الأقل');
        db.execute(
          'UPDATE modifier_options SET active = 0 WHERE group_id = ? AND id NOT IN (${List.filled(keep.length, '?').join(',')})',
          [id, ...keep],
        );
      }
      db.execute('UPDATE modifier_groups SET updated_at = ? WHERE id = ?', [now, id]);
    });
    _broadcast('menu');
    return {'id': id, ..._menuJson(includeInactive: true)};
  }

  Future<Object?> _sortMenu(Request req, AuthUser u) async {
    final body = await _body(req);
    db.transaction(() {
      for (final e in const {'categories': 'categories', 'items': 'items', 'stations': 'stations', 'modifierGroups': 'modifier_groups'}.entries) {
        final ids = body[e.key];
        if (ids is! List) continue;
        for (var i = 0; i < ids.length; i++) {
          db.execute('UPDATE ${e.value} SET sort = ? WHERE id = ?', [i, ids[i]]);
        }
      }
    });
    _broadcast('menu');
    return _menuJson(includeInactive: true);
  }

  // ---------------------------------------------------------------- pricing (العروض)

  List<Map<String, Object?>> _activePromotions([DateTime? at]) {
    final now = (at ?? DateTime.now()).toLocal();
    final weekday = now.weekday % 7; // 0 = الأحد
    final hm = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return db.select('SELECT * FROM promotions WHERE active = 1').where((pr) {
      final days = (jsonDecode(pr['days'] as String) as List).cast<int>();
      if (!days.contains(weekday)) return false;
      final from = pr['time_from'] as String, to = pr['time_to'] as String;
      // عرض بيعدّي نص الليل (مثلاً 22:00-02:00)
      return from.compareTo(to) <= 0 ? hm.compareTo(from) >= 0 && hm.compareTo(to) < 0 : hm.compareTo(from) >= 0 || hm.compareTo(to) < 0;
    }).toList();
  }

  /// أكبر نسبة خصم (bp) سارية على الصنف دلوقتي.
  int _promoFor(List<Map<String, Object?>> promos, Map<String, Object?> item) {
    var best = 0;
    for (final pr in promos) {
      final cats = (jsonDecode(pr['category_ids'] as String) as List).cast<String>();
      final items = (jsonDecode(pr['item_ids'] as String) as List).cast<String>();
      final applies = (cats.isEmpty && items.isEmpty) || cats.contains(item['category_id']) || items.contains(item['id']);
      if (applies && (pr['percent_bp'] as int) > best) best = pr['percent_bp'] as int;
    }
    return best;
  }

  int _applyPromo(int cents, int bp) => (cents * (10000 - bp) / 10000).round();
}

/// علامات بتظهر على الصنف في منيو العميل.
const itemTags = {'new', 'best', 'spicy', 'vegan', 'hot', 'cold', 'sugar_free'};
