import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../ui/widgets.dart';
import 'csv_export.dart';

class ExpensesPage extends StatefulWidget {
  const ExpensesPage({super.key});

  @override
  State<ExpensesPage> createState() => _ExpensesPageState();
}

class _ExpensesPageState extends State<ExpensesPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final canOp = AppState.session.canOperate;
    return PageBody(
      title: 'Expenses',
      subtitle: 'Marketing, salaries, rent and every other cost — included in net profit',
      actions: [
        if (canOp)
          OutlinedButton.icon(onPressed: () => _categories(context), icon: const Icon(Icons.category_outlined), label: const Text('Categories')),
        if (canOp && _tab == 1)
          FilledButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(context: context, builder: (_) => const RecurringDialog());
              if (ok == true) AppState.dataChanged();
            },
            icon: const Icon(Icons.event_repeat),
            label: const Text('Add recurring'),
          ),
        if (canOp && _tab == 0)
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await runAction(context, () async {
                final r = await Api.instance.syncAdSpend();
                if (context.mounted) showSnack(context, 'Ad spend synced: ${rs(r['total_spend'])} over ${r['synced_days']} days');
              });
              if (ok) AppState.dataChanged();
            },
            icon: const Icon(Icons.campaign_outlined),
            label: const Text('Sync ad spend'),
          ),
        if (canOp && _tab == 0)
          FilledButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(context: context, builder: (_) => const ExpenseDialog());
              if (ok == true) AppState.dataChanged();
            },
            icon: const Icon(Icons.add),
            label: const Text('Add expense'),
          ),
      ],
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Expenses in period'), icon: Icon(Icons.receipt_long)),
            ButtonSegment(value: 1, label: Text('Recurring (monthly)'), icon: Icon(Icons.event_repeat)),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        if (_tab == 0) const _EntriesView() else const _RecurringView(),
      ],
    );
  }

  Future<void> _categories(BuildContext context) async {
    await showDialog(context: context, builder: (_) => const _CategoriesDialog());
    AppState.dataChanged();
  }
}

class _EntriesView extends StatelessWidget {
  const _EntriesView();

  Future<(List<Rec>, List<Rec>)> _load() async {
    final p = AppState.period.value;
    final r = await Future.wait([Api.instance.expenses(p.start, p.end), Api.instance.expensesInPeriod(p.start, p.end)]);
    return (r[0], r[1]);
  }

  @override
  Widget build(BuildContext context) {
    final canOp = AppState.session.canOperate;
    return Loader<(List<Rec>, List<Rec>)>(
      load: _load,
      builder: (context, data, reload) {
        final (rows, byCat) = data;
        final total = byCat.fold<num>(0, (a, r) => a + toNum(r['amount']));
        byCat.sort((a, b) => toNum(b['amount']).compareTo(toNum(a['amount'])));
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionCard(
            title: 'By category (allocated to ${AppState.period.label.toLowerCase()})',
            trailing: Text(rs(total), style: const TextStyle(fontWeight: FontWeight.w800)),
            child: byCat.isEmpty
                ? const Text('No expenses in this period')
                : Column(children: [
                    for (final c in byCat)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          SizedBox(width: 180, child: Text('${c['category']}', overflow: TextOverflow.ellipsis)),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: total == 0 ? 0 : (toNum(c['amount']) / total).toDouble(),
                                minHeight: 10,
                                color: c['kind'] == 'marketing' ? Palette.warning : (c['kind'] == 'inventory' ? Palette.muted : Palette.info),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(width: 110, child: Align(alignment: Alignment.centerRight, child: Amount(c['amount'], bold: true))),
                        ]),
                      ),
                    const SizedBox(height: 8),
                    const Text('A spread expense counts only its share of days inside the period. '
                        'Inventory purchases are shown but excluded from P&L (product cost is counted per order).',
                        style: TextStyle(fontSize: 12)),
                  ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: '${rows.length} expense entries affecting this period',
            trailing: TextButton.icon(
              onPressed: () => downloadCsv('expenses-${ymd(AppState.period.value.start)}.csv',
                  ['Paid on', 'Category', 'Amount', 'Vendor', 'Description', 'Payment', 'Applies from', 'Applies to', 'Recurring'], [
                for (final e in rows)
                  [e['expense_date'], e['category_name'], e['amount'], e['vendor'], e['description'], e['payment_method'],
                    e['period_start'] ?? e['expense_date'], e['period_end'] ?? e['expense_date'], e['recurring_id'] != null ? 'yes' : ''],
              ]),
              icon: const Icon(Icons.download),
              label: const Text('CSV'),
            ),
            padding: const EdgeInsets.all(8),
            child: DataList(
              rows: rows,
              onTap: canOp
                  ? (e) async {
                      if (e['source'] == 'triplewhale') {
                        showSnack(context, 'Synced automatically from Triple Whale — it updates on every sync.');
                        return;
                      }
                      final ok = await showDialog<bool>(context: context, builder: (_) => ExpenseDialog(initial: e));
                      if (ok == true) AppState.dataChanged();
                    }
                  : null,
              empty: const EmptyState(icon: Icons.payments_outlined, title: 'No expenses for this period'),
              columns: [
                Col('Applies to', (e) => Text(e['period_start'] == null
                    ? dateShort(e['expense_date'])
                    : '${dateShort(e['period_start'])} – ${dateShort(e['period_end'])}'), sort: 'applies_from'),
                Col('Category', (e) => Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('${e['category_name'] ?? ''}'),
                      if (e['recurring_id'] != null) ...[const SizedBox(width: 6), const Pill('Monthly', color: Palette.info)],
                      if (e['source'] == 'triplewhale') ...[const SizedBox(width: 6), const Pill('Auto · Triple Whale', color: Palette.positive)],
                    ]), sort: 'category_name'),
                Col('Vendor', (e) => Text('${e['vendor'] ?? ''}'), sort: 'vendor'),
                Col('Description', (e) => SizedBox(width: 260, child: Text('${e['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis))),
                Col('Paid on', (e) => Text(dateShort(e['expense_date'])), sort: 'expense_date'),
                Col('Paid via', (e) => Text('${e['payment_method'] ?? ''}${e['bank_transaction_id'] != null ? ' (bank-linked)' : ''}'), sort: 'payment_method'),
                Col('Amount', (e) => Amount(e['amount'], bold: true), numeric: true, sort: 'amount'),
              ],
              tile: (e) => ListTile(
                title: Text('${e['category_name'] ?? ''}${e['vendor'] != null ? ' · ${e['vendor']}' : ''}'),
                subtitle: Text(e['period_start'] == null
                    ? dateShort(e['expense_date'])
                    : '${dateShort(e['period_start'])} – ${dateShort(e['period_end'])}${e['recurring_id'] != null ? ' · monthly' : ''}'),
                trailing: Amount(e['amount'], bold: true),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _RecurringView extends StatelessWidget {
  const _RecurringView();

  @override
  Widget build(BuildContext context) {
    final canOp = AppState.session.canOperate;
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.recurringExpenses,
      builder: (context, rows, reload) {
        final monthly = rows.where((r) => r['active'] == true && r['end_month'] == null).fold<num>(0, (a, r) => a + toNum(r['amount']));
        return SectionCard(
          title: 'Recurring expenses',
          trailing: Text('Active: ${rs(monthly)} / month', style: const TextStyle(fontWeight: FontWeight.w800)),
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('Each rule adds one expense every month, counted in that month\'s P&L. '
                  'To change one month (e.g. a bonus), edit that month\'s entry in "Expenses in period". '
                  'Deleting a month\'s entry skips that month for good.'),
            ),
            DataList(
              rows: [for (final r in rows) {...r, 'category_name': r['expense_categories']?['name']}],
              onTap: canOp
                  ? (r) async {
                      final ok = await showDialog<bool>(context: context, builder: (_) => RecurringDialog(initial: r));
                      if (ok == true) AppState.dataChanged();
                    }
                  : null,
              empty: EmptyState(
                icon: Icons.event_repeat,
                title: 'No recurring expenses yet',
                message: 'Add rent, salaries, subscriptions once — they are added automatically every month.',
                action: canOp
                    ? FilledButton.icon(
                        onPressed: () async {
                          final ok = await showDialog<bool>(context: context, builder: (_) => const RecurringDialog());
                          if (ok == true) AppState.dataChanged();
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Add recurring expense'),
                      )
                    : null,
              ),
              columns: [
                Col('Category', (r) => Text('${r['category_name'] ?? ''}'), sort: 'category_name'),
                Col('Vendor / paid to', (r) => Text('${r['vendor'] ?? ''}'), sort: 'vendor'),
                Col('Every month on', (r) => Text('day ${r['day_of_month']}'), sort: 'day_of_month'),
                Col('From', (r) => Text(PeriodState.monthLabel(DateTime.parse('${r['start_month']}'))), sort: 'start_month'),
                Col('Until', (r) => Text(r['end_month'] == null ? 'ongoing' : PeriodState.monthLabel(DateTime.parse('${r['end_month']}')))),
                Col('Status', (r) => Pill(r['active'] == true ? 'Active' : 'Paused', color: r['active'] == true ? Palette.positive : Palette.muted)),
                Col('Amount', (r) => Amount(r['amount'], bold: true), numeric: true, sort: 'amount'),
              ],
              tile: (r) => ListTile(
                title: Text('${r['category_name'] ?? ''}${r['vendor'] != null ? ' · ${r['vendor']}' : ''}'),
                subtitle: Text('Day ${r['day_of_month']} each month · from ${PeriodState.monthLabel(DateTime.parse('${r['start_month']}'))}'
                    '${r['active'] == true ? '' : ' · paused'}'),
                trailing: Amount(r['amount'], bold: true),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class RecurringDialog extends StatefulWidget {
  const RecurringDialog({super.key, this.initial = const {}});
  final Map<String, dynamic> initial;

  @override
  State<RecurringDialog> createState() => _RecurringDialogState();
}

class _RecurringDialogState extends State<RecurringDialog> {
  late final Map<String, dynamic> _r = {...widget.initial};
  late final _amount = TextEditingController(text: _r['amount']?.toString() ?? '');
  late final _vendor = TextEditingController(text: _r['vendor'] ?? '');
  late final _desc = TextEditingController(text: _r['description'] ?? '');
  late int _day = (_r['day_of_month'] as int?) ?? 1;
  late int? _category = _r['category_id'] as int?;
  late String? _method = _r['payment_method'] as String? ?? 'bank';
  late DateTime _start = DateTime.tryParse('${_r['start_month']}') ?? DateTime(DateTime.now().year, DateTime.now().month, 1);
  late DateTime? _end = DateTime.tryParse('${_r['end_month']}');
  late bool _active = _r['active'] != false;
  List<Rec> _cats = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Api.instance.expenseCategories().then((c) {
      if (mounted) setState(() => _cats = c.where((x) => x['active'] != false || x['id'] == _category).toList());
    });
  }

  List<DateTime> get _months {
    final now = DateTime.now();
    return [for (var i = -24; i <= 12; i++) DateTime(now.year, now.month + i, 1)];
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.replaceAll(',', ''));
    if (amount == null || amount <= 0 || _category == null) {
      showSnack(context, 'Enter an amount and choose a category', error: true);
      return;
    }
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      () => Api.instance.saveRecurring({
        'id': _r['id'],
        'category_id': _category,
        'amount': amount,
        'vendor': _vendor.text.trim().isEmpty ? null : _vendor.text.trim(),
        'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        'payment_method': _method,
        'day_of_month': _day,
        'start_month': ymd(_start),
        'end_month': _end == null ? null : ymd(_end!),
        'active': _active,
      }),
      success: 'Saved — monthly entries created up to this month',
    );
    if (mounted) {
      setState(() => _busy = false);
      if (ok) Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final months = _months;
    DropdownMenuItem<DateTime> monthItem(DateTime m) => DropdownMenuItem(value: m, child: Text(PeriodState.monthLabel(m)));
    return AlertDialog(
      title: Text(_r['id'] == null ? 'Add recurring expense' : 'Edit recurring expense'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<int>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Category (e.g. Rent, Salaries)'),
              items: [for (final c in _cats) DropdownMenuItem(value: c['id'] as int, child: Text('${c['name']}'))],
              onChanged: (v) => setState(() => _category = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount per month (Rs)')),
            const SizedBox(height: 12),
            TextField(controller: _vendor, decoration: const InputDecoration(labelText: 'Paid to (landlord, staff names…)')),
            const SizedBox(height: 12),
            TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Description (optional)')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<DateTime>(
                  initialValue: months.contains(_start) ? _start : null,
                  decoration: const InputDecoration(labelText: 'Starting month'),
                  items: [for (final m in months) monthItem(m)],
                  onChanged: (v) => setState(() => _start = v ?? _start),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _day,
                  decoration: const InputDecoration(labelText: 'Paid on day'),
                  items: [for (var d = 1; d <= 28; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                  onChanged: (v) => setState(() => _day = v ?? 1),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            DropdownButtonFormField<DateTime?>(
              initialValue: _end != null && months.contains(_end) ? _end : null,
              decoration: const InputDecoration(labelText: 'Ends after'),
              items: [
                const DropdownMenuItem<DateTime?>(value: null, child: Text('Ongoing (no end)')),
                for (final m in months.where((m) => !m.isBefore(_start))) DropdownMenuItem<DateTime?>(value: m, child: Text(PeriodState.monthLabel(m))),
              ],
              onChanged: (v) => setState(() => _end = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _method,
              decoration: const InputDecoration(labelText: 'Paid via'),
              items: [for (final m in ['bank', 'cash', 'card', 'wallet', 'other']) DropdownMenuItem(value: m, child: Text(titleCase(m)))],
              onChanged: (v) => setState(() => _method = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              subtitle: const Text('Pause to stop adding new months (past months stay)'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            if (_r['id'] == null)
              Text('Entries are created for every month from ${PeriodState.monthLabel(_start)} up to this month, then automatically each month.',
                  style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ),
      actions: [
        if (_r['id'] != null)
          TextButton(
            onPressed: () async {
              if (!await confirm(context, 'Delete this recurring expense?',
                  'Future months stop. Months already added stay in your expenses (delete them there if needed).',
                  action: 'Delete', danger: true)) {
                return;
              }
              if (!context.mounted) return;
              final ok = await runAction(context, () => Api.instance.deleteRecurring(_r['id'] as int), success: 'Deleted');
              if (ok && context.mounted) Navigator.pop(context, true);
            },
            child: const Text('Delete'),
          ),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}

class ExpenseDialog extends StatefulWidget {
  const ExpenseDialog({super.key, this.initial = const {}});
  final Map<String, dynamic> initial;

  @override
  State<ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends State<ExpenseDialog> {
  late final Map<String, dynamic> _e = {...widget.initial};
  late final _amount = TextEditingController(text: _e['amount']?.toString() ?? '');
  late final _vendor = TextEditingController(text: _e['vendor'] ?? '');
  late final _desc = TextEditingController(text: _e['description'] ?? '');
  late DateTime _date = DateTime.tryParse('${_e['expense_date']}') ?? DateTime.now();
  late DateTime? _from = DateTime.tryParse('${_e['period_start']}');
  late DateTime? _to = DateTime.tryParse('${_e['period_end']}');
  late int? _category = _e['category_id'] as int?;
  late String? _method = _e['payment_method'] as String? ?? 'bank';
  List<Rec> _cats = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Api.instance.expenseCategories().then((c) {
      if (mounted) setState(() => _cats = c.where((x) => x['active'] != false || x['id'] == _category).toList());
    });
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.replaceAll(',', ''));
    if (amount == null || amount <= 0 || _category == null) {
      showSnack(context, 'Enter an amount and choose a category', error: true);
      return;
    }
    setState(() => _busy = true);
    final ok = await runAction(context, () => Api.instance.saveExpense({
          'id': _e['id'],
          'expense_date': ymd(_date),
          'category_id': _category,
          'amount': amount,
          'vendor': _vendor.text.trim().isEmpty ? null : _vendor.text.trim(),
          'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
          'payment_method': _method,
          'bank_transaction_id': _e['bank_transaction_id'],
          'period_start': _from == null ? null : ymd(_from!),
          'period_end': _to == null ? null : ymd(_to!),
        }), success: 'Expense saved');
    if (mounted) {
      setState(() => _busy = false);
      if (ok) Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_e['id'] == null ? 'Add expense' : 'Edit expense'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<int>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [for (final c in _cats) DropdownMenuItem(value: c['id'] as int, child: Text('${c['name']}'))],
              onChanged: (v) => setState(() => _category = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount (Rs)')),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(2100), initialDate: _date);
                if (d != null) setState(() => _date = d);
              },
              icon: const Icon(Icons.event),
              label: Text('Date: ${dateShort(_date)}'),
            ),
            const SizedBox(height: 12),
            TextField(controller: _vendor, decoration: const InputDecoration(labelText: 'Vendor / paid to')),
            const SizedBox(height: 12),
            TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _method,
              decoration: const InputDecoration(labelText: 'Paid via'),
              items: [for (final m in ['bank', 'cash', 'card', 'wallet', 'other']) DropdownMenuItem(value: m, child: Text(titleCase(m)))],
              onChanged: (v) => setState(() => _method = v),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Spread over a period'),
              subtitle: const Text('e.g. a yearly subscription allocated month by month'),
              value: _from != null,
              onChanged: (v) => setState(() {
                if (v) {
                  _from = DateTime(_date.year, _date.month, 1);
                  _to = DateTime(_date.year + 1, _date.month, 0);
                } else {
                  _from = _to = null;
                }
              }),
            ),
            if (_from != null)
              OutlinedButton(
                onPressed: () async {
                  final r = await showDateRangePicker(
                      context: context, firstDate: DateTime(2020), lastDate: DateTime(2100), initialDateRange: DateTimeRange(start: _from!, end: _to!));
                  if (r != null) {
                    setState(() {
                      _from = r.start;
                      _to = r.end;
                    });
                  }
                },
                child: Text('${dateShort(_from)} – ${dateShort(_to)}'),
              ),
          ]),
        ),
      ),
      actions: [
        if (_e['id'] != null)
          TextButton(
            onPressed: () async {
              if (!await confirm(context, 'Delete expense?', 'This cannot be undone (it stays in the audit log).', action: 'Delete', danger: true)) return;
              if (!context.mounted) return;
              final ok = await runAction(context, () => Api.instance.deleteExpense(_e['id'] as int), success: 'Deleted');
              if (ok && context.mounted) Navigator.pop(context, true);
            },
            child: const Text('Delete'),
          ),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}

class _CategoriesDialog extends StatefulWidget {
  const _CategoriesDialog();

  @override
  State<_CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends State<_CategoriesDialog> {
  int _v = 0;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Expense categories'),
      content: SizedBox(
        width: 460,
        height: 460,
        child: Loader<List<Rec>>(
          key: ValueKey(_v),
          watchPeriod: false,
          load: Api.instance.expenseCategories,
          builder: (context, cats, _) => ListView(children: [
            for (final c in cats)
              SwitchListTile(
                title: Text('${c['name']}'),
                subtitle: Text(titleCase('${c['kind']}')),
                value: c['active'] != false,
                onChanged: (v) async {
                  await runAction(context, () => Api.instance.saveCategory({'id': c['id'], 'active': v}));
                  setState(() => _v++);
                },
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final name = await promptText(context, 'New category', label: 'Name', required: true);
            if (name == null || !context.mounted) return;
            final kind = await showDialog<String>(
              context: context,
              builder: (c) => SimpleDialog(title: const Text('Type'), children: [
                for (final k in ['marketing', 'operating', 'payroll', 'inventory', 'tax', 'other'])
                  SimpleDialogOption(onPressed: () => Navigator.pop(c, k), child: Text(titleCase(k))),
              ]),
            );
            if (kind == null || !context.mounted) return;
            await runAction(context, () => Api.instance.saveCategory({'name': name, 'kind': kind}), success: 'Category added');
            setState(() => _v++);
          },
          child: const Text('Add category'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}
