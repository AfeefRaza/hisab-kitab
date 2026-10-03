import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../ui/widgets.dart';
import 'csv_export.dart';

class ExpensesPage extends StatelessWidget {
  const ExpensesPage({super.key});

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
        return PageBody(
          title: 'Expenses',
          subtitle: 'Marketing, salaries, rent and every other cost — included in net profit',
          actions: [
            OutlinedButton.icon(
              onPressed: () => downloadCsv('expenses-${ymd(AppState.period.value.start)}.csv',
                  ['Date', 'Category', 'Amount', 'Vendor', 'Description', 'Payment', 'Spread from', 'Spread to'], [
                for (final e in rows)
                  [e['expense_date'], e['expense_categories']?['name'], e['amount'], e['vendor'], e['description'], e['payment_method'], e['period_start'], e['period_end']],
              ]),
              icon: const Icon(Icons.download),
              label: const Text('CSV'),
            ),
            if (canOp)
              OutlinedButton.icon(onPressed: () => _categories(context), icon: const Icon(Icons.category_outlined), label: const Text('Categories')),
            if (canOp)
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
            SectionCard(
              title: 'By category (allocated to this period)',
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
                      const Text('Inventory purchases are shown here but excluded from P&L (product cost is counted per order as COGS).',
                          style: TextStyle(fontSize: 12)),
                    ]),
            ),
            SectionCard(
              title: '${rows.length} expense entries',
              padding: const EdgeInsets.all(8),
              child: DataList(
                rows: rows,
                onTap: canOp
                    ? (e) async {
                        final ok = await showDialog<bool>(context: context, builder: (_) => ExpenseDialog(initial: e));
                        if (ok == true) AppState.dataChanged();
                      }
                    : null,
                empty: const EmptyState(icon: Icons.payments_outlined, title: 'No expenses recorded for this period'),
                columns: [
                  Col('Date', (e) => Text(dateShort(e['expense_date']))),
                  Col('Category', (e) => Text('${e['expense_categories']?['name'] ?? ''}')),
                  Col('Vendor', (e) => Text('${e['vendor'] ?? ''}')),
                  Col('Description', (e) => SizedBox(width: 280, child: Text('${e['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis))),
                  Col('Paid via', (e) => Text('${e['payment_method'] ?? ''}${e['bank_transaction_id'] != null ? ' (bank-linked)' : ''}')),
                  Col('Spread', (e) => Text(e['period_start'] == null ? '' : '${dateShort(e['period_start'])} – ${dateShort(e['period_end'])}')),
                  Col('Amount', (e) => Amount(e['amount'], bold: true), numeric: true),
                ],
                tile: (e) => ListTile(
                  title: Text('${e['expense_categories']?['name'] ?? ''}${e['vendor'] != null ? ' · ${e['vendor']}' : ''}'),
                  subtitle: Text('${dateShort(e['expense_date'])} · ${e['description'] ?? ''}'),
                  trailing: Amount(e['amount'], bold: true),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _categories(BuildContext context) async {
    await showDialog(context: context, builder: (_) => const _CategoriesDialog());
    AppState.dataChanged();
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
