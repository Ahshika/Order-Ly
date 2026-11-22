// Firebase وهمي على الجهاز (Auth + Realtime Database REST + Server-Sent Events) للاختبارات.
// مابيطبقش القواعد (دي بتتجرب على Firebase الحقيقي)، بس بيعدّ كل بايت بيرجع للي طلبه:
// ده اللي Firebase بيحاسب عليه (التنزيل)، فالاختبارات بتقيس الاستهلاك بيه.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:orderly/src/core/firebase_config.dart';

class FakeRequest {
  FakeRequest(this.method, this.path, this.silent, this.bytes);
  final String method;
  final String path;
  final bool silent;

  /// البايتات اللي رجعت في الرد (من غير الهيدرز).
  int bytes;
}

class FakeFirebase {
  late final HttpServer _server;
  final Map<String, Object?> root = {};
  final requests = <FakeRequest>[];
  final _streams = <(String, HttpResponse, FakeRequest)>[];
  final _users = <String, String>{}; // email → uid
  var _nextUid = 0;

  String get base => 'http://127.0.0.1:${_server.port}';
  FirebaseEndpoints get endpoints => FirebaseEndpoints(apiKey: 'fake', rtdb: base, auth: base, token: base);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() async {
    for (final s in _streams) {
      await s.$2.close().catchError((_) {});
    }
    await _server.close(force: true);
  }

  // ---------------------------------------------------------------- data

  static List<String> _parts(String path) => path.split('/').where((s) => s.isNotEmpty).toList();

  Object? get(String path) {
    Object? node = root;
    for (final p in _parts(path)) {
      if (node is! Map) return null;
      node = node[p];
    }
    return node;
  }

  void set(String path, Object? value) {
    final parts = _parts(path);
    if (parts.isEmpty) {
      root
        ..clear()
        ..addAll(value is Map ? value.cast<String, Object?>() : {});
      return;
    }
    final chain = <Map<String, Object?>>[root];
    for (final p in parts.take(parts.length - 1)) {
      final next = chain.last[p];
      if (next is! Map<String, Object?>) {
        if (value == null) return;
        chain.last[p] = <String, Object?>{};
      }
      chain.add(chain.last[p] as Map<String, Object?>);
    }
    final v = _resolve(value);
    if (v == null || (v is Map && v.isEmpty)) {
      chain.last.remove(parts.last);
      // زي Firebase: الأب اللي فضي بيختفي
      for (var i = chain.length - 1; i > 0 && chain[i].isEmpty; i--) {
        chain[i - 1].remove(parts[i - 1]);
      }
    } else {
      chain.last[parts.last] = v;
    }
  }

  /// {'.sv': 'timestamp'} ← الوقت، والقيم الفاضية بتتشال.
  static Object? _resolve(Object? v) {
    if (v is Map) {
      if (v['.sv'] == 'timestamp') return DateTime.now().millisecondsSinceEpoch;
      final out = <String, Object?>{};
      for (final e in v.entries) {
        final r = _resolve(e.value);
        if (r != null && !(r is Map && r.isEmpty)) out['${e.key}'] = r;
      }
      return out;
    }
    if (v is List) return v.map(_resolve).toList();
    return v;
  }

  /// كتابة من بره (كأنها موبايل عميل) + إبلاغ اللي بيسمعوا.
  void write(String path, Object? value) {
    set(path, value);
    _notify(path);
  }

  void _notify(String changed) {
    for (final (path, res, rec) in [..._streams]) {
      if (!(changed.startsWith(path) || path.startsWith(changed) || path.isEmpty)) continue;
      final rel = changed.length > path.length ? changed.substring(path.length) : '/';
      final data = changed.length > path.length ? get(changed) : get(path);
      final event = 'event: put\ndata: ${jsonEncode({'path': rel.startsWith('/') ? rel : '/$rel', 'data': data})}\n\n';
      final bytes = utf8.encode(event);
      rec.bytes += bytes.length;
      try {
        res.add(bytes);
        res.flush();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------- HTTP

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final body = await utf8.decoder.bind(req).join();
    if (path.startsWith('/v1/')) return _auth(req, path, body);
    final dbPath = path.replaceFirst(RegExp(r'\.json$'), '').replaceFirst(RegExp('^/'), '');
    final silent = req.uri.queryParameters['print'] == 'silent';
    final rec = FakeRequest(req.method, dbPath, silent, 0);
    requests.add(rec);
    final res = req.response;

    if (req.method == 'GET' && (req.headers.value('accept') ?? '').contains('text/event-stream')) {
      res.headers.contentType = ContentType('text', 'event-stream');
      res.bufferOutput = false;
      final first = utf8.encode('event: put\ndata: ${jsonEncode({'path': '/', 'data': get(dbPath)})}\n\n');
      rec.bytes += first.length;
      res.add(first);
      await res.flush();
      _streams.add((dbPath, res, rec));
      return;
    }

    Object? echo;
    switch (req.method) {
      case 'GET':
        echo = get(dbPath);
      case 'PUT':
        echo = jsonDecode(body);
        write(dbPath, echo);
      case 'PATCH':
        final updates = (jsonDecode(body) as Map).cast<String, Object?>();
        for (final e in updates.entries) {
          set(dbPath.isEmpty ? e.key : '$dbPath/${e.key}', e.value);
        }
        for (final k in updates.keys) {
          _notify(dbPath.isEmpty ? k : '$dbPath/$k');
        }
        echo = updates;
      case 'DELETE':
        write(dbPath, null);
        echo = null;
    }
    if (silent && req.method != 'GET') {
      res.statusCode = 204;
    } else {
      final out = utf8.encode(jsonEncode(echo));
      rec.bytes = out.length;
      res.headers.contentType = ContentType.json;
      res.add(out);
    }
    await res.close();
  }

  Future<void> _auth(HttpRequest req, String path, String body) async {
    final j = body.isEmpty ? <String, dynamic>{} : (path.endsWith('/token') ? Uri.splitQueryString(body) : jsonDecode(body) as Map<String, dynamic>);
    final res = req.response..headers.contentType = ContentType.json;
    Map<String, Object?> out;
    if (path.endsWith('accounts:signUp')) {
      final uid = 'uid${_nextUid++}';
      _users[j['email'] as String] = uid;
      out = {'idToken': 'tok-$uid', 'refreshToken': 'ref-$uid', 'localId': uid, 'expiresIn': '3600'};
    } else if (path.endsWith('accounts:signInWithPassword')) {
      final uid = _users[j['email']];
      if (uid == null) {
        res.statusCode = 400;
        out = {'error': {'message': 'EMAIL_NOT_FOUND'}};
      } else {
        out = {'idToken': 'tok-$uid', 'refreshToken': 'ref-$uid', 'localId': uid, 'expiresIn': '3600'};
      }
    } else if (path.endsWith('/token')) {
      final uid = '${j['refresh_token']}'.replaceFirst('ref-', '');
      out = {'id_token': 'tok-$uid', 'refresh_token': 'ref-$uid', 'user_id': uid, 'expires_in': '3600'};
    } else {
      out = {};
    }
    res.write(jsonEncode(out));
    await res.close();
  }

  // ---------------------------------------------------------------- القياس

  /// البايتات اللي نزلت (ردود + أحداث لحظية)، وعدد الطلبات (كل طلب ليه هيدرز وممكن تشفير جديد).
  ({int bytes, int requests}) usage({bool Function(FakeRequest r)? where}) {
    final list = where == null ? requests : requests.where(where).toList();
    return (bytes: list.fold(0, (s, r) => s + r.bytes), requests: list.length);
  }

  void resetUsage() => requests.clear();

  int sizeOf(String path) => utf8.encode(jsonEncode(get(path))).length;
}
