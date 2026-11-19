part of 'api_server.dart';

/// النسخة كل قد إيه (بالساعات): المالك بيختار من دول. الافتراضي كل يوم.
const backupEveryChoices = [1, 3, 6, 12, 24, 168];

/// بيحتفظ بكام نسخة. الافتراضي 14.
const backupKeepChoices = [7, 14, 30, 60];

/// نسخ احتياطي أوتوماتيك كل يوم: قاعدة البيانات + الصور + اللوجو في ملف zip واحد.
/// بيتحفظ في فولدر البرنامج، ونسخة كمان في فولدر تاني لو المحل اختاره
/// (فلاشة، أو هارد تاني، أو فولدر Google Drive على الكمبيوتر عشان يبقى على النت ببلاش).
extension _BackupRoutes on OrderlyServer {
  void _registerBackupRoutes(Router r) {
    r.get('/api/backups', _authed(_listBackups, only: {'owner'}));
    r.post('/api/backups', _authed((req, u) async {
      final name = await _createBackup(manual: true);
      _audit(u.id, 'backup.create', 'backup', null, name);
      return _listBackups(req, u);
    }, only: {'owner'}));
    r.patch('/api/backups/settings', _authed(_backupSettings, only: {'owner'}));
    r.post('/api/backups/restore', _authed(_stageRestore, only: {'owner'}));
  }

  Directory get _backupDir => Directory(p.join(dataDir, 'backups'))..createSync(recursive: true);

  int get _backupEveryHours {
    final v = int.tryParse(db.setting('backup_every_hours') ?? '');
    return backupEveryChoices.contains(v) ? v! : 24;
  }

  int get _backupKeep {
    final v = int.tryParse(db.setting('backup_keep') ?? '');
    return backupKeepChoices.contains(v) ? v! : 14;
  }

  bool get _backupOnShiftClose => db.setting('backup_on_shift_close') == '1';

  Object? _listBackups(Request req, AuthUser u) {
    final files = _backupDir.listSync().whereType<File>().where((f) => f.path.endsWith('.zip')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    final sizes = files.map((f) => f.lengthSync()).toList();
    return {
      'backups': [
        for (var i = 0; i < files.length; i++)
          {'name': p.basename(files[i].path), 'size': sizes[i], 'createdAt': files[i].lastModifiedSync().toUtc().toIso8601String()},
      ],
      'backupDir': db.setting('backup_dir'),
      'lastBackupAt': db.setting('last_backup_at'),
      'lastBackupError': db.setting('last_backup_error'),
      'localPath': _backupDir.path,
      'restorePending': File(p.join(dataDir, 'restore.pending')).existsSync(),
      'everyHours': _backupEveryHours,
      'keep': _backupKeep,
      'onShiftClose': _backupOnShiftClose,
      'everyChoices': backupEveryChoices,
      'keepChoices': backupKeepChoices,
      // المساحة المتوقعة = حجم آخر نسخة × عدد النسخ اللي بنحتفظ بيها
      'totalBytes': sizes.fold<int>(0, (s, x) => s + x),
      'estimatedBytes': sizes.isEmpty ? null : sizes.first * _backupKeep,
      'recovery': _recoveryInfo(),
    };
  }

  Future<Object?> _backupSettings(Request req, AuthUser u) async {
    final body = await _body(req);
    final changes = <String>[];
    if (body.containsKey('everyHours')) {
      final v = body['everyHours'];
      if (v is! int || !backupEveryChoices.contains(v)) throw ApiError(400, 'اختار مواعيد النسخ من الاختيارات');
      db.setSetting('backup_every_hours', '$v');
      changes.add('كل $v ساعة');
    }
    if (body.containsKey('keep')) {
      final v = body['keep'];
      if (v is! int || !backupKeepChoices.contains(v)) throw ApiError(400, 'اختار عدد النسخ من الاختيارات');
      db.setSetting('backup_keep', '$v');
      changes.add('يحتفظ بـ $v');
    }
    if (body.containsKey('onShiftClose')) {
      if (body['onShiftClose'] is! bool) throw ApiError(400, 'البيانات المبعوتة مش مفهومة');
      db.setSetting('backup_on_shift_close', body['onShiftClose'] == true ? '1' : '0');
      changes.add(body['onShiftClose'] == true ? 'نسخة مع قفل الوردية' : 'من غير نسخة مع قفل الوردية');
    }
    // الفولدر التاني بيتغير بس لو اتبعت (قبل كده أي تعديل كان بيمسحه)
    if (body.containsKey('backupDir')) {
      final dir = _optionalText(body, 'backupDir');
      if (dir != null && !Directory(dir).existsSync()) throw ApiError(400, 'الفولدر ده مش موجود على كمبيوتر السيرفر');
      db.setSetting('backup_dir', dir ?? '');
      changes.add(dir == null ? 'من غير فولدر تاني' : 'فولدر تاني: $dir');
      if (dir != null) await _createBackup(manual: true);
    }
    if (body['dismissRecovery'] == true) {
      db.setSetting('db_recovered', '');
      changes.add('المالك شاف رسالة الرجوع لنسخة احتياطية');
    }
    if (changes.isNotEmpty) _audit(u.id, 'backup.settings', 'backup', null, changes.join('، '));
    return _listBackups(req, u);
  }

  /// بيعمل نسخة لو آخر نسخة عدّى عليها المدة اللي المالك اختارها (بيتنادى كل 10 دقايق).
  Future<void> _runBackupIfDue() async {
    try {
      final last = DateTime.tryParse(db.setting('last_backup_at') ?? '');
      // 5 دقايق سماح عشان الكشف كل 10 دقايق ما يأخّرش النسخة دورة كاملة
      final due = Duration(hours: _backupEveryHours) - const Duration(minutes: 5);
      if (last != null && DateTime.now().toUtc().difference(last) < due) return;
      if (db.selectOne('SELECT id FROM shop LIMIT 1') == null) return;
      await _createBackup();
    } catch (e) {
      db.setSetting('last_backup_error', 'النسخة الأوتوماتيك ما اتعملتش: $e');
      _log.write('ERROR', 'النسخ الاحتياطي: $e');
    }
  }

  /// نسخة بعد قفل الوردية (لو المالك مفعّلها). بتشتغل في الخلفية ومابتأخرش رد الكاشير.
  void _backupAfterShiftClose() {
    if (!_backupOnShiftClose) return;
    unawaited(_createBackup(manual: true).then((_) {}, onError: (Object e) {
      db.setSetting('last_backup_error', 'نسخة قفل الوردية ما اتعملتش: $e');
      _log.write('ERROR', 'نسخة قفل الوردية: $e');
    }));
  }

  Future<String> _createBackup({bool manual = false}) async {
    // نسختين في نفس اللحظة (مثلاً قفل وردية + الأوتوماتيك) بيكتبوا على نفس ملف الـ snapshot
    while (_backupRunning != null) {
      await _backupRunning;
    }
    final done = Completer<void>();
    _backupRunning = done.future;
    try {
      return await _writeBackup();
    } finally {
      _backupRunning = null;
      done.complete();
    }
  }

  Future<String> _writeBackup() async {
    final stamp = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'orderly-${stamp.year}-${two(stamp.month)}-${two(stamp.day)}-${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}.zip';

    // نسخة متسقة من قاعدة البيانات حتى لو فيه شغل شغال
    final snapshot = File(p.join(_backupDir.path, '.snapshot.db'));
    if (snapshot.existsSync()) snapshot.deleteSync();
    db.raw.execute('VACUUM INTO ?', [snapshot.path]);

    final info = jsonEncode({'app': 'orderly', 'version': appVersion, 'createdAt': stamp.toUtc().toIso8601String(), 'serverId': db.setting('server_id')});
    final outPath = p.join(_backupDir.path, name);
    final snapshotPath = snapshot.path, data = dataDir;
    // الضغط بيحصل في Isolate لوحده: السيرفر يفضل يرد على الأجهزة، ومن غير ما الصور كلها تتحمّل في الذاكرة
    await backupInBackground(outPath, snapshotPath, 'orderly.db', data, info);
    final out = File(outPath);
    snapshot.deleteSync();

    // نسخة في الفولدر التاني (لو المحل اختاره)
    final external = db.setting('backup_dir');
    String? externalError;
    if (external != null && external.isNotEmpty) {
      try {
        final dir = Directory(p.join(external, 'Order Ly Backups'))..createSync(recursive: true);
        out.copySync(p.join(dir.path, name));
        final old = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.zip')).toList()..sort((a, b) => b.path.compareTo(a.path));
        for (final f in old.skip(_backupKeep)) {
          f.deleteSync();
        }
      } catch (e) {
        externalError = 'مش قادر أحفظ في الفولدر التاني: $e';
      }
    }

    final local = _backupDir.listSync().whereType<File>().where((f) => f.path.endsWith('.zip')).toList()..sort((a, b) => b.path.compareTo(a.path));
    for (final f in local.skip(_backupKeep)) {
      f.deleteSync();
    }
    db.setSetting('last_backup_at', nowIso());
    db.setSetting('last_backup_error', externalError ?? '');
    return name;
  }

  // ---------------------------------------------------------------- الرجوع لوحده لو قاعدة البيانات باظت

  /// بيفتح قاعدة البيانات. لو الملف بايظ لدرجة إن الشغل مش هينفع (قطع كهربا وقت الكتابة، هارد بايظ):
  /// بيحتفظ بالملف البايظ في فولدر لوحده، ويرجّع آخر نسخة احتياطية سليمة، ويسجل اللي حصل عشان المالك يشوفه.
  /// لو الملف فيه مشكلة صغيرة بس لسه بيتقري، بيكمّل عليه ويحذّر المالك (أحسن من إننا نرجع لنسخة قديمة ونضيّع شغل).
  AppDb _openOrRecover() {
    final path = p.join(dataDir, 'orderly.db');
    Object? problem;
    try {
      final d = AppDb.open(path);
      if (d.usable()) return d;
      d.close();
      problem = 'الجداول الأساسية مش بتتقري';
    } on SqliteException catch (e) {
      problem = e;
    }
    _log.write('ERROR', 'قاعدة البيانات بايظة: $problem — بنحاول نرجع آخر نسخة سليمة');

    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final corruptDir = Directory(p.join(dataDir, 'corrupt-$stamp'))..createSync(recursive: true);
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (f.existsSync()) f.renameSync(p.join(corruptDir.path, 'orderly.db$suffix'));
    }

    final external = _backupDirFromCorrupt(corruptDir.path);
    final candidates = <File>[
      ..._zipsNewestFirst(_backupDir),
      if (external != null && external.isNotEmpty) ..._zipsNewestFirst(Directory(p.join(external, 'Order Ly Backups'))),
    ];
    for (final zip in candidates) {
      final scratch = p.join(dataDir, '.recover-check.db');
      if (backupProblemSync(zip.path, scratch, keepAs: path) != null) continue;
      final d = AppDb.open(path);
      final info = {
        'at': nowIso(),
        'backup': p.basename(zip.path),
        'backupAt': zip.lastModifiedSync().toUtc().toIso8601String(),
        'corruptFolder': corruptDir.path,
        'error': '$problem'.split('\n').first,
      };
      d.setSetting('db_recovered', jsonEncode(info));
      _log.write('ERROR', 'قاعدة البيانات اترجعت من النسخة ${info['backup']}. الملف البايظ اتحفظ في ${corruptDir.path}');
      return d;
    }
    throw ApiError(500,
        'قاعدة البيانات بايظة ومفيش نسخة احتياطية سليمة نرجع لها. الملف البايظ اتحفظ في ${corruptDir.path}. كلم الدعم الفني ومتمسحش الفولدر ده');
  }

  List<File> _zipsNewestFirst(Directory dir) => !dir.existsSync()
      ? const []
      : (dir.listSync().whereType<File>().where((f) => f.path.endsWith('.zip')).toList()..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync())));

  /// فولدر النسخ التاني من قاعدة البيانات البايظة نفسها (لو لسه بيتقري)، عشان ندوّر فيه كمان.
  String? _backupDirFromCorrupt(String corruptFolder) {
    try {
      final raw = sqlite3.open(p.join(corruptFolder, 'orderly.db'), mode: OpenMode.readOnly);
      try {
        return raw.select("SELECT value FROM settings WHERE key = 'backup_dir'").firstOrNull?['value'] as String?;
      } finally {
        raw.close();
      }
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?>? _recoveryInfo() {
    final raw = db.setting('db_recovered');
    if (raw == null || raw.isEmpty) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  /// الاسترجاع بيحصل وقت ما البرنامج يتفتح تاني (عشان قاعدة البيانات مش مفتوحة).
  Future<Object?> _stageRestore(Request req, AuthUser u) async {
    final body = await _body(req);
    final name = p.basename(_field<String>(body, 'name') ?? '');
    final file = File(p.join(_backupDir.path, name));
    if (!name.endsWith('.zip') || !file.existsSync()) throw ApiError(404, 'النسخة دي مش موجودة');
    // بنفتح قاعدة البيانات اللي جوه النسخة ونفحصها قبل ما نجهّز الاسترجاع،
    // عشان نسخة بايظة ماتخليش السيرفر مايقومش تاني بعد إعادة التشغيل
    final problem = await backupProblem(file.path, p.join(_backupDir.path, '.restore-check.db'));
    if (problem != null) throw ApiError(400, problem);
    File(p.join(dataDir, 'restore.pending')).writeAsStringSync(file.path);
    _audit(u.id, 'backup.restore', 'backup', null, name);
    return {'ok': true, 'message': 'اقفل البرنامج على كمبيوتر السيرفر وافتحه تاني عشان الاسترجاع يتم'};
  }
}

/// بيتنفذ قبل فتح قاعدة البيانات: لو فيه استرجاع مستني، بيحط النسخة مكان البيانات الحالية
/// (وبيحتفظ بنسخة من البيانات الحالية للاحتياط).
void applyPendingRestore(String dataDir) {
  final pending = File(p.join(dataDir, 'restore.pending'));
  if (!pending.existsSync()) return;
  final zip = File(pending.readAsStringSync().trim());
  pending.deleteSync();
  if (!zip.existsSync()) return;
  final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
  final dbFile = File(p.join(dataDir, 'orderly.db'));
  if (dbFile.existsSync()) {
    final safety = Directory(p.join(dataDir, 'backups'))..createSync(recursive: true);
    dbFile.copySync(p.join(safety.path, 'before-restore-${DateTime.now().millisecondsSinceEpoch}.db'));
  }
  for (final suffix in ['-wal', '-shm']) {
    final f = File('${dbFile.path}$suffix');
    if (f.existsSync()) f.deleteSync();
  }
  for (final entry in archive.files) {
    if (!entry.isFile || entry.name == 'backup.json') continue;
    final target = p.normalize(p.join(dataDir, entry.name));
    if (!p.isWithin(dataDir, target)) continue; // حماية من ملفات zip فيها مسارات برا الفولدر
    File(target)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(entry.content as List<int>);
  }
}

Future<void> backupInBackground(String outPath, String snapshotPath, String dbName, String dataDir, String infoJson) =>
    Isolate.run(() => writeBackupZip(outPath, snapshotPath, dbName, dataDir, infoJson));

/// null لو النسخة سليمة، أو سبب رفضها (بالعربي للمالك). بيشتغل في Isolate لوحده.
Future<String?> backupProblem(String zipPath, String scratchPath) => Isolate.run(() => backupProblemSync(zipPath, scratchPath));

/// نفس [backupProblem] من غير Isolate. لو [keepAs] اتبعت والنسخة سليمة، قاعدة البيانات بتتنقل للمكان ده.
String? backupProblemSync(String zipPath, String scratchPath, {String? keepAs}) {
  final scratch = File(scratchPath);
  InputFileStream? input;
  try {
    input = InputFileStream(zipPath);
    final entry = ZipDecoder().decodeStream(input).findFile('orderly.db');
    if (entry == null) return 'الملف ده مش نسخة احتياطية من Order Ly';
    scratch.writeAsBytesSync(entry.content as List<int>);
    final check = sqlite3.open(scratch.path, mode: OpenMode.readOnly);
    try {
      final health = check.select('PRAGMA quick_check;').map((r) => '${r.values.first}').toList();
      if (health.length != 1 || health.first != 'ok') return 'النسخة دي بايظة (قاعدة البيانات اللي جواها فيها مشكلة)';
      if (check.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'shop'").isEmpty) {
        return 'الملف ده مش نسخة احتياطية من Order Ly';
      }
    } finally {
      check.close();
    }
    if (keepAs != null) scratch.renameSync(keepAs);
    return null;
  } on SqliteException {
    return 'النسخة دي بايظة (قاعدة البيانات اللي جواها فيها مشكلة)';
  } on ArchiveException {
    return 'ملف النسخة بايظ';
  } on FileSystemException {
    return 'ملف النسخة مش بيتقري';
  } finally {
    input?.closeSync();
    if (scratch.existsSync()) scratch.deleteSync();
  }
}

/// بيكتب ملف النسخة الاحتياطية على الديسك مباشرة (بيتنادى في Isolate لوحده).
Future<void> writeBackupZip(String outPath, String snapshotPath, String dbName, String dataDir, String infoJson) async {
  final enc = ZipFileEncoder()..create(outPath);
  await enc.addFile(File(snapshotPath), dbName);
  final logo = File(p.join(dataDir, 'logo.png'));
  if (logo.existsSync()) await enc.addFile(logo, 'logo.png');
  final files = Directory(p.join(dataDir, 'files'));
  if (files.existsSync()) {
    for (final f in files.listSync().whereType<File>()) {
      await enc.addFile(f, 'files/${p.basename(f.path)}');
    }
  }
  final info = utf8.encode(infoJson);
  enc.addArchiveFile(ArchiveFile('backup.json', info.length, info));
  await enc.close();
}
