import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisab_kitab/core/format.dart';
import 'package:hisab_kitab/data/models.dart';
import 'package:hisab_kitab/features/csv_export.dart';

void main() {
  test('every money state the SQL engine can emit has a UI definition', () {
    // Parse the CASE in v_order_finance so the Dart enum can never drift from the database.
    final sql = File('../supabase/migrations/20261003100300_finance_engine.sql').readAsStringSync();
    final caseBlock = sql.substring(sql.indexOf('end as money_state') - 1200, sql.indexOf('end as money_state'));
    final states = RegExp(r"then '([a-z_]+)'").allMatches(caseBlock).map((m) => m[1]!).toSet();
    expect(states, isNotEmpty);
    for (final s in states) {
      expect(MoneyState.fromKey(s), isNotNull, reason: 'money_state "$s" missing in MoneyState');
    }
    expect(MoneyState.flow.toSet(), MoneyState.values.toSet());
  });

  test('money formatting', () {
    expect(rs(1234567), 'Rs 1,234,567');
    expect(rs(-250), '−Rs 250');
    expect(rs('1500.4'), 'Rs 1,500');
    expect(rs(null), 'Rs 0');
    expect(rs(99.5, decimals: true), 'Rs 99.5');
    expect(rsCompact(2500000), 'Rs 2.5M');
    expect(pct(null), '—');
    expect(pct(75), '75.0%');
    expect(titleCase('settled_unbanked'), 'Settled Unbanked');
  });

  test('CSV export escapes and adds a BOM for Excel', () {
    final csv = buildCsv(['Order', 'Note'], [
      ['#1', 'a, b'],
      ['#2', 'say "hi"'],
      ['#3', null],
    ]);
    expect(csv.startsWith('﻿'), isTrue);
    expect(csv, contains('"a, b"'));
    expect(csv, contains('"say ""hi"""'));
    expect(csv.split('\n').last, '#3,');
  });
}
