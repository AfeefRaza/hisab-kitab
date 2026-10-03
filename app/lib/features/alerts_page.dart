import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../ui/widgets.dart';

const _kindLabels = {
  'settlement_overdue': 'COD not settled',
  'cod_mismatch': 'COD mismatch',
  'unknown_settlement_parcel': 'Unknown parcel in statement',
  'settled_but_returned': 'Settled but returned',
  'duplicate_settlement': 'Paid twice',
  'bank_deposit_missing': 'Deposit missing in bank',
  'stuck_shipment': 'Stuck parcel',
  'courier_overcharge': 'High courier charge',
  'cancelled_but_delivered': 'Cancelled but delivered',
  'tracking_error': 'Tracking error',
};

class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  String _status = 'open';
  String? _kind;
  int _v = 0;

  Color _sev(String s) => switch (s) { 'critical' => Palette.negative, 'warning' => Palette.warning, _ => Palette.info };

  void _open(Rec a) {
    switch (a['entity_type']) {
      case 'order':
        context.go('/orders/${a['entity_id']}');
      case 'settlement_batch':
        context.go('/settlements/${a['entity_id']}');
      default:
        context.go('/settlements');
    }
  }

  Future<void> _resolve(Rec a, String status) async {
    final note = await promptText(context, status == 'ignored' ? 'Ignore this alert?' : 'Mark as resolved',
        label: 'Note (what was done / why)', required: status == 'ignored');
    if (note == null || !mounted) return;
    final ok = await runAction(context, () => Api.instance.setAlertStatus(a['id'] as int, status, note), success: 'Alert updated');
    if (ok) AppState.dataChanged();
  }

  @override
  Widget build(BuildContext context) {
    return PageBody(
      title: 'Alerts & reconciliation',
      subtitle: 'Everything where money does not add up — refreshed after every sync and import',
      actions: [
        if (AppState.session.canOperate)
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await runAction(context, () async {
                final r = await Api.instance.refreshAlerts();
                if (context.mounted) showSnack(context, '${r['open']} open · ${r['auto_resolved']} auto-resolved');
              });
              if (ok) AppState.dataChanged();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Re-check now'),
          ),
      ],
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'open', label: Text('Open')),
              ButtonSegment(value: 'resolved', label: Text('Resolved')),
              ButtonSegment(value: 'ignored', label: Text('Ignored')),
            ],
            selected: {_status},
            onSelectionChanged: (s) => setState(() {
              _status = s.first;
              _v++;
            }),
          ),
        ]),
        Loader<List<Rec>>(
          key: ValueKey(_v),
          watchPeriod: false,
          load: () => Api.instance.alerts(status: _status),
          builder: (context, all, _) {
            final kinds = <String, int>{};
            for (final a in all) {
              kinds[a['kind'] as String] = (kinds[a['kind']] ?? 0) + 1;
            }
            const order = {'critical': 0, 'warning': 1, 'info': 2};
            final rows = all.where((a) => _kind == null || a['kind'] == _kind).toList()
              ..sort((a, b) => (order[a['severity']] ?? 3).compareTo(order[b['severity']] ?? 3));
            final money = rows.fold<num>(0, (s, a) => s + toNum(a['amount']).abs());
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilterChip(label: Text('All (${all.length})'), selected: _kind == null, onSelected: (_) => setState(() => _kind = null)),
                for (final e in kinds.entries)
                  FilterChip(
                    label: Text('${_kindLabels[e.key] ?? titleCase(e.key)} (${e.value})'),
                    selected: _kind == e.key,
                    onSelected: (_) => setState(() => _kind = _kind == e.key ? null : e.key),
                  ),
              ]),
              const SizedBox(height: 12),
              SectionCard(
                title: '${rows.length} alerts',
                trailing: Text('Money involved ${rs(money)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                padding: const EdgeInsets.all(8),
                child: rows.isEmpty
                    ? EmptyState(
                        icon: Icons.verified_outlined,
                        title: _status == 'open' ? 'All clear' : 'Nothing here',
                        message: _status == 'open' ? 'No reconciliation problems found.' : null,
                      )
                    : Column(children: [
                        for (final a in rows)
                          ListTile(
                            onTap: () => _open(a),
                            leading: Icon(
                              a['severity'] == 'critical' ? Icons.error : (a['severity'] == 'warning' ? Icons.warning_amber_rounded : Icons.info_outline),
                              color: _sev(a['severity'] as String),
                            ),
                            title: Text('${a['title']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text([
                              _kindLabels[a['kind']] ?? a['kind'],
                              if (a['detail'] != null) a['detail'],
                              'since ${dateShort(a['first_seen_at'])}',
                              if (a['resolution_note'] != null) 'note: ${a['resolution_note']}',
                            ].join(' · ')),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              if (a['amount'] != null) Amount(a['amount']),
                              if (_status == 'open' && AppState.session.canOperate)
                                PopupMenuButton<String>(
                                  onSelected: (v) => _resolve(a, v),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'resolved', child: Text('Mark resolved')),
                                    PopupMenuItem(value: 'ignored', child: Text('Ignore (won’t come back)')),
                                  ],
                                ),
                            ]),
                          ),
                      ]),
              ),
            ]);
          },
        ),
      ],
    );
  }
}
