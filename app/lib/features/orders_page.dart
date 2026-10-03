import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../ui/widgets.dart';
import 'csv_export.dart';

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key, this.initialState, this.initialCourier});
  final String? initialState;
  final String? initialCourier;

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  static const _pageSize = 50;
  late String? _state = widget.initialState;
  late String? _courier = widget.initialCourier;
  final _search = TextEditingController();
  Timer? _debounce;
  String _sort = 'created_at_shop';
  bool _asc = false;
  int _page = 0;
  int _version = 0;

  @override
  void didUpdateWidget(OrdersPage old) {
    super.didUpdateWidget(old);
    if (old.initialState != widget.initialState || old.initialCourier != widget.initialCourier) {
      _state = widget.initialState;
      _courier = widget.initialCourier;
      _page = 0;
      _version++;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<({List<Rec> rows, int total})> _load() {
    final p = AppState.period.value;
    return Api.instance.orders(
      from: p.start,
      to: p.end,
      moneyState: _state,
      courier: _courier,
      search: _search.text,
      sort: _sort,
      ascending: _asc,
      page: _page,
      pageSize: _pageSize,
    );
  }

  void _refilter(VoidCallback change) => setState(() {
        change();
        _page = 0;
        _version++;
      });

  Future<void> _export() async {
    final p = AppState.period.value;
    final all = <Rec>[];
    for (var page = 0; page < 200; page++) {
      final r = await Api.instance.orders(
          from: p.start, to: p.end, moneyState: _state, courier: _courier, search: _search.text, page: page, pageSize: 1000);
      all.addAll(r.rows);
      if (all.length >= r.total || r.rows.isEmpty) break;
    }
    downloadCsv('orders-${ymd(p.start)}-to-${ymd(p.end)}.csv', [
      'Order', 'Date', 'Customer', 'Phone', 'City', 'COD', 'Courier', 'Tracking', 'Parcel status', 'Money state',
      'Order total', 'Settled COD', 'Courier cost', 'Courier cost source', 'Revenue', 'Contribution',
    ], [
      for (final r in all)
        [
          r['name'], r['order_date'], r['customer_name'], r['phone'], r['city'], r['is_cod'] == true ? 'COD' : 'Prepaid',
          courierName(r['courier']), r['tracking_number'], r['status_raw'] ?? r['shipment_status'],
          MoneyState.fromKey(r['money_state'])?.label, r['current_total'], r['settled_cod'], r['courier_cost'],
          r['courier_cost_source'], r['revenue'], r['contribution'],
        ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return PageBody(
      title: 'Orders',
      subtitle: 'Every order with its parcel status, money state and profit',
      actions: [
        OutlinedButton.icon(
          onPressed: () => runAction(context, _export, success: 'CSV downloaded'),
          icon: const Icon(Icons.download),
          label: const Text('Export CSV'),
        ),
      ],
      children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 320,
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Order #, customer, phone, tracking, city'),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 400), () => _refilter(() {}));
              },
            ),
          ),
          DropdownMenu<String?>(
            initialSelection: _state,
            label: const Text('Money state'),
            width: 230,
            onSelected: (v) => _refilter(() => _state = v),
            dropdownMenuEntries: [
              const DropdownMenuEntry(value: null, label: 'All states'),
              for (final s in MoneyState.flow) DropdownMenuEntry(value: s.key, label: s.label),
            ],
          ),
          DropdownMenu<String?>(
            initialSelection: _courier,
            label: const Text('Courier'),
            width: 170,
            onSelected: (v) => _refilter(() => _courier = v),
            dropdownMenuEntries: [
              const DropdownMenuEntry(value: null, label: 'All couriers'),
              for (final e in courierNames.entries.where((e) => e.key != 'other')) DropdownMenuEntry(value: e.key, label: e.value),
            ],
          ),
          DropdownMenu<String>(
            initialSelection: '$_sort|$_asc',
            label: const Text('Sort'),
            width: 210,
            onSelected: (v) => _refilter(() {
              final parts = v!.split('|');
              _sort = parts[0];
              _asc = parts[1] == 'true';
            }),
            dropdownMenuEntries: const [
              DropdownMenuEntry(value: 'created_at_shop|false', label: 'Newest first'),
              DropdownMenuEntry(value: 'created_at_shop|true', label: 'Oldest first'),
              DropdownMenuEntry(value: 'current_total|false', label: 'Highest amount'),
              DropdownMenuEntry(value: 'contribution|true', label: 'Lowest profit'),
              DropdownMenuEntry(value: 'contribution|false', label: 'Highest profit'),
              DropdownMenuEntry(value: 'status_at|true', label: 'Oldest status update'),
            ],
          ),
        ]),
        SectionCard(
          padding: const EdgeInsets.all(8),
          child: Loader<({List<Rec> rows, int total})>(
            key: ValueKey(_version),
            load: _load,
            builder: (context, res, _) {
              final pages = (res.total / _pageSize).ceil();
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                DataList(
                  rows: res.rows,
                  onTap: (r) => context.go('/orders/${r['order_id']}'),
                  empty: const EmptyState(icon: Icons.receipt_long_outlined, title: 'No orders match', message: 'Try another period or filter.'),
                  columns: [
                    Col('Order', (r) => Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                    Col('Date', (r) => Text(dateShort(r['created_at_shop']))),
                    Col('Customer', (r) => Text('${r['customer_name'] ?? ''}\n${r['city'] ?? ''}', maxLines: 2)),
                    Col('Courier', (r) => Text('${courierName(r['courier'])}\n${r['tracking_number'] ?? ''}', maxLines: 2)),
                    Col('Parcel', (r) => SizedBox(
                          width: 160,
                          child: Text(
                            '${r['is_manual'] == true ? '✎ ' : ''}${r['status_raw'] ?? shipmentStatuses[r['shipment_status']] ?? '—'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                    Col('Money', (r) => StateChip(r['money_state'])),
                    Col('Amount', (r) => Amount(r['current_total']), numeric: true),
                    Col('Profit', (r) => Amount(r['contribution'], colored: true), numeric: true),
                  ],
                  tile: (r) => ListTile(
                    title: Row(children: [
                      Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      StateChip(r['money_state']),
                    ]),
                    subtitle: Text('${dateShort(r['created_at_shop'])} · ${r['city'] ?? ''} · ${courierName(r['courier'])}\n'
                        '${r['status_raw'] ?? shipmentStatuses[r['shipment_status']] ?? 'Not shipped'}'),
                    isThreeLine: true,
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Amount(r['current_total'], bold: true),
                      Amount(r['contribution'], colored: true, style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
                ),
                if (res.total > 0)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(children: [
                      Expanded(child: Text('${count(res.total)} orders · page ${_page + 1} of $pages')),
                      IconButton(
                        onPressed: _page == 0 ? null : () => setState(() {
                          _page--;
                          _version++;
                        }),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      IconButton(
                        onPressed: _page + 1 >= pages ? null : () => setState(() {
                          _page++;
                          _version++;
                        }),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ]),
                  ),
              ]);
            },
          ),
        ),
      ],
    );
  }
}
