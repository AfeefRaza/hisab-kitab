import 'package:intl/intl.dart';

final _money = NumberFormat('#,##0', 'en_US');
final _money2 = NumberFormat('#,##0.##', 'en_US');
final _compact = NumberFormat.compact(locale: 'en_US');

num toNum(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v;
  return num.tryParse(v.toString()) ?? 0;
}

num? toNumOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v;
  return num.tryParse(v.toString());
}

/// "Rs 12,345" (negative as "−Rs 12,345").
String rs(dynamic v, {bool decimals = false}) {
  final n = toNum(v);
  final s = (decimals ? _money2 : _money).format(n.abs());
  return n < 0 ? '−Rs $s' : 'Rs $s';
}

/// "Rs 1.2M" for tight spaces.
String rsCompact(dynamic v) {
  final n = toNum(v);
  if (n.abs() < 100000) return rs(n);
  final s = _compact.format(n.abs());
  return n < 0 ? '−Rs $s' : 'Rs $s';
}

String count(dynamic v) => _money.format(toNum(v));

String pct(dynamic v, {int digits = 1}) {
  final n = toNumOrNull(v);
  return n == null ? '—' : '${n.toStringAsFixed(digits)}%';
}

DateTime? parseTs(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse(v.toString())?.toLocal();
}

String dateShort(dynamic v) {
  final d = v is DateTime ? v : parseTs(v);
  return d == null ? '—' : DateFormat('d MMM yyyy').format(d);
}

String dateTime(dynamic v) {
  final d = v is DateTime ? v : parseTs(v);
  return d == null ? '—' : DateFormat('d MMM yyyy, h:mm a').format(d);
}

String ago(dynamic v) {
  final d = v is DateTime ? v : parseTs(v);
  if (d == null) return 'never';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return '${diff.inDays} d ago';
}

String ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

String titleCase(String s) => s
    .replaceAll('_', ' ')
    .split(' ')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');
