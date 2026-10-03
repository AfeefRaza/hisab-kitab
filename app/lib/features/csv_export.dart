import 'save_file_stub.dart' if (dart.library.js_interop) 'save_file_web.dart' as saver;

/// Builds a UTF-8 CSV (with BOM so Excel opens Urdu/Unicode text correctly).
String buildCsv(List<String> headers, List<List<dynamic>> rows) {
  String esc(dynamic v) {
    if (v == null) return '';
    final s = v.toString();
    return (s.contains(',') || s.contains('"') || s.contains('\n')) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  return '﻿${[headers.map(esc).join(','), ...rows.map((r) => r.map(esc).join(','))].join('\n')}';
}

Future<void> downloadCsv(String fileName, List<String> headers, List<List<dynamic>> rows) =>
    saver.saveTextFile(fileName, buildCsv(headers, rows), 'text/csv;charset=utf-8');
