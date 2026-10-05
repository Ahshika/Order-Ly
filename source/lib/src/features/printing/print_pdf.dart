import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/shop.dart';

pw.ThemeData? _theme;

Future<pw.ThemeData> _loadTheme() async {
  if (_theme != null) return _theme!;
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
  return _theme = pw.ThemeData.withFont(base: regular, bold: bold, fontFallback: [regular]);
}

PdfPageFormat paperFormat(String paper) => switch (paper) {
      '58mm' => const PdfPageFormat(58 * PdfPageFormat.mm, double.infinity, marginAll: 2 * PdfPageFormat.mm),
      'a5' => PdfPageFormat.a5.copyWith(marginLeft: 12 * PdfPageFormat.mm, marginRight: 12 * PdfPageFormat.mm, marginTop: 10 * PdfPageFormat.mm, marginBottom: 10 * PdfPageFormat.mm),
      'a4' => PdfPageFormat.a4.copyWith(marginLeft: 20 * PdfPageFormat.mm, marginRight: 20 * PdfPageFormat.mm, marginTop: 15 * PdfPageFormat.mm, marginBottom: 15 * PdfPageFormat.mm),
      _ => const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 3 * PdfPageFormat.mm),
    };

pw.Widget _divider() => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Divider(thickness: 0.6, borderStyle: pw.BorderStyle.dashed, color: PdfColors.grey700),
    );

String _time(DateTime d) => formatTime(d.toLocal());

/// تيكت البار / المطبخ: خط كبير وواضح، من غير أسعار.
Future<Uint8List> buildKitchenTicket(Map<String, dynamic> p, {String paper = '80mm', bool isVoid = false}) async {
  final theme = await _loadTheme();
  final small = paper == '58mm';
  final s = small ? 0.85 : 1.0;
  final doc = pw.Document(theme: theme);
  final items = (p['items'] as List).cast<Map<String, dynamic>>();
  final type = p['type'] as String?;
  final place = p['tableName'] != null
      ? 'ترابيزة ${p['tableName']}'
      : type == 'delivery'
          ? 'ديليفري'
          : 'تيك أواي';
  pw.TextStyle st(double size, {bool bold = false}) => pw.TextStyle(fontSize: size * s, fontWeight: bold ? pw.FontWeight.bold : null);

  doc.addPage(pw.Page(
    pageFormat: paperFormat(paper),
    textDirection: pw.TextDirection.rtl,
    build: (_) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        if (isVoid)
          pw.Container(
            color: PdfColors.black,
            padding: const pw.EdgeInsets.all(3),
            child: pw.Center(child: pw.Text('*** إلغاء ***', style: st(16, bold: true).copyWith(color: PdfColors.white))),
          ),
        if (p['stationName'] != null) pw.Center(child: pw.Text('${p['stationName']}', style: st(11))),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(place, style: st(18, bold: true)),
          pw.Text('#${p['orderNumber']}', style: st(18, bold: true), textDirection: pw.TextDirection.ltr),
        ]),
        if (p['customerName'] != null || p['customerPhone'] != null)
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('${p['customerName'] ?? ''}', style: st(12, bold: true)),
            if (p['customerPhone'] != null) pw.Text('${p['customerPhone']}', style: st(11), textDirection: pw.TextDirection.ltr),
          ]),
        pw.Text(
          [
            if (p['source'] == 'qr') 'طلب العميل (QR)' else if (p['waiter'] != null) '${p['waiter']}',
            if (p['createdAt'] != null) _time(DateTime.parse(p['createdAt'] as String)),
          ].join(' • '),
          style: st(9),
        ),
        _divider(),
        for (final i in items)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.SizedBox(width: 26 * s, child: pw.Text('${i['qty']}×', style: st(14, bold: true), textDirection: pw.TextDirection.ltr)),
                pw.Expanded(child: pw.Text('${i['name']}', style: st(14, bold: true))),
              ]),
              for (final m in (i['modifiers'] as List? ?? const []).cast<Map<String, dynamic>>())
                pw.Padding(padding: pw.EdgeInsets.only(right: 26 * s), child: pw.Text('+ ${m['name']}', style: st(11))),
              if (i['note'] != null)
                pw.Padding(padding: pw.EdgeInsets.only(right: 26 * s), child: pw.Text('ملاحظة: ${i['note']}', style: st(11, bold: true))),
              if (i['guest'] != null) pw.Padding(padding: pw.EdgeInsets.only(right: 26 * s), child: pw.Text('(${i['guest']})', style: st(9))),
            ]),
          ),
        if (p['note'] != null) ...[_divider(), pw.Text('ملاحظة الطلب: ${p['note']}', style: st(12, bold: true))],
        if (p['reason'] != null) ...[_divider(), pw.Text('السبب: ${p['reason']}', style: st(11))],
        pw.SizedBox(height: 8),
      ],
    ),
  ));
  return doc.save();
}

/// الحساب (قبل الدفع) أو الفاتورة (بعد القفل).
Future<Uint8List> buildCheckPdf(CheckDetail d, ShopProfile shop, {String? paper}) async {
  final theme = await _loadTheme();
  final size = paper ?? shop.receiptPaper;
  final small = size == '58mm';
  final s = small ? 0.85 : 1.0;
  final c = d.check;
  final doc = pw.Document(theme: theme, title: 'حساب ${c.number}', author: shop.name);
  pw.TextStyle st(double v, {bool bold = false}) => pw.TextStyle(fontSize: v * s, fontWeight: bold ? pw.FontWeight.bold : null);
  pw.Widget row(String label, String value, {bool bold = false, double sz = 10}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Text(label, style: st(sz, bold: bold)), pw.Text(value, style: st(sz, bold: bold))]),
      );

  // نجمّع الأصناف المتشابهة
  final grouped = <String, ({String name, String mods, int qty, int unit})>{};
  for (final l in d.lines) {
    final key = '${l.name}|${l.modsText}|${l.unitPriceCents}';
    final g = grouped[key];
    grouped[key] = (name: l.name, mods: l.modsText, qty: (g?.qty ?? 0) + l.qty, unit: l.unitPriceCents);
  }
  final closed = c.status == 'closed';
  final confirmedPays = d.payments.where((p) => p.status == 'confirmed').toList();

  doc.addPage(pw.Page(
    pageFormat: paperFormat(size),
    textDirection: pw.TextDirection.rtl,
    build: (_) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        if (shop.logo != null) pw.Center(child: pw.Image(pw.MemoryImage(shop.logo!), height: 46 * s)),
        pw.Center(child: pw.Text(shop.name, style: st(15, bold: true))),
        if (shop.address != null) pw.Center(child: pw.Text(shop.address!, style: st(8.5), textAlign: pw.TextAlign.center)),
        if (shop.phone != null) pw.Center(child: pw.Text(shop.phone!, style: st(9), textDirection: pw.TextDirection.ltr)),
        _divider(),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(closed ? 'فاتورة' : 'الحساب', style: st(13, bold: true)),
          pw.Text('#${c.number}', style: st(13, bold: true), textDirection: pw.TextDirection.ltr),
        ]),
        pw.Text(c.title, style: st(10)),
        pw.Text(formatDateTime((c.closedAt ?? DateTime.now()).toLocal()), style: st(8.5)),
        _divider(),
        for (final g in grouped.values)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.SizedBox(width: 20 * s, child: pw.Text('${g.qty}', style: st(10, bold: true))),
              pw.Expanded(
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                  pw.Text(g.name, style: st(10)),
                  if (g.mods.isNotEmpty) pw.Text(g.mods, style: st(8)),
                ]),
              ),
              pw.Text(_m(g.qty * g.unit), style: st(10)),
            ]),
          ),
        _divider(),
        row('المجموع', _m(c.subtotalCents)),
        if (c.discountCents > 0) row('خصم${c.discountNote != null ? ' (${c.discountNote})' : ''}', '- ${_m(c.discountCents)}'),
        if (c.pointsUsed > 0) row('نقط (${c.pointsUsed})', '- ${_m(c.pointsUsed * shop.intSetting('loyaltyPointValue', 25))}'),
        if (c.serviceCents > 0) row('خدمة ${percent(c.serviceBp)}', _m(c.serviceCents)),
        if (c.taxCents > 0) row('ضريبة ${percent(c.taxBp)}', _m(c.taxCents)),
        if (c.deliveryCents > 0) row('توصيل', _m(c.deliveryCents)),
        row('الإجمالي', money(c.totalCents), bold: true, sz: 13),
        if (confirmedPays.isNotEmpty) ...[
          for (final p in confirmedPays) row('مدفوع ${p.methodName}', _m(p.amountCents), sz: 9),
          if (c.dueCents > 0) row('الباقي', money(c.dueCents), bold: true),
        ],
        if (shop.receiptFooter.isNotEmpty) ...[_divider(), pw.Center(child: pw.Text(shop.receiptFooter, style: st(10), textAlign: pw.TextAlign.center))],
        pw.SizedBox(height: 4),
        pw.Center(child: pw.Text('Order Ly', style: st(7).copyWith(color: PdfColors.grey600), textDirection: pw.TextDirection.ltr)),
        pw.SizedBox(height: 8),
      ],
    ),
  ));
  return doc.save();
}

String _m(int cents) => money(cents).replaceAll(' ج.م', '');

const _brand = PdfColor.fromInt(0xFF0F766E);
const _brandLight = PdfColor.fromInt(0xFFE6F4F2);
const _accent = PdfColor.fromInt(0xFFD97706);

/// كروت الـ QR للترابيزات باسم الكافيه ولوجوه. [perPage] = 4 (كارت يتحط على الترابيزة) أو 1 (كارت كبير للكاونتر أو الحيطة).
/// الكروت مترصوصة بصفوف ثابتة المقاس (من غير GridView) عشان تطلع كلها جوه الورقة في الاتجاه العربي.
Future<Uint8List> buildQrCardsPdf(List<({String title, String subtitle, String url})> cards, ShopProfile shop, {int perPage = 4}) async {
  final theme = await _loadTheme();
  final doc = pw.Document(theme: theme, title: 'QR ${shop.name}', author: shop.name);
  const margin = 18.0;
  final page = PdfPageFormat.a4.copyWith(marginLeft: margin, marginRight: margin, marginTop: margin, marginBottom: margin);
  const gap = 14.0;
  final cols = perPage == 1 ? 1 : 2;
  final rows = perPage == 1 ? 1 : 2;
  final cardW = (page.availableWidth - gap * (cols - 1)) / cols;
  final cardH = (page.availableHeight - gap * (rows - 1)) / rows;
  final s = perPage == 1 ? 1.75 : 1.0;
  final logo = shop.logo == null ? null : pw.MemoryImage(shop.logo!);
  final wifiName = shop.strSetting('wifiName');
  final wifiPass = shop.strSetting('wifiPassword');

  pw.Widget step(String n, String text) => pw.Padding(
        padding: pw.EdgeInsets.symmetric(vertical: 1.5 * s),
        child: pw.Row(children: [
          pw.Container(
            width: 15 * s,
            height: 15 * s,
            alignment: pw.Alignment.center,
            decoration: const pw.BoxDecoration(color: _accent, shape: pw.BoxShape.circle),
            child: pw.Text(n, style: pw.TextStyle(color: PdfColors.white, fontSize: 8.5 * s, fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(width: 6 * s),
          pw.Text(text, style: pw.TextStyle(fontSize: 9.5 * s)),
        ]),
      );

  pw.Widget card(({String title, String subtitle, String url}) c) {
    // "ترابيزة 5" ← بنكبّر الرقم لوحده
    final m = RegExp(r'^(ترابيزة)\s+(.+)$').firstMatch(c.title);
    final qrSize = perPage == 1 ? 240.0 : 116.0;
    return pw.Container(
      width: cardW,
      height: cardH,
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border.all(color: _brand, width: 1.4),
        borderRadius: pw.BorderRadius.circular(16 * s),
      ),
      child: pw.Column(children: [
        // الشريط اللي فوق: اللوجو واسم الكافيه
        pw.Container(
          width: double.infinity,
          padding: pw.EdgeInsets.symmetric(horizontal: 12 * s, vertical: 9 * s),
          decoration: pw.BoxDecoration(
            color: _brand,
            borderRadius: pw.BorderRadius.only(topLeft: pw.Radius.circular(15 * s), topRight: pw.Radius.circular(15 * s)),
          ),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.center, children: [
            if (logo != null) ...[
              pw.Container(
                width: 34 * s,
                height: 34 * s,
                padding: pw.EdgeInsets.all(2 * s),
                decoration: const pw.BoxDecoration(color: PdfColors.white, shape: pw.BoxShape.circle),
                child: pw.ClipOval(child: pw.Image(logo, fit: pw.BoxFit.contain)),
              ),
              pw.SizedBox(width: 8 * s),
            ],
            pw.Flexible(
              child: pw.Text(shop.name, maxLines: 1, style: pw.TextStyle(color: PdfColors.white, fontSize: 15 * s, fontWeight: pw.FontWeight.bold)),
            ),
          ]),
        ),
        pw.SizedBox(height: 8 * s),
        // رقم الترابيزة
        if (m != null)
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.center, crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
            pw.Text('${m.group(1)} ', style: pw.TextStyle(fontSize: 13 * s, color: PdfColors.grey800)),
            pw.Text(m.group(2)!, style: pw.TextStyle(fontSize: 26 * s, fontWeight: pw.FontWeight.bold, color: _brand)),
          ])
        else
          pw.Text(c.title, style: pw.TextStyle(fontSize: 22 * s, fontWeight: pw.FontWeight.bold, color: _brand)),
        if (c.subtitle.isNotEmpty && c.subtitle != shop.name)
          pw.Text(c.subtitle, style: pw.TextStyle(fontSize: 9 * s, color: PdfColors.grey700)),
        pw.SizedBox(height: 6 * s),
        // الـ QR (ولو فيه لوجو بيتحط في النص، والكود بيستحمل ده لأنه بأعلى درجة تصحيح)
        pw.Container(
          padding: pw.EdgeInsets.all(7 * s),
          decoration: pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.circular(10 * s), border: pw.Border.all(color: PdfColors.grey300)),
          child: pw.Stack(alignment: pw.Alignment.center, children: [
            pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(errorCorrectLevel: pw.BarcodeQRCorrectionLevel.high),
              data: c.url,
              width: qrSize,
              height: qrSize,
              color: PdfColors.black,
            ),
            if (logo != null)
              pw.Container(
                width: qrSize * 0.22,
                height: qrSize * 0.22,
                padding: pw.EdgeInsets.all(2 * s),
                decoration: pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.circular(6 * s)),
                child: pw.Image(logo, fit: pw.BoxFit.contain),
              ),
          ]),
        ),
        pw.SizedBox(height: 7 * s),
        pw.Container(
          padding: pw.EdgeInsets.symmetric(horizontal: 10 * s, vertical: 3 * s),
          decoration: pw.BoxDecoration(color: _brandLight, borderRadius: pw.BorderRadius.circular(12 * s)),
          child: pw.Text('امسح • اطلب • ادفع من موبايلك', style: pw.TextStyle(fontSize: 10.5 * s, fontWeight: pw.FontWeight.bold, color: _brand)),
        ),
        pw.Spacer(),
        pw.Padding(
          padding: pw.EdgeInsets.symmetric(horizontal: 14 * s),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            step('1', 'افتح كاميرا الموبايل ووجّهها على الكود'),
            step('2', 'اختار طلبك من المنيو وابعته'),
            step('3', 'تابع طلبك واطلب الحساب من نفس الصفحة'),
          ]),
        ),
        pw.Spacer(),
        pw.Text('شغال على أي نت: واي فاي الكافيه أو باقة موبايلك', style: pw.TextStyle(fontSize: 8.5 * s, color: PdfColors.grey700)),
        if (wifiName.isNotEmpty)
          pw.Padding(
            padding: pw.EdgeInsets.only(top: 2 * s),
            child: pw.Text('Wi-Fi: $wifiName${wifiPass.isEmpty ? '' : '   •   $wifiPass'}',
                textDirection: pw.TextDirection.ltr, style: pw.TextStyle(fontSize: 8.5 * s, color: PdfColors.grey800, fontWeight: pw.FontWeight.bold)),
          ),
        pw.SizedBox(height: 3 * s),
        pw.Text('Scan • Order • Pay', textDirection: pw.TextDirection.ltr, style: pw.TextStyle(fontSize: 7.5 * s, color: PdfColors.grey500)),
        pw.SizedBox(height: 9 * s),
      ]),
    );
  }

  for (var i = 0; i < cards.length; i += perPage) {
    final chunk = cards.skip(i).take(perPage).toList();
    doc.addPage(pw.Page(
      pageFormat: page,
      textDirection: pw.TextDirection.rtl,
      build: (_) => pw.Column(children: [
        for (var r = 0; r < rows; r++) ...[
          if (r > 0) pw.SizedBox(height: gap),
          pw.Row(children: [
            for (var col = 0; col < cols; col++) ...[
              if (col > 0) pw.SizedBox(width: gap),
              if (r * cols + col < chunk.length) card(chunk[r * cols + col]) else pw.SizedBox(width: cardW, height: cardH),
            ],
          ]),
        ],
      ]),
    ));
  }
  return doc.save();
}
