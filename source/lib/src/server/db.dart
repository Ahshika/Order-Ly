import 'package:sqlite3/sqlite3.dart';

/// قاعدة بيانات الكافيه. موجودة على كمبيوتر السيرفر بس.
///
/// كل تعديل على شكل الجداول بيتضاف كـ migration جديدة في آخر [_migrations]،
/// وماينفعش نعدّل migration قديمة لأنها ممكن تكون اتنفذت عند كافيهات بالفعل.
class AppDb {
  AppDb._(this.raw);

  final Database raw;

  static AppDb open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('PRAGMA synchronous = NORMAL;');
    final appDb = AppDb._(db);
    appDb._migrate();
    return appDb;
  }

  void _migrate() {
    for (var v = raw.userVersion; v < _migrations.length; v++) {
      transaction(() {
        raw.execute(_migrations[v]);
        raw.userVersion = v + 1;
      });
    }
  }

  T transaction<T>(T Function() body) {
    raw.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      raw.execute('COMMIT');
      return result;
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Map<String, Object?>> select(String sql, [List<Object?> params = const []]) =>
      raw.select(sql, params).map((r) => Map<String, Object?>.from(r)).toList();

  Map<String, Object?>? selectOne(String sql, [List<Object?> params = const []]) {
    final rows = select(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  void execute(String sql, [List<Object?> params = const []]) => raw.execute(sql, params);

  String? setting(String key) =>
      selectOne('SELECT value FROM settings WHERE key = ?', [key])?['value'] as String?;

  void setSetting(String key, String value) => execute(
        'INSERT INTO settings(key, value) VALUES(?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );

  /// فحص سريع إن ملف قاعدة البيانات سليم ('ok' لو تمام).
  String integrity() {
    try {
      final rows = raw.select('PRAGMA quick_check;');
      final msgs = rows.map((r) => '${r.values.first}').toList();
      return msgs.length == 1 && msgs.first == 'ok' ? 'ok' : msgs.take(5).join(' | ');
    } catch (e) {
      return '$e';
    }
  }

  /// صيانة بتتعمل كل ساعة: تحسين الفهارس، وتصغير ملف الـ WAL.
  void maintenance() {
    try {
      raw.execute('PRAGMA optimize;');
      raw.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } catch (_) {}
  }

  void close() => raw.close();
}

const _migrations = <String>[
  // v1: الكافيه، والفروع، والموظفين، والجلسات، والإعدادات، وسجل النشاط، والملفات
  '''
  CREATE TABLE shop (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    phone       TEXT,
    address     TEXT,
    created_at  TEXT NOT NULL
  );

  CREATE TABLE branches (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    phone       TEXT,
    address     TEXT,
    is_local    INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL
  );

  CREATE TABLE users (
    id             TEXT PRIMARY KEY,
    branch_id      TEXT REFERENCES branches(id),
    name           TEXT NOT NULL,
    username       TEXT NOT NULL UNIQUE,
    password_hash  TEXT NOT NULL,
    role           TEXT NOT NULL CHECK (role IN ('owner', 'cashier', 'waiter', 'kitchen')),
    active         INTEGER NOT NULL DEFAULT 1,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
  );

  CREATE TABLE sessions (
    token_hash    TEXT PRIMARY KEY,
    user_id       TEXT NOT NULL REFERENCES users(id),
    device_name   TEXT,
    created_at    TEXT NOT NULL,
    last_seen_at  TEXT NOT NULL
  );
  CREATE INDEX idx_sessions_user ON sessions(user_id);

  CREATE TABLE settings (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
  );

  CREATE TABLE audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     TEXT,
    action      TEXT NOT NULL,
    entity      TEXT,
    entity_id   TEXT,
    details     TEXT,
    created_at  TEXT NOT NULL
  );
  CREATE INDEX idx_audit_created ON audit_log(created_at);

  -- صور المنيو وصور التحويلات (الملف نفسه في dataDir/files)
  CREATE TABLE files (
    id          TEXT PRIMARY KEY,
    kind        TEXT NOT NULL,
    mime        TEXT NOT NULL,
    size        INTEGER NOT NULL,
    user_id     TEXT REFERENCES users(id),
    created_at  TEXT NOT NULL
  );
  ''',

  // v2: المنيو: أماكن التحضير (البار / المطبخ)، والأقسام، والأصناف، والإضافات
  // الفلوس كلها بالقروش (INTEGER) عشان نتجنب أخطاء الكسور.
  '''
  CREATE TABLE stations (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    sort        INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL
  );

  CREATE TABLE categories (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    name_en     TEXT,
    station_id  TEXT REFERENCES stations(id),
    sort        INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1,
    -- مواعيد ظهور القسم في منيو العميل (مثلاً الفطار للصبح بس): "08:00-12:00" أو NULL
    hours       TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  );

  CREATE TABLE items (
    id              TEXT PRIMARY KEY,
    category_id     TEXT NOT NULL REFERENCES categories(id),
    name            TEXT NOT NULL,
    name_en         TEXT,
    description     TEXT,
    description_en  TEXT,
    price_cents     INTEGER NOT NULL DEFAULT 0,
    -- تكلفة يدوي لو الصنف من غير وصفة
    cost_cents      INTEGER NOT NULL DEFAULT 0,
    image_id        TEXT REFERENCES files(id),
    station_id      TEXT REFERENCES stations(id),
    tags            TEXT NOT NULL DEFAULT '[]',
    -- متاح دلوقتي (الكاشير بيقفله لو خلص)
    available       INTEGER NOT NULL DEFAULT 1,
    show_in_qr      INTEGER NOT NULL DEFAULT 1,
    active          INTEGER NOT NULL DEFAULT 1,
    sort            INTEGER NOT NULL DEFAULT 0,
    -- أصناف بنقترحها مع الصنف ده في منيو العميل (JSON ids)
    upsell          TEXT NOT NULL DEFAULT '[]',
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
  );
  CREATE INDEX idx_items_category ON items(category_id);

  CREATE TABLE modifier_groups (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    name_en     TEXT,
    min_select  INTEGER NOT NULL DEFAULT 0,
    max_select  INTEGER NOT NULL DEFAULT 1,
    sort        INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  );

  CREATE TABLE modifier_options (
    id           TEXT PRIMARY KEY,
    group_id     TEXT NOT NULL REFERENCES modifier_groups(id),
    name         TEXT NOT NULL,
    name_en      TEXT,
    price_cents  INTEGER NOT NULL DEFAULT 0,
    is_default   INTEGER NOT NULL DEFAULT 0,
    sort         INTEGER NOT NULL DEFAULT 0,
    active       INTEGER NOT NULL DEFAULT 1
  );
  CREATE INDEX idx_modifier_options_group ON modifier_options(group_id);

  CREATE TABLE item_modifier_groups (
    item_id   TEXT NOT NULL REFERENCES items(id),
    group_id  TEXT NOT NULL REFERENCES modifier_groups(id),
    sort      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (item_id, group_id)
  );
  ''',

  // v3: الصالة: الأماكن، والترابيزات (وكود الـ QR السري بتاع كل ترابيزة)
  '''
  CREATE TABLE areas (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    sort        INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL
  );

  CREATE TABLE tables (
    id          TEXT PRIMARY KEY,
    area_id     TEXT REFERENCES areas(id),
    name        TEXT NOT NULL,
    seats       INTEGER NOT NULL DEFAULT 4,
    qr_key      TEXT NOT NULL UNIQUE,
    -- NULL = حسب إعداد الكافيه، 1 = طلبات الـ QR بتتقبل لوحدها، 0 = لازم الكاشير يوافق
    auto_accept INTEGER,
    sort        INTEGER NOT NULL DEFAULT 0,
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  );
  ''',

  // v4: العملاء، والدرج، والحسابات، والطلبات، وطرق الدفع، والدفعات، ونداء الويتر، والطباعة
  '''
  CREATE TABLE customers (
    id             TEXT PRIMARY KEY,
    name           TEXT,
    phone          TEXT NOT NULL,
    phone_norm     TEXT NOT NULL UNIQUE,
    points         INTEGER NOT NULL DEFAULT 0,
    visits         INTEGER NOT NULL DEFAULT 0,
    spent_cents    INTEGER NOT NULL DEFAULT 0,
    last_visit_at  TEXT,
    notes          TEXT,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
  );

  CREATE TABLE register_sessions (
    id                   TEXT PRIMARY KEY,
    branch_id            TEXT REFERENCES branches(id),
    opened_by            TEXT REFERENCES users(id),
    opened_at            TEXT NOT NULL,
    opening_cash_cents   INTEGER NOT NULL DEFAULT 0,
    closed_by            TEXT REFERENCES users(id),
    closed_at            TEXT,
    expected_cash_cents  INTEGER,
    counted_cash_cents   INTEGER,
    kept_cash_cents      INTEGER,
    note                 TEXT
  );
  CREATE INDEX idx_register_open ON register_sessions(closed_at);

  -- الحساب: ترابيزة مفتوحة، أو تيك أواي، أو ديليفري
  CREATE TABLE checks (
    id               TEXT PRIMARY KEY,
    number           INTEGER NOT NULL UNIQUE,
    type             TEXT NOT NULL CHECK (type IN ('dine_in', 'takeaway', 'delivery')),
    table_id         TEXT REFERENCES tables(id),
    status           TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'void')),
    guests           INTEGER,
    customer_id      TEXT REFERENCES customers(id),
    customer_name    TEXT,
    customer_phone   TEXT,
    address          TEXT,
    waiter_id        TEXT REFERENCES users(id),
    discount_cents   INTEGER NOT NULL DEFAULT 0,
    discount_note    TEXT,
    -- نسبة الخدمة والضريبة وقت فتح الحساب (bp: 1200 = 12%)
    service_bp       INTEGER NOT NULL DEFAULT 0,
    tax_bp           INTEGER NOT NULL DEFAULT 0,
    delivery_cents   INTEGER NOT NULL DEFAULT 0,
    subtotal_cents   INTEGER NOT NULL DEFAULT 0,
    service_cents    INTEGER NOT NULL DEFAULT 0,
    tax_cents        INTEGER NOT NULL DEFAULT 0,
    total_cents      INTEGER NOT NULL DEFAULT 0,
    paid_cents       INTEGER NOT NULL DEFAULT 0,
    points_used      INTEGER NOT NULL DEFAULT 0,
    points_earned    INTEGER NOT NULL DEFAULT 0,
    note             TEXT,
    session_id       TEXT REFERENCES register_sessions(id),
    -- العميل طلب الحساب من الـ QR
    bill_requested   INTEGER NOT NULL DEFAULT 0,
    opened_by        TEXT REFERENCES users(id),
    opened_at        TEXT NOT NULL,
    closed_by        TEXT REFERENCES users(id),
    closed_at        TEXT,
    void_reason      TEXT,
    updated_at       TEXT NOT NULL
  );
  CREATE INDEX idx_checks_status ON checks(status);
  CREATE INDEX idx_checks_table ON checks(table_id, status);
  CREATE INDEX idx_checks_closed ON checks(closed_at);

  -- الطلب: أصناف اتطلبت مرة واحدة (من الكاشير أو الويتر أو العميل بالـ QR)
  CREATE TABLE orders (
    id             TEXT PRIMARY KEY,
    check_id       TEXT REFERENCES checks(id),
    number         INTEGER NOT NULL,
    day            TEXT NOT NULL,
    source         TEXT NOT NULL CHECK (source IN ('cashier', 'waiter', 'qr')),
    status         TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'ready', 'served', 'rejected', 'cancelled')),
    table_id       TEXT REFERENCES tables(id),
    guest_name     TEXT,
    note           TEXT,
    -- طريقة الدفع اللي العميل اختارها من الـ QR
    pay_method_id  TEXT,
    cloud_id       TEXT UNIQUE,
    client_id      TEXT,
    reject_reason  TEXT,
    user_id        TEXT REFERENCES users(id),
    created_at     TEXT NOT NULL,
    accepted_at    TEXT,
    accepted_by    TEXT REFERENCES users(id),
    ready_at       TEXT,
    served_at      TEXT
  );
  CREATE INDEX idx_orders_check ON orders(check_id);
  CREATE INDEX idx_orders_status ON orders(status);
  CREATE INDEX idx_orders_day ON orders(day, number);

  CREATE TABLE order_items (
    id                TEXT PRIMARY KEY,
    order_id          TEXT NOT NULL REFERENCES orders(id),
    check_id          TEXT REFERENCES checks(id),
    item_id           TEXT REFERENCES items(id),
    name              TEXT NOT NULL,
    qty               INTEGER NOT NULL,
    -- سعر الوحدة شامل الإضافات وبعد العرض
    unit_price_cents  INTEGER NOT NULL,
    cost_cents        INTEGER NOT NULL DEFAULT 0,
    -- الإضافات اللي اتختارت: JSON [{id, name, price}]
    modifiers         TEXT NOT NULL DEFAULT '[]',
    note              TEXT,
    station_id        TEXT REFERENCES stations(id),
    -- اسم صاحب الصنف (عشان تقسيم الحساب)
    guest             TEXT,
    status            TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'preparing', 'ready', 'served', 'void')),
    void_reason       TEXT,
    voided_by         TEXT REFERENCES users(id),
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL
  );
  CREATE INDEX idx_order_items_order ON order_items(order_id);
  CREATE INDEX idx_order_items_check ON order_items(check_id);
  CREATE INDEX idx_order_items_station ON order_items(station_id, status);

  CREATE TABLE pay_methods (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    kind          TEXT NOT NULL CHECK (kind IN ('cash', 'card', 'instapay', 'wallet', 'other')),
    -- رقم المحفظة أو عنوان InstaPay
    account       TEXT,
    link          TEXT,
    instructions  TEXT,
    -- العميل لازم يرفع صورة التحويل
    needs_proof   INTEGER NOT NULL DEFAULT 0,
    show_in_qr    INTEGER NOT NULL DEFAULT 1,
    active        INTEGER NOT NULL DEFAULT 1,
    sort          INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL
  );

  CREATE TABLE payments (
    id             TEXT PRIMARY KEY,
    check_id       TEXT NOT NULL REFERENCES checks(id),
    amount_cents   INTEGER NOT NULL,
    method_id      TEXT REFERENCES pay_methods(id),
    method_kind    TEXT NOT NULL,
    method_name    TEXT NOT NULL,
    -- confirmed: الفلوس وصلت. pending: العميل رفع صورة التحويل ومستني الكاشير يتأكد. rejected: الكاشير رفضها
    status         TEXT NOT NULL CHECK (status IN ('confirmed', 'pending', 'rejected')),
    source         TEXT NOT NULL DEFAULT 'cashier',
    proof_file     TEXT REFERENCES files(id),
    reference      TEXT,
    payer          TEXT,
    cloud_id       TEXT UNIQUE,
    session_id     TEXT REFERENCES register_sessions(id),
    user_id        TEXT REFERENCES users(id),
    created_at     TEXT NOT NULL,
    reviewed_by    TEXT REFERENCES users(id),
    reviewed_at    TEXT,
    reject_reason  TEXT
  );
  CREATE INDEX idx_payments_check ON payments(check_id);
  CREATE INDEX idx_payments_status ON payments(status);
  CREATE INDEX idx_payments_created ON payments(created_at);

  -- كل فلوس داخلة أو خارجة من الدرج (بيع، مصروف، إيداع، سحب...)
  CREATE TABLE cash_moves (
    id            TEXT PRIMARY KEY,
    session_id    TEXT NOT NULL REFERENCES register_sessions(id),
    type          TEXT NOT NULL,
    amount_cents  INTEGER NOT NULL,
    method        TEXT NOT NULL,
    category      TEXT,
    ref_type      TEXT,
    ref_id        TEXT,
    note          TEXT,
    user_id       TEXT REFERENCES users(id),
    created_at    TEXT NOT NULL
  );
  CREATE INDEX idx_cash_moves_session ON cash_moves(session_id);
  CREATE INDEX idx_cash_moves_ref ON cash_moves(ref_type, ref_id);

  -- نداء الويتر وطلب الحساب من الترابيزة
  CREATE TABLE service_calls (
    id             TEXT PRIMARY KEY,
    table_id       TEXT REFERENCES tables(id),
    check_id       TEXT REFERENCES checks(id),
    type           TEXT NOT NULL CHECK (type IN ('waiter', 'bill')),
    note           TEXT,
    pay_method_id  TEXT,
    status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
    cloud_id       TEXT UNIQUE,
    created_at     TEXT NOT NULL,
    done_by        TEXT REFERENCES users(id),
    done_at        TEXT
  );
  CREATE INDEX idx_service_calls_status ON service_calls(status);

  -- الطباعة: الطلبات بتتطبع على طابعة البار/المطبخ من الجهاز المتحدد كمحطة طباعة
  CREATE TABLE print_jobs (
    id          TEXT PRIMARY KEY,
    station_id  TEXT,
    kind        TEXT NOT NULL,
    ref_id      TEXT,
    payload     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'printing', 'done', 'failed')),
    claimed_by  TEXT,
    claimed_at  TEXT,
    error       TEXT,
    created_at  TEXT NOT NULL,
    printed_at  TEXT
  );
  CREATE INDEX idx_print_jobs_status ON print_jobs(status, station_id);
  ''',

  // v5: المخزون بالوصفات: الخامات، ووصفة كل صنف وإضافة، والموردين، والمشتريات، والعروض، والتقييمات
  '''
  CREATE TABLE ingredients (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    -- g / ml / pcs
    unit        TEXT NOT NULL,
    qty         REAL NOT NULL DEFAULT 0,
    -- تكلفة الوحدة الواحدة بالقروش (ممكن تبقى كسر: الجرام بـ 0.8 قرش)
    unit_cost   REAL NOT NULL DEFAULT 0,
    low_stock   REAL NOT NULL DEFAULT 0,
    -- لو خلصت، الأصناف اللي عليها تبقى "خلصان" لوحدها
    auto_hide   INTEGER NOT NULL DEFAULT 1,
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  );

  CREATE TABLE recipes (
    id             TEXT PRIMARY KEY,
    item_id        TEXT REFERENCES items(id),
    option_id      TEXT REFERENCES modifier_options(id),
    ingredient_id  TEXT NOT NULL REFERENCES ingredients(id),
    qty            REAL NOT NULL
  );
  CREATE INDEX idx_recipes_item ON recipes(item_id);
  CREATE INDEX idx_recipes_option ON recipes(option_id);
  CREATE INDEX idx_recipes_ingredient ON recipes(ingredient_id);

  CREATE TABLE stock_moves (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    ingredient_id  TEXT NOT NULL REFERENCES ingredients(id),
    qty_change     REAL NOT NULL,
    qty_after      REAL NOT NULL,
    reason         TEXT NOT NULL,
    ref_type       TEXT,
    ref_id         TEXT,
    cost_cents     INTEGER NOT NULL DEFAULT 0,
    note           TEXT,
    user_id        TEXT REFERENCES users(id),
    created_at     TEXT NOT NULL
  );
  CREATE INDEX idx_stock_moves_ingredient ON stock_moves(ingredient_id);
  CREATE INDEX idx_stock_moves_created ON stock_moves(created_at);

  CREATE TABLE suppliers (
    id             TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    phone          TEXT,
    notes          TEXT,
    active         INTEGER NOT NULL DEFAULT 1,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
  );

  CREATE TABLE purchases (
    id           TEXT PRIMARY KEY,
    number       INTEGER NOT NULL UNIQUE,
    supplier_id  TEXT REFERENCES suppliers(id),
    total_cents  INTEGER NOT NULL,
    paid_cents   INTEGER NOT NULL DEFAULT 0,
    note         TEXT,
    user_id      TEXT REFERENCES users(id),
    created_at   TEXT NOT NULL
  );
  CREATE INDEX idx_purchases_supplier ON purchases(supplier_id);

  CREATE TABLE purchase_items (
    id             TEXT PRIMARY KEY,
    purchase_id    TEXT NOT NULL REFERENCES purchases(id),
    ingredient_id  TEXT NOT NULL REFERENCES ingredients(id),
    qty            REAL NOT NULL,
    total_cents    INTEGER NOT NULL
  );
  CREATE INDEX idx_purchase_items_purchase ON purchase_items(purchase_id);

  CREATE TABLE supplier_payments (
    id            TEXT PRIMARY KEY,
    supplier_id   TEXT NOT NULL REFERENCES suppliers(id),
    amount_cents  INTEGER NOT NULL,
    note          TEXT,
    user_id       TEXT REFERENCES users(id),
    created_at    TEXT NOT NULL
  );

  -- العروض بالمواعيد (هابي أور): خصم نسبة على أقسام أو أصناف في أيام وساعات معينة
  CREATE TABLE promotions (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    percent_bp    INTEGER NOT NULL,
    days          TEXT NOT NULL DEFAULT '[0,1,2,3,4,5,6]',
    time_from     TEXT NOT NULL,
    time_to       TEXT NOT NULL,
    category_ids  TEXT NOT NULL DEFAULT '[]',
    item_ids      TEXT NOT NULL DEFAULT '[]',
    active        INTEGER NOT NULL DEFAULT 1,
    created_at    TEXT NOT NULL
  );

  -- تقييم العميل بعد ما يدفع (من الـ QR)
  CREATE TABLE feedback (
    id          TEXT PRIMARY KEY,
    check_id    TEXT REFERENCES checks(id),
    table_id    TEXT REFERENCES tables(id),
    rating      INTEGER NOT NULL,
    comment     TEXT,
    cloud_id    TEXT UNIQUE,
    created_at  TEXT NOT NULL
  );
  ''',

  // v6: رقم موبايل العميل اللي طلب من الـ QR
  '''
  ALTER TABLE orders ADD COLUMN guest_phone TEXT;
  ''',
];
