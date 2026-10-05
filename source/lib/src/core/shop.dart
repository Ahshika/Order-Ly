import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'providers.dart';
import 'realtime.dart';

/// بيانات الكافيه وإعداداته.
class ShopProfile {
  ShopProfile(Map<String, dynamic> j)
      : name = j['name'] as String? ?? '',
        phone = j['phone'] as String?,
        address = j['address'] as String?,
        branchName = j['branchName'] as String?,
        logo = j['logoBase64'] == null ? null : base64.decode(j['logoBase64'] as String),
        settings = Map<String, dynamic>.from(j['settings'] as Map? ?? const {}),
        menuBaseUrl = j['menuBaseUrl'] as String?,
        cafeId = (j['cloud'] as Map?)?['cafeId'] as String?,
        cloudLastSync = parseDate((j['cloud'] as Map?)?['lastSync']),
        cloudError = ((j['cloud'] as Map?)?['lastError'] as String?)?.isEmpty ?? true ? null : (j['cloud'] as Map)['lastError'] as String,
        cloudLive = (j['cloud'] as Map?)?['live'] as bool? ?? false;

  final String name;
  final String? phone;
  final String? address;
  final String? branchName;
  final Uint8List? logo;
  final Map<String, dynamic> settings;
  final String? menuBaseUrl;
  final String? cafeId;
  final DateTime? cloudLastSync;
  final String? cloudError;
  final bool cloudLive;

  int intSetting(String key, [int def = 0]) => settings[key] as int? ?? def;
  bool boolSetting(String key, [bool def = false]) => settings[key] as bool? ?? def;
  String strSetting(String key, [String def = '']) => settings[key] as String? ?? def;

  String get receiptPaper => strSetting('receiptPaper', '80mm');
  String get receiptFooter => strSetting('receiptFooter');
  bool get cashierCanDiscount => boolSetting('cashierCanDiscount', true);
  bool get loyaltyEnabled => boolSetting('loyaltyEnabled');
}

final shopProvider = FutureProvider.autoDispose<ShopProfile>((ref) async {
  refreshOnAny(ref, const {'shop', 'cloud'});
  ref.keepAlive();
  return ShopProfile(await apiOf(ref).get('/api/shop'));
});
