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
  String? _category; // Transactions filter, set from the Analysis tab

  void _openTransactions(String? category) => setState(() {
        _category = category;
        _tab = 1;
      });

  @override
  Widget build(BuildContext context) {
    final canOp = AppState.session.canOperate;
    return PageBody(
      title: 'Bank & reconciliation',
      subtitle: 'Does the money in and out of the bank match what Shopify, couriers, Meta and your expenses say should happen?',
      actions: [
        if (canOp)
          OutlinedButton.icon(
            onPressed: () async {
              final r = await withProgress(context, 'Matching bank transactions…', (_) => Api.instance.runBankMatching());
              if (r == null) return;
              AppState.dataChanged();
              if (context.mounted) {
                showSnack(context, 'Re-checked: ${r['courier_matches'] ?? 0} courier, ${r['order_matches'] ?? 0} order and '
                    '${r['expense_matches'] ?? 0} expense matches');
              }
            },
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('Re-run matching'),
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
            ButtonSegment(value: 0, label: Text('Analysis'), icon: Icon(Icons.fact_check_outlined)),
            ButtonSegment(value: 1, label: Text('Transactions'), icon: Icon(Icons.list_alt)),
            ButtonSegment(value: 2, label: Text('Rules'), icon: Icon(Icons.rule)),
            ButtonSegment(value: 3, label: Text('Accounts'), icon: Icon(Icons.account_balance)),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        switch (_tab) {
          0 => _AnalysisView(onOpenTransactions: _openTransactions),
          1 => _TransactionsView(key: ValueKey(_category), initialCategory: _category),
          2 => const _RulesView(),
          _ => const _AccountsView(),
        },
      ],
    );
  }
}

// =============================================================== analysis
class _AnalysisView extends StatelessWidget {
  const _AnalysisView({required this.onOpenTransactions});
  final void Function(String? category) onOpenTransactions;

  @override
  Widget build(BuildContext context) {
    return Loader<Rec>(
      load: () => Api.instance.bankReconciliation(AppState.period.value.start, AppState.period.value.end),
      builder: (context, r, reload) {
        final cov = (r['coverage'] as Map).cast<String, dynamic>();
        final totals = (r['totals'] as Map).cast<String, dynamic>();
        final window = (r['window'] as Map?)?.cast<String, dynamic>() ?? {};
        final areas = (r['areas'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        final review = (r['review'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        final dups = (r['duplicates'] as List).cast<Map>();
        final breaks = (r['balance_breaks'] as List).cast<Map>();
        final accounts = (cov['accounts'] as List).cast<Map>();

        if (cov['to'] == null) {
          return SectionCard(
            child: EmptyState(
              icon: Icons.account_balance,
              title: 'Import a bank statement to start',
              message: 'Upload the PDF (or CSV / Excel) statement of the account your couriers and customers pay into. '
                  'Hisab Kitab reads it, categorises every transaction and checks it against Shopify, PostEx, Meta and your expenses.',
              action: AppState.session.canOperate
                  ? FilledButton.icon(
                      onPressed: () => showDialog(context: context, builder: (_) => const BankImportDialog()),
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Import statement'))
                  : null,
            ),
          );
        }

        final moneyIn = toNum(totals['money_in']), moneyOut = toNum(totals['money_out']);
        final explained = moneyIn + moneyOut == 0
            ? null
            : (toNum(totals['explained_in']) + toNum(totals['explained_out'])) / (moneyIn + moneyOut) * 100;
        final problems = areas.where((a) => a['status'] == 'bad' || a['status'] == 'warn').toList();
        final shown = areas.where((a) => a['status'] != 'empty').toList()
          ..sort((a, b) => _rank(a['status']).compareTo(_rank(b['status'])));

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (window['clipped'] == true)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _Banner(
                icon: Icons.date_range,
                color: Palette.info,
                text: 'Compared for ${dateShort(window['from'])} – ${dateShort(window['to'])}: the dates your bank statements cover '
                    '(${dateShort(cov['from'])} – ${dateShort(cov['to'])}). Import more statements to widen it.',
              ),
            ),
          TileGrid(children: [
            KpiCard(label: 'Money in', value: rs(moneyIn), icon: Icons.south_west, color: Palette.positive,
                hint: 'Bank credits in the period'),
            KpiCard(label: 'Money out', value: rs(moneyOut), icon: Icons.north_east, color: Palette.negative,
                hint: 'Bank debits in the period'),
            KpiCard(
              label: 'Explained',
              value: pct(explained, digits: 0),
              hint: 'of the money moving through the bank has a category',
              icon: Icons.fact_check_outlined,
              color: (explained ?? 0) >= 90 ? Palette.positive : Palette.warning,
            ),
            KpiCard(
              label: 'Needs review',
              value: count(totals['review_count']),
              hint: 'in ${rs(totals['review_in'])} · out ${rs(totals['review_out'])} — tap to categorise',
              icon: Icons.help_outline,
              color: toNum(totals['review_count']) > 0 ? Palette.warning : Palette.positive,
              onTap: () => onOpenTransactions('needs_review'),
            ),
            KpiCard(
              label: problems.isEmpty ? 'Reconciliation' : 'Areas to check',
              value: problems.isEmpty ? 'All match' : count(problems.length),
              hint: problems.isEmpty ? 'Bank agrees with Hisab Kitab' : problems.map((a) => a['label']).join(' · '),
              icon: problems.isEmpty ? Icons.verified_outlined : Icons.report_problem_outlined,
              color: problems.isEmpty ? Palette.positive : Palette.negative,
            ),
            for (final a in accounts)
              KpiCard(
                label: '${a['name']} balance',
                value: rs(a['closing']),
                hint: a['to'] == null ? 'No transactions yet' : 'Statement ${dateShort(a['from'])} – ${dateShort(a['to'])}',
                icon: Icons.account_balance,
                color: Palette.info,
              ),
          ]),
          const SizedBox(height: 16),
          for (final b in breaks.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Banner(
                icon: Icons.link_off,
                color: Palette.negative,
                text: 'Statement gap on ${dateShort(b['date'])}: balance ${rs(b['balance'], decimals: true)} should be '
                    '${rs(b['expected'], decimals: true)} — a transaction is missing between two imports. Import the missing statement.',
              ),
            ),
          for (final d in dups.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Banner(
                icon: Icons.copy_all_outlined,
                color: Palette.warning,
                text: 'Possible duplicate payment on ${dateShort(d['date'])}: ${rs(d['amount'])} twice to the same account within 2 days — ${d['description']}',
              ),
            ),
          for (final a in shown) _AreaCard(area: a, reload: reload),
          if (review.isNotEmpty)
            SectionCard(
              title: 'Unmatched — needs review (${review.length})',
              trailing: TextButton(onPressed: () => onOpenTransactions('needs_review'), child: const Text('Open all')),
              padding: const EdgeInsets.all(8),
              child: Column(children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Text('Money that Hisab Kitab cannot explain yet. Categorise it once and tick "always" to create a rule — '
                      'every past and future transaction with that account or name is then categorised automatically.',
                      style: TextStyle(fontSize: 13)),
                ),
                for (final t in review.take(15))
                  ListTile(
                    dense: true,
                    leading: Icon(toNum(t['credit']) > 0 ? Icons.south_west : Icons.north_east,
                        color: toNum(t['credit']) > 0 ? Palette.positive : Palette.negative),
                    title: Text('${t['counterparty'] ?? t['description']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${dateShort(t['date'])}${t['account'] != null ? ' · ${t['account']}' : ''}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(toNum(t['credit']) > 0 ? '+${rs(t['credit'])}' : '−${rs(t['debit'])}',
                          style: TextStyle(fontWeight: FontWeight.w700, color: toNum(t['credit']) > 0 ? Palette.positive : null)),
                      if (AppState.session.canOperate) ...[
                        const SizedBox(width: 8),
                        FilledButton.tonal(onPressed: () => _categoriseById(context, t['id'] as int), child: const Text('Categorise')),
                      ],
                    ]),
                  ),
              ]),
            ),
          _WhereMoneyWent(rows: (r['by_category'] as List).cast<Map>(), onTap: onOpenTransactions),
        ]);
      },
    );
  }

  static int _rank(Object? s) => switch (s) { 'bad' => 0, 'warn' => 1, 'unknown' => 2, 'ok' => 3, _ => 4 };
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.35))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ]),
      );
}

/// Expected → Actual → Difference for one area, with the explanation and the items to check.
class _AreaCard extends StatelessWidget {
  const _AreaCard({required this.area, required this.reload});
  final Rec area;
  final VoidCallback reload;

  @override
  Widget build(BuildContext context) {
    final status = area['status'] as String?;
    final (color, icon, label) = switch (status) {
      'ok' => (Palette.positive, Icons.check_circle, 'Matches'),
      'bad' => (Palette.negative, Icons.error, 'Missing money'),
      'warn' => (Palette.warning, Icons.warning_amber_rounded, 'Difference'),
      _ => (Palette.muted, Icons.help_outline, 'Not verifiable'),
    };
    final items = (area['items'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final diff = toNum(area['difference']);
    final isIn = area['direction'] == 'in';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: color.withValues(alpha: 0.5))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text('${area['label']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              Pill(diff.abs() <= 5 ? label : '$label ${rs(diff.abs())}', color: color),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _Figure(area['expected_label'] as String? ?? 'Expected', area['expected']),
              const Icon(Icons.arrow_forward, size: 18),
              _Figure(area['actual_label'] as String? ?? 'Actual', area['actual']),
              const Icon(Icons.arrow_forward, size: 18),
              _Figure('Matched one-to-one', area['matched']),
              const Icon(Icons.drag_handle, size: 18),
              _Figure(isIn ? 'Not found in bank' : (diff >= 0 ? 'Bank paid more' : 'Not paid from bank'), diff.abs(), color: diff.abs() <= 5 ? Palette.positive : color),
            ]),
            const SizedBox(height: 12),
            Text('${area['explanation']}'),
            if (area['action'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text.rich(TextSpan(children: [
                  const TextSpan(text: 'Action: ', style: TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: '${area['action']}'),
                ])),
              ),
            if (items.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('${items.length} item${items.length == 1 ? '' : 's'} to check', style: const TextStyle(fontWeight: FontWeight.w600)),
                children: [
                  for (final it in items.take(60))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(switch (it['kind']) {
                        'cpr' => Icons.request_quote_outlined,
                        'order' => Icons.receipt_long_outlined,
                        'expense' => Icons.payments_outlined,
                        _ => Icons.account_balance_outlined,
                      }),
                      title: Text('${it['ref'] ?? it['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${dateShort(it['date'])} · ${it['note']}'),
                      trailing: Text(rs(it['amount']), style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () async {
                        switch (it['kind']) {
                          case 'cpr':
                            context.go('/settlements/${it['id']}');
                          case 'order':
                            context.go('/orders/${it['id']}');
                          case 'expense':
                            context.go('/expenses');
                          default:
                            if (AppState.session.canOperate) {
                              await _categoriseById(context, it['id'] as int);
                              reload();
                            }
                        }
                      },
                    ),
                ],
              ),
          ]),
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {this.color});
  final String label;
  final dynamic value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Text(rs(value), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: color)),
      ]);
}

class _WhereMoneyWent extends StatelessWidget {
  const _WhereMoneyWent({required this.rows, required this.onTap});
  final List<Map> rows;
  final void Function(String? category) onTap;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final max = rows.fold<num>(0, (a, r) => [a, toNum(r['in']), toNum(r['out'])].reduce((x, y) => x > y ? x : y));
    return SectionCard(
      title: 'Where the money came from and went',
      child: Column(children: [
        for (final r in rows)
          InkWell(
            onTap: () => onTap(r['category'] as String),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Icon(BankCategory.of(r['category'] as String?)?.icon ?? Icons.help_outline, size: 18,
                    color: BankCategory.of(r['category'] as String?)?.color ?? Palette.warning),
                const SizedBox(width: 8),
                SizedBox(width: 210, child: Text('${BankCategory.labelOf(r['category'] as String?)} (${r['n']})', overflow: TextOverflow.ellipsis)),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: max == 0 ? 0 : ((toNum(r['in']) + toNum(r['out'])) / max).clamp(0, 1).toDouble(),
                      minHeight: 10,
                      color: toNum(r['in']) > 0 ? Palette.positive : (BankCategory.of(r['category'] as String?)?.color ?? Palette.warning),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: Text(toNum(r['in']) > 0 && toNum(r['out']) == 0 ? '+${rs(r['in'])}' : '−${rs(r['out'])}${toNum(r['in']) > 0 ? ' / +${rs(r['in'])}' : ''}',
                      textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

// =============================================================== transactions
class _TransactionsView extends StatefulWidget {
  const _TransactionsView({super.key, this.initialCategory});
  final String? initialCategory;

  @override
  State<_TransactionsView> createState() => _TransactionsViewState();
}

class _TransactionsViewState extends State<_TransactionsView> {
  String _filter = 'all';
  late String? _category = widget.initialCategory;
  int _v = 0;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
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
        FilterMenu<String>(
          label: 'Category',
          value: _category,
          items: {'needs_review': 'Needs review', for (final c in BankCategory.all) c.key: c.label},
          onChanged: (v) => setState(() {
            _category = v;
            _v++;
          }),
        ),
      ]),
      const SizedBox(height: 12),
      Loader<List<Rec>>(
        key: ValueKey(_v),
        load: () => Api.instance.bankTransactions(
            filter: _filter, category: _category, from: AppState.period.value.start, to: AppState.period.value.end),
        builder: (context, rows, reload) {
          return SectionCard(
            title: '${rows.length} transactions in period',
            padding: const EdgeInsets.all(8),
            child: DataList(
              rows: rows,
              onTap: AppState.session.canOperate
                  ? (t) async {
                      await showCategoriseDialog(context, t);
                      reload();
                    }
                  : null,
              empty: const EmptyState(icon: Icons.account_balance, title: 'No bank transactions here', message: 'Import a statement, or change the period / filter.'),
              columns: [
                Col('Date', (t) => Text(dateShort(t['txn_date'])), sort: 'txn_date'),
                Col('Counterparty', (t) => SizedBox(
                      width: 230,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text('${t['counterparty'] ?? _short(t['description'])}', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (t['counterparty_account'] != null) Text('${t['counterparty_account']}', style: const TextStyle(fontSize: 11)),
                      ]),
                    ), sort: 'counterparty'),
                Col('Description', (t) => SizedBox(width: 260, child: Text('${t['description']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))), sort: 'description'),
                Col('Category', (t) => _CategoryPill(t), sort: 'category'),
                Col('In', (t) => toNum(t['credit']) > 0 ? Amount(t['credit'], style: const TextStyle(color: Palette.positive)) : const Text(''), numeric: true, sort: 'credit'),
                Col('Out', (t) => toNum(t['debit']) > 0 ? Amount(t['debit']) : const Text(''), numeric: true, sort: 'debit'),
                Col('Balance', (t) => Amount(t['balance']), numeric: true, sort: 'balance'),
              ],
              tile: (t) => ListTile(
                title: Text('${t['counterparty'] ?? t['description']}', maxLines: 2),
                subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Align(alignment: Alignment.centerLeft, child: _CategoryPill(t))),
                leading: Text(dateShort(t['txn_date']), style: const TextStyle(fontSize: 12)),
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

  static String _short(Object? d) => '$d'.length > 40 ? '${'$d'.substring(0, 40)}…' : '$d';
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill(this.t);
  final Rec t;

  @override
  Widget build(BuildContext context) {
    final c = BankCategory.of(t['category'] as String?);
    final links = <String>[
      if ((t['settlement_bank_matches'] as List? ?? const []).isNotEmpty) '${(t['settlement_bank_matches'] as List).length} CPR',
      for (final m in (t['bank_order_matches'] as List? ?? const []).cast<Map>()) '${(m['orders'] as Map?)?['name'] ?? 'order'}',
      if ((t['expenses'] as List? ?? const []).isNotEmpty) 'expense',
    ];
    final source = switch (t['category_source']) { 'rule' => ' · rule', 'match' => ' · matched', 'manual' => '', 'auto' => ' · auto', _ => '' };
    return Tooltip(
      message: links.isEmpty ? '' : 'Linked to ${links.join(', ')}',
      child: Pill(c == null ? 'Needs review' : '${c.label}$source${links.isEmpty ? '' : ' ✓'}', color: c?.color ?? Palette.warning),
    );
  }
}

Future<void> _categoriseById(BuildContext context, int id) async {
  final t = await Api.instance.bankTransaction(id);
  if (t != null && context.mounted) await showCategoriseDialog(context, t);
}

/// Pick a category; optionally save it as a rule for every transaction with this account or name.
Future<void> showCategoriseDialog(BuildContext context, Rec t) async {
  final isCredit = toNum(t['credit']) > 0;
  final amount = isCredit ? toNum(t['credit']) : toNum(t['debit']);
  String? category = t['category'] as String?;
  String rule = 'once';
  final note = TextEditingController(text: t['note'] as String? ?? '');
  final cats = BankCategory.all.where((c) => c.dir == 'both' || c.dir == (isCredit ? 'in' : 'out')).toList();
  final settlements = (t['settlement_bank_matches'] as List? ?? const []).cast<Map>();
  final orders = (t['bank_order_matches'] as List? ?? const []).cast<Map>();

  final action = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text('${isCredit ? 'Money in' : 'Money out'} · ${rs(amount)}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${dateShort(t['txn_date'])} · ${t['description']}', style: const TextStyle(fontSize: 13)),
              if (t['counterparty'] != null || t['counterparty_account'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${t['counterparty'] ?? ''}${t['counterparty_account'] != null ? '  ·  ${t['counterparty_account']}' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final cat in cats)
                  ChoiceChip(
                    avatar: Icon(cat.icon, size: 18, color: cat.color),
                    label: Text(cat.label),
                    selected: category == cat.key,
                    onSelected: (_) => set(() => category = cat.key),
                  ),
              ]),
              const SizedBox(height: 14),
              const Text('Apply to', style: TextStyle(fontWeight: FontWeight.w700)),
              RadioGroup<String>(
                groupValue: rule,
                onChanged: (v) => set(() => rule = v ?? 'once'),
                child: Column(children: [
                  const RadioListTile(value: 'once', dense: true, title: Text('Only this transaction')),
                  if (t['counterparty_account'] != null)
                    RadioListTile(value: 'account', dense: true,
                        title: Text('Always for account ${t['counterparty_account']}'),
                        subtitle: const Text('Past and future transactions to/from this account')),
                  if (t['counterparty'] != null)
                    RadioListTile(value: 'name', dense: true,
                        title: Text('Always for "${t['counterparty']}"'),
                        subtitle: const Text('Past and future transactions with this name')),
                ]),
              ),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
              if (settlements.isNotEmpty || orders.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Linked', style: TextStyle(fontWeight: FontWeight.w700)),
                for (final m in settlements)
                  ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.request_quote_outlined),
                      title: Text('Courier statement #${m['batch_id']} · ${rs(m['amount'])}'),
                      trailing: TextButton(onPressed: () => Navigator.pop(c, 'unmatch:${m['id']}'), child: const Text('Unlink'))),
                for (final m in orders)
                  ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.receipt_long_outlined),
                      title: Text('Order ${(m['orders'] as Map?)?['name'] ?? m['order_id']} · ${rs(m['amount'])}'),
                      trailing: TextButton(onPressed: () => Navigator.pop(c, 'unorder:${m['id']}'), child: const Text('Unlink'))),
              ],
            ]),
          ),
        ),
        actions: [
          if (!isCredit && (t['expenses'] as List? ?? const []).isEmpty)
            TextButton.icon(onPressed: () => Navigator.pop(c, 'expense'), icon: const Icon(Icons.payments_outlined), label: const Text('Record as expense')),
          if (isCredit) TextButton.icon(onPressed: () => Navigator.pop(c, 'order'), icon: const Icon(Icons.link), label: const Text('Link to order')),
          if (isCredit && settlements.isEmpty)
            TextButton.icon(onPressed: () => Navigator.pop(c, 'cpr'), icon: const Icon(Icons.request_quote_outlined), label: const Text('Match to CPR')),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;

  bool ok = false;
  if (action == 'save') {
    ok = await runAction(context, () async {
      final r = await Api.instance.setBankCategory(t['id'] as int, category, rule: rule == 'once' ? null : rule, note: note.text.trim().isEmpty ? null : note.text.trim());
      if (rule != 'once' && context.mounted) {
        showSnack(context, 'Rule saved — ${r['applied_to']} transaction(s) now categorised as ${BankCategory.labelOf(category)}');
      }
    }, success: rule == 'once' ? 'Saved' : null);
  } else if (action == 'expense') {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => ExpenseDialog(initial: {
        'expense_date': t['txn_date'],
        'amount': t['debit'],
        'vendor': t['counterparty'],
        'description': t['description'],
        'payment_method': 'bank',
        'bank_transaction_id': t['id'],
      }),
    );
    ok = saved == true;
  } else if (action == 'order') {
    final name = await promptText(context, 'Link to which order?', label: 'Order number, e.g. #haven34027', required: true);
    if (name == null || !context.mounted) return;
    ok = await runAction(context, () => Api.instance.linkBankOrder(t['id'] as int, name, amount.toDouble()), success: 'Linked to order');
  } else if (action == 'cpr') {
    ok = await _matchToCpr(context, t, amount);
  } else if (action.startsWith('unmatch:')) {
    ok = await runAction(context, () => Api.instance.unmatch(int.parse(action.substring(8))), success: 'Unlinked');
  } else if (action.startsWith('unorder:')) {
    ok = await runAction(context, () => Api.instance.unlinkBankOrder(int.parse(action.substring(8))), success: 'Unlinked');
  }
  if (ok) AppState.dataChanged();
}

Future<bool> _matchToCpr(BuildContext context, Rec t, num available) async {
  final batches = (await Api.instance.settlementBatches())
      .where((b) => b['voided_at'] == null && b['is_banked'] != true && toNum(b['total_net']) - toNum(b['matched_amount']) > 1)
      .toList()
    ..sort((a, b) => ((toNum(a['total_net']) - toNum(a['matched_amount'])) - available).abs()
        .compareTo(((toNum(b['total_net']) - toNum(b['matched_amount'])) - available).abs()));
  if (!context.mounted) return false;
  final picked = await showDialog<Rec>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Match ${rs(available)} to a courier statement'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: batches.isEmpty
            ? const Center(child: Text('Every courier statement is already matched.'))
            : ListView(children: [
                for (final b in batches.take(40))
                  ListTile(
                    title: Text('${courierName(b['courier'])} · ${b['statement_ref'] ?? b['file_name']}'),
                    subtitle: Text(dateShort(b['statement_date'])),
                    trailing: Text(rs(toNum(b['total_net']) - toNum(b['matched_amount'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                    onTap: () => Navigator.pop(c, b),
                  ),
              ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
    ),
  );
  if (picked == null || !context.mounted) return false;
  final remaining = toNum(picked['total_net']) - toNum(picked['matched_amount']);
  final amount = available < remaining ? available : remaining;
  return runAction(context, () async {
    await Api.instance.matchSettlement(picked['id'] as int, t['id'] as int, amount.toDouble());
    await Api.instance.runBankMatching();
  }, success: 'Matched ${rs(amount)} — partial payments are fine, the rest stays open');
}

// =============================================================== rules
class _RulesView extends StatelessWidget {
  const _RulesView();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.bankRules,
      builder: (context, rows, reload) => SectionCard(
        title: 'Saved rules',
        padding: const EdgeInsets.all(8),
        child: rows.isEmpty
            ? const EmptyState(
                icon: Icons.rule,
                title: 'No rules yet',
                message: 'Open a transaction, choose its category and tick "Always for this account" — '
                    'every past and future transaction with that account is categorised automatically.\n'
                    'Courier accounts are learned on their own when a deposit matches a CPR.')
            : Column(children: [
                for (final r in rows)
                  ListTile(
                    leading: Icon(BankCategory.of(r['category'] as String?)?.icon ?? Icons.label_outline,
                        color: BankCategory.of(r['category'] as String?)?.color),
                    title: Text(switch (r['match_field']) {
                      'account' => 'Account ${r['pattern']}',
                      'name' => 'Name "${r['pattern']}"',
                      _ => 'Description contains "${r['pattern']}"',
                    }),
                    subtitle: Text('→ ${BankCategory.labelOf(r['category'] as String?)}'
                        '${r['label'] != null && r['label'] != r['pattern'] ? ' · ${r['label']}' : ''}'
                        '${r['learned'] == true ? ' · learned automatically' : ''}'),
                    trailing: AppState.session.canOperate
                        ? IconButton(
                            tooltip: 'Delete rule',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final yes = await confirm(context, 'Delete this rule?',
                                  'Transactions it categorised go back to automatic categorisation (manual choices stay).', action: 'Delete', danger: true);
                              if (!yes || !context.mounted) return;
                              final ok = await runAction(context, () => Api.instance.deleteBankRule(r['id'] as int), success: 'Rule deleted');
                              if (ok) {
                                reload();
                                AppState.dataChanged();
                              }
                            },
                          )
                        : null,
                  ),
              ]),
      ),
    );
  }
}

// =============================================================== accounts
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
            ? const EmptyState(icon: Icons.account_balance, title: 'No bank accounts yet', message: 'Import a PDF statement and the account is created for you, or add it here.')
            : Column(children: [
                for (final a in rows)
                  ListTile(
                    leading: const Icon(Icons.account_balance),
                    title: Text('${a['name']}'),
                    subtitle: Text([
                      if (a['bank'] != null && '${a['bank']}'.isNotEmpty) a['bank'],
                      if (a['account_hint'] != null) '••••${a['account_hint']}',
                      if (a['holder_name'] != null) 'Holder: ${a['holder_name']} (transfers to this name count as own-account)',
                      if (a['active'] == false) 'inactive',
                    ].join(' · ')),
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
    final holder = TextEditingController(text: a['holder_name'] ?? '');
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
            TextField(controller: holder, decoration: const InputDecoration(labelText: 'Account holder name', helperText: 'Transfers to this name are your own-account transfers')),
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
        () async {
          await Api.instance.saveBankAccount({
            'id': a['id'],
            'name': name.text.trim(),
            'bank': bank.text.trim(),
            'account_hint': hint.text.trim().isEmpty ? null : hint.text.trim(),
            'holder_name': holder.text.trim().isEmpty ? null : holder.text.trim(),
          });
          await Api.instance.runBankMatching();
        },
        success: 'Saved',
      );
      if (saved) reload();
    }
  }
}

// =============================================================== import
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
  BankParseResult? _parsed; // CSV / Excel
  Rec? _pdf; // PDF: {header, rows, warnings, balance_check}
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final a = await Api.instance.bankAccounts();
    if (!mounted) return;
    setState(() {
      _accounts = a.where((x) => x['active'] != false).toList();
      if (_accounts!.length == 1) _account = _accounts!.first['id'] as int;
    });
  }

  List<BankRow> get _rows {
    if (_pdf != null) {
      return [
        for (final r in (_pdf!['rows'] as List).cast<Map>())
          BankRow(DateTime.parse(r['date'] as String), '${r['description']}', null, toNum(r['debit']).toDouble(),
              toNum(r['credit']).toDouble(), r['balance'] == null ? null : toNum(r['balance']).toDouble()),
      ];
    }
    return _parsed?.rows ?? const [];
  }

  Rec? get _header => (_pdf?['header'] as Map?)?.cast<String, dynamic>();

  Future<void> _pick() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'xlsx', 'xls', 'csv', 'html', 'htm', 'txt']);
      if (files.isEmpty) return;
      final bytes = await files.first.xFile.readAsBytes();
      final name = files.first.name;
      setState(() {
        _busy = true;
        _error = null;
        _pdf = null;
        _parsed = null;
      });
      if (name.toLowerCase().endsWith('.pdf')) {
        final pdf = await Api.instance.parseBankPdf(bytes);
        final h = (pdf['header'] as Map?)?.cast<String, dynamic>() ?? {};
        // pick the account with the same last 4 digits, if it exists
        final match = _accounts?.where((a) => h['account_last4'] != null && a['account_hint'] == h['account_last4']).toList() ?? const [];
        setState(() {
          _pdf = pdf;
          if (match.isNotEmpty) _account = match.first['id'] as int;
        });
      } else {
        final table = readTable(bytes);
        setState(() {
          _table = table;
          _parsed = parseBankStatement(table);
        });
      }
      setState(() {
        _fileName = name;
        _sha = sha256Hex(bytes);
      });
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      var account = _account;
      final h = _header;
      if (account == null && h != null) {
        // first statement from this account: create it from the statement header (last 4 digits only)
        account = await Api.instance.createBankAccount({
          'name': '${h['bank'] ?? 'Bank'}${h['account_last4'] != null ? ' ••${h['account_last4']}' : ''}',
          'bank': h['bank'],
          'account_hint': h['account_last4'],
          'holder_name': h['account_title'],
        });
      }
      final r = await Api.instance.importBankStatement(account!, _fileName!, _sha!, _rows.map((e) => e.toJson()).toList(), meta: h);
      AppState.dataChanged();
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, 'Imported ${r['inserted']} transactions (${r['duplicates_skipped']} duplicates skipped) · '
          'matched ${r['courier_matches'] ?? 0} courier payout(s), ${r['order_matches'] ?? 0} order(s), ${r['expense_matches'] ?? 0} expense(s) · '
          '${toNum(r['by_rule']) + toNum(r['auto'])} categorised automatically');
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _parsed;
    final h = _header;
    final rows = _rows;
    final canCreate = _account == null && h != null;
    final check = (_pdf?['balance_check'] as Map?)?.cast<String, dynamic>();
    final warnings = [...?(_pdf?['warnings'] as List?)?.map((w) => '$w'), ...?p?.warnings];
    return AlertDialog(
      title: const Text('Import bank statement'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('PDF statements from internet banking (e.g. Meezan) are read directly. CSV and Excel exports work too.',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            if (_accounts == null)
              const LinearProgressIndicator()
            else
              DropdownButtonFormField<int?>(
                initialValue: _account,
                decoration: const InputDecoration(labelText: 'Account'),
                items: [
                  if (_accounts!.isEmpty || h != null) const DropdownMenuItem(value: null, child: Text('New account (from the statement)')),
                  for (final a in _accounts!) DropdownMenuItem(value: a['id'] as int, child: Text('${a['name']}')),
                ],
                onChanged: (v) => setState(() => _account = v),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _busy ? null : _pick, icon: const Icon(Icons.attach_file), label: Text(_fileName ?? 'Choose statement (PDF, CSV or Excel)')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            if (h != null) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 16, runSpacing: 6, children: [
                Text('${h['bank'] ?? 'Bank'} ••${h['account_last4'] ?? '????'}', style: const TextStyle(fontWeight: FontWeight.w700)),
                if (h['account_title'] != null) Text('${h['account_title']}'),
                if (h['from'] != null) Text('${dateShort(h['from'])} – ${dateShort(h['to'])}'),
                if (h['opening_balance'] != null) Text('Opening ${rs(h['opening_balance'], decimals: true)}'),
                if (h['closing_balance'] != null) Text('Closing ${rs(h['closing_balance'], decimals: true)}'),
              ]),
              if (check != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Icon(check['ok'] == true ? Icons.verified : Icons.error_outline, color: check['ok'] == true ? Palette.positive : Palette.negative, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(check['ok'] == true
                          ? 'Every row checked against the running balance (${check['checked']} rows) — nothing missing or misread.'
                          : '${check['breaks']} balance break(s) — some rows may be missing or misread. Check the warnings below.'),
                    ),
                  ]),
                ),
              if (canCreate)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('A new bank account will be created from this statement (only the last 4 digits are stored).', style: TextStyle(fontSize: 12)),
                ),
            ],
            if (p != null)
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
            for (final w in warnings) Text(w, style: const TextStyle(color: Palette.warning)),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('${rows.length} transactions · money in ${rs(rows.fold<double>(0, (a, r) => a + r.credit))} · '
                  'money out ${rs(rows.fold<double>(0, (a, r) => a + r.debit))}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              for (final r in rows.take(8))
                ListTile(
                  dense: true,
                  title: Text(r.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(dateShort(r.date)),
                  trailing: Text(r.credit > 0 ? '+${rs(r.credit)}' : '−${rs(r.debit)}', style: TextStyle(color: r.credit > 0 ? Palette.positive : null)),
                ),
              if (rows.length > 8) Text('…and ${rows.length - 8} more'),
              const SizedBox(height: 8),
              const Text('Re-importing an overlapping statement is safe: duplicate transactions are skipped. '
                  'After import every transaction is categorised and matched to CPRs, orders and expenses.', style: TextStyle(fontSize: 12)),
            ],
            if (_busy) const LinearProgressIndicator(),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: (_busy || (_account == null && !canCreate) || rows.isEmpty || _fileName == null) ? null : _import,
          child: Text(rows.isEmpty ? 'Import' : 'Import ${rows.length}'),
        ),
      ],
    );
  }
}
