import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:html/parser.dart' as html;

/// A file read into a grid of trimmed strings.
class TableData {
  TableData(this.rows, this.format, this.rawText);
  final List<List<String>> rows;
  final String format; // xlsx | html | csv
  /// Lower-cased text of the file (for courier keyword detection).
  final String rawText;
}

String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

/// Reads xlsx, CSV, and the HTML-table ".xls" files most Pakistani couriers export.
TableData readTable(Uint8List bytes) {
  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    return _readXlsx(bytes);
  }
  if (bytes.length >= 4 && bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
    throw const FormatException(
        'This is an old binary .xls file. Open it in Excel and "Save As" .xlsx or CSV, then import again.');
  }
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  if (RegExp(r'<table', caseSensitive: false).hasMatch(text)) {
    return _readHtml(text);
  }
  final rows = Csv(dynamicTyping: false)
      .decode(text)
      .map((r) => r.map((c) => c == null ? '' : c.toString().trim()).toList())
      .where((r) => r.any((c) => c.isNotEmpty))
      .toList();
  return TableData(rows, 'csv', text.toLowerCase());
}

TableData _readXlsx(Uint8List bytes) {
  final book = Excel.decodeBytes(bytes);
  // Use the sheet with the most rows (statements usually have one data sheet)
  Sheet? best;
  for (final name in book.tables.keys) {
    final s = book.tables[name]!;
    if (best == null || s.maxRows > best.maxRows) best = s;
  }
  if (best == null) return TableData(const [], 'xlsx', '');
  final rows = <List<String>>[];
  for (final r in best.rows) {
    final row = r.map((c) => _cellText(c?.value)).toList();
    if (row.any((c) => c.isNotEmpty)) rows.add(row);
  }
  final text = rows.map((r) => r.join(' ')).join('\n').toLowerCase();
  return TableData(rows, 'xlsx', text);
}

String _two(int v) => v.toString().padLeft(2, '0');

String _cellText(CellValue? v) {
  if (v == null) return '';
  switch (v) {
    case DoubleCellValue():
      final d = v.value;
      return d == d.truncateToDouble() && d.abs() < 1e15 ? d.toInt().toString() : d.toString();
    case IntCellValue():
      return v.value.toString();
    case DateCellValue():
      return '${v.year}-${_two(v.month)}-${_two(v.day)}';
    case DateTimeCellValue():
      return '${v.year}-${_two(v.month)}-${_two(v.day)} ${_two(v.hour)}:${_two(v.minute)}';
    case TextCellValue():
      return v.value.toString().trim();
    default:
      return v.toString().trim();
  }
}

TableData _readHtml(String text) {
  final doc = html.parse(text);
  final rows = <List<String>>[];
  for (final tr in doc.querySelectorAll('tr')) {
    final cells = tr.querySelectorAll('td, th').map((c) => c.text.replaceAll(RegExp(r'\s+'), ' ').trim()).toList();
    if (cells.any((c) => c.isNotEmpty)) rows.add(cells);
  }
  return TableData(rows, 'html', (doc.body?.text ?? text).toLowerCase());
}
