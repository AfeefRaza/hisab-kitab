import 'cells.dart';
import 'column_mapper.dart';
import 'table_reader.dart';

const bankRoles = <ColumnRole>[
  ColumnRole('date', 'Date', [
    'date', 'transaction date', 'txn date', 'tran date', 'value date', 'posting date', 'booking date', 'trans date', 'post date',
  ], contains: ['date'], required: true),
  ColumnRole('description', 'Description', [
    'description', 'narration', 'particulars', 'details', 'transaction details', 'remarks', 'transaction description', 'narrative',
  ], contains: ['description', 'narration', 'particular', 'detail', 'remark']),
  ColumnRole('debit', 'Debit (money out)', [
    'debit', 'debits', 'withdrawal', 'withdrawals', 'dr', 'debit amount', 'paid out', 'withdrawal amount',
  ], contains: ['debit', 'withdraw']),
  ColumnRole('credit', 'Credit (money in)', [
    'credit', 'credits', 'deposit', 'deposits', 'cr', 'credit amount', 'paid in', 'deposit amount',
  ], contains: ['credit', 'deposit']),
  ColumnRole('balance', 'Balance', [
    'balance', 'running balance', 'closing balance', 'available balance', 'ledger balance',
  ], contains: ['balance']),
  ColumnRole('reference', 'Reference', [
    'reference', 'ref', 'ref no', 'reference no', 'cheque no', 'chq no', 'cheque number', 'instrument no', 'transaction id', 'tran id',
  ], contains: ['reference', 'cheque', 'instrument', 'ref no']),
  ColumnRole('amount', 'Signed amount (if no debit/credit columns)', ['amount', 'transaction amount', 'amount (pkr)'],
      contains: ['amount']),
  ColumnRole('type', 'Dr/Cr indicator', ['type', 'dr/cr', 'cr/dr', 'debit/credit', 'txn type', 'transaction type'],
      contains: ['dr/cr', 'cr/dr']),
];

class BankRow {
  BankRow(this.date, this.description, this.reference, this.debit, this.credit, this.balance);
  final DateTime date;
  final String description;
  final String? reference;
  final double debit;
  final double credit;
  final double? balance;

  Map<String, dynamic> toJson() => {
        'date': isoDate(date),
        'description': description,
        'reference': reference,
        'debit': debit,
        'credit': credit,
        'balance': balance,
      };
}

class BankParseResult {
  BankParseResult(this.rows, this.mapping, this.skipped, this.warnings);
  final List<BankRow> rows;
  final ColumnMapping mapping;
  final int skipped;
  final List<String> warnings;
  double get totalCredit => rows.fold(0, (a, r) => a + r.credit);
  double get totalDebit => rows.fold(0, (a, r) => a + r.debit);
}

BankParseResult parseBankStatement(TableData table, {ColumnMapping? mapping}) {
  final m = mapping ?? autoMap(table.rows, bankRoles);
  if (m.headerRow < 0 || m.single('date') == null) {
    return BankParseResult(const [], m, 0, ['Could not find a date column. Map the columns manually.']);
  }
  final hasSplit = m.single('debit') != null || m.single('credit') != null;
  if (!hasSplit && m.single('amount') == null) {
    return BankParseResult(const [], m, 0, ['Could not find debit/credit or amount columns. Map them manually.']);
  }
  final rows = <BankRow>[];
  var skipped = 0;
  for (var i = m.headerRow + 1; i < table.rows.length; i++) {
    final r = table.rows[i];
    final date = parseDate(cellAt(r, m.single('date')));
    if (date == null) {
      skipped++;
      continue;
    }
    double debit = 0, credit = 0;
    if (hasSplit) {
      debit = (parseAmount(cellAt(r, m.single('debit'))) ?? 0).abs();
      credit = (parseAmount(cellAt(r, m.single('credit'))) ?? 0).abs();
    } else {
      final amt = parseAmount(cellAt(r, m.single('amount'))) ?? 0;
      final type = cellAt(r, m.single('type')).toLowerCase();
      final isDebit = type.isNotEmpty ? (type.startsWith('d') || type.contains('dr')) : amt < 0;
      if (isDebit) {
        debit = amt.abs();
      } else {
        credit = amt.abs();
      }
    }
    if (debit == 0 && credit == 0) {
      skipped++; // opening/closing balance lines
      continue;
    }
    final ref = cellAt(r, m.single('reference'));
    rows.add(BankRow(
      date,
      cellAt(r, m.single('description')),
      ref.isEmpty ? null : ref,
      debit,
      credit,
      parseAmount(cellAt(r, m.single('balance'))),
    ));
  }
  return BankParseResult(rows, m, skipped, rows.isEmpty ? ['No transactions found under the header row.'] : const []);
}
