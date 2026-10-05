import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'cafe_models.dart';
import 'realtime.dart';
import 'session.dart';

ApiClient apiOf(Ref ref) => ref.watch(sessionProvider).value!.api!;

/// المنيو المتاح (للطلب). [menuAllProvider] فيه كمان الحاجات المتوقفة (لإدارة المنيو).
final menuProvider = FutureProvider.autoDispose<MenuData>((ref) async {
  refreshOnAny(ref, const {'menu', 'stock'});
  ref.keepAlive();
  return MenuData(await apiOf(ref).get('/api/menu'));
});

final menuAllProvider = FutureProvider.autoDispose<MenuData>((ref) async {
  refreshOnAny(ref, const {'menu', 'stock'});
  return MenuData(await apiOf(ref).get('/api/menu', query: {'all': '1'}));
});

final floorProvider = FutureProvider.autoDispose<FloorData>((ref) async {
  refreshOnAny(ref, const {'tables', 'checks', 'orders', 'calls', 'payments'});
  return FloorData(await apiOf(ref).get('/api/floor'));
});

final checkProvider = FutureProvider.autoDispose.family<CheckDetail, String>((ref, id) async {
  refreshOnAny(ref, const {'checks', 'orders', 'payments', 'calls'});
  return CheckDetail(await apiOf(ref).get('/api/checks/$id'));
});

typedef CheckQuery = ({String status, String q, String? from, String? to});

final checksProvider = FutureProvider.autoDispose.family<List<CheckSummary>, CheckQuery>((ref, q) async {
  refreshOn(ref, 'checks');
  final res = await apiOf(ref).get('/api/checks', query: {
    'status': q.status,
    if (q.q.isNotEmpty) 'q': q.q,
    'from': ?q.from,
    'to': ?q.to,
  });
  return (res['checks'] as List).cast<Json>().map(CheckSummary.new).toList();
});

/// الطلبات: 'pending' (طلبات الـ QR المستنية) أو 'active' (كل اللي لسه ما اتقدمش).
final ordersProvider = FutureProvider.autoDispose.family<List<OrderInfo>, String>((ref, status) async {
  refreshOnAny(ref, const {'orders', 'payments'});
  final res = await apiOf(ref).get('/api/orders', query: {'status': status});
  return (res['orders'] as List).cast<Json>().map(OrderInfo.new).toList();
});

final pendingPaymentsProvider = FutureProvider.autoDispose<List<PaymentInfo>>((ref) async {
  refreshOn(ref, 'payments');
  final res = await apiOf(ref).get('/api/payments/pending');
  return (res['payments'] as List).cast<Json>().map(PaymentInfo.new).toList();
});

final callsProvider = FutureProvider.autoDispose<List<ServiceCall>>((ref) async {
  refreshOn(ref, 'calls');
  final res = await apiOf(ref).get('/api/calls');
  return (res['calls'] as List).cast<Json>().map(ServiceCall.new).toList();
});

final liveProvider = FutureProvider.autoDispose<LiveCounts>((ref) async {
  refreshOnAny(ref, const {'orders', 'calls', 'payments', 'register', 'checks'});
  return LiveCounts(await apiOf(ref).get('/api/live'));
});

final kdsProvider = FutureProvider.autoDispose.family<List<OrderInfo>, String>((ref, station) async {
  refreshOnAny(ref, const {'kds', 'orders'});
  final res = await apiOf(ref).get('/api/kds', query: {if (station.isNotEmpty) 'station': station});
  return (res['orders'] as List).cast<Json>().map(OrderInfo.new).toList();
});

final payMethodsProvider = FutureProvider.autoDispose<List<PayMethod>>((ref) async {
  refreshOn(ref, 'shop');
  final res = await apiOf(ref).get('/api/pay-methods', query: {'all': '1'});
  return (res['methods'] as List).cast<Json>().map(PayMethod.new).toList();
});

final registerProvider = FutureProvider.autoDispose<Json>((ref) async {
  refreshOnAny(ref, const {'register', 'payments'});
  return apiOf(ref).get('/api/register');
});

final licenseProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  refreshOn(ref, 'license');
  ref.keepAlive();
  return apiOf(ref).get('/api/license');
});
