import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../import/bank_parser.dart';
import '../import/table_reader.dart';
import '../ui/widgets.dart';
import 'expenses_page.dart';

class BankPage extends StatefulWidget {
  const BankPage({super.key});

  @override
  State<BankPage> createState() => _BankPageState();
}

class _BankPageState extends State<BankPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final canOp = AppState.session.canOperate;
    return PageBody(
      title: 'Bank & reconciliation',
      subtitle: 'Import bank statements and match courier deposits — the last step of "where is our money?"',
      actions: [
        if (canOp)
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await runAction(context, () async {
                final n = await Api.instance.autoMatch();
                await Api.instance.refreshAlerts();
                if (context.mounted) showSnack(context, 'Auto-matched $n statement(s)');
              });
              if (ok) AppState.dataChanged();
            },
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('Auto-match'),
          ),
        if (canOp)
          FilledButton.icon(
            onPressed: () => showDialog(context: context, builder: (_) => const BankImportDialog()),
            icon: const Icon(Icons.upload_file),
            label: const Text('Import statement'),
          ),
      ],
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Reconcile'), icon: Icon(Icons.compare_arrows)),
            ButtonSegment(value: 1, label: Text('Transactions'), icon: Icon(Icons.list_alt)),
            ButtonSegment(value: 2, label: Text('Accounts'), icon: Icon(Icons.account_balance)),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        switch (_tab) {
          0 => const _ReconcileView(),
          1 => const _TransactionsView(),
          _ => const _AccountsView(),
        },
      ],
    );
  }
}

// --------------------------------------------------------------- reconcile
class _ReconcileView extends StatelessWidget {
  const _ReconcileView();

  Future<(List<Rec>, List<Rec>)> _load() async {
    final r = await Future.wait([Api.instance.settlementBatches(), Api.instance.bankTransactions(filter: 'credits')]);
    return (r[0], r[1]);
  }

  @override
  Widget build(BuildContext context) {
    return Loader<(List<Rec>, List<Rec>)>(
      watchPeriod: false,
      load: _load,
      builder: (context, data, reload) {
        final (batches, credits) = data;
        final open = batches.where((b) => b['voided_at'] == null && b['is_banked'] != true && toNum(b['total_net']) > 0).toList();
        num matchedOf(Rec t) => (t['settlement_bank_matches'] as List).fold<num>(0, (a, m) => a + toNum(m['amount']));
        final freeCredits = credits.where((t) => toNum(t['credit']) - matchedOf(t) > 1 && (t['expenses'] as List).isEmpty).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TileGrid(children: [
            KpiCard(
              label: 'Settled by couriers, not seen in bank',
              value: rs(open.fold<num>(0, (a, b) => a + toNum(b['total_net']) - toNum(b['matched_amount']))),
              hint: '${open.length} statement(s)',
              color: MoneyState.settledUnbanked.color,
              icon: Icons.receipt_long,
            ),
            KpiCard(
              label: 'Unexplained bank credits',
              value: rs(freeCredits.fold<num>(0, (a, t) => a + toNum(t['credit']) - matchedOf(t))),
              hint: '${freeCredits.length} credit(s) not matched to a statement',
              icon: Icons.help_outline,
              color: Palette.info,
            ),
          ]),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Statements waiting for a bank deposit',
            padding: const EdgeInsets.all(8),
            child: open.isEmpty
                ? const EmptyState(icon: Icons.verified_outlined, title: 'Every courier statement is matched to the bank')
                : Column(children: [
                    for (final b in open)
                      ListTile(
                        leading: const Icon(Icons.receipt_long, color: Palette.warning),
                        title: Text('${courierName(b['courier'])} · ${b['statement_ref'] ?? b['file_name']}'),
                        subtitle: Text('Paid ${dateShort(b['statement_date'])} · net ${rs(b['total_net'])}'
                            '${toNum(b['matched_amount']) > 0 ? ' · matched ${rs(b['matched_amount'])}' : ''}'),
                        trailing: AppState.session.canOperate
                            ? FilledButton.tonal(
                                onPressed: () => _matchDialog(context, b, freeCredits, matchedOf, reload),
                                child: const Text('Match'),
                              )
                            : null,
                        onTap: () => context.go('/settlements/${b['id']}'),
                      ),
                  ]),
          ),
        ]);
      },
    );
  }

  Future<void> _matchDialog(BuildContext context, Rec batch, List<Rec> credits, num Function(Rec) matchedOf, VoidCallback reload) async {
    final remaining = toNum(batch['total_net']) - toNum(batch['matched_amount']);
    final sorted = [...credits]..sort((a, b) => ((toNum(a['credit']) - matchedOf(a)) - remaining).abs().compareTo(((toNum(b['credit']) - matchedOf(b)) - remaining).abs()));
    final picked = await showDialog<Rec>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Match ${rs(remaining)} from ${courierName(batch['courier'])}'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: sorted.isEmpty
              ? const Center(child: Text('No unmatched bank credits. Import a bank statement first.'))
              : ListView(children: [
                  for (final t in sorted.take(40))
                    ListTile(
                      title: Text('${t['description']}'),
                      subtitle: Text('${dateShort(t['txn_date'])}${t['reference'] != null ? ' · ${t['reference']}' : ''}'),
                      trailing: Text(rs(toNum(t['credit']) - matchedOf(t)),
                          style: TextStyle(fontWeight: FontWeight.w700, color: ((toNum(t['credit']) - matchedOf(t)) - remaining).abs() <= 1 ? Palette.positive : null)),
                      onTap: () => Navigator.pop(c, t),
                    ),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
      ),
    );
    if (picked == null || !context.mounted) return;
    final available = toNum(picked['credit']) - matchedOf(picked);
    final amount = available < remaining ? available : remaining;
    final ok = await runAction(
      context,
      () => Api.instance.matchSettlement(batch['id'] as int, picked['id'] as int, amount.toDouble()),
      success: 'Matched ${rs(amount)}',
    );
    if (ok) {
      await Api.instance.refreshAlerts().catchError((_) => <String, dynamic>{});
      AppState.dataChanged();
    }
  }
}

// --------------------------------------------------------------- transactions
class _TransactionsView extends StatefulWidget {
  const _TransactionsView();

  @override
  State<_TransactionsView> createState() => _TransactionsViewState();
}

class _TransactionsViewState extends State<_TransactionsView> {
  String _filter = 'all';
  int _v = 0;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'all', label: Text('All')),
          ButtonSegment(value: 'credits', label: Text('Money in')),
          ButtonSegment(value: 'debits', label: Text('Money out')),
        ],
        selected: {_filter},
        onSelectionChanged: (s) => setState(() {
          _filter = s.first;
          _v++;
        }),
      ),
      const SizedBox(height: 12),
      Loader<List<Rec>>(
        key: ValueKey(_v),
        load: () => Api.instance.bankTransactions(filter: _filter, from: AppState.period.value.start, to: AppState.period.value.end),
        builder: (context, rows, reload) {
          String status(Rec t) {
            if ((t['settlement_bank_matches'] as List).isNotEmpty) return 'Courier settlement';
            if ((t['expenses'] as List).isNotEmpty) return 'Expense';
            return t['category'] != null ? titleCase(t['category']) : 'Unexplained';
          }

          return SectionCard(
            title: '${rows.length} transactions in period',
            padding: const EdgeInsets.all(8),
            child: DataList(
              rows: rows,
              onTap: AppState.session.canOperate ? (t) => _actions(context, t) : null,
              empty: const EmptyState(icon: Icons.account_balance, title: 'No bank transactions in this period', message: 'Import a statement to start reconciling.'),
              columns: [
                Col('Date', (t) => Text(dateShort(t['txn_date']))),
                Col('Description', (t) => SizedBox(width: 320, child: Text('${t['description']}', maxLines: 2, overflow: TextOverflow.ellipsis))),
                Col('Reference', (t) => Text('${t['reference'] ?? ''}')),
                Col('In', (t) => toNum(t['credit']) > 0 ? Amount(t['credit'], style: const TextStyle(color: Palette.positive)) : const Text(''), numeric: true),
                Col('Out', (t) => toNum(t['debit']) > 0 ? Amount(t['debit']) : const Text(''), numeric: true),
                Col('Balance', (t) => Amount(t['balance']), numeric: true),
                Col('Explained as', (t) {
                  final s = status(t);
                  return Pill(s, color: s == 'Unexplained' ? Palette.warning : Palette.positive);
                }),
              ],
              tile: (t) => ListTile(
                title: Text('${t['description']}', maxLines: 2),
                subtitle: Text('${dateShort(t['txn_date'])} · ${status(t)}'),
                trailing: toNum(t['credit']) > 0
                    ? Amount(t['credit'], style: const TextStyle(color: Palette.positive, fontWeight: FontWeight.w700))
                    : Amount(-toNum(t['debit']), bold: true),
              ),
            ),
          );
        },
      ),
    ]);
  }

  Future<void> _actions(BuildContext context, Rec t) async {
    final isDebit = toNum(t['debit']) > 0;
    final matches = (t['settlement_bank_matches'] as List).cast<Map>();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('${t['description']}'), subtitle: Text('${dateShort(t['txn_date'])} · ${rs(isDebit ? t['debit'] : t['credit'])}')),
          const Divider(),
          if (isDebit && (t['expenses'] as List).isEmpty)
            ListTile(leading: const Icon(Icons.payments_outlined), title: const Text('Record as expense'), onTap: () => Navigator.pop(c, 'expense')),
          for (final m in matches)
            ListTile(leading: const Icon(Icons.link_off), title: Text('Unmatch from settlement batch #${m['batch_id']} (${rs(m['amount'])})'), onTap: () => Navigator.pop(c, 'unmatch:${m['id']}')),
          for (final cat in ['transfer', 'owner', 'loan', 'other', 'courier_settlement'])
            ListTile(leading: const Icon(Icons.label_outline), title: Text('Mark as ${titleCase(cat)}'), onTap: () => Navigator.pop(c, 'cat:$cat')),
          ListTile(leading: const Icon(Icons.label_off_outlined), title: const Text('Clear category'), onTap: () => Navigator.pop(c, 'cat:')),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    bool ok = false;
    if (choice == 'expense') {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => ExpenseDialog(initial: {
          'expense_date': t['txn_date'],
          'amount': t['debit'],
          'description': t['description'],
          'payment_method': 'bank',
          'bank_transaction_id': t['id'],
        }),
      );
      ok = saved == true;
    } else if (choice.startsWith('unmatch:')) {
      ok = await runAction(context, () => Api.instance.unmatch(int.parse(choice.substring(8))), success: 'Unmatched');
    } else if (choice.startsWith('cat:')) {
      final cat = choice.substring(4);
      ok = await runAction(context, () => Api.instance.updateBankTxn(t['id'] as int, category: cat.isEmpty ? null : cat, note: t['note'] as String?),
          success: 'Updated');
    }
    if (ok) AppState.dataChanged();
  }
}

// --------------------------------------------------------------- accounts
class _AccountsView extends StatelessWidget {
  const _AccountsView();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.bankAccounts,
      builder: (context, rows, reload) => SectionCard(
        title: 'Bank accounts',
        trailing: AppState.session.canOperate
            ? TextButton.icon(onPressed: () => _edit(context, {}, reload), icon: const Icon(Icons.add), label: const Text('Add account'))
            : null,
        child: rows.isEmpty
            ? const EmptyState(icon: Icons.account_balance, title: 'No bank accounts yet', message: 'Add the account your couriers pay into.')
            : Column(children: [
                for (final a in rows)
                  ListTile(
                    leading: const Icon(Icons.account_balance),
                    title: Text('${a['name']}'),
                    subtitle: Text('${a['bank'] ?? ''}${a['account_hint'] != null ? ' · ••••${a['account_hint']}' : ''}${a['active'] == false ? ' · inactive' : ''}'),
                    trailing: AppState.session.canOperate ? IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(context, a, reload)) : null,
                  ),
              ]),
      ),
    );
  }

  Future<void> _edit(BuildContext context, Rec a, VoidCallback reload) async {
    final name = TextEditingController(text: a['name'] ?? '');
    final bank = TextEditingController(text: a['bank'] ?? '');
    final hint = TextEditingController(text: a['account_hint'] ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(a['id'] == null ? 'Add bank account' : 'Edit bank account'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. Meezan Current)')),
            const SizedBox(height: 12),
            TextField(controller: bank, decoration: const InputDecoration(labelText: 'Bank')),
            const SizedBox(height: 12),
            TextField(controller: hint, maxLength: 4, decoration: const InputDecoration(labelText: 'Last 4 digits only', helperText: 'Never store full account numbers')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, name.text.trim().isNotEmpty), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final saved = await runAction(
        context,
        () => Api.instance.saveBankAccount({
          'id': a['id'],
          'name': name.text.trim(),
          'bank': bank.text.trim(),
          'account_hint': hint.text.trim().isEmpty ? null : hint.text.trim(),
        }),
        success: 'Saved',
      );
      if (saved) reload();
    }
  }
}

// --------------------------------------------------------------- import
class BankImportDialog extends StatefulWidget {
  const BankImportDialog({super.key});

  @override
  State<BankImportDialog> createState() => _BankImportDialogState();
}

class _BankImportDialogState extends State<BankImportDialog> {
  List<Rec>? _accounts;
  int? _account;
  String? _fileName, _sha, _error;
  TableData? _table;
  BankParseResult? _parsed;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Api.instance.bankAccounts().then((a) => setState(() {
          _accounts = a.where((x) => x['active'] != false).toList();
          if (_accounts!.length == 1) _account = _accounts!.first['id'] as int;
        }));
  }

  Future<void> _pick() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv', 'html', 'htm', 'txt']);
      if (files.isEmpty) return;
      final bytes = await files.first.xFile.readAsBytes();
      final table = readTable(bytes);
      setState(() {
        _fileName = files.first.name;
        _sha = sha256Hex(bytes);
        _table = table;
        _parsed = parseBankStatement(table);
        _error = null;
      });
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final r = await Api.instance.importBankStatement(_account!, _fileName!, _sha!, _parsed!.rows.map((e) => e.toJson()).toList());
      AppState.dataChanged();
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, 'Imported ${r['inserted']} transactions · ${r['duplicates_skipped']} duplicates skipped');
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _parsed;
    return AlertDialog(
      title: const Text('Import bank statement'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_accounts == null)
              const LinearProgressIndicator()
            else if (_accounts!.isEmpty)
              const Text('Add a bank account first (Bank → Accounts).')
            else
              DropdownButtonFormField<int>(
                initialValue: _account,
                decoration: const InputDecoration(labelText: 'Account'),
                items: [for (final a in _accounts!) DropdownMenuItem(value: a['id'] as int, child: Text('${a['name']}'))],
                onChanged: (v) => setState(() => _account = v),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.attach_file), label: Text(_fileName ?? 'Choose statement (CSV or xlsx)')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            if (p != null) ...[
              const SizedBox(height: 12),
              ExpansionTile(
                title: Text('Column mapping (header row ${p.mapping.headerRow + 1})'),
                initiallyExpanded: p.rows.isEmpty,
                children: [
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    for (final role in bankRoles)
                      SizedBox(
                        width: 220,
                        child: DropdownButtonFormField<int?>(
                          initialValue: p.mapping.single(role.key),
                          isExpanded: true,
                          decoration: InputDecoration(labelText: role.label),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('— none —')),
                            for (var i = 0; i < p.mapping.headers.length; i++)
                              DropdownMenuItem(value: i, child: Text(p.mapping.headers[i].isEmpty ? 'Column ${i + 1}' : p.mapping.headers[i], overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => setState(() => _parsed = parseBankStatement(_table!, mapping: p.mapping.copyWith(role.key, v == null ? [] : [v]))),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 12),
                ],
              ),
              for (final w in p.warnings) Text(w, style: const TextStyle(color: Palette.warning)),
              Text('${p.rows.length} transactions · money in ${rs(p.totalCredit)} · money out ${rs(p.totalDebit)} · ${p.skipped} rows skipped',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              for (final r in p.rows.take(8))
                ListTile(
                  dense: true,
                  title: Text(r.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(dateShort(r.date)),
                  trailing: Text(r.credit > 0 ? '+${rs(r.credit)}' : '−${rs(r.debit)}', style: TextStyle(color: r.credit > 0 ? Palette.positive : null)),
                ),
              if (p.rows.length > 8) Text('…and ${p.rows.length - 8} more'),
              const SizedBox(height: 8),
              const Text('Re-importing an overlapping statement is safe: duplicate transactions are skipped.', style: TextStyle(fontSize: 12)),
            ],
            if (_busy) const LinearProgressIndicator(),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: (_busy || _account == null || p == null || p.rows.isEmpty) ? null : _import,
          child: Text(p == null ? 'Import' : 'Import ${p.rows.length}'),
        ),
      ],
    );
  }
}
