import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../features/printing/print_pdf.dart' show loadPdfTheme;
import 'day_report_view.dart';

const _brand = PdfColor.fromInt(0xFF0F766E);
const _light = PdfColor.fromInt(0xFFE6F4F2);

/// تقرير يوم واحد PDF (A4 عربي بخط Cairo): نفس أقسام شاشة المالك.
Future<Uint8List> buildDayReportPdf(Map<String, dynamic> report) async {
  final theme = await loadPdfTheme();
  final title = '${report['shop'] ?? ''}${(report['branch'] ?? '').toString().isEmpty ? '' : ' • ${report['branch']}'}';
  final doc = pw.Document(theme: theme, title: 'تقرير ${report['date']} $title', author: 'Order Ly');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 32, marginRight: 32, marginTop: 28, marginBottom: 28),
    textDirection: pw.TextDirection.rtl,
    header: (ctx) => pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 8),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _brand, width: 2))),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(title, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text('تقرير يوم ${report['date']}${report['final'] == true ? '' : ' (لسه شغال)'}', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        ]),
        pw.Text('Order Ly', style: pw.TextStyle(fontSize: 14, color: _brand, fontWeight: pw.FontWeight.bold)),
      ]),
    ),
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerLeft,
      child: pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
    ),
    build: (ctx) => [
      for (final sec in dayReportSections(report)) ...[
        pw.SizedBox(height: 10),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: _light,
          child: pw.Text(sec.title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: _brand)),
        ),
        for (final (label, value) in sec.rows)
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5))),
            child: pw.Row(children: [
              pw.Expanded(child: pw.Text(label, style: const pw.TextStyle(fontSize: 10))),
              pw.SizedBox(width: 8),
              pw.Text(value, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            ]),
          ),
      ],
    ],
  ));
  return doc.save();
}
