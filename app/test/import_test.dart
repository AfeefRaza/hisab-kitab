import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisab_kitab/import/bank_parser.dart';
import 'package:hisab_kitab/import/cells.dart';
import 'package:hisab_kitab/import/settlement_parser.dart';
import 'package:hisab_kitab/import/table_reader.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('parseAmount', () {
    test('handles currency, commas, signs and brackets', () {
      expect(parseAmount('Rs. 1,250.50'), 1250.5);
      expect(parseAmount('PKR 3,000'), 3000);
      expect(parseAmount('(300)'), -300);
      expect(parseAmount('300-'), -300);
      expect(parseAmount('-45.5'), -45.5);
      expect(parseAmount('1,000 CR'), 1000);
      expect(parseAmount('1,000 DR'), -1000);
      expect(parseAmount(''), isNull);
      expect(parseAmount('-'), isNull);
      expect(parseAmount('abc'), isNull);
    });
  });

  group('parseDate', () {
    test('day-first numeric, ISO, month names, Excel serial', () {
      expect(parseDate('05/09/2026'), DateTime.utc(2026, 9, 5));
      expect(parseDate('5-9-26'), DateTime.utc(2026, 9, 5));
      expect(parseDate('2026-09-05 10:00'), DateTime.utc(2026, 9, 5));
      expect(parseDate('05-Sep-2026'), DateTime.utc(2026, 9, 5));
      expect(parseDate('5 September 2026'), DateTime.utc(2026, 9, 5));
      expect(parseDate('Sep 5, 2026'), DateTime.utc(2026, 9, 5));
      expect(parseDate('09/25/2026'), DateTime.utc(2026, 9, 25)); // month-first only when day-first is impossible
      expect(parseDate('46270'), DateTime.utc(2026, 9, 5));
      expect(parseDate('31/02/2026'), isNull);
      expect(parseDate('Opening Balance'), isNull);
    });
  });

  group('settlement parser', () {
    test('BlueEx HTML export: blank Amount Received is NOT treated as paid (legacy bug)', () {
      const html = '''
<html><body><table><tr><td>Blue-Ex Payment Advice</td></tr></table>
<table>
<tr><th>S.No</th><th>CNNO</th><th>Reference</th><th>Amount</th><th>Amount Received</th><th>Blue-Ex Charges</th><th>Status</th></tr>
<tr><td>1</td><td>50312345678</td><td>#1001</td><td>3,000</td><td>2,750</td><td>250</td><td>Delivered</td></tr>
<tr><td>2</td><td>50312345679</td><td>#1002</td><td>2,000</td><td></td><td>200</td><td>Delivered</td></tr>
<tr><td>3</td><td>50312345680</td><td>#1003</td><td>1,500</td><td>-150</td><td>150</td><td>Returned to shipper</td></tr>
<tr><td></td><td>Total</td><td></td><td>6,500</td><td>2,600</td><td>600</td><td></td></tr>
</table></body></html>''';
      final t = readTable(_bytes(html));
      expect(t.format, 'html');
      final r = parseSettlement(t);
      expect(r.lines.length, 3);
      expect(detectSettlementCourier(t, r.lines), 'blueex');

      final a = r.lines[0];
      expect(a.trackingNumber, '50312345678');
      expect(a.orderRef, '#1001');
      expect(a.cod, 3000);
      expect(a.net, 2750);
      expect(a.charges, 250);

      // Blank "Amount Received": net is computed (2000 - 200), never the full COD
      expect(r.lines[1].net, 1800);

      final ret = r.lines[2];
      expect(ret.lineKind, 'returned');
      expect(ret.cod, 0);
      expect(ret.net, -150);
      expect(r.totalNet, 2750 + 1800 - 150);
    });

    test('CSV with net computed from COD - charges - taxes', () {
      const csv = 'Tracking Number,Order ID,COD Amount,Delivery Charges,GST,Fuel Surcharge,Status\n'
          '22085990000463,#2001,"2,500",200,32,10,Delivered\n'
          '22085990000464,#2002,1800,200,32,10,Delivered\n';
      final t = readTable(_bytes(csv));
      final r = parseSettlement(t);
      expect(r.lines.length, 2);
      expect(r.lines[0].deductions, 42);
      expect(r.lines[0].net, 2500 - 200 - 42);
      expect(detectSettlementCourier(t, r.lines), 'postex');
    });

    test('Net-only file back-computes COD', () {
      const csv = 'CN Number,Ref,Net Amount,Charges\nT0012345,#3,1800,200\n';
      final r = parseSettlement(readTable(_bytes(csv)));
      expect(r.lines.single.cod, 2000);
      expect(r.lines.single.net, 1800);
    });

    test('xlsx: numeric tracking numbers are not rendered as 1.2e13 or with .0', () {
      final book = Excel.createExcel();
      final sheet = book['Sheet1'];
      sheet.appendRow([TextCellValue('Tracking No'), TextCellValue('COD Amount'), TextCellValue('Delivery Charges')]);
      sheet.appendRow([DoubleCellValue(22085990000463), IntCellValue(3000), DoubleCellValue(250.5)]);
      final bytes = Uint8List.fromList(book.encode()!);
      final t = readTable(bytes);
      expect(t.format, 'xlsx');
      final r = parseSettlement(t);
      expect(r.lines.single.trackingNumber, '22085990000463');
      expect(r.lines.single.charges, 250.5);
      expect(r.lines.single.net, 2749.5);
    });

    test('missing tracking column produces a mapping warning, not garbage', () {
      final r = parseSettlement(readTable(_bytes('Name,Amount\nAli,100\n')));
      expect(r.lines, isEmpty);
      expect(r.warnings.first, contains('tracking'));
    });

    test('old binary xls is rejected with guidance', () {
      expect(() => readTable(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0, 0])), throwsFormatException);
    });
  });

  group('bank parser', () {
    test('debit/credit columns, skips opening balance', () {
      const csv = 'Statement of Account\n'
          'Date,Narration,Cheque No,Withdrawal,Deposit,Balance\n'
          '01/09/2026,Opening Balance,,,,"10,000"\n'
          '02/09/2026,IBFT POSTEX PVT LTD,,,"2,750.00","12,750.00"\n'
          '03/09/2026,FB ADS CARD,,"1,000.00",,"11,750.00"\n';
      final r = parseBankStatement(readTable(_bytes(csv)));
      expect(r.rows.length, 2);
      expect(r.skipped, 1);
      expect(r.rows[0].credit, 2750);
      expect(r.rows[0].description, 'IBFT POSTEX PVT LTD');
      expect(r.rows[0].date, DateTime.utc(2026, 9, 2));
      expect(r.rows[1].debit, 1000);
      expect(r.rows[1].balance, 11750);
      expect(r.totalCredit, 2750);
    });

    test('signed amount with Dr/Cr column', () {
      const csv = 'Txn Date,Description,Amount,Dr/Cr\n05-Sep-2026,Courier,500,CR\n06-Sep-2026,Rent,300,DR\n';
      final r = parseBankStatement(readTable(_bytes(csv)));
      expect(r.rows[0].credit, 500);
      expect(r.rows[1].debit, 300);
    });
  });
}
