import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../import/settlement_parser.dart';
import '../import/table_reader.dart';
import '../ui/widgets.dart';

class SettlementsPage extends StatefulWidget {
  const SettlementsPage({super.key});

  @override
  State<SettlementsPage> createState() => _SettlementsPageState();
}

class _SettlementsPageState extends State<SettlementsPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return PageBody(
      title: 'Courier settlements',
      subtitle: 'COD remittance statements from couriers, matched parcel-by-parcel and to your bank',
      actions: [
        if (AppState.session.canOperate)
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await runAction(context, () async {
                final r = await Api.instance.syncPayments();
                if (context.mounted) {
                  showSnack(context, r['skipped'] != null
                      ? '${r['skipped']}'
                      : 'Checked ${r['checked']} parcels · ${r['settled']} settled by PostEx');
                }
              });
              if (ok) AppState.dataChanged();
            },
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('Fetch PostEx CPRs'),
          ),
        if (AppState.session.canOperate)
          FilledButton.icon(
            onPressed: () => showDialog(context: context, builder: (_) => const SettlementImportDialog()),
            icon: const Icon(Icons.upload_file),
            label: const Text('Import statement'),
          ),
      ],
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Statements'), icon: Icon(Icons.receipt_long)),
            ButtonSegment(value: 1, label: Text('Unsettled COD'), icon: Icon(Icons.hourglass_bottom)),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        if (_tab == 0) const _BatchesList() else const _UnsettledView(),
      ],
    );
  }
}

class _BatchesList extends StatelessWidget {
  const _BatchesList();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.settlementBatches,
      builder: (context, rows, _) {
        final active = rows.where((r) => r['voided_at'] == null);
        final unbanked = active.where((r) => r['is_banked'] != true);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TileGrid(children: [
            KpiCard(label: 'Statements imported', value: count(active.length), icon: Icons.receipt_long),
            KpiCard(label: 'Total settled (net)', value: rs(active.fold<num>(0, (a, r) => a + toNum(r['total_net']))), icon: Icons.payments),
            KpiCard(
              label: 'Not yet seen in bank',
              value: rs(unbanked.fold<num>(0, (a, r) => a + toNum(r['total_net']) - toNum(r['matched_amount']))),
              hint: '${unbanked.length} statement(s)',
              icon: Icons.account_balance,
              color: MoneyState.settledUnbanked.color,
              onTap: () => context.go('/bank'),
            ),
          ]),
          const SizedBox(height: 16),
          SectionCard(
            padding: const EdgeInsets.all(8),
            child: DataList(
              rows: rows,
              onTap: (r) => context.go('/settlements/${r['id']}'),
              empty: const EmptyState(
                icon: Icons.upload_file,
                title: 'No statements imported yet',
                message: 'PostEx CPRs are fetched automatically every 3 hours (or press "Fetch PostEx CPRs").\n'
                    'For other couriers, import the COD payment files they send (xlsx, csv or their .xls export).',
              ),
              columns: [
                Col('Courier', (r) => Text(courierName(r['courier']), style: const TextStyle(fontWeight: FontWeight.w700))),
                Col('Statement', (r) => Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('${r['statement_ref'] ?? r['file_name']}'),
                      if (r['source'] == 'api') ...[const SizedBox(width: 6), const Pill('API', color: Palette.info)],
                    ])),
                Col('Date', (r) => Text(dateShort(r['statement_date']))),
                Col('Parcels', (r) => Text(count(r['row_count'])), numeric: true),
                Col('COD', (r) => Amount(r['total_cod']), numeric: true),
                Col('Charges', (r) => Amount(r['total_charges']), numeric: true),
                Col('Net', (r) => Amount(r['total_net'], bold: true), numeric: true),
                Col('Bank', (r) => _bankPill(r)),
              ],
              tile: (r) => ListTile(
                title: Text('${courierName(r['courier'])} · ${r['statement_ref'] ?? r['file_name']}'),
                subtitle: Text('${dateShort(r['statement_date'])} · ${r['row_count']} parcels'),
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Amount(r['total_net'], bold: true),
                  _bankPill(r),
                ]),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

Widget _bankPill(Rec r) {
  if (r['voided_at'] != null) return const Pill('Voided', color: Palette.muted);
  if (r['is_banked'] == true) return Pill('In bank ${dateShort(r['banked_on'])}', color: Palette.positive);
  if (toNum(r['matched_amount']) > 0) return Pill('Part: ${rs(r['matched_amount'])}', color: Palette.warning);
  return const Pill('Not in bank', color: Palette.negative);
}

class _UnsettledView extends StatelessWidget {
  const _UnsettledView();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.unsettled,
      builder: (context, rows, _) {
        int age(Rec r) {
          final d = parseTs(r['delivered_at']) ?? parseTs(r['status_at']);
          return d == null ? 0 : DateTime.now().difference(d).inDays;
        }

        final byCourier = <String, List<Rec>>{};
        for (final r in rows) {
          byCourier.putIfAbsent(r['courier'] as String? ?? 'unknown', () => []).add(r);
        }
        const buckets = [(0, 7, '0–7 d'), (8, 14, '8–14 d'), (15, 30, '15–30 d'), (31, 100000, '30+ d')];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionCard(
            title: 'Delivered COD still with couriers — ageing',
            child: byCourier.isEmpty
                ? const EmptyState(icon: Icons.check_circle_outline, title: 'All delivered COD is settled')
                : DataList(
                    rows: [
                      for (final e in byCourier.entries)
                        {
                          'courier': e.key,
                          'n': e.value.length,
                          'total': e.value.fold<num>(0, (a, r) => a + toNum(r['expected_cod'])),
                          for (final b in buckets)
                            b.$3: e.value.where((r) => age(r) >= b.$1 && age(r) <= b.$2).fold<num>(0, (a, r) => a + toNum(r['expected_cod'])),
                        },
                    ],
                    onTap: (r) => context.go('/orders?state=with_courier&courier=${r['courier']}'),
                    columns: [
                      Col('Courier', (r) => Text(courierName(r['courier']), style: const TextStyle(fontWeight: FontWeight.w700))),
                      Col('Parcels', (r) => Text(count(r['n'])), numeric: true),
                      for (final b in buckets)
                        Col(b.$3, (r) => Amount(r[b.$3], style: TextStyle(color: b.$1 > 14 && toNum(r[b.$3]) > 0 ? Palette.negative : null)), numeric: true),
                      Col('Total', (r) => Amount(r['total'], bold: true), numeric: true),
                    ],
                    tile: (r) => ListTile(
                      title: Text(courierName(r['courier'])),
                      subtitle: Text('${r['n']} parcels · 30+ days: ${rs(r['30+ d'])}'),
                      trailing: Amount(r['total'], bold: true),
                    ),
                  ),
          ),
        ]);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Import wizard
// ---------------------------------------------------------------------------
class SettlementImportDialog extends StatefulWidget {
  const SettlementImportDialog({super.key});

  @override
  State<SettlementImportDialog> createState() => _SettlementImportDialogState();
}

class _SettlementImportDialogState extends State<SettlementImportDialog> {
  String? _fileName;
  String? _sha;
  TableData? _table;
  SettlementParseResult? _parsed;
  String? _courier;
  final _ref = TextEditingController();
  DateTime _date = DateTime.now();
  List<Rec>? _preview;
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    setState(() => _error = null);
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv', 'html', 'htm', 'txt']);
      if (files.isEmpty) return;
      final f = files.first;
      final bytes = await f.xFile.readAsBytes();
      final table = readTable(bytes);
      final parsed = parseSettlement(table);
      setState(() {
        _fileName = f.name;
        _sha = sha256Hex(bytes);
        _table = table;
        _parsed = parsed;
        _courier = detectSettlementCourier(table, parsed.lines);
        _ref.text = f.name.replaceAll(RegExp(r'\.[^.]+$'), '');
        _preview = null;
      });
      if (parsed.lines.isNotEmpty) _runPreview();
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  void _remap(String key, int? col) {
    final m = _parsed!.mapping.copyWith(key, col == null ? [] : [col]);
    setState(() {
      _parsed = parseSettlement(_table!, mapping: m);
      _preview = null;
    });
    if (_parsed!.lines.isNotEmpty) _runPreview();
  }

  Future<void> _runPreview() async {
    setState(() => _busy = true);
    try {
      final p = await Api.instance.previewSettlement(_parsed!.lines.map((l) => l.toJson()).toList());
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await Api.instance.importSettlement(
        courier: _courier!,
        fileName: _fileName!,
        sha256: _sha!,
        statementRef: _ref.text,
        statementDate: _date,
        lines: _parsed!.lines.map((l) => l.toJson()).toList(),
      );
      AppState.dataChanged();
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, 'Imported ${res['lines']} parcels · net ${rs(res['total_net'])}'
          '${toNum(res['unknown_parcels']) > 0 ? ' · ${res['unknown_parcels']} unknown parcels flagged' : ''}');
      context.go('/settlements/${res['batch_id']}');
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _parsed;
    final issues = _preview?.where((r) => r['issue'] != null).toList() ?? [];
    final matched = _preview?.where((r) => r['order_id'] != null).length ?? 0;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 820),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('Import courier settlement'), automaticallyImplyLeading: false, actions: [
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.attach_file),
              label: Text(_fileName ?? 'Choose statement file (xlsx, csv, or courier .xls export)'),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            if (p != null) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 12, runSpacing: 12, children: [
                SizedBox(
                  width: 200,
                  child: DropdownButtonFormField<String>(
                    initialValue: _courier,
                    decoration: const InputDecoration(labelText: 'Courier'),
                    items: [for (final c in ['postex', 'blueex', 'mnp', 'tranzo', 'xps', 'other']) DropdownMenuItem(value: c, child: Text(courierName(c)))],
                    onChanged: (v) => setState(() => _courier = v),
                  ),
                ),
                SizedBox(width: 260, child: TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Statement / invoice reference'))),
                OutlinedButton.icon(
                  onPressed: () async {
                    final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now(), initialDate: _date);
                    if (d != null) setState(() => _date = d);
                  },
                  icon: const Icon(Icons.event),
                  label: Text('Paid on ${dateShort(_date)}'),
                ),
              ]),
              const SizedBox(height: 12),
              ExpansionTile(
                title: Text('Column mapping (header row ${p.mapping.headerRow + 1})'),
                subtitle: const Text('Detected automatically — adjust if a column is wrong'),
                initiallyExpanded: p.lines.isEmpty,
                children: [
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    for (final role in settlementRoles)
                      SizedBox(
                        width: 280,
                        child: DropdownButtonFormField<int?>(
                          initialValue: p.mapping.single(role.key),
                          isExpanded: true,
                          decoration: InputDecoration(labelText: role.label),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('— none —')),
                            for (var i = 0; i < p.mapping.headers.length; i++)
                              DropdownMenuItem(value: i, child: Text(p.mapping.headers[i].isEmpty ? 'Column ${i + 1}' : p.mapping.headers[i], overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => _remap(role.key, v),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 12),
                ],
              ),
              for (final w in p.warnings) ListTile(leading: const Icon(Icons.warning_amber, color: Palette.warning), title: Text(w)),
              TileGrid(minTileWidth: 170, children: [
                KpiCard(label: 'Parcels', value: count(p.lines.length), hint: '${p.returnedCount} returns · ${p.skippedRows} rows skipped'),
                KpiCard(label: 'COD', value: rs(p.totalCod)),
                KpiCard(label: 'Charges & deductions', value: rs(p.totalCharges)),
                KpiCard(label: 'Net (expected in bank)', value: rs(p.totalNet), color: Palette.positive),
                if (_preview != null)
                  KpiCard(
                    label: 'Matched to orders',
                    value: '$matched / ${p.lines.length}',
                    hint: '${issues.length} need attention',
                    color: issues.isEmpty ? Palette.positive : Palette.warning,
                  ),
              ]),
              if (_busy) const LinearProgressIndicator(),
              if (issues.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Issues found (${issues.length}) — they will also appear in Alerts after import',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                for (final r in issues.take(50))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.error_outline, color: Palette.warning),
                    title: Text('${r['tracking_number']} ${r['order_name'] ?? ''}'),
                    subtitle: Text('${r['issue']}'),
                    trailing: Amount(r['net_amount']),
                  ),
                if (issues.length > 50) Text('…and ${issues.length - 50} more'),
              ],
            ],
          ]),
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: (_busy || p == null || p.lines.isEmpty || _courier == null) ? null : _import,
                icon: const Icon(Icons.check),
                label: Text(p == null ? 'Import' : 'Import ${p.lines.length} parcels'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Batch detail
// ---------------------------------------------------------------------------
class SettlementBatchPage extends StatelessWidget {
  const SettlementBatchPage({super.key, required this.batchId});
  final int batchId;

  Future<(Rec?, List<Rec>, Map<String, Rec>)> _load() async {
    final batches = await Api.instance.settlementBatches();
    final batch = batches.where((b) => b['id'] == batchId).firstOrNull;
    final lines = await Api.instance.batchLines(batchId);
    final orders = await Api.instance.ordersByTracking(lines.map((l) => l['tracking_number'] as String).toList());
    return (batch, lines, {for (final o in orders) o['tracking_number'] as String: o});
  }

  @override
  Widget build(BuildContext context) {
    return Loader<(Rec?, List<Rec>, Map<String, Rec>)>(
      watchPeriod: false,
      load: _load,
      builder: (context, data, reload) {
        final (b, lines, orders) = data;
        if (b == null) return const EmptyState(icon: Icons.search_off, title: 'Statement not found');
        return PageBody(
          title: '${courierName(b['courier'])} statement',
          subtitle: '${b['statement_ref'] ?? b['file_name']} · paid ${dateShort(b['statement_date'])} · imported ${dateTime(b['imported_at'])}',
          actions: [
            OutlinedButton.icon(onPressed: () => context.go('/settlements'), icon: const Icon(Icons.arrow_back), label: const Text('Statements')),
            if (AppState.session.canOperate && b['voided_at'] == null)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                onPressed: () async {
                  final reason = await promptText(context, 'Void this statement?', label: 'Reason (required)', required: true);
                  if (reason == null || !context.mounted) return;
                  final ok = await runAction(context, () => Api.instance.voidBatch(batchId, reason), success: 'Statement voided');
                  if (ok) {
                    AppState.dataChanged();
                    reload();
                  }
                },
                icon: const Icon(Icons.block),
                label: const Text('Void'),
              ),
          ],
          children: [
            if (b['voided_at'] != null)
              Card(child: ListTile(leading: const Icon(Icons.block), title: const Text('This statement is voided and excluded from all totals'), subtitle: Text('${b['note'] ?? ''}'))),
            TileGrid(children: [
              KpiCard(label: 'Parcels', value: count(b['row_count'])),
              KpiCard(label: 'COD collected', value: rs(b['total_cod'])),
              KpiCard(label: 'Charges & deductions', value: rs(b['total_charges'])),
              KpiCard(label: 'Net payable', value: rs(b['total_net']), color: Palette.positive),
              KpiCard(label: 'Bank', value: b['is_banked'] == true ? 'Received' : 'Not matched', hint: 'Matched ${rs(b['matched_amount'])}', onTap: () => context.go('/bank')),
            ]),
            SectionCard(
              title: 'Parcels',
              padding: const EdgeInsets.all(8),
              child: DataList(
                rows: lines,
                onTap: (l) {
                  final o = orders[l['tracking_number']];
                  if (o != null) context.go('/orders/${o['order_id']}');
                },
                columns: [
                  Col('Tracking', (l) => Text('${l['tracking_number']}')),
                  Col('Order', (l) {
                    final o = orders[l['tracking_number']];
                    return o == null ? const Pill('Unknown', color: Palette.negative) : Text('${o['name']}');
                  }),
                  Col('Kind', (l) => Text('${l['line_kind']}')),
                  Col('COD', (l) => Amount(l['cod_amount']), numeric: true),
                  Col('Order total', (l) {
                    final o = orders[l['tracking_number']];
                    if (o == null) return const Text('—');
                    final diff = toNum(l['cod_amount']) - toNum(o['current_total']);
                    return Text(rs(o['current_total']), style: TextStyle(color: l['line_kind'] == 'delivered' && diff.abs() > 1 ? Palette.negative : null));
                  }, numeric: true),
                  Col('Charges', (l) => Amount(toNum(l['courier_charges']) + toNum(l['other_deductions'])), numeric: true),
                  Col('Net', (l) => Amount(l['net_amount'], bold: true), numeric: true),
                  Col('Status', (l) => Text('${l['courier_status'] ?? ''}')),
                ],
                tile: (l) {
                  final o = orders[l['tracking_number']];
                  return ListTile(
                    title: Text('${o?['name'] ?? 'Unknown parcel'} · ${l['tracking_number']}'),
                    subtitle: Text('COD ${rs(l['cod_amount'])} − charges ${rs(toNum(l['courier_charges']) + toNum(l['other_deductions']))}'),
                    trailing: Amount(l['net_amount'], bold: true),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
