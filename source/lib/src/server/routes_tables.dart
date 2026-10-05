part of 'api_server.dart';

/// الصالة: الأماكن والترابيزات. كل ترابيزة ليها كود سري في الـ QR بتاعها؛
/// اللي معاه الكود بس يقدر يطلب على الترابيزة دي، والكود ممكن يتغير لو اتسرب.
extension _TableRoutes on OrderlyServer {
  void _registerTableRoutes(Router r) {
    r.get('/api/floor', _authed((req, u) => _floorJson(), only: floorRoles));
    r.post('/api/areas', _authed(_saveArea, only: {'owner'}));
    r.patch('/api/areas/<id>', _authed(_saveArea, only: {'owner'}));
    r.post('/api/tables', _authed(_saveTable, only: {'owner'}));
    r.post('/api/tables/bulk', _authed(_bulkTables, only: {'owner'}));
    r.patch('/api/tables/<id>', _authed(_saveTable, only: {'owner'}));
    r.post('/api/tables/<id>/new-key', _authed(_rotateTableKey, only: {'owner'}));
    r.get('/api/tables/qr', _authed(_tableQrLinks, only: {'owner'}));
  }

  String _newTableKey() {
    const alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(16, (_) => alphabet[rnd.nextInt(alphabet.length)]).join();
  }

  Map<String, Object?> _floorJson() {
    final openChecks = <String, Map<String, Object?>>{};
    for (final c in db.select("SELECT * FROM checks WHERE status = 'open' AND table_id IS NOT NULL")) {
      openChecks[c['table_id'] as String] = c;
    }
    final pending = <String, int>{};
    for (final o in db.select("SELECT table_id, COUNT(*) AS c FROM orders WHERE status = 'pending' AND table_id IS NOT NULL GROUP BY table_id")) {
      pending[o['table_id'] as String] = o['c'] as int;
    }
    final ready = <String, int>{};
    for (final o in db.select("SELECT table_id, COUNT(*) AS c FROM orders WHERE status = 'ready' AND table_id IS NOT NULL GROUP BY table_id")) {
      ready[o['table_id'] as String] = o['c'] as int;
    }
    final calls = <String, List<String>>{};
    for (final c in db.select("SELECT table_id, type FROM service_calls WHERE status = 'open' AND table_id IS NOT NULL")) {
      calls.putIfAbsent(c['table_id'] as String, () => []).add(c['type'] as String);
    }
    final proofs = <String, int>{};
    for (final p in db.select(
        "SELECT c.table_id, COUNT(*) AS n FROM payments pa JOIN checks c ON c.id = pa.check_id WHERE pa.status = 'pending' AND c.table_id IS NOT NULL GROUP BY c.table_id")) {
      proofs[p['table_id'] as String] = p['n'] as int;
    }
    return {
      'areas': db.select('SELECT * FROM areas WHERE active = 1 ORDER BY sort, name').map((a) => {'id': a['id'], 'name': a['name']}).toList(),
      'tables': db.select('SELECT * FROM tables WHERE active = 1 ORDER BY sort, name').map((t) {
        final c = openChecks[t['id']];
        return {
          'id': t['id'],
          'areaId': t['area_id'],
          'name': t['name'],
          'seats': t['seats'],
          'autoAccept': t['auto_accept'] == null ? null : t['auto_accept'] == 1,
          'check': c == null
              ? null
              : {
                  'id': c['id'],
                  'number': c['number'],
                  'totalCents': c['total_cents'],
                  'paidCents': c['paid_cents'],
                  'guests': c['guests'],
                  'openedAt': c['opened_at'],
                  'billRequested': c['bill_requested'] == 1,
                },
          'pendingOrders': pending[t['id']] ?? 0,
          'readyOrders': ready[t['id']] ?? 0,
          'calls': calls[t['id']] ?? const [],
          'pendingPayments': proofs[t['id']] ?? 0,
        };
      }).toList(),
      'others': db
          .select("SELECT * FROM checks WHERE status = 'open' AND table_id IS NULL ORDER BY number")
          .map((c) => {
                'id': c['id'],
                'number': c['number'],
                'type': c['type'],
                'customerName': c['customer_name'],
                'totalCents': c['total_cents'],
                'paidCents': c['paid_cents'],
                'openedAt': c['opened_at'],
              })
          .toList(),
    };
  }

  Future<Object?> _saveArea(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = req.params['id'];
    if (id == null) {
      db.execute('INSERT INTO areas(id, name, sort, created_at) VALUES(?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM areas), ?)',
          [_uuid.v4(), _requiredText(body, 'name', 'اسم المكان'), nowIso()]);
    } else {
      if (db.selectOne('SELECT id FROM areas WHERE id = ?', [id]) == null) throw ApiError(404, 'المكان ده مش موجود');
      if (body.containsKey('name')) db.execute('UPDATE areas SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم المكان'), id]);
      if (body['active'] is bool) {
        if (body['active'] == false && db.selectOne('SELECT id FROM tables WHERE area_id = ? AND active = 1', [id]) != null) {
          throw ApiError(400, 'انقل أو اقفل الترابيزات اللي في المكان ده الأول');
        }
        db.execute('UPDATE areas SET active = ? WHERE id = ?', [body['active'] == true ? 1 : 0, id]);
      }
    }
    _broadcast('tables');
    return _floorJson();
  }

  String? _validArea(Object? id) {
    if (id == null || id == '') return null;
    if (db.selectOne('SELECT id FROM areas WHERE id = ? AND active = 1', [id]) == null) throw ApiError(400, 'المكان مش موجود');
    return id as String;
  }

  Future<Object?> _saveTable(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = req.params['id'];
    final now = nowIso();
    db.transaction(() {
      if (id == null) {
        final name = _requiredText(body, 'name', 'اسم الترابيزة');
        if (db.selectOne('SELECT id FROM tables WHERE name = ? AND active = 1', [name]) != null) throw ApiError(409, 'فيه ترابيزة بنفس الاسم');
        db.execute(
          'INSERT INTO tables(id, area_id, name, seats, qr_key, sort, created_at, updated_at) '
          'VALUES(?, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM tables), ?, ?)',
          [_uuid.v4(), _validArea(body['areaId']), name, (body['seats'] as int? ?? 4).clamp(1, 50), _newTableKey(), now, now],
        );
        return;
      }
      if (db.selectOne('SELECT id FROM tables WHERE id = ?', [id]) == null) throw ApiError(404, 'الترابيزة دي مش موجودة');
      if (body.containsKey('name')) db.execute('UPDATE tables SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم الترابيزة'), id]);
      if (body.containsKey('areaId')) db.execute('UPDATE tables SET area_id = ? WHERE id = ?', [_validArea(body['areaId']), id]);
      if (body['seats'] is int) db.execute('UPDATE tables SET seats = ? WHERE id = ?', [(body['seats'] as int).clamp(1, 50), id]);
      if (body.containsKey('autoAccept')) {
        final v = body['autoAccept'];
        db.execute('UPDATE tables SET auto_accept = ? WHERE id = ?', [v == null ? null : (v == true ? 1 : 0), id]);
      }
      if (body['active'] is bool) {
        if (body['active'] == false && db.selectOne("SELECT id FROM checks WHERE table_id = ? AND status = 'open'", [id]) != null) {
          throw ApiError(400, 'الترابيزة عليها حساب مفتوح');
        }
        db.execute('UPDATE tables SET active = ? WHERE id = ?', [body['active'] == true ? 1 : 0, id]);
      }
      db.execute('UPDATE tables SET updated_at = ? WHERE id = ?', [now, id]);
    });
    _audit(u.id, id == null ? 'table.create' : 'table.update', 'table', id, body['name'] as String?);
    _broadcast('tables');
    return _floorJson();
  }

  /// إضافة كذا ترابيزة مرة واحدة (مثلاً من 1 لـ 20).
  Future<Object?> _bulkTables(Request req, AuthUser u) async {
    final body = await _body(req);
    final from = body['from'] as int? ?? 1, to = body['to'] as int? ?? 0;
    if (from < 1 || to < from || to - from > 200) throw ApiError(400, 'الأرقام مش صحيحة');
    final prefix = (body['prefix'] as String? ?? '').trim();
    final area = _validArea(body['areaId']);
    final seats = (body['seats'] as int? ?? 4).clamp(1, 50);
    var added = 0;
    db.transaction(() {
      final now = nowIso();
      for (var n = from; n <= to; n++) {
        final name = prefix.isEmpty ? '$n' : '$prefix $n';
        if (db.selectOne('SELECT id FROM tables WHERE name = ? AND active = 1', [name]) != null) continue;
        db.execute(
          'INSERT INTO tables(id, area_id, name, seats, qr_key, sort, created_at, updated_at) '
          'VALUES(?, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM tables), ?, ?)',
          [_uuid.v4(), area, name, seats, _newTableKey(), now, now],
        );
        added++;
      }
    });
    _broadcast('tables');
    return {'added': added, ..._floorJson()};
  }

  Object? _rotateTableKey(Request req, AuthUser u) {
    final id = req.params['id']!;
    final t = db.selectOne('SELECT * FROM tables WHERE id = ?', [id]);
    if (t == null) throw ApiError(404, 'الترابيزة دي مش موجودة');
    db.execute('UPDATE tables SET qr_key = ?, updated_at = ? WHERE id = ?', [_newTableKey(), nowIso(), id]);
    _audit(u.id, 'table.new_key', 'table', id, t['name'] as String);
    _broadcast('tables');
    return {'ok': true};
  }

  /// لينكات الـ QR لكل الترابيزات (عشان تتطبع). محتاجة إن الكافيه اتسجل على النت مرة.
  Object? _tableQrLinks(Request req, AuthUser u) {
    final cafeId = db.setting('cloud_uid');
    return {
      'cafeId': cafeId,
      'tables': db.select('SELECT t.*, a.name AS area_name FROM tables t LEFT JOIN areas a ON a.id = t.area_id WHERE t.active = 1 ORDER BY a.sort, t.sort, t.name').map((t) => {
            'id': t['id'],
            'name': t['name'],
            'areaName': t['area_name'],
            'url': cafeId == null ? null : _menuLink(cafeId, t['qr_key'] as String),
          }).toList(),
      // QR للتيك أواي (عند الكاونتر): العميل يطلب ويستلم بنفسه
      'takeawayUrl': cafeId == null ? null : _menuLink(cafeId, _takeawayKey),
    };
  }

  String _menuLink(String cafeId, String key) => '$menuSiteUrl/m/$cafeId/$key';

  /// الكود السري لـ QR التيك أواي (واحد للكافيه كله).
  String get _takeawayKey {
    var k = db.setting('takeaway_key');
    if (k == null) {
      k = 'tk${_newTableKey()}';
      db.setSetting('takeaway_key', k);
    }
    return k;
  }
}
