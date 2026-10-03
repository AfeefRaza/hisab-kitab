import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../ui/widgets.dart';

class ShipmentsPage extends StatefulWidget {
  const ShipmentsPage({super.key});

  @override
  State<ShipmentsPage> createState() => _ShipmentsPageState();
}

class _ShipmentsPageState extends State<ShipmentsPage> {
  String? _courier;
  String _view = 'all'; // all | stuck | returning
  int _version = 0;
  static const _stuckDays = 5;

  int _days(Rec r) {
    final d = parseTs(r['status_at']) ?? parseTs(r['fulfilled_at']);
    return d == null ? 0 : DateTime.now().difference(d).inDays;
  }

  @override
  Widget build(BuildContext context) {
    return PageBody(
      title: 'Shipments',
      subtitle: 'Parcels still moving — money on the road. Tracking refreshes automatically every hour.',
      children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('All open')),
              ButtonSegment(value: 'stuck', label: Text('Stuck $_stuckDays+ days')),
              ButtonSegment(value: 'returning', label: Text('Returning')),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
          DropdownMenu<String?>(
            initialSelection: _courier,
            label: const Text('Courier'),
            width: 170,
            onSelected: (v) => setState(() {
              _courier = v;
              _version++;
            }),
            dropdownMenuEntries: [
              const DropdownMenuEntry(value: null, label: 'All couriers'),
              for (final e in courierNames.entries.where((e) => e.key != 'other')) DropdownMenuEntry(value: e.key, label: e.value),
            ],
          ),
        ]),
        Loader<List<Rec>>(
          key: ValueKey(_version),
          watchPeriod: false,
          load: () => Api.instance.openShipments(courier: _courier),
          builder: (context, all, reload) {
            final rows = all.where((r) {
              if (_view == 'stuck') return _days(r) >= _stuckDays && r['money_state'] != 'returning';
              if (_view == 'returning') return r['money_state'] == 'returning';
              return true;
            }).toList()
              ..sort((a, b) => _days(b).compareTo(_days(a)));
            final value = rows.fold<num>(0, (a, r) => a + toNum(r['current_total']));
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TileGrid(children: [
                KpiCard(label: 'Parcels', value: count(rows.length), icon: Icons.local_shipping_outlined),
                KpiCard(label: 'Order value on the road', value: rs(value), icon: Icons.payments_outlined),
                KpiCard(
                  label: 'Stuck $_stuckDays+ days',
                  value: count(all.where((r) => _days(r) >= _stuckDays).length),
                  icon: Icons.hourglass_bottom,
                  color: Palette.warning,
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
                trailing: AppState.session.canOperate && rows.isNotEmpty
                    ? TextButton.icon(
                        onPressed: () async {
                          final ids = rows.map((r) => r['shipment_id'] as int).take(600).toList();
                          final ok = await runAction(context, () => Api.instance.syncTracking(shipmentIds: ids),
                              success: 'Tracking refreshed for ${ids.length} parcels');
                          if (ok) AppState.dataChanged();
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh these'),
                      )
                    : null,
                padding: const EdgeInsets.all(8),
                child: DataList(
                  rows: rows,
                  onTap: (r) => context.go('/orders/${r['order_id']}'),
                  empty: const EmptyState(icon: Icons.check_circle_outline, title: 'Nothing here', message: 'No parcels in this view.'),
                  columns: [
                    Col('Order', (r) => Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                    Col('City', (r) => Text('${r['city'] ?? ''}')),
                    Col('Courier', (r) => Text('${courierName(r['courier'])}\n${r['tracking_number']}')),
                    Col('Last status', (r) => SizedBox(
                          width: 220,
                          child: Text('${r['status_raw'] ?? shipmentStatuses[r['shipment_status']]}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        )),
                    Col('Days', (r) {
                      final d = _days(r);
                      return Pill('$d d', color: d >= _stuckDays ? Palette.negative : (d >= 3 ? Palette.warning : Palette.positive));
                    }, numeric: true),
                    Col('State', (r) => StateChip(r['money_state'])),
                    Col('COD', (r) => Amount(r['current_total']), numeric: true),
                  ],
                  tile: (r) => ListTile(
                    title: Text('${r['name']} · ${courierName(r['courier'])}'),
                    subtitle: Text('${r['status_raw'] ?? shipmentStatuses[r['shipment_status']]}\n${r['city'] ?? ''} · ${r['tracking_number']}'),
                    isThreeLine: true,
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Amount(r['current_total']),
                      Text('${_days(r)} days', style: TextStyle(color: _days(r) >= _stuckDays ? Palette.negative : null)),
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
