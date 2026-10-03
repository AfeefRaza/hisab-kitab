import 'cells.dart';
import 'column_mapper.dart';
import 'table_reader.dart';

/// Column roles for courier COD settlement statements (PostEx, BlueEx, M&P,
/// Tranzo, XPS and others). Order matters: earlier roles claim columns first.
const settlementRoles = <ColumnRole>[
  ColumnRole('tracking', 'Tracking number', [
    'tracking number', 'tracking no', 'tracking', 'tracking id', 'cn', 'cnno', 'cn no', 'cn number', 'cn #',
    'consignment number', 'consignment no', 'consignment', 'awb', 'awb no', 'awb number', 'shipment number', 'shipment no',
  ], contains: ['tracking', 'consignment', 'cnno', 'awb'], required: true),
  ColumnRole('net', 'Net paid to us', [
    'net amount', 'net payable', 'net', 'amount received', 'payable amount', 'net amount payable', 'amount paid',
    'paid amount', 'invoice amount', 'net receivable', 'net cod', 'net payable amount',
  ], contains: ['net amount', 'net payable', 'amount received', 'payable', 'net cod']),
  ColumnRole('cod', 'COD collected', [
    'cod amount', 'cod', 'collected amount', 'order amount', 'amount', 'cod value', 'collection amount', 'cod collected',
  ], contains: ['cod', 'collected', 'amount']),
  ColumnRole('charges', 'Courier charges', [
    'delivery charges', 'delivery charge', 'shipping charges', 'shipping charge', 'charges', 'delivery fee',
    'service charges', 'blue-ex charges', 'blue ex charges', 'courier charges', 'total charges', 'freight', 'upfront charges',
  ], contains: ['charges', 'charge', 'freight']),
  ColumnRole('deductions', 'Other deductions (tax, fuel…)', [
    'gst', 'sales tax', 'fuel', 'fuel surcharge', 'fuel charges', 'tax', 'wht', 'withholding tax', 'income tax',
    'insurance', 'cod fee', 'sst', 'pst', 'handling', 'other deductions',
  ], contains: ['tax', 'gst', 'fuel', 'insurance', 'surcharge', 'wht', 'withholding', 'deduction', 'fee'], multi: true),
  ColumnRole('order_ref', 'Order reference', [
    'order ref no', 'order id', 'order number', 'order no', 'reference', 'reference number', 'reference no', 'ref',
    'ref no', 'customer reference', 'order ref', 'order reference', 'shipper reference', 'order #',
  ], contains: ['reference', 'order id', 'order no', 'order ref', 'order #', 'order number']),
  ColumnRole('status', 'Parcel status', [
    'status', 'cn status', 'order status', 'shipment status', 'delivery status', 'current status',
  ], contains: ['status']),
];

class SettlementLine {
  SettlementLine({
    required this.trackingNumber,
    required this.lineKind,
    required this.cod,
    required this.charges,
    required this.deductions,
    required this.net,
    this.orderRef,
    this.status,
    this.raw = const {},
  });
  final String trackingNumber;
  final String lineKind; // delivered | returned
  final double cod;
  final double charges;
  final double deductions;
  final double net;
  final String? orderRef;
  final String? status;
  final Map<String, String> raw;

  Map<String, dynamic> toJson() => {
        'tracking_number': trackingNumber,
        'line_kind': lineKind,
        'cod_amount': cod,
        'courier_charges': charges,
        'other_deductions': deductions,
        'net_amount': net,
        'order_ref': orderRef,
        'courier_status': status,
        'raw': raw,
      };
}

class SettlementParseResult {
  SettlementParseResult(this.lines, this.mapping, this.skippedRows, this.warnings);
  final List<SettlementLine> lines;
  final ColumnMapping mapping;
  final int skippedRows;
  final List<String> warnings;

  double get totalCod => lines.fold(0, (a, l) => a + l.cod);
  double get totalCharges => lines.fold(0, (a, l) => a + l.charges + l.deductions);
  double get totalNet => lines.fold(0, (a, l) => a + l.net);
  int get returnedCount => lines.where((l) => l.lineKind == 'returned').length;
}

/// Same tracking-number rules as the backend (supabase/functions/_shared/couriers.ts).
String courierFromTracking(String tn) {
  final t = normalizeTracking(tn);
  if (t.startsWith('503')) return 'blueex';
  if (t.startsWith('559')) return 'mnp';
  if (t.startsWith('T00')) return 'tranzo';
  if (RegExp(r'^2\d{13}$').hasMatch(t)) return 'postex';
  if (t.startsWith('KI') || (RegExp(r'^12\d+$').hasMatch(t) && t.length != 14)) return 'xps';
  return 'unknown';
}

/// Detects the courier from file text, then from the majority tracking-number shape.
String? detectSettlementCourier(TableData table, List<SettlementLine> lines) {
  final t = table.rawText;
  if (t.contains('postex') || t.contains('post ex')) return 'postex';
  if (t.contains('blue-ex') || t.contains('blueex') || t.contains('blue ex')) return 'blueex';
  if (t.contains('mulphilog') || t.contains('m&p') || t.contains('muller')) return 'mnp';
  if (t.contains('tranzo')) return 'tranzo';
  if (t.contains('xps')) return 'xps';
  final counts = <String, int>{};
  for (final l in lines) {
    final c = courierFromTracking(l.trackingNumber);
    if (c != 'unknown') counts[c] = (counts[c] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
}

bool _looksLikeTracking(String s) => s.length >= 6 && RegExp(r'\d').hasMatch(s) && !s.contains(' ');

SettlementParseResult parseSettlement(TableData table, {ColumnMapping? mapping}) {
  final m = mapping ?? autoMap(table.rows, settlementRoles);
  final warnings = <String>[];
  if (m.headerRow < 0 || m.single('tracking') == null) {
    return SettlementParseResult(const [], m, 0, ['Could not find a tracking-number column. Map the columns manually.']);
  }
  if (m.single('cod') == null && m.single('net') == null) {
    warnings.add('No COD or net amount column found — map one manually.');
  }

  final headerNorms = m.headers.map(normHeader).toSet();
  final lines = <SettlementLine>[];
  var skipped = 0;
  for (var i = m.headerRow + 1; i < table.rows.length; i++) {
    final row = table.rows[i];
    final tn = normalizeTracking(cellAt(row, m.single('tracking')));
    if (tn.isEmpty || headerNorms.contains(normHeader(tn)) || !_looksLikeTracking(tn)) {
      skipped++;
      continue;
    }
    final status = cellAt(row, m.single('status'));
    final s = status.toLowerCase();
    final isReturn = s.contains('return') || RegExp(r'\brto\b').hasMatch(s);

    final charges = (parseAmount(cellAt(row, m.single('charges'))) ?? 0).abs();
    final deductions = m.all('deductions').fold<double>(0, (a, c) => a + (parseAmount(cellAt(row, c)) ?? 0).abs());
    var cod = parseAmount(cellAt(row, m.single('cod'))) ?? 0;
    final netCell = parseAmount(cellAt(row, m.single('net')));

    if (isReturn) cod = 0; // COD is never collected on a returned parcel
    // Net: use the courier's figure when present; otherwise compute it.
    // (Legacy bug: a blank "Amount Received" used to be treated as fully paid.)
    final net = netCell ?? _round(cod - charges - deductions);
    if (!isReturn && cod == 0 && netCell != null && netCell > 0) {
      cod = _round(netCell + charges + deductions);
    }

    final raw = <String, String>{};
    for (var c = 0; c < m.headers.length && c < row.length; c++) {
      if (m.headers[c].isNotEmpty && row[c].isNotEmpty) raw[m.headers[c]] = row[c];
    }
    lines.add(SettlementLine(
      trackingNumber: tn,
      lineKind: isReturn ? 'returned' : 'delivered',
      cod: _round(cod),
      charges: _round(charges),
      deductions: _round(deductions),
      net: _round(net),
      orderRef: cellAt(row, m.single('order_ref')).isEmpty ? null : cellAt(row, m.single('order_ref')),
      status: status.isEmpty ? null : status,
      raw: raw,
    ));
  }
  if (lines.isEmpty) warnings.add('No parcel rows found under the header row.');
  return SettlementParseResult(lines, m, skipped, warnings);
}

double _round(double v) => (v * 100).roundToDouble() / 100;
