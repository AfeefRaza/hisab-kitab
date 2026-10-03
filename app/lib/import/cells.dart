/// Cell-level parsing helpers shared by the settlement and bank importers.
library;

final _amountJunk = RegExp(r'(rs\.?|pkr|,|\s)', caseSensitive: false);

/// Parses "Rs. 1,250.50", "(300)", "300-", "-300", "1,000 CR" into a number.
/// Returns null when the text contains no number.
double? parseAmount(String? input) {
  if (input == null) return null;
  var s = input.trim();
  if (s.isEmpty || s == '-' || s == '--') return null;
  var negative = false;
  if (s.startsWith('(') && s.endsWith(')')) {
    negative = true;
    s = s.substring(1, s.length - 1);
  }
  final upper = s.toUpperCase();
  if (upper.endsWith('DR')) {
    negative = true;
    s = s.substring(0, s.length - 2);
  } else if (upper.endsWith('CR')) {
    s = s.substring(0, s.length - 2);
  }
  s = s.replaceAll(_amountJunk, '');
  if (s.endsWith('-')) {
    negative = true;
    s = s.substring(0, s.length - 1);
  }
  if (s.startsWith('-')) {
    negative = !negative;
    s = s.substring(1);
  }
  if (s.startsWith('+')) s = s.substring(1);
  final v = double.tryParse(s);
  if (v == null) return null;
  final rounded = (v * 100).roundToDouble() / 100;
  return negative ? -rounded : rounded;
}

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'sept': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

/// Parses a calendar date from bank/courier exports. Day-first is assumed for
/// numeric dates (Pakistani convention) unless that is impossible.
DateTime? parseDate(String? input) {
  if (input == null) return null;
  final s = input.trim();
  if (s.isEmpty) return null;

  // ISO yyyy-mm-dd (optionally with time)
  var m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})').firstMatch(s);
  if (m != null) return _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));

  // dd/mm/yyyy, dd-mm-yy, dd.mm.yyyy
  m = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})\b').firstMatch(s);
  if (m != null) {
    var a = int.parse(m[1]!), b = int.parse(m[2]!);
    final y = _year(int.parse(m[3]!));
    if (b > 12 && a <= 12) {
      final t = a;
      a = b;
      b = t;
    }
    return _date(y, b, a);
  }

  // dd-MMM-yyyy, dd MMM yyyy, dd-MMM-yy
  m = RegExp(r'^(\d{1,2})[-\s/]([A-Za-z]{3,9})[-\s/,]+(\d{2,4})').firstMatch(s);
  if (m != null) {
    final mo = _months[m[2]!.toLowerCase().substring(0, 3)];
    if (mo != null) return _date(_year(int.parse(m[3]!)), mo, int.parse(m[1]!));
  }

  // MMM dd, yyyy
  m = RegExp(r'^([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{4})').firstMatch(s);
  if (m != null) {
    final mo = _months[m[1]!.toLowerCase().substring(0, 3)];
    if (mo != null) return _date(int.parse(m[3]!), mo, int.parse(m[2]!));
  }

  // Excel serial date
  final serial = double.tryParse(s);
  if (serial != null && serial > 20000 && serial < 80000) {
    return DateTime.utc(1899, 12, 30).add(Duration(days: serial.floor()));
  }
  return null;
}

int _year(int y) => y < 100 ? 2000 + y : y;

DateTime? _date(int y, int mo, int d) {
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) return null;
  final dt = DateTime.utc(y, mo, d);
  return dt.month == mo ? dt : null; // rejects 31 Feb etc.
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Normalises a tracking number the same way the database does.
String normalizeTracking(String? s) =>
    (s ?? '').replaceAll(RegExp(r'''[\s'"]+'''), '').toUpperCase();

/// Normalises a header cell for matching.
String normHeader(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[\.:_\*]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
