import 'format.dart';

typedef Json = Map<String, dynamic>;

List<Json> _list(Object? v) => (v as List? ?? const []).cast<Json>();

// ---------------------------------------------------------------- المنيو

class Station {
  Station(Json j)
      : id = j['id'] as String,
        name = j['name'] as String,
        active = j['active'] as bool? ?? true;
  final String id;
  final String name;
  final bool active;
}

class Category {
  Category(Json j)
      : id = j['id'] as String,
        name = j['name'] as String,
        nameEn = j['nameEn'] as String?,
        stationId = j['stationId'] as String?,
        hours = j['hours'] as String?,
        active = j['active'] as bool? ?? true;
  final String id;
  final String name;
  final String? nameEn;
  final String? stationId;
  final String? hours;
  final bool active;
}

class ModOption {
  ModOption(Json j)
      : id = j['id'] as String,
        name = j['name'] as String,
        nameEn = j['nameEn'] as String?,
        priceCents = j['priceCents'] as int? ?? 0,
        isDefault = j['isDefault'] as bool? ?? false,
        active = j['active'] as bool? ?? true;
  final String id;
  final String name;
  final String? nameEn;
  final int priceCents;
  final bool isDefault;
  final bool active;
}

class ModGroup {
  ModGroup(Json j)
      : id = j['id'] as String,
        name = j['name'] as String,
        nameEn = j['nameEn'] as String?,
        minSelect = j['minSelect'] as int? ?? 0,
        maxSelect = j['maxSelect'] as int? ?? 1,
        active = j['active'] as bool? ?? true,
        options = _list(j['options']).map(ModOption.new).toList();
  final String id;
  final String name;
  final String? nameEn;
  final int minSelect;
  final int maxSelect;
  final bool active;
  final List<ModOption> options;

  String get rule => minSelect == 0
      ? (maxSelect == 1 ? 'اختياري' : 'اختياري • لحد $maxSelect')
      : minSelect == maxSelect
          ? (minSelect == 1 ? 'إجباري' : 'اختار $minSelect')
          : 'من $minSelect لـ $maxSelect';
}

class MenuItem {
  MenuItem(Json j)
      : id = j['id'] as String,
        categoryId = j['categoryId'] as String,
        name = j['name'] as String,
        nameEn = j['nameEn'] as String?,
        description = j['description'] as String?,
        descriptionEn = j['descriptionEn'] as String?,
        priceCents = j['priceCents'] as int,
        promoPriceCents = j['promoPriceCents'] as int?,
        costCents = j['costCents'] as int? ?? 0,
        recipeCostCents = j['recipeCostCents'] as int?,
        imageId = j['imageId'] as String?,
        stationId = j['stationId'] as String?,
        tags = (j['tags'] as List? ?? const []).cast<String>(),
        available = j['available'] as bool? ?? true,
        soldOut = j['soldOut'] as bool? ?? false,
        showInQr = j['showInQr'] as bool? ?? true,
        active = j['active'] as bool? ?? true,
        upsell = (j['upsell'] as List? ?? const []).cast<String>(),
        groupIds = (j['groupIds'] as List? ?? const []).cast<String>();
  final String id;
  final String categoryId;
  final String name;
  final String? nameEn;
  final String? description;
  final String? descriptionEn;
  final int priceCents;
  final int? promoPriceCents;
  final int costCents;
  final int? recipeCostCents;
  final String? imageId;
  final String? stationId;
  final List<String> tags;
  final bool available;
  final bool soldOut;
  final bool showInQr;
  final bool active;
  final List<String> upsell;
  final List<String> groupIds;

  int get effectivePrice => promoPriceCents ?? priceCents;
  bool get canOrder => available && !soldOut && active;
  int get unitCost => recipeCostCents ?? costCents;
}

const tagLabels = {
  'new': 'جديد',
  'best': 'الأكتر طلباً',
  'spicy': 'حراق',
  'vegan': 'نباتي',
  'hot': 'سخن',
  'cold': 'ساقع',
  'sugar_free': 'من غير سكر',
};

class MenuData {
  MenuData(Json j)
      : stations = _list(j['stations']).map(Station.new).toList(),
        categories = _list(j['categories']).map(Category.new).toList(),
        items = _list(j['items']).map(MenuItem.new).toList(),
        groups = _list(j['modifierGroups']).map(ModGroup.new).toList();
  final List<Station> stations;
  final List<Category> categories;
  final List<MenuItem> items;
  final List<ModGroup> groups;

  MenuItem? item(String id) => items.where((i) => i.id == id).firstOrNull;
  ModGroup? group(String id) => groups.where((g) => g.id == id).firstOrNull;
  Category? category(String id) => categories.where((c) => c.id == id).firstOrNull;
  Station? station(String? id) => id == null ? null : stations.where((s) => s.id == id).firstOrNull;
  List<MenuItem> itemsIn(String categoryId) => items.where((i) => i.categoryId == categoryId).toList();
}

// ---------------------------------------------------------------- الصالة والحسابات

class CheckSummary {
  CheckSummary(Json j)
      : id = j['id'] as String,
        number = j['number'] as int,
        type = j['type'] as String? ?? 'dine_in',
        status = j['status'] as String? ?? 'open',
        tableId = j['tableId'] as String?,
        tableName = j['tableName'] as String?,
        guests = j['guests'] as int?,
        customerName = j['customerName'] as String?,
        customerPhone = j['customerPhone'] as String?,
        address = j['address'] as String?,
        subtotalCents = j['subtotalCents'] as int? ?? 0,
        discountCents = j['discountCents'] as int? ?? 0,
        discountNote = j['discountNote'] as String?,
        pointsUsed = j['pointsUsed'] as int? ?? 0,
        serviceBp = j['serviceBp'] as int? ?? 0,
        serviceCents = j['serviceCents'] as int? ?? 0,
        taxBp = j['taxBp'] as int? ?? 0,
        taxCents = j['taxCents'] as int? ?? 0,
        deliveryCents = j['deliveryCents'] as int? ?? 0,
        totalCents = j['totalCents'] as int? ?? 0,
        paidCents = j['paidCents'] as int? ?? 0,
        note = j['note'] as String?,
        billRequested = j['billRequested'] as bool? ?? false,
        customerId = j['customerId'] as String?,
        openedAt = parseDate(j['openedAt']),
        closedAt = parseDate(j['closedAt']),
        closedByName = j['closedByName'] as String?,
        voidReason = j['voidReason'] as String?;
  final String id;
  final int number;
  final String type;
  final String status;
  final String? tableId;
  final String? tableName;
  final int? guests;
  final String? customerName;
  final String? customerPhone;
  final String? address;
  final int subtotalCents;
  final int discountCents;
  final String? discountNote;
  final int pointsUsed;
  final int serviceBp;
  final int serviceCents;
  final int taxBp;
  final int taxCents;
  final int deliveryCents;
  final int totalCents;
  final int paidCents;
  final String? note;
  final bool billRequested;
  final String? customerId;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final String? closedByName;
  final String? voidReason;

  int get dueCents => totalCents - paidCents;
  bool get isOpen => status == 'open';

  String get title => switch (type) {
        'dine_in' => 'ترابيزة ${tableName ?? ''}',
        'delivery' => 'ديليفري${customerName != null ? ' • $customerName' : ''}',
        _ => 'تيك أواي${customerName != null ? ' • $customerName' : ''}',
      };
}

const checkTypeLabels = {'dine_in': 'صالة', 'takeaway': 'تيك أواي', 'delivery': 'ديليفري'};

class OrderLine {
  OrderLine(Json j)
      : id = j['id'] as String,
        orderId = j['orderId'] as String,
        itemId = j['itemId'] as String?,
        name = j['name'] as String,
        qty = j['qty'] as int,
        unitPriceCents = j['unitPriceCents'] as int,
        modifiers = _list(j['modifiers']),
        note = j['note'] as String?,
        guest = j['guest'] as String?,
        stationId = j['stationId'] as String?,
        status = j['status'] as String,
        voidReason = j['voidReason'] as String?;
  final String id;
  final String orderId;
  final String? itemId;
  final String name;
  final int qty;
  final int unitPriceCents;
  final List<Json> modifiers;
  final String? note;
  final String? guest;
  final String? stationId;
  final String status;
  final String? voidReason;

  bool get isVoid => status == 'void';
  int get totalCents => qty * unitPriceCents;
  String get modsText => modifiers.map((m) => m['name']).join('، ');
}

const lineStatusLabels = {'new': 'جديد', 'preparing': 'بيتحضر', 'ready': 'جاهز', 'served': 'اتقدم', 'void': 'ملغي'};

class OrderInfo {
  OrderInfo(Json j)
      : id = j['id'] as String,
        checkId = j['checkId'] as String?,
        number = j['number'] as int,
        source = j['source'] as String,
        status = j['status'] as String,
        tableId = j['tableId'] as String?,
        tableName = j['tableName'] as String?,
        guestName = j['guestName'] as String?,
        guestPhone = j['guestPhone'] as String? ?? j['customerPhone'] as String?,
        note = j['note'] as String?,
        payMethodName = j['payMethodName'] as String?,
        payMethodKind = j['payMethodKind'] as String?,
        rejectReason = j['rejectReason'] as String?,
        checkType = j['checkType'] as String?,
        customerName = j['customerName'] as String?,
        createdAt = parseDate(j['createdAt']) ?? DateTime.now(),
        acceptedAt = parseDate(j['acceptedAt']),
        readyAt = parseDate(j['readyAt']),
        items = _list(j['items']).map(OrderLine.new).toList(),
        payments = _list(j['payments']).map(PaymentInfo.new).toList();
  final String id;
  final String? checkId;
  final int number;
  final String source;
  final String status;
  final String? tableId;
  final String? tableName;
  final String? guestName;
  final String? guestPhone;
  final String? note;
  final String? payMethodName;
  final String? payMethodKind;
  final String? rejectReason;
  final String? checkType;
  final String? customerName;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? readyAt;
  final List<OrderLine> items;
  final List<PaymentInfo> payments;

  int get totalCents => items.where((i) => !i.isVoid || status == 'pending').fold(0, (s, i) => s + i.totalCents);

  String get place => tableName != null
      ? 'ترابيزة $tableName'
      : checkType == 'delivery'
          ? 'ديليفري${customerName != null ? ' • $customerName' : ''}'
          : 'تيك أواي${(customerName ?? guestName) != null ? ' • ${customerName ?? guestName}' : ''}';
}

const orderStatusLabels = {
  'pending': 'مستني موافقة',
  'accepted': 'بيتحضر',
  'ready': 'جاهز',
  'served': 'اتقدم',
  'rejected': 'اترفض',
  'cancelled': 'اتلغى',
};

const orderSourceLabels = {'cashier': 'الكاشير', 'waiter': 'الويتر', 'qr': 'العميل (QR)'};

class PaymentInfo {
  PaymentInfo(Json j)
      : id = j['id'] as String,
        checkId = j['checkId'] as String?,
        checkNumber = j['checkNumber'] as int?,
        tableName = j['tableName'] as String?,
        amountCents = j['amountCents'] as int,
        methodKind = j['methodKind'] as String,
        methodName = j['methodName'] as String,
        status = j['status'] as String,
        source = j['source'] as String? ?? 'cashier',
        proofFileId = j['proofFileId'] as String?,
        reference = j['reference'] as String?,
        rejectReason = j['rejectReason'] as String?,
        createdAt = parseDate(j['createdAt']) ?? DateTime.now();
  final String id;
  final String? checkId;
  final int? checkNumber;
  final String? tableName;
  final int amountCents;
  final String methodKind;
  final String methodName;
  final String status;
  final String source;
  final String? proofFileId;
  final String? reference;
  final String? rejectReason;
  final DateTime createdAt;
}

class ServiceCall {
  ServiceCall(Json j)
      : id = j['id'] as String,
        type = j['type'] as String,
        tableId = j['tableId'] as String?,
        tableName = j['tableName'] as String?,
        checkId = j['checkId'] as String?,
        note = j['note'] as String?,
        payMethodName = j['payMethodName'] as String?,
        createdAt = parseDate(j['createdAt']) ?? DateTime.now();
  final String id;
  final String type;
  final String? tableId;
  final String? tableName;
  final String? checkId;
  final String? note;
  final String? payMethodName;
  final DateTime createdAt;

  String get label => type == 'bill' ? 'عايز الحساب${payMethodName != null ? ' ($payMethodName)' : ''}' : 'بينادي الويتر';
}

class Customer {
  Customer(Json j)
      : id = j['id'] as String,
        name = j['name'] as String?,
        phone = j['phone'] as String,
        points = j['points'] as int? ?? 0,
        visits = j['visits'] as int? ?? 0,
        spentCents = j['spentCents'] as int? ?? 0,
        pointsValueCents = j['pointsValueCents'] as int? ?? 0,
        lastVisitAt = parseDate(j['lastVisitAt']);
  final String id;
  final String? name;
  final String phone;
  final int points;
  final int visits;
  final int spentCents;
  final int pointsValueCents;
  final DateTime? lastVisitAt;
}

class CheckDetail {
  CheckDetail(Json j)
      : check = CheckSummary(j['check'] as Json),
        orders = _list(j['orders']).map(OrderInfo.new).toList(),
        payments = _list(j['payments']).map(PaymentInfo.new).toList(),
        calls = _list(j['calls']).map(ServiceCall.new).toList(),
        customer = j['customer'] == null ? null : Customer(j['customer'] as Json);
  final CheckSummary check;
  final List<OrderInfo> orders;
  final List<PaymentInfo> payments;
  final List<ServiceCall> calls;
  final Customer? customer;

  List<OrderLine> get lines => [
        for (final o in orders)
          if (o.status != 'pending' && o.status != 'rejected') ...o.items.where((i) => !i.isVoid),
      ];
  List<OrderInfo> get pendingOrders => orders.where((o) => o.status == 'pending').toList();
}

class TableInfo {
  TableInfo(Json j)
      : id = j['id'] as String,
        areaId = j['areaId'] as String?,
        name = j['name'] as String,
        seats = j['seats'] as int? ?? 4,
        autoAccept = j['autoAccept'] as bool?,
        check = j['check'] == null ? null : CheckSummary({...(j['check'] as Json), 'type': 'dine_in', 'tableName': j['name']}),
        pendingOrders = j['pendingOrders'] as int? ?? 0,
        readyOrders = j['readyOrders'] as int? ?? 0,
        calls = (j['calls'] as List? ?? const []).cast<String>(),
        pendingPayments = j['pendingPayments'] as int? ?? 0;
  final String id;
  final String? areaId;
  final String name;
  final int seats;
  final bool? autoAccept;
  final CheckSummary? check;
  final int pendingOrders;
  final int readyOrders;
  final List<String> calls;
  final int pendingPayments;

  bool get busy => check != null;
  bool get needsAttention => pendingOrders > 0 || calls.isNotEmpty || pendingPayments > 0;
}

class Area {
  Area(Json j)
      : id = j['id'] as String,
        name = j['name'] as String;
  final String id;
  final String name;
}

class FloorData {
  FloorData(Json j)
      : areas = _list(j['areas']).map(Area.new).toList(),
        tables = _list(j['tables']).map(TableInfo.new).toList(),
        others = _list(j['others']).map(CheckSummary.new).toList();
  final List<Area> areas;
  final List<TableInfo> tables;
  final List<CheckSummary> others;
}

class PayMethod {
  PayMethod(Json j)
      : id = j['id'] as String,
        name = j['name'] as String,
        kind = j['kind'] as String,
        account = j['account'] as String?,
        link = j['link'] as String?,
        instructions = j['instructions'] as String?,
        needsProof = j['needsProof'] as bool? ?? false,
        showInQr = j['showInQr'] as bool? ?? true,
        active = j['active'] as bool? ?? true;
  final String id;
  final String name;
  final String kind;
  final String? account;
  final String? link;
  final String? instructions;
  final bool needsProof;
  final bool showInQr;
  final bool active;
}

const payKindLabels = {'cash': 'كاش', 'card': 'فيزا / كارت', 'instapay': 'InstaPay', 'wallet': 'محفظة إلكترونية', 'other': 'تانية'};

class LiveCounts {
  LiveCounts(Json j)
      : pendingOrders = j['pendingOrders'] as int? ?? 0,
        readyOrders = j['readyOrders'] as int? ?? 0,
        openCalls = j['openCalls'] as int? ?? 0,
        pendingPayments = j['pendingPayments'] as int? ?? 0,
        registerOpen = j['registerOpen'] as bool? ?? false;
  final int pendingOrders;
  final int readyOrders;
  final int openCalls;
  final int pendingPayments;
  final bool registerOpen;

  int get attention => pendingOrders + openCalls + pendingPayments;
}

/// نسبة بالـ basis points كنص: 1200 → "12%"
String percent(int bp) {
  final v = bp / 100;
  return '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}%';
}
