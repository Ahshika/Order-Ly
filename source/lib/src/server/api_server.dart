import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sqlite3/sqlite3.dart' show OpenMode, SqliteException, sqlite3;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/app_info.dart';
import '../core/diagnostics.dart';
import '../core/firebase_config.dart';
import '../core/format.dart';
import '../core/license.dart';
import 'db.dart';
import 'discovery.dart';
import 'passwords.dart';

part 'backup_service.dart';
part 'cloud_sync.dart';
part 'routes_branches.dart';
part 'routes_checks.dart';
part 'routes_inventory.dart';
part 'routes_license.dart';
part 'routes_menu.dart';
part 'routes_payments.dart';
part 'routes_reports.dart';
part 'routes_shop.dart';
part 'routes_tables.dart';

const serverPort = 8753;
const roles = {'owner', 'supervisor', 'cashier', 'waiter', 'kitchen'};

/// اللي بيقدروا يشتغلوا على الحسابات والفلوس
const cashRoles = {'owner', 'supervisor', 'cashier'};

/// المالك ومسؤول الشفت: الإلغاء، وفتح الحسابات تاني، والمرتجع، والورديات القديمة
const managerRoles = {'owner', 'supervisor'};

/// اللي بيقدروا ياخدوا طلبات ويشوفوا الترابيزات
const floorRoles = {'owner', 'supervisor', 'cashier', 'waiter'};

/// أقصى عدد طلبات على شاشة المطبخ مرة واحدة (الأقدم الأول)، عشان الشاشة متتقلش لو المطبخ اتملى.
const kdsLimit = 200;

/// أكبر طلب مقبول. أكبر حاجة حقيقية: صورة صنف 8 ميجا بالـ base64 (حوالي 11 ميجا).
const maxBodyBytes = 12 * 1024 * 1024;

const _uuid = Uuid();

String nowIso() => DateTime.now().toUtc().toIso8601String();

class ApiError implements Exception {
  ApiError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'ApiError($status): $message';
}

class AuthUser {
  AuthUser(this.row, this.tokenHash);
  final Map<String, Object?> row;
  final String tokenHash;
  String get id => row['id'] as String;
  String get role => row['role'] as String;
  bool get isOwner => role == 'owner';
  bool get isManager => managerRoles.contains(role);

  /// الرقم المميز للجهاز اللي الجلسة دي عليه.
  String? get deviceId => row['session_device'] as String?;
}

/// سيرفر الكافيه: بيشتغل على كمبيوتر الكاشير، وكل الموبايلات والتابلتات التانية بتكلمه.
class OrderlyServer {
  OrderlyServer({required this.dataDir, this.requestedPort = serverPort, this.cloudSync = true, this.firebase});

  final String dataDir;
  final int requestedPort;

  /// المزامنة مع منيو العملاء على Firebase (بتتقفل في الاختبارات).
  final bool cloudSync;

  /// للاختبارات (Firebase وهمي). null = المشروع اللي في كود التفعيل، أو الأساسي.
  final FirebaseEndpoints? firebase;

  /// مشروع Firebase اللي المحل ده بيستخدمه: من كود التفعيل لو فيه، وإلا الأساسي.
  Future<FirebaseEndpoints> _resolveFirebase() async {
    if (firebase != null) return firebase!;
    final code = db.setting('license_code');
    if (code == null || code.isEmpty) return FirebaseEndpoints.live;
    try {
      final fb = (await verifyLicense(code, deviceCode: _deviceCode)).firebase;
      return fb == null ? FirebaseEndpoints.live : FirebaseEndpoints.forProject(fb);
    } on LicenseException {
      return FirebaseEndpoints.live;
    }
  }
  CloudSync? _cloud;
  Timer? _jobsTimer;
  Timer? _firstJobTimer;
  Timer? _backupTimer;

  /// نسخة احتياطية شغالة دلوقتي (عشان نسختين مايتعملوش في نفس اللحظة).
  Future<void>? _backupRunning;

  /// البورت الفعلي (بيفرق عن requestedPort لو طلبنا 0 في الاختبارات).
  int get port => _http?.port ?? requestedPort;

  late final AppDb db;
  late final DiagLog _log = DiagLog.openIn(dataDir, 'server');
  HttpServer? _http;
  DiscoveryResponder? _discovery;
  final _sockets = <WebSocketChannel>{};
  final _loginFailures = <String, _Failures>{};

  /// آخر مرة "آخر ظهور" اتكتب لكل جلسة: كان بيتكتب في قاعدة البيانات مع كل طلب (كتابة زيادة في كل قراية).
  final _lastSeenWritten = <String, DateTime>{};

  /// آخر الإشعارات (وقتها، ونصه) عشان الجهاز اللي اتصاله قطع ثواني ياخد اللي فاته لما يرجع.
  final _recentNotifications = <(DateTime, String, String)>[];
  static const _notifyReplayWindow = Duration(minutes: 3);

  /// ردود الشاشات اللي كل الأجهزة بتسأل عليها كل ثانية (الصالة، المطبخ، الأرقام اللايف، الحسابات المفتوحة).
  /// بتتحسب مرة واحدة وتتبعت للكل، وبتتمسح مع أي تغيير ([_broadcast]) أو بعد ثانيتين بالكتير.
  final _screenCache = <String, (DateTime, String)>{};

  Future<void> start() async {
    await initializeDateFormatting('ar');
    await Directory(dataDir).create(recursive: true);
    applyPendingRestore(dataDir);
    db = _openOrRecover();
    if (db.setting('server_id') == null) db.setSetting('server_id', _uuid.v4());
    _log.write('INFO', 'السيرفر اشتغل ($appName $appVersion)');
    final health = db.integrity();
    if (health != 'ok') _log.write('ERROR', 'فحص قاعدة البيانات لقى مشكلة: $health (ارجع لآخر نسخة احتياطية من الإعدادات)');
    db.setSetting('db_health', health);

    final handler = const Pipeline().addMiddleware(_errors()).addHandler(_router().call);
    try {
      // من غير X-Powered-By: مفيش داعي نقول لأي حد على الشبكة السيرفر مكتوب بإيه
      _http = await shelf_io.serve(handler, InternetAddress.anyIPv4, requestedPort, shared: false, poweredByHeader: null);
    } on SocketException {
      db.close();
      throw ApiError(500, 'البورت $requestedPort مستخدم. غالباً البرنامج مفتوح بالفعل على الجهاز ده.');
    }
    _http!.autoCompress = true;

    _discovery = DiscoveryResponder(() {
      final info = _info();
      return {'port': port, 'shopName': info['shopName'], 'branchName': info['branchName'], 'serverId': info['serverId']};
    });
    try {
      await _discovery!.start();
    } catch (_) {
      // لو بورت البحث مش متاح، الموبايلات لسه تقدر تتصل يدوي بالـ IP
    }

    if (cloudSync) _cloud = CloudSync(this)..start();

    // شغل بيتكرر: الصيانة وتنضيف الطباعة القديمة كل ساعة، والنسخ الاحتياطي بيتكشف عليه كل 10 دقايق
    // (عشان لو المالك اختار "كل ساعة" النسخة متتأخرش)
    Future<void> jobs() async {
      db.maintenance();
      _cleanupPrintJobs();
      await _runBackupIfDue();
    }

    Future<void> safeJobs() => jobs().catchError((Object e, StackTrace st) => _log.error('الشغل الدوري: $e', st));
    _jobsTimer = Timer.periodic(const Duration(hours: 1), (_) => safeJobs());
    _firstJobTimer = Timer(const Duration(minutes: 1), safeJobs);
    _backupTimer = Timer.periodic(const Duration(minutes: 10), (_) => _runBackupIfDue());
  }

  /// كشف النسخ الاحتياطي اللي بيحصل كل 10 دقايق، بس دلوقتي (للاختبارات).
  Future<void> runBackupCheckNow() => _runBackupIfDue();

  /// مزامنة فورية مع صفحة التتبع (للاختبارات وزرار "مزامنة دلوقتي").
  Future<void> syncNow() async => _cloud?.runNow();

  /// رسالة من منيو العميل كأنها جاية من النت (للاختبارات).
  void ingestCloudMessage(String cloudId, Map<String, dynamic> msg, [List<int>? proof]) =>
      _ingestCloudMessage(cloudId, msg, proof == null ? null : shrinkToJpeg(proof, 1400, 80));

  String get takeawayKey => _takeawayKey;

  /// ملخص الفرع اللي بيتبعت للفرع الرئيسي (للاختبارات).
  Future<Map<String, Object?>> branchSummaryForTests() => _branchSummary();

  /// بيمسح كل بيانات الكافيه من Firebase (للاختبارات بس).
  Future<void> cleanupCloudForTests() async => _cloud?.deleteEverything();

  /// كأن توكن Firebase خلص (بيعيش ساعة) عشان المزامنة الجاية تجدده (للاختبارات).
  void expireCloudTokenForTests() => _cloud?._idToken = null;

  /// آخر خطأ في المزامنة (فاضي لو كله تمام).
  String? get cloudError => db.setting('cloud_last_error');

  Future<void> stop() async {
    _cloud?.stop();
    _jobsTimer?.cancel();
    _firstJobTimer?.cancel();
    _backupTimer?.cancel();
    // نستنى أي نسخة احتياطية شغالة قبل ما نقفل قاعدة البيانات
    if (_backupRunning != null) await _backupRunning;
    _discovery?.close();
    // نسخة من القايمة: كل اتصال بيشيل نفسه منها أول ما يتقفل، فاللفّ عليها مباشرة كان بيوقّع الإيقاف
    // (ومعاه قاعدة البيانات ماكانتش بتتقفل صح)
    for (final s in _sockets.toList()) {
      await s.sink.close();
    }
    await _http?.close(force: true);
    db.close();
  }

  // ---------------------------------------------------------------- routing

  Router _router() {
    final r = Router();
    r.get('/api/info', _public((_) => _info()));
    r.post('/api/setup', _public(_setup));
    r.post('/api/auth/login', _public(_login));
    r.post('/api/auth/logout', _authed((req, u) {
      db.execute('DELETE FROM sessions WHERE token_hash = ?', [u.tokenHash]);
      return {'ok': true};
    }));
    r.get('/api/auth/me', _authed((req, u) => {'user': _publicUser(u.row)}));
    r.post('/api/auth/password', _authed(_changeOwnPassword));

    r.get('/api/users', _authed(_listUsers, only: {'owner'}));
    r.post('/api/users', _authed(_createUser, only: {'owner'}));
    r.patch('/api/users/<id>', _authed(_updateUser, only: {'owner'}));

    r.get('/api/audit', _authed(_listAudit, only: {'owner'}));
    _registerShopRoutes(r);
    _registerMenuRoutes(r);
    _registerTableRoutes(r);
    _registerCheckRoutes(r);
    _registerPaymentRoutes(r);
    _registerInventoryRoutes(r);
    _registerBackupRoutes(r);
    _registerReportRoutes(r);
    _registerLicenseRoutes(r);
    _registerBranchRoutes(r);

    r.get('/api/ws', _webSocket);
    r.all('/<ignored|.*>', (Request _) => _json(404, {'error': 'المسار ده مش موجود'}));
    return r;
  }

  Middleware _errors() => (inner) => (req) async {
        final sw = Stopwatch()..start();
        try {
          final res = await inner(req);
          if (sw.elapsedMilliseconds > 700 && !req.url.path.startsWith('api/ws')) {
            _log.write('SLOW', '${req.method} /${req.url.path} خد ${sw.elapsedMilliseconds} مللي ثانية');
          }
          return res;
        } on ApiError catch (e) {
          return _json(e.status, {'error': e.message});
        } on HijackException {
          // ده مش خطأ: الـ WebSocket بياخد الاتصال، وshelf لازم يشوف الاستثناء ده عشان يكمّل
          rethrow;
        } catch (e, st) {
          stderr.writeln('Server error on ${req.method} ${req.url}: $e\n$st');
          _log.error('${req.method} /${req.url.path}: $e', st);
          return _json(500, {'error': 'حصل خطأ في السيرفر، جرّب تاني'});
        }
      };

  Handler _public(FutureOr<Object?> Function(Request req) fn) => (req) async => _json(200, await fn(req));

  Handler _authed(FutureOr<Object?> Function(Request req, AuthUser user) fn, {Set<String>? only}) => (req) async {
        final user = _authenticate(req);
        if (only != null && !only.contains(user.role)) {
          throw ApiError(403, 'مش مسموحلك تعمل العملية دي');
        }
        final result = await fn(req, user);
        // الملفات (زي صور المنيو والتحويلات) بترجع Response جاهز مش JSON
        return result is Response ? result : _json(200, result);
      };

  AuthUser _authenticate(Request req) {
    final header = req.headers['authorization'];
    // التوكن في الرابط بيتقبل في الـ WebSocket بس (مفيش طريقة تانية تبعته فيه).
    // في أي مكان تاني الروابط بتتسجل في اللوجات والسكرين شوت، فالتوكن لازم في الهيدر.
    final token = header != null && header.startsWith('Bearer ')
        ? header.substring(7)
        : req.url.path == 'api/ws'
            ? req.url.queryParameters['token']
            : null;
    if (token == null || token.isEmpty) throw ApiError(401, 'لازم تسجل دخول الأول');

    final tokenHash = sha256Hex(token);
    final row = db.selectOne(
      'SELECT u.*, s.device_id AS session_device FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?',
      [tokenHash],
    );
    if (row == null) throw ApiError(401, 'الجلسة انتهت، سجل دخول تاني');
    if (row['active'] != 1) throw ApiError(401, 'الحساب ده متوقف، كلم صاحب الكافيه');
    // "آخر ظهور" بيتستخدم لحد الأجهزة (آخر 30 يوم)، فكفاية يتكتب مرة كل دقيقة
    final now = DateTime.now();
    final written = _lastSeenWritten[tokenHash];
    if (written == null || now.difference(written).inSeconds >= 60) {
      db.execute('UPDATE sessions SET last_seen_at = ? WHERE token_hash = ?', [nowIso(), tokenHash]);
      if (_lastSeenWritten.length > 5000) _lastSeenWritten.clear();
      _lastSeenWritten[tokenHash] = now;
    }
    return AuthUser(row, tokenHash);
  }

  // ---------------------------------------------------------------- setup & auth

  Map<String, Object?> _info() {
    final shop = db.selectOne('SELECT name FROM shop LIMIT 1');
    final branch = db.selectOne('SELECT name FROM branches WHERE is_local = 1 LIMIT 1');
    return {
      'app': 'orderly',
      'api': apiVersion,
      'version': appVersion,
      'serverId': db.setting('server_id'),
      'setupDone': shop != null,
      'shopName': shop?['name'],
      'branchName': branch?['name'],
    };
  }

  Future<Object?> _setup(Request req) async {
    final body = await _body(req);
    if (db.selectOne('SELECT id FROM shop LIMIT 1') != null) {
      throw ApiError(409, 'الكافيه متسجل بالفعل على السيرفر ده');
    }
    final shopName = _requiredText(body, 'shopName', 'اسم الكافيه');
    final branchName = _optionalText(body, 'branchName') ?? 'الفرع الرئيسي';
    final ownerName = _requiredText(body, 'ownerName', 'اسم صاحب الكافيه');
    final username = _validUsername(body['username']);
    final password = _validPassword(body['password']);
    final now = nowIso();
    final shopId = _uuid.v4(), branchId = _uuid.v4(), userId = _uuid.v4();
    final passwordHash = hashPassword(password);

    db.transaction(() {
      db.execute('INSERT INTO shop(id, name, phone, address, created_at) VALUES(?, ?, ?, ?, ?)',
          [shopId, shopName, _optionalText(body, 'shopPhone'), _optionalText(body, 'shopAddress'), now]);
      db.execute('INSERT INTO branches(id, name, phone, address, is_local, created_at) VALUES(?, ?, ?, ?, 1, ?)',
          [branchId, branchName, _optionalText(body, 'shopPhone'), _optionalText(body, 'shopAddress'), now]);
      db.execute(
        'INSERT INTO users(id, branch_id, name, username, password_hash, role, active, created_at, updated_at) '
        'VALUES(?, ?, ?, ?, ?, \'owner\', 1, ?, ?)',
        [userId, branchId, ownerName, username, passwordHash, now, now],
      );
      _seedDefaults(now);
    });
    _audit(userId, 'shop.setup', 'shop', shopId, shopName);
    db.setSetting('trial_started', nowIso());
    final user = db.selectOne('SELECT * FROM users WHERE id = ?', [userId])!;
    return {'token': _createSession(userId, body['deviceName'], body['deviceId']), 'user': _publicUser(user)};
  }

  Future<Object?> _login(Request req) async {
    final ip = _clientIp(req);
    final failures = _loginFailures[ip];
    if (failures != null && failures.lockedUntil != null && DateTime.now().isBefore(failures.lockedUntil!)) {
      final seconds = failures.lockedUntil!.difference(DateTime.now()).inSeconds + 1;
      throw ApiError(429, 'محاولات كتير غلط. استنى $seconds ثانية وجرّب تاني');
    }

    final body = await _body(req);
    final username = (_field<String>(body, 'username') ?? '').trim().toLowerCase();
    final password = _field<String>(body, 'password') ?? '';
    final deviceName = _field<String>(body, 'deviceName');
    final deviceId = _field<String>(body, 'deviceId');
    final user = db.selectOne('SELECT * FROM users WHERE username = ?', [username]);

    if (user == null || !verifyPassword(password, user['password_hash'] as String)) {
      final f = _loginFailures.putIfAbsent(ip, _Failures.new);
      f.count++;
      if (f.count >= 5) {
        f.lockedUntil = DateTime.now().add(const Duration(minutes: 1));
        f.count = 0;
      }
      throw ApiError(401, 'اسم المستخدم أو كلمة السر غلط');
    }
    if (user['active'] != 1) throw ApiError(403, 'الحساب ده متوقف، كلم صاحب الكافيه');

    // كل جهاز بيتعرف برقمه المميز (مش باسمه: الموبايلات ممكن يبقى ليها نفس الاسم، والاسم ممكن ميتبعتش أصلاً)
    if (deviceId == null || deviceId.length < 8 || deviceId.length > 64) {
      throw ApiError(400, 'نسخة البرنامج دي قديمة. حدّث البرنامج على الجهاز ده وجرّب تاني');
    }
    await _checkDeviceLimit(deviceId);
    _loginFailures.remove(ip);
    _audit(user['id'] as String, 'auth.login', 'user', user['id'] as String, deviceName);
    return {'token': _createSession(user['id'] as String, deviceName, deviceId), 'user': _publicUser(user)};
  }

  Future<Object?> _changeOwnPassword(Request req, AuthUser u) async {
    final body = await _body(req);
    if (!verifyPassword(_field<String>(body, 'currentPassword') ?? '', u.row['password_hash'] as String)) {
      throw ApiError(400, 'كلمة السر الحالية غلط');
    }
    final password = _validPassword(body['newPassword']);
    db.transaction(() {
      db.execute('UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?', [hashPassword(password), nowIso(), u.id]);
      // نخرج من كل الأجهزة التانية ونسيب الجهاز الحالي بس
      db.execute('DELETE FROM sessions WHERE user_id = ? AND token_hash <> ?', [u.id, u.tokenHash]);
    });
    _audit(u.id, 'user.password', 'user', u.id, null);
    return {'ok': true};
  }

  String _createSession(String userId, Object? deviceName, [Object? deviceId]) {
    final token = randomToken();
    final now = nowIso();
    db.execute(
      'INSERT INTO sessions(token_hash, user_id, device_name, device_id, created_at, last_seen_at) VALUES(?, ?, ?, ?, ?, ?)',
      [sha256Hex(token), userId, deviceName is String ? deviceName : null, deviceId is String && deviceId.length <= 64 ? deviceId : null, now, now],
    );
    return token;
  }

  // ---------------------------------------------------------------- users

  Object? _listUsers(Request req, AuthUser u) {
    final rows = db.select('SELECT * FROM users ORDER BY active DESC, role, name');
    return {'users': rows.map(_publicUser).toList()};
  }

  Future<Object?> _createUser(Request req, AuthUser u) async {
    final body = await _body(req);
    final name = _requiredText(body, 'name', 'الاسم');
    final username = _validUsername(body['username']);
    final password = _validPassword(body['password']);
    final role = _validRole(body['role']);
    if (db.selectOne('SELECT id FROM users WHERE username = ?', [username]) != null) {
      throw ApiError(409, 'اسم المستخدم "$username" موجود بالفعل، اختار اسم تاني');
    }
    final id = _uuid.v4();
    final now = nowIso();
    final branchId = db.selectOne('SELECT id FROM branches WHERE is_local = 1 LIMIT 1')?['id'];
    db.execute(
      'INSERT INTO users(id, branch_id, name, username, password_hash, role, active, created_at, updated_at) '
      'VALUES(?, ?, ?, ?, ?, ?, 1, ?, ?)',
      [id, branchId, name, username, hashPassword(password), role, now, now],
    );
    _audit(u.id, 'user.create', 'user', id, '$name ($role)');
    _broadcast('users');
    return {'user': _publicUser(db.selectOne('SELECT * FROM users WHERE id = ?', [id])!)};
  }

  Future<Object?> _updateUser(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final body = await _body(req);
    final target = db.selectOne('SELECT * FROM users WHERE id = ?', [id]);
    if (target == null) throw ApiError(404, 'الموظف ده مش موجود');

    final name = body.containsKey('name') ? _requiredText(body, 'name', 'الاسم') : target['name'] as String;
    final role = body.containsKey('role') ? _validRole(body['role']) : target['role'] as String;
    final active = body.containsKey('active') ? (body['active'] == true ? 1 : 0) : target['active'] as int;
    final newPassword = body['password'] is String && (body['password'] as String).isNotEmpty
        ? _validPassword(body['password'])
        : null;

    if (id == u.id && (role != 'owner' || active != 1)) {
      throw ApiError(400, 'مينفعش توقف حسابك أو تغيّر صلاحيتك بنفسك');
    }
    if (target['role'] == 'owner' && (role != 'owner' || active != 1)) {
      final owners = db.selectOne("SELECT COUNT(*) AS c FROM users WHERE role = 'owner' AND active = 1")!['c'] as int;
      if (owners <= 1) throw ApiError(400, 'لازم يفضل فيه مالك واحد على الأقل');
    }

    db.transaction(() {
      db.execute('UPDATE users SET name = ?, role = ?, active = ?, updated_at = ? WHERE id = ?', [name, role, active, nowIso(), id]);
      if (newPassword != null) {
        db.execute('UPDATE users SET password_hash = ? WHERE id = ?', [hashPassword(newPassword), id]);
      }
      // أي تغيير في الصلاحية أو الإيقاف أو كلمة السر بيخرج الموظف من كل أجهزته
      if (newPassword != null || active != 1 || role != target['role']) {
        db.execute('DELETE FROM sessions WHERE user_id = ?', [id]);
      }
    });
    final changes = [
      if (name != target['name']) 'الاسم: من ${target['name']} لـ $name',
      if (role != target['role']) 'الصلاحية: من ${target['role']} لـ $role',
      if (active != target['active']) active == 1 ? 'تفعيل الحساب' : 'إيقاف الحساب',
      if (newPassword != null) 'تغيير كلمة السر',
    ];
    if (changes.isNotEmpty) _audit(u.id, 'user.update', 'user', id, changes.join('، '));
    _broadcast('users');
    return {'user': _publicUser(db.selectOne('SELECT * FROM users WHERE id = ?', [id])!)};
  }

  Map<String, Object?> _publicUser(Map<String, Object?> row) => {
        'id': row['id'],
        'name': row['name'],
        'username': row['username'],
        'role': row['role'],
        'active': row['active'] == 1,
        'branchId': row['branch_id'],
        'createdAt': row['created_at'],
      };

  // ---------------------------------------------------------------- audit

  void _audit(String? userId, String action, String? entity, String? entityId, String? details) {
    db.execute(
      'INSERT INTO audit_log(user_id, action, entity, entity_id, details, created_at) VALUES(?, ?, ?, ?, ?, ?)',
      [userId, action, entity, entityId, details, nowIso()],
    );
  }

  Object? _listAudit(Request req, AuthUser u) {
    final limit = (int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 100).clamp(1, 500);
    final before = int.tryParse(req.url.queryParameters['before'] ?? '');
    final rows = db.select(
      'SELECT a.*, u.name AS user_name FROM audit_log a LEFT JOIN users u ON u.id = a.user_id '
      '${before != null ? 'WHERE a.id < ?' : ''} ORDER BY a.id DESC LIMIT ?',
      [?before, limit],
    );
    return {
      'entries': rows
          .map((r) => {
                'id': r['id'],
                'userName': r['user_name'],
                'action': r['action'],
                'details': r['details'],
                'createdAt': r['created_at'],
              })
          .toList(),
    };
  }

  // ---------------------------------------------------------------- realtime

  FutureOr<Response> _webSocket(Request req) {
    _authenticate(req);
    // since = آخر وقت (بساعة السيرفر) الجهاز شاف فيه حاجة قبل ما الاتصال يقطع
    final since = DateTime.tryParse(req.url.queryParameters['since'] ?? '');
    return webSocketHandler((WebSocketChannel ch, String? _) {
      _sockets.add(ch);
      ch.stream.listen((_) {}, onDone: () => _sockets.remove(ch), onError: (_) => _sockets.remove(ch));
      // ساعة السيرفر عشان الجهاز يقولنا "since" بيها المرة الجاية (ساعات الموبايلات ممكن تبقى مختلفة)
      ch.sink.add(jsonEncode({'type': 'hello', 'at': nowIso()}));
      if (since != null) {
        for (final n in _recentNotifications) {
          if (n.$1.isAfter(since)) ch.sink.add(n.$3);
        }
      }
    })(req);
  }

  /// بيبلّغ كل الأجهزة المتصلة إن فيه حاجة اتغيرت عشان تحدّث الشاشة.
  void _broadcast(String topic) {
    _screenCache.clear();
    if (const {'shop', 'menu', 'tables', 'checks', 'orders', 'payments', 'calls', 'stock'}.contains(topic)) _cloud?.kick(topic);
    final msg = jsonEncode({'type': 'changed', 'topic': topic});
    for (final s in _sockets.toList()) {
      try {
        s.sink.add(msg);
      } catch (_) {
        _sockets.remove(s);
      }
    }
  }

  /// إشعار للموظفين (بيطلع على الموبايلات والكمبيوتر بصوت). [roles] = مين يستلمه، و[goTo] = الشاشة اللي تتفتح لو داس عليه.
  /// بيتبعت بعد ما العملية تتسجل (مش جوه الـ transaction) عشان مايطلعش إشعار لحاجة اترجعت.
  void _notify(String kind, String title, String body, Set<String> roles, {String? goTo}) {
    final at = nowIso();
    final msg = jsonEncode({
      'type': 'notify',
      'id': _uuid.v4(),
      'kind': kind,
      'title': title,
      'body': body,
      'roles': roles.toList(),
      'goTo': ?goTo,
      'at': at,
    });
    // آخر الإشعارات بتتحفظ شوية: الموبايل اللي الواي فاي بتاعه قطع ثواني ياخدها لما يرجع
    _recentNotifications.add((DateTime.parse(at), at, msg));
    final cutoff = DateTime.now().toUtc().subtract(_notifyReplayWindow);
    _recentNotifications.removeWhere((n) => n.$1.isBefore(cutoff));
    if (_recentNotifications.length > 200) _recentNotifications.removeRange(0, _recentNotifications.length - 200);
    for (final s in _sockets.toList()) {
      try {
        s.sink.add(msg);
      } catch (_) {
        _sockets.remove(s);
      }
    }
  }

  String _placeName(String? tableId, {String? customerName}) {
    final t = tableId == null ? null : db.selectOne('SELECT name FROM tables WHERE id = ?', [tableId]);
    return t != null ? 'ترابيزة ${t['name']}' : (customerName == null ? 'تيك أواي' : 'تيك أواي • $customerName');
  }

  /// طلب اتبعت للبار/المطبخ (من الكاشير/الويتر أو QR اتقبل).
  void _notifyKitchen(String orderId) {
    final o = db.selectOne('SELECT number, table_id, guest_name, check_id FROM orders WHERE id = ?', [orderId]);
    if (o == null) return;
    final n = db.selectOne("SELECT COALESCE(SUM(qty), 0) AS n FROM order_items WHERE order_id = ? AND status <> 'void'", [orderId])!['n'];
    final customer = o['check_id'] == null ? null : db.selectOne('SELECT customer_name FROM checks WHERE id = ?', [o['check_id']])?['customer_name'] as String?;
    _notify('kitchen_new', 'طلب #${o['number']} للتحضير', '${_placeName(o['table_id'] as String?, customerName: o['guest_name'] as String? ?? customer)} • $n صنف', const {'kitchen'},
        goTo: 'kds');
  }

  // ---------------------------------------------------------------- helpers

  /// رد شاشة من الكاش لو لسه صالح، أو بيحسبه ويحفظه. المفتاح = المسار بالـ query (مش بيفرق بين الموظفين).
  Response _cachedScreen(Request req, Object? Function() build) {
    final key = '${req.url}';
    final now = DateTime.now();
    final hit = _screenCache[key];
    if (hit != null && now.difference(hit.$1).inMilliseconds < 2000) return _jsonText(200, hit.$2);
    final text = jsonEncode(build());
    if (_screenCache.length > 200) _screenCache.clear();
    _screenCache[key] = (now, text);
    return _jsonText(200, text);
  }

  Response _jsonText(int status, String text) => Response(
        status,
        body: text,
        headers: {'content-type': 'application/json; charset=utf-8', 'x-content-type-options': 'nosniff'},
      );

  Response _json(int status, Object? body) => Response(
        status,
        body: jsonEncode(body),
        headers: {'content-type': 'application/json; charset=utf-8', 'x-content-type-options': 'nosniff'},
      );

  /// بيقرا الـ body بحد أقصى [maxBodyBytes]، عشان أي جهاز على الواي فاي (حتى من غير تسجيل دخول)
  /// مايقدرش يخلي السيرفر يحمّل في الذاكرة طلب ضخم ويقع.
  Future<Map<String, dynamic>> _body(Request req) async {
    if ((req.contentLength ?? 0) > maxBodyBytes) throw ApiError(413, 'البيانات المبعوتة كبيرة جداً');
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in req.read()) {
        bytes.add(chunk);
        if (bytes.length > maxBodyBytes) throw ApiError(413, 'البيانات المبعوتة كبيرة جداً');
      }
    } on HttpException {
      // الموبايل فصل (واي فاي ضعيف) قبل ما الطلب يكمل: مش خطأ في السيرفر
      throw ApiError(400, 'الاتصال اتقطع قبل ما البيانات توصل، جرّب تاني');
    }
    if (bytes.isEmpty) return {};
    try {
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    throw ApiError(400, 'البيانات المبعوتة مش مفهومة');
  }

  /// قيمة من الطلب بالنوع المطلوب (أو null لو مش مبعوتة). لو جاية بنوع تاني يبقى الطلب نفسه غلط (400) مش عطل في السيرفر.
  T? _field<T>(Map<String, dynamic> body, String key) {
    final v = body[key];
    if (v == null || v is T) return v as T?;
    throw ApiError(400, 'البيانات المبعوتة مش مفهومة');
  }

  String _clientIp(Request req) =>
      (req.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address ?? 'unknown';

  String _requiredText(Map<String, dynamic> body, String key, String label) {
    final v = (_field<String>(body, key) ?? '').trim();
    if (v.isEmpty) throw ApiError(400, 'لازم تكتب $label');
    if (v.length > 200) throw ApiError(400, '$label طويل جداً');
    return v;
  }

  String? _optionalText(Map<String, dynamic> body, String key) {
    final v = (_field<String>(body, key) ?? '').trim();
    return v.isEmpty ? null : v;
  }

  String _validUsername(Object? raw) {
    final v = (raw as String? ?? '').trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_.]{3,30}$').hasMatch(v)) {
      throw ApiError(400, 'اسم المستخدم لازم يكون بالإنجليزي من 3 لـ 30 حرف (حروف وأرقام و _ و . بس)');
    }
    return v;
  }

  String _validPassword(Object? raw) {
    final v = raw as String? ?? '';
    if (v.length < 6) throw ApiError(400, 'كلمة السر لازم تكون 6 حروف أو أرقام على الأقل');
    if (v.length > 100) throw ApiError(400, 'كلمة السر طويلة جداً');
    return v;
  }

  String _validRole(Object? raw) {
    if (raw is! String || !roles.contains(raw)) throw ApiError(400, 'الصلاحية مش صحيحة');
    return raw;
  }
}

class _Failures {
  int count = 0;
  DateTime? lockedUntil;
}
