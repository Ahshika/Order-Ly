part of 'api_server.dart';

/// التحكم من بعيد (أبلكيشن المالك): قايمة أوامر ثابتة بس، مش باب للبرنامج كله.
/// - مقفول افتراضياً. المالك بيفتحه من كمبيوتر الفرع (الإعدادات › المالك من بره).
/// - المالك المربوط بالفرع بيكتب الأمر في cmd/{cafe}/{id}، والكمبيوتر بيسمع لحظياً، وبينفّذ، وبيكتب الرد في
///   cmdr/{cafe}/{id} (صاحب الأمر بس يقراه)، وبيمسح الأمر.
/// - الأمر اللي عدّى عليه دقيقتين بيترفض، وأكتر من [_remotePerMinute] أمر في الدقيقة بيترفضوا،
///   وكل تعديل بيتسجل في سجل العمليات "من أبلكيشن المالك".
const _remotePerMinute = 30;
const _remoteMaxAge = Duration(minutes: 2);

extension _RemoteRoutes on OrderlyServer {
  void _registerRemoteRoutes(Router r) {
    r.post('/api/owner/remote', _authed((req, u) async {
      final on = (await _body(req))['on'] == true;
      db.setSetting('remote_control', on ? '1' : '');
      _audit(u.id, on ? 'remote.on' : 'remote.off', 'owner', null, on ? 'التحكم من بعيد اتفتح' : 'التحكم من بعيد اتقفل');
      _cloud?._startCommandListener();
      _broadcast('owner');
      return _ownerStatus();
    }, only: {'owner'}));
  }

  bool get _remoteOn => db.setting('remote_control') == '1';

  /// بينفّذ أمر واحد من القايمة. بيرجع الرد، أو بيرمي ApiError برسالة للمالك.
  Map<String, Object?> _remoteExec(String op, Map<String, dynamic> a, String by) {
    String itemId() {
      final id = a['id'];
      if (id is! String || db.selectOne('SELECT id FROM items WHERE id = ? AND active = 1', [id]) == null) throw ApiError(404, 'الصنف ده مش موجود');
      return id;
    }

    switch (op) {
      case 'menu.get':
        return {
          'items': db
              .select('SELECT i.id, i.name, c.name AS cat, i.price_cents, i.available FROM items i JOIN categories c ON c.id = i.category_id '
                  'WHERE i.active = 1 AND c.active = 1 ORDER BY c.sort, c.name, i.sort, i.name')
              .map((r) => {'id': r['id'], 'n': r['name'], 'c': r['cat'], 'p': r['price_cents'], 'av': r['available'] == 1})
              .toList(),
        };
      case 'item.price':
        final id = itemId();
        final price = a['p'];
        if (price is! int || price < 0 || price > 100000000) throw ApiError(400, 'السعر مش صحيح');
        final old = db.selectOne('SELECT name, price_cents FROM items WHERE id = ?', [id])!;
        db.execute('UPDATE items SET price_cents = ?, updated_at = ? WHERE id = ?', [price, nowIso(), id]);
        _audit(null, 'menu.item.price.remote', 'item', id, 'من أبلكيشن المالك: ${old['name']} ${money(old['price_cents'] as int)} › ${money(price)}');
        _broadcast('menu');
        return {'ok': true};
      case 'item.available':
        final id = itemId();
        final available = a['av'] == true;
        db.execute('UPDATE items SET available = ?, updated_at = ? WHERE id = ?', [available ? 1 : 0, nowIso(), id]);
        final name = db.selectOne('SELECT name FROM items WHERE id = ?', [id])!['name'];
        _audit(null, available ? 'menu.item.available.remote' : 'menu.item.soldout.remote', 'item', id, 'من أبلكيشن المالك: $name');
        _broadcast('menu');
        return {'ok': true};
      case 'checks.open':
        return {
          'checks': db
              .select("SELECT c.number, c.type, c.total_cents, c.paid_cents, c.opened_at, c.customer_name, t.name AS tbl, u.name AS waiter FROM checks c "
                  "LEFT JOIN tables t ON t.id = c.table_id LEFT JOIN users u ON u.id = c.waiter_id WHERE c.status = 'open' ORDER BY c.opened_at")
              .map((r) => {'n': r['number'], 'type': r['type'], 't': r['total_cents'], 'paid': r['paid_cents'], 'at': r['opened_at'], 'table': r['tbl'], 'name': r['customer_name'], 'w': r['waiter']})
              .toList(),
        };
      case 'audit.recent':
        return {
          'log': db
              .select('SELECT a.action, a.details, a.created_at, u.name AS who FROM audit_log a LEFT JOIN users u ON u.id = a.user_id ORDER BY a.created_at DESC LIMIT 50')
              .map((r) => {'a': r['action'], 'd': r['details'], 'at': r['created_at'], 'who': r['who']})
              .toList(),
        };
    }
    throw ApiError(400, 'الأمر ده مش مسموح');
  }
}

/// كلام الأوامر مع Firebase.
extension _RemoteSync on CloudSync {
  /// بيسمع على cmd/{cafe} لحظياً لو التحكم من بعيد مفتوح (اتصال واحد زيادة بس وقت ما هو مفتوح).
  void _startCommandListener() {
    if (_stopped || _cmdListening || !server._remoteOn || _uid == null) return;
    _cmdListening = true;
    unawaited(_listenCommands());
  }

  Future<void> _listenCommands() async {
    final client = http.Client();
    try {
      await _token();
      final req = http.Request('GET', _url('cmd/$_uid'))..headers['accept'] = 'text/event-stream';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('cmd stream ${res.statusCode}');
      String? event;
      await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (_stopped || !server._remoteOn) break;
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          if (event == 'auth_revoked' || event == 'cancel') break;
          if (event != 'put' && event != 'patch') continue;
          final j = jsonDecode(line.substring(5).trim());
          if (j is! Map || j['data'] == null) continue;
          final parts = '${j['path']}'.split('/').where((s) => s.isNotEmpty).toList();
          if (parts.isEmpty && j['data'] is Map) {
            for (final e in (j['data'] as Map).entries) {
              if (e.value is Map) await _handleCommand('${e.key}', (e.value as Map).cast<String, dynamic>());
            }
          } else if (parts.length == 1 && j['data'] is Map) {
            await _handleCommand(parts.first, (j['data'] as Map).cast<String, dynamic>());
          }
        }
      }
    } catch (_) {
      // بنرجع نتصل تاني تحت
    } finally {
      client.close();
      _cmdListening = false;
      if (!_stopped && server._remoteOn) Timer(const Duration(seconds: 5), _startCommandListener);
    }
  }

  Future<void> _handleCommand(String id, Map<String, dynamic> cmd) async {
    if (!_cmdSeen.add(id)) return;
    if (_cmdSeen.length > 500) _cmdSeen.remove(_cmdSeen.first);
    final by = '${cmd['by'] ?? ''}';
    final at = cmd['at'] is int ? DateTime.fromMillisecondsSinceEpoch(cmd['at'] as int) : DateTime(2000);
    final now = DateTime.now();
    _cmdTimes.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    bool ok;
    Object? result;
    try {
      if (!server._remoteOn) throw ApiError(403, 'التحكم من بعيد مقفول من كمبيوتر الكافيه');
      if (now.difference(at).abs() > _remoteMaxAge) throw ApiError(400, 'الأمر اتأخر في الوصول. جرّب تاني');
      if (_cmdTimes.length >= _remotePerMinute) throw ApiError(429, 'أوامر كتير في دقيقة. استنى شوية');
      _cmdTimes.add(now);
      Map<String, dynamic> args;
      try {
        final decoded = jsonDecode('${cmd['a'] ?? '{}'}');
        args = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
      } on FormatException {
        args = <String, dynamic>{};
      }
      result = server._remoteExec('${cmd['op']}', args, by);
      ok = true;
    } on ApiError catch (e) {
      ok = false;
      result = e.message;
    } catch (e) {
      ok = false;
      result = 'حصل خطأ في الكمبيوتر: $e';
    }
    try {
      await _patch({
        'cmdr/$_uid/$id': {'ok': ok, 'r': jsonEncode(result), 'by': by, 'at': {'.sv': 'timestamp'}},
        'cmd/$_uid/$id': null,
      });
      _cmdReplies[id] = now;
      // الردود القديمة (المالك قراها خلاص) بتتمسح بعد 10 دقايق
      final old = _cmdReplies.entries.where((e) => now.difference(e.value) > const Duration(minutes: 10)).map((e) => e.key).toList();
      if (old.isNotEmpty) {
        await _patch({for (final k in old) 'cmdr/$_uid/$k': null});
        old.forEach(_cmdReplies.remove);
      }
    } catch (e) {
      _cmdSeen.remove(id);
      db.setSetting('owner_last_error', 'رد الأمر ماوصلش: ${_errorText(e)}');
    }
  }
}
