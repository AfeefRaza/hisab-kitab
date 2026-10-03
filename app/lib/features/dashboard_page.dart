import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../ui/shell.dart';
import '../ui/widgets.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  Future<(Rec, List<Rec>)> _load() async {
    final p = AppState.period.value;
    final results = await Future.wait([
      Api.instance.financeSummary(p.start, p.end),
      Api.instance.financeDaily(p.start, p.end),
    ]);
    return (results[0] as Rec, results[1] as List<Rec>);
  }

  @override
  Widget build(BuildContext context) {
    return Loader<(Rec, List<Rec>)>(
      load: _load,
      builder: (context, data, reload) {
        final (s, daily) = data;
        final pnl = (s['pnl'] as Map).cast<String, dynamic>();
        final states = (s['money_states'] as Map).cast<String, dynamic>();
        final cash = (s['cash'] as Map).cast<String, dynamic>();
        final alerts = (s['open_alerts'] as Map).cast<String, dynamic>();
        final lastSync = (s['last_sync'] as Map?)?.cast<String, dynamic>() ?? {};
        final noData = toNum(pnl['orders']) == 0;

        return PageBody(
          title: 'Where is our money?',
          subtitle: 'Orders placed ${dateShort(AppState.period.value.start)} – ${dateShort(AppState.period.value.end)} · '
              'orders synced ${ago(lastSync['orders'])}, tracking ${ago(lastSync['tracking'])}',
          actions: [
            if (AppState.session.canOperate)
              FilledButton.tonalIcon(onPressed: () => runFullSync(context), icon: const Icon(Icons.sync), label: const Text('Sync now')),
          ],
          children: [
            if (noData)
              SectionCard(
                child: EmptyState(
                  icon: Icons.cloud_sync_outlined,
                  title: 'No orders in this period yet',
                  message: AppState.session.isAdmin
                      ? 'Connect Shopify and your couriers in Integrations, then run a sync.'
                      : 'Pick another period, or ask an admin to run a sync.',
                  action: AppState.session.isAdmin
                      ? FilledButton(onPressed: () => context.go('/integrations'), child: const Text('Open Integrations'))
                      : null,
                ),
              ),
            _MoneyFlowCard(states: states),
            TileGrid(children: [
              KpiCard(
                label: 'Net profit',
                value: rs(pnl['net_profit']),
                hint: 'After courier, product, packaging, returns & expenses',
                icon: Icons.savings_outlined,
                color: toNum(pnl['net_profit']) >= 0 ? Palette.positive : Palette.negative,
                onTap: () => context.go('/profit'),
              ),
              KpiCard(
                label: 'Revenue (delivered)',
                value: rs(pnl['revenue']),
                hint: '${count(pnl['delivered'])} delivered orders · AOV ${rs(pnl['aov'])}',
                icon: Icons.trending_up,
              ),
              KpiCard(
                label: 'Cash still with couriers',
                value: rs(toNum(states['with_courier']?['amount']) + toNum(states['settled_unbanked']?['amount'])),
                hint: 'Delivered but not yet in your bank',
                icon: Icons.account_balance_wallet_outlined,
                color: MoneyState.withCourier.color,
                onTap: () => context.go('/settlements'),
              ),
              KpiCard(
                label: 'Delivery rate',
                value: pct(pnl['delivery_rate']),
                hint: '${count(pnl['returned'])} returned of ${count(toNum(pnl['delivered']) + toNum(pnl['returned']))} completed',
                icon: Icons.local_shipping_outlined,
                color: Palette.info,
                onTap: () => context.go('/profit'),
              ),
              KpiCard(
                label: 'Return losses',
                value: rs(pnl['return_loss']),
                hint: 'Shipping + packaging lost on returns',
                icon: Icons.assignment_return_outlined,
                color: Palette.negative,
                onTap: () => context.go('/orders?state=returned'),
              ),
              KpiCard(
                label: 'Expenses',
                value: rs(pnl['expenses']),
                hint: 'Marketing ${rs(pnl['marketing'])} · ROAS ${pnl['roas'] == null ? '—' : '${pnl['roas']}x'}',
                icon: Icons.payments_outlined,
                color: Palette.warning,
                onTap: () => context.go('/expenses'),
              ),
              KpiCard(
                label: 'Open alerts',
                value: count(toNum(alerts['critical']) + toNum(alerts['warning']) + toNum(alerts['info'])),
                hint: '${alerts['critical']} critical · ${alerts['warning']} warnings',
                icon: Icons.notifications_active_outlined,
                color: toNum(alerts['critical']) > 0 ? Palette.negative : Palette.muted,
                onTap: () => context.go('/alerts'),
              ),
              KpiCard(
                label: 'Settled, awaiting bank',
                value: rs(cash['unbanked_amount']),
                hint: '${cash['unbanked_batches']} courier statement(s) not matched to a deposit',
                icon: Icons.receipt_long_outlined,
                color: MoneyState.settledUnbanked.color,
                onTap: () => context.go('/bank'),
              ),
            ]),
            LayoutBuilder(builder: (context, c) {
              final pl = _PnlCard(pnl: pnl);
              final chart = _DailyChart(daily: daily);
              if (c.maxWidth < 900) return Column(children: [pl, const SizedBox(height: 16), chart]);
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 2, child: pl),
                const SizedBox(width: 16),
                Expanded(flex: 3, child: chart),
              ]);
            }),
            _NoticesCard(pnl: pnl),
          ],
        );
      },
    );
  }
}

class _MoneyFlowCard extends StatelessWidget {
  const _MoneyFlowCard({required this.states});
  final Map<String, dynamic> states;

  @override
  Widget build(BuildContext context) {
    final entries = [
      for (final s in MoneyState.flow)
        if (states[s.key] != null) (s, toNum(states[s.key]['amount']), toNum(states[s.key]['orders']).toInt()),
    ];
    final total = entries.fold<num>(0, (a, e) => a + e.$2);
    return SectionCard(
      title: 'Money by stage',
      trailing: Text('Total ${rs(total)}', style: const TextStyle(fontWeight: FontWeight.w700)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (total > 0)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 22,
              child: Row(children: [
                for (final e in entries)
                  if (e.$2 > 0)
                    Expanded(
                      flex: (e.$2 / total * 1000).round().clamp(1, 1000),
                      child: Tooltip(message: '${e.$1.label}: ${rs(e.$2)}', child: Container(color: e.$1.color)),
                    ),
              ]),
            ),
          ),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth > 1100 ? 4 : (c.maxWidth > 700 ? 3 : (c.maxWidth > 420 ? 2 : 1));
          final w = (c.maxWidth - (cols - 1) * 8) / cols;
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in entries)
              SizedBox(
                width: w,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => context.go('/orders?state=${e.$1.key}'),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: e.$1.color.withValues(alpha: 0.35)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(children: [
                      Icon(e.$1.icon, color: e.$1.color, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e.$1.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${e.$3} orders', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ]),
                      ),
                      Text(rs(e.$2), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              ),
          ]);
        }),
      ]),
    );
  }
}

class _PnlCard extends StatelessWidget {
  const _PnlCard({required this.pnl});
  final Map<String, dynamic> pnl;

  @override
  Widget build(BuildContext context) {
    Widget line(String label, dynamic v, {bool minus = false, bool total = false, String? hint}) {
      final style = TextStyle(fontWeight: total ? FontWeight.w800 : FontWeight.w500, fontSize: total ? 16 : 14);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: style),
              if (hint != null) Text(hint, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
          Amount(minus ? -toNum(v) : v, style: style, colored: total),
        ]),
      );
    }

    return SectionCard(
      title: 'Profit & loss',
      child: Column(children: [
        line('Revenue (delivered, excl. tax)', pnl['revenue']),
        line('Product cost (COGS)', pnl['cogs'], minus: true),
        line('Courier charges', pnl['courier_cost'], minus: true, hint: 'Actual from statements, else rate card'),
        line('Packaging', pnl['packaging_cost'], minus: true),
        const Divider(),
        line('Contribution', pnl['contribution'], total: true, hint: 'Includes ${rs(pnl['return_loss'])} lost on returns'),
        line('Operating expenses', pnl['expenses'], minus: true),
        line('Tax', pnl['tax'], minus: true),
        const Divider(),
        line('Net profit', pnl['net_profit'], total: true),
      ]),
    );
  }
}

class _DailyChart extends StatelessWidget {
  const _DailyChart({required this.daily});
  final List<Rec> daily;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (daily.isEmpty) return const SectionCard(title: 'Daily trend', child: SizedBox(height: 220));
    final sales = <FlSpot>[], contrib = <FlSpot>[];
    for (var i = 0; i < daily.length; i++) {
      sales.add(FlSpot(i.toDouble(), toNum(daily[i]['gross_sales']).toDouble()));
      contrib.add(FlSpot(i.toDouble(), toNum(daily[i]['contribution']).toDouble()));
    }
    final step = (daily.length / 6).ceil().clamp(1, 1000);
    return SectionCard(
      title: 'Daily trend',
      trailing: Wrap(spacing: 12, children: [
        _legend(scheme.primary, 'Gross sales'),
        _legend(Palette.positive, 'Contribution (final orders)'),
      ]),
      child: SizedBox(
        height: 260,
        child: LineChart(LineChartData(
          gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: scheme.outlineVariant.withValues(alpha: 0.4), strokeWidth: 1)),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 56,
                getTitlesWidget: (v, meta) => Text(rsCompact(v).replaceFirst('Rs ', ''), style: const TextStyle(fontSize: 10)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: step.toDouble(),
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i < 0 || i >= daily.length || v != i.toDouble()) return const SizedBox.shrink();
                  final d = DateTime.parse(daily[i]['day'].toString());
                  return Padding(padding: const EdgeInsets.only(top: 6), child: Text('${d.day}/${d.month}', style: const TextStyle(fontSize: 10)));
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${s.barIndex == 0 ? 'Sales' : 'Contribution'}: ${rs(s.y)}',
                    TextStyle(color: s.bar.color, fontWeight: FontWeight.w700, fontSize: 12),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(spots: sales, color: scheme.primary, barWidth: 2.5, dotData: const FlDotData(show: false), isCurved: true, preventCurveOverShooting: true,
                belowBarData: BarAreaData(show: true, color: scheme.primary.withValues(alpha: 0.08))),
            LineChartBarData(spots: contrib, color: Palette.positive, barWidth: 2, dotData: const FlDotData(show: false), isCurved: true, preventCurveOverShooting: true),
          ],
        )),
      ),
    );
  }

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 12)),
      ]);
}

class _NoticesCard extends StatelessWidget {
  const _NoticesCard({required this.pnl});
  final Map<String, dynamic> pnl;

  @override
  Widget build(BuildContext context) {
    final notes = <Widget>[];
    final est = toNum(pnl['courier_cost_estimated_orders']);
    final missing = toNum(pnl['missing_cost_orders']);
    if (est > 0) {
      notes.add(ListTile(
        leading: const Icon(Icons.info_outline, color: Palette.info),
        title: Text('$est completed orders use rate-card courier charges'),
        subtitle: const Text('Import courier settlement statements to replace estimates with actual charges.'),
        onTap: () => context.go('/settlements'),
      ));
    }
    if (missing > 0) {
      notes.add(ListTile(
        leading: const Icon(Icons.warning_amber_rounded, color: Palette.warning),
        title: Text('$missing delivered orders have products with no cost'),
        subtitle: const Text('Set "Cost per item" in Shopify or add a product cost rule.'),
        onTap: () => context.go('/settings?tab=costs'),
      ));
    }
    if (notes.isEmpty) return const SizedBox.shrink();
    return SectionCard(title: 'Accuracy notes', padding: const EdgeInsets.fromLTRB(8, 16, 8, 8), child: Column(children: notes));
  }
}
