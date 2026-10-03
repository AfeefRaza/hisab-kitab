import 'cells.dart';

/// A logical column we want to find in an imported sheet.
class ColumnRole {
  const ColumnRole(this.key, this.label, this.exact, {this.contains = const [], this.multi = false, this.required = false});
  final String key;
  final String label;
  /// Header texts that match exactly (after [normHeader]).
  final List<String> exact;
  /// Header fragments that match when contained.
  final List<String> contains;
  /// Role can take several columns (values are summed), e.g. deductions.
  final bool multi;
  final bool required;
}

class ColumnMapping {
  ColumnMapping(this.headerRow, this.headers, this.columns);
  final int headerRow;
  final List<String> headers;
  /// role key -> column indexes
  final Map<String, List<int>> columns;

  int? single(String key) {
    final c = columns[key];
    return (c == null || c.isEmpty) ? null : c.first;
  }

  List<int> all(String key) => columns[key] ?? const [];

  ColumnMapping copyWith(String key, List<int> cols) =>
      ColumnMapping(headerRow, headers, {...columns, key: cols});
}

bool _matches(String header, ColumnRole role, {required bool exactOnly}) {
  final h = normHeader(header);
  if (h.isEmpty) return false;
  if (role.exact.contains(h)) return true;
  if (exactOnly) return false;
  return role.contains.any(h.contains);
}

/// Finds the most header-like row in the first 40 rows.
int detectHeaderRow(List<List<String>> rows, List<ColumnRole> roles) {
  var best = -1, bestScore = 0;
  for (var i = 0; i < rows.length && i < 40; i++) {
    var score = 0;
    for (final cell in rows[i]) {
      if (roles.any((r) => _matches(cell, r, exactOnly: false))) score++;
    }
    if (score > bestScore) {
      bestScore = score;
      best = i;
    }
  }
  return bestScore >= 2 ? best : -1;
}

/// Assigns columns to roles: exact matches first, then "contains" matches,
/// in role order, never reusing a column.
ColumnMapping autoMap(List<List<String>> rows, List<ColumnRole> roles) {
  final headerRow = detectHeaderRow(rows, roles);
  if (headerRow < 0) return ColumnMapping(-1, const [], {});
  final headers = rows[headerRow];
  final used = <int>{};
  final cols = <String, List<int>>{};
  for (final pass in [true, false]) {
    for (final role in roles) {
      if (!role.multi && (cols[role.key]?.isNotEmpty ?? false)) continue;
      for (var i = 0; i < headers.length; i++) {
        if (used.contains(i)) continue;
        if (_matches(headers[i], role, exactOnly: pass)) {
          cols.putIfAbsent(role.key, () => []).add(i);
          used.add(i);
          if (!role.multi) break;
        }
      }
    }
  }
  return ColumnMapping(headerRow, headers, cols);
}

String cellAt(List<String> row, int? index) =>
    (index == null || index < 0 || index >= row.length) ? '' : row[index].trim();
