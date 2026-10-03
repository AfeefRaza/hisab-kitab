import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../ui/widgets.dart';

class OrderDetailPage extends StatelessWidget {
  const OrderDetailPage({super.key, required this.orderId});
  final int orderId;

  Future<(Rec?, List<Rec>, List<Rec>)> _load() async {
    final r = await Future.wait([
      Api.instance.order(orderId),
      Api.instance.orderLines(orderId),
      Api.instance.orderTimeline(orderId),
    ]);
    return (r[0] as Rec?, r[1] as List<Rec>, r[2] as List<Rec>);
  }

  @override
  Widget build(BuildContext context) {
    return Loader<(Rec?, List<Rec>, List<Rec>)>(
      load: _load,
      watchPeriod: false,
      builder: (context, data, reload) {
        final (o, lines, timeline) = data;
        if (o == null) {
          return const EmptyState(icon: Icons.search_off, title: 'Order not found');
        }
        final state = MoneyState.fromKey(o['money_state']);
        return PageBody(
          title: 'Order ${o['name']}',
          subtitle: '${dateTime(o['created_at_shop'])} · ${o['customer_name'] ?? ''} · ${o['city'] ?? ''} · ${o['phone'] ?? ''}',
          actions: [
            OutlinedButton.icon(onPressed: () => context.go('/orders'), icon: const Icon(Icons.arrow_back), label: const Text('All orders')),
            if (AppState.session.canOperate && o['shipment_id'] != null) ...[
              OutlinedButton.icon(
                onPressed: () async {
                  final ok = await runAction(context, () => Api.instance.syncTracking(shipmentIds: [o['shipment_id'] as int]),
                      success: 'Tracking refreshed');
                  if (ok) reload();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh tracking'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _overrideStatus(context, o, reload),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Set status manually'),
              ),
            ],
          ],
          children: [
            if (state != null)
              Card(
                color: state.color.withValues(alpha: 0.08),
                child: ListTile(
                  leading: Icon(state.icon, color: state.color, size: 32),
                  title: Text(state.label, style: TextStyle(fontWeight: FontWeight.w800, color: state.color)),
                  subtitle: Text(state.description),
                  trailing: Amount(o['current_total'], bold: true, style: const TextStyle(fontSize: 18)),
                ),
              ),
            TileGrid(minTileWidth: 200, children: [
              KpiCard(label: 'Order total', value: rs(o['current_total']), hint: o['is_cod'] == true ? 'Cash on delivery' : 'Prepaid'),
              KpiCard(
                label: 'Courier',
                value: courierName(o['courier']),
                hint: '${o['tracking_number'] ?? 'Not shipped'}${o['is_manual'] == true ? ' · manual status' : ''}',
              ),
              KpiCard(
                label: 'Parcel status',
                value: shipmentStatuses[o['shipment_status']] ?? '—',
                hint: '${o['status_raw'] ?? ''}${o['status_at'] != null ? ' · ${ago(o['status_at'])}' : ''}',
              ),
              KpiCard(
                label: 'Settled by courier',
                value: rs(o['settled_cod']),
                hint: o['last_statement_date'] != null
                    ? 'Statement ${dateShort(o['last_statement_date'])}${o['banked_on'] != null ? ' · banked ${dateShort(o['banked_on'])}' : ''}'
                    : 'Not in any statement yet',
              ),
            ]),
            if (o['check_error'] != null)
              Card(
                color: Palette.warning.withValues(alpha: 0.08),
                child: ListTile(leading: const Icon(Icons.warning_amber, color: Palette.warning), title: const Text('Tracking problem'), subtitle: Text('${o['check_error']}')),
              ),
            LayoutBuilder(builder: (context, c) {
              final profit = _ProfitCard(o: o);
              final tl = _TimelineCard(items: timeline);
              if (c.maxWidth < 900) return Column(children: [profit, const SizedBox(height: 16), tl]);
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: profit),
                const SizedBox(width: 16),
                Expanded(child: tl),
              ]);
            }),
            SectionCard(
              title: 'Products',
              child: DataList(
                rows: lines,
                columns: [
                  Col('Product', (l) => Text('${l['title']}${l['variant_title'] != null ? ' — ${l['variant_title']}' : ''}')),
                  Col('SKU', (l) => Text('${l['sku'] ?? ''}')),
                  Col('Qty', (l) => Text('${l['current_quantity']}${l['current_quantity'] != l['quantity'] ? ' (of ${l['quantity']})' : ''}'), numeric: true),
                  Col('Price', (l) => Amount(l['unit_price']), numeric: true),
                  Col('Unit cost', (l) => Amount(l['unit_cost']), numeric: true),
                  Col('Cost source', (l) => Pill('${l['cost_source']}', color: l['cost_source'] == 'none' ? Palette.negative : null)),
                ],
                tile: (l) => ListTile(
                  title: Text('${l['title']}'),
                  subtitle: Text('${l['current_quantity']} × ${rs(l['unit_price'])} · cost ${rs(l['unit_cost'])} (${l['cost_source']})'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _overrideStatus(BuildContext context, Rec o, VoidCallback reload) async {
    String? status = o['is_manual'] == true ? o['shipment_status'] as String? : null;
    final note = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Set parcel status manually'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('A manual status overrides the courier until cleared. It is recorded in the audit log.'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('— Use courier status (clear override) —')),
                  for (final e in shipmentStatuses.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => set(() => status = v),
              ),
              const SizedBox(height: 12),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Reason / note')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result == true && context.mounted) {
      final ok = await runAction(context, () => Api.instance.setShipmentStatus(o['shipment_id'] as int, status, note.text),
          success: 'Status updated');
      if (ok) AppState.dataChanged();
      reload();
    }
  }
}

class _ProfitCard extends StatelessWidget {
  const _ProfitCard({required this.o});
  final Rec o;

  @override
  Widget build(BuildContext context) {
    final finalOrder = o['contribution'] != null;
    Widget line(String l, dynamic v, {bool minus = false, bool total = false, String? hint}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(hint == null ? l : '$l  ($hint)', style: TextStyle(fontWeight: total ? FontWeight.w800 : null))),
            Amount(minus ? -toNum(v) : v, colored: total, bold: total),
          ]),
        );
    return SectionCard(
      title: 'Order profit',
      child: Column(children: [
        line('Revenue', o['revenue']),
        line('Tax collected (excluded)', o['total_tax']),
        line('Product cost', o['is_delivered'] == true ? o['cogs'] : 0, minus: true),
        line('Courier charges', o['courier_cost'], minus: true, hint: switch (o['courier_cost_source']) {
          'actual' => 'from settlement',
          'courier_api' => 'courier per-parcel fee',
          _ => 'rate card estimate',
        }),
        if (toNum(o['cod_withholding_tax']) > 0) line('  of which COD tax', o['cod_withholding_tax']),
        line('Packaging', o['packaging_cost'], minus: true),
        const Divider(),
        if (finalOrder)
          line('Contribution', o['contribution'], total: true)
        else
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.hourglass_empty),
            title: Text('Profit is recognised when the parcel is delivered or returned.'),
          ),
      ]),
    );
  }
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.items});
  final List<Rec> items;

  static const _icons = {
    'order': Icons.shopping_bag_outlined,
    'shipment': Icons.local_shipping_outlined,
    'tracking': Icons.place_outlined,
    'manual': Icons.edit_outlined,
    'settlement': Icons.request_quote_outlined,
    'bank': Icons.account_balance_outlined,
    'refund': Icons.money_off,
    'cancelled': Icons.block,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'Financial timeline',
      child: items.isEmpty
          ? const Text('No events yet')
          : Column(children: [
              for (var i = 0; i < items.length; i++)
                IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Column(children: [
                      CircleAvatar(radius: 14, backgroundColor: scheme.primaryContainer, child: Icon(_icons[items[i]['kind']] ?? Icons.circle, size: 15)),
                      if (i < items.length - 1) Expanded(child: VerticalDivider(width: 2, thickness: 2, color: scheme.outlineVariant)),
                    ]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(child: Text('${items[i]['title']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                            if (items[i]['amount'] != null) Amount(items[i]['amount']),
                          ]),
                          Text(
                            [dateTime(items[i]['at']), if ((items[i]['detail'] ?? '').toString().isNotEmpty) items[i]['detail']].join(' · '),
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ]),
                      ),
                    ),
                  ]),
                ),
            ]),
    );
  }
}
