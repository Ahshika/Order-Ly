enum Role {
  owner('المالك'),
  cashier('كاشير'),
  waiter('ويتر'),
  kitchen('بار / مطبخ');

  const Role(this.label);
  final String label;

  static Role parse(String? v) => Role.values.firstWhere((r) => r.name == v, orElse: () => Role.waiter);
}

class AppUser {
  AppUser({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    required this.active,
    this.createdAt,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as String,
        name: j['name'] as String,
        username: j['username'] as String,
        role: Role.parse(j['role'] as String?),
        active: j['active'] as bool? ?? true,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal(),
      );

  final String id;
  final String name;
  final String username;
  final Role role;
  final bool active;
  final DateTime? createdAt;

  bool get isOwner => role == Role.owner;

  /// بيشتغل على الفلوس (الدفع، والدرج، والقفل).
  bool get handlesCash => role == Role.owner || role == Role.cashier;
}

class ServerInfo {
  ServerInfo({
    required this.serverId,
    required this.setupDone,
    required this.version,
    required this.api,
    this.shopName,
    this.branchName,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> j) {
    if (j['app'] != 'orderly') throw const FormatException('not an Order Ly server');
    return ServerInfo(
      serverId: j['serverId'] as String? ?? '',
      setupDone: j['setupDone'] as bool? ?? false,
      version: j['version'] as String? ?? '',
      api: j['api'] as int? ?? 0,
      shopName: j['shopName'] as String?,
      branchName: j['branchName'] as String?,
    );
  }

  final String serverId;
  final bool setupDone;
  final String version;
  final int api;
  final String? shopName;
  final String? branchName;
}
