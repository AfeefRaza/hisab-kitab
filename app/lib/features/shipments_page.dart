import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../ui/widgets.dart';
import 'csv_export.dart';

class ShipmentsPage extends StatefulWidget {
  const ShipmentsPage({super.key});

  @override
  State<ShipmentsPage> createState() => _ShipmentsPageState();
}

class _ShipmentsPageState extends State<ShipmentsPage> {
  static const _stuckDays = 5;
  String _view = 'all'; // all | stuck | returning
  String? _courier;
  String? _parcel;
  int _minDays = 0;
  final _search = TextEditingController();
  final _city = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    _city.dispose();
    super.dispose();
  }

  /// Adds computed `days` (since last status update) for display, filtering and sorting.
  List<Rec> _withDays(List<Rec> rows) => [
        for (final r in rows)
          {
            ...r,
            'days': () {
              final d = parseTs(r['status_at']) ?? parseTs(r['fulfilled_at']);
              return d == null ? 0 : DateTime.now().difference(d).inDays;
            }(),
          },
      ];

  bool _match(Rec r) {
    final days = r['days'] as int;
    if (_view == 'stuck' && (days < _stuckDays || r['money_state'] == 'returning')) return false;
    if (_view == 'returning' && r['money_state'] != 'returning') return false;
    if (_courier != null && r['courier'] != _courier) return false;
    if (_parcel != null && r['shipment_status'] != _parcel) return false;
    if (days < _minDays) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty &&
        !['name', 'tracking_number', 'status_raw'].any((k) => '${r[k] ?? ''}'.toLowerCase().contains(q))) {
      return false;
    }
    final c = _city.text.trim().toLowerCase();
    if (c.isNotEmpty && !'${r['city'] ?? ''}'.toLowerCase().contains(c)) return false;
    return true;
  }

  bool get _hasFilters =>
      _courier != null || _parcel != null || _minDays > 0 || _search.text.isNotEmpty || _city.text.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return PageBody(
      title: 'Shipments',
      subtitle: 'Parcels still moving — money on the road. Tracking refreshes automatically every hour.',
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'all', label: Text('All open')),
            ButtonSegment(value: 'stuck', label: Text('Stuck $_stuckDays+ days')),
            ButtonSegment(value: 'returning', label: Text('Returning')),
          ],
          selected: {_view},
          onSelectionChanged: (s) => setState(() => _view = s.first),
        ),
        SectionCard(
          padding: const EdgeInsets.all(12),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 280,
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Order #, tracking, status text'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _city,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.location_city, size: 18), hintText: 'City'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            FilterMenu<String>(
              label: 'Courier',
              value: _courier,
              items: {for (final e in courierNames.entries.where((e) => e.key != 'other')) e.key: e.value},
              onChanged: (v) => setState(() => _courier = v),
            ),
            FilterMenu<String>(
              label: 'Parcel status',
              value: _parcel,
              items: Map.fromEntries(shipmentStatuses.entries.where((e) => !['delivered', 'returned', 'cancelled'].contains(e.key))),
              onChanged: (v) => setState(() => _parcel = v),
            ),
            FilterMenu<int>(
              label: 'No update for',
              value: _minDays == 0 ? null : _minDays,
              items: const {2: '2+ days', 3: '3+ days', 5: '5+ days', 7: '7+ days', 10: '10+ days', 15: '15+ days'},
              onChanged: (v) => setState(() => _minDays = v ?? 0),
            ),
            if (_hasFilters)
              TextButton.icon(
                onPressed: () => setState(() {
                  _courier = _parcel = null;
                  _minDays = 0;
                  _search.clear();
                  _city.clear();
                }),
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Clear filters'),
              ),
          ]),
        ),
        Loader<List<Rec>>(
          watchPeriod: false,
          load: Api.instance.openShipments,
          builder: (context, raw, reload) {
            final all = _withDays(raw);
            final rows = all.where(_match).toList()..sort((a, b) => (b['days'] as int).compareTo(a['days'] as int));
            final value = rows.fold<num>(0, (a, r) => a + toNum(r['current_total']));
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TileGrid(children: [
                KpiCard(label: 'Parcels shown', value: count(rows.length), hint: 'of ${all.length} open', icon: Icons.local_shipping_outlined),
                KpiCard(label: 'Order value on the road', value: rs(value), icon: Icons.payments_outlined),
                KpiCard(
                  label: 'Stuck $_stuckDays+ days',
                  value: count(all.where((r) => (r['days'] as int) >= _stuckDays).length),
                  icon: Icons.hourglass_bottom,
                  color: Palette.warning,
                  onTap: () => setState(() => _view = 'stuck'),
                ),
                KpiCard(
                  label: 'Tracking errors',
                  value: count(all.where((r) => r['check_error'] != null).length),
                  icon: Icons.error_outline,
                  color: Palette.negative,
                ),
              ]),
              const SizedBox(height: 16),
              SectionCard(
                title: '${rows.length} parcels',
                trailing: Wrap(spacing: 4, children: [
                  TextButton.icon(
                    onPressed: rows.isEmpty
                        ? null
                        : () => downloadCsv('shipments.csv', ['Order', 'City', 'Courier', 'Tracking', 'Last status', 'Days', 'Money state', 'COD'], [
                              for (final r in rows)
                                [r['name'], r['city'], courierName(r['courier']), r['tracking_number'], r['status_raw'], r['days'],
                                  MoneyState.fromKey(r['money_state'])?.label, r['current_total']],
                            ]),
                    icon: const Icon(Icons.download),
                    label: const Text('CSV'),
                  ),
                  if (AppState.session.canOperate && rows.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        final ids = rows.map((r) => r['shipment_id'] as int).take(600).toList();
                        final ok = await runAction(context, () => Api.instance.syncTracking(shipmentIds: ids),
                            success: 'Tracking refreshed for ${ids.length} parcels');
                        if (ok) AppState.dataChanged();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh these'),
                    ),
                ]),
                padding: const EdgeInsets.all(8),
                child: DataList(
                  rows: rows,
                  onTap: (r) => context.go('/orders/${r['order_id']}'),
                  empty: const EmptyState(icon: Icons.check_circle_outline, title: 'Nothing here', message: 'No parcels match these filters.'),
                  columns: [
                    Col('Order', (r) => CopyText('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700)), sort: 'name'),
                    Col('City', (r) => Text('${r['city'] ?? ''}'), sort: 'city'),
                    Col('Courier', (r) => Text(courierName(r['courier'])), sort: 'courier'),
                    Col('Tracking', (r) => CopyText('${r['tracking_number']}'), sort: 'tracking_number'),
                    Col('Last status', (r) => SizedBox(
                          width: 220,
                          child: Text('${r['status_raw'] ?? shipmentStatuses[r['shipment_status']]}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        ), sort: 'status_raw'),
                    Col('Days', (r) {
                      final d = r['days'] as int;
                      return Pill('$d d', color: d >= _stuckDays ? Palette.negative : (d >= 3 ? Palette.warning : Palette.positive));
                    }, numeric: true, sort: 'days'),
                    Col('State', (r) => StateChip(r['money_state']), sort: 'money_state'),
                    Col('COD', (r) => Amount(r['current_total']), numeric: true, sort: 'current_total'),
                  ],
                  tile: (r) => ListTile(
                    title: Row(children: [
                      Flexible(child: CopyText('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                      Text(' · ${courierName(r['courier'])}'),
                    ]),
                    subtitle: Text('${r['status_raw'] ?? shipmentStatuses[r['shipment_status']]}\n${r['city'] ?? ''} · ${r['tracking_number']}'),
                    isThreeLine: true,
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Amount(r['current_total']),
                      Text('${r['days']} days', style: TextStyle(color: (r['days'] as int) >= _stuckDays ? Palette.negative : null)),
                    ]),
                  ),
                ),
              ),
            ]);
          },
        ),
      ],
    );
  }
}
