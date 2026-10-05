import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../core/app_config.dart';
import '../../core/cafe_models.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../widgets/common.dart';
import 'print_pdf.dart';

/// بيطبع على طابعة محددة من غير ما يسأل، أو بيفتح شاشة الطباعة لو مفيش طابعة.
Future<bool> printBytes(Uint8List bytes, {String? printerUrl, String? printerName, required String name, PdfPageFormat? format}) async {
  if (printerUrl != null) {
    return Printing.directPrintPdf(
      printer: Printer(url: printerUrl, name: printerName),
      onLayout: (_) async => bytes,
      name: name,
      format: format ?? PdfPageFormat.roll80,
    );
  }
  return Printing.layoutPdf(onLayout: (_) async => bytes, name: name, format: format ?? PdfPageFormat.roll80);
}

/// طباعة الحساب أو الفاتورة من الجهاز ده (على طابعة الحسابات بتاعته لو متحددة).
Future<void> printCheckHere(BuildContext context, WidgetRef ref, String checkId) async {
  try {
    final api = ref.read(sessionProvider).value!.api!;
    final detail = CheckDetail(await api.get('/api/checks/$checkId'));
    final shop = await ref.read(shopProvider.future);
    final bytes = await buildCheckPdf(detail, shop);
    final printer = ref.read(appConfigProvider).printStations['receipt'];
    final ok = await printBytes(bytes,
        printerUrl: printer?.url, printerName: printer?.name, name: 'حساب-${detail.check.number}', format: paperFormat(shop.receiptPaper));
    if (!ok && printer != null && context.mounted) showMessage(context, 'الطباعة ما تمتش، اتأكد إن الطابعة شغالة', error: true);
  } catch (e) {
    if (context.mounted) showMessage(context, 'مشكلة في الطباعة: ${errorText(e)}', error: true);
  }
}

/// اختيار طابعة لمحطة على الجهاز ده.
Future<void> pickStationPrinter(BuildContext context, WidgetRef ref, String stationId, String label) async {
  final printer = await Printing.pickPrinter(context: context, title: 'اختار طابعة $label');
  if (printer == null) return;
  await ref.read(appConfigProvider).setPrintStation(stationId, printer.url, printer.name);
  ref.invalidate(printAgentProvider);
  if (context.mounted) showMessage(context, '$label هيتطبع على ${printer.name}');
}

class PrintAgentState {
  const PrintAgentState({this.active = false, this.printed = 0, this.failed = 0, this.lastError});
  final bool active;
  final int printed;
  final int failed;
  final String? lastError;
}

/// "محطة الطباعة": لو الجهاز ده عليه طابعة البار أو المطبخ أو الحسابات، بيسحب الشغل من السيرفر ويطبعه لوحده.
final printAgentProvider = NotifierProvider<PrintAgent, PrintAgentState>(PrintAgent.new);

class PrintAgent extends Notifier<PrintAgentState> {
  Timer? _timer;
  bool _busy = false;

  @override
  PrintAgentState build() {
    final session = ref.watch(sessionProvider).value;
    final stations = ref.read(appConfigProvider).printStations;
    ref.onDispose(() => _timer?.cancel());
    if (session?.status != SessionStatus.ready || stations.isEmpty) return const PrintAgentState();
    ref.listen(realtimeProvider, (_, next) {
      if (next.value?.topic == 'print') _tick();
    });
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _tick());
    Future.microtask(_tick);
    return const PrintAgentState(active: true);
  }

  Future<void> _tick() async {
    if (_busy) return;
    final session = ref.read(sessionProvider).value;
    final api = session?.api;
    if (api == null) return;
    final config = ref.read(appConfigProvider);
    final stations = config.printStations;
    if (stations.isEmpty) return;
    _busy = true;
    try {
      final res = await api.get('/api/print/claim', query: {'stations': stations.keys.join(','), 'device': config.deviceId});
      final shop = await ref.read(shopProvider.future);
      for (final job in (res['jobs'] as List).cast<Map<String, dynamic>>()) {
        final stationKey = (job['stationId'] as String?) ?? 'receipt';
        final printer = stations[stationKey];
        String? error;
        try {
          final payload = job['payload'] as Map<String, dynamic>;
          final Uint8List bytes;
          var paper = shop.receiptPaper;
          if (paper != '58mm') paper = '80mm';
          switch (job['kind']) {
            case 'ticket':
              bytes = await buildKitchenTicket(payload, paper: paper);
            case 'void':
              bytes = await buildKitchenTicket(payload, paper: paper, isVoid: true);
            default:
              final detail = CheckDetail(await api.get('/api/checks/${payload['checkId']}'));
              bytes = await buildCheckPdf(detail, shop);
              paper = shop.receiptPaper;
          }
          final ok = printer == null
              ? false
              : await Printing.directPrintPdf(
                  printer: Printer(url: printer.url, name: printer.name),
                  onLayout: (_) async => bytes,
                  name: 'Order Ly ${job['kind']}',
                  format: paperFormat(paper),
                );
          if (!ok) error = 'الطابعة ${printer?.name ?? ''} مش بترد';
        } catch (e) {
          error = '$e';
        }
        await api.post('/api/print/${job['id']}/result', {'ok': error == null, 'error': ?error});
        state = PrintAgentState(
          active: true,
          printed: state.printed + (error == null ? 1 : 0),
          failed: state.failed + (error == null ? 0 : 1),
          lastError: error ?? state.lastError,
        );
      }
    } catch (_) {
      // السيرفر مش متاح دلوقتي، هنحاول الدورة الجاية
    } finally {
      _busy = false;
    }
  }
}
