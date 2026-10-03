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
  String? _parcel;
  bool? _cod;
  final _search = TextEditingController();
  final _city = TextEditingController();
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
    _city.dispose();
    super.dispose();
  }

  bool get _hasFilters =>
      _state != null || _courier != null || _parcel != null || _cod != null || _search.text.isNotEmpty || _city.text.isNotEmpty;

  Future<({List<Rec> rows, int total})> _query({int page = 0, int pageSize = _pageSize}) {
    final p = AppState.period.value;
    return Api.instance.orders(
      from: p.start,
      to: p.end,
      moneyState: _state,
      courier: _courier,
      shipmentStatus: _parcel,
      isCod: _cod,
      city: _city.text,
      search: _search.text,
      sort: _sort,
      ascending: _asc,
      page: page,
      pageSize: pageSize,
    );
  }

  void _refilter(VoidCallback change) => setState(() {
        change();
        _page = 0;
        _version++;
      });

  void _typed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _refilter(() {}));
  }

  Future<void> _export() async {
    final p = AppState.period.value;
    final all = <Rec>[];
    for (var page = 0; page < 200; page++) {
      final r = await _query(page: page, pageSize: 1000);
      all.addAll(r.rows);
      if (all.length >= r.total || r.rows.isEmpty) break;
    }
    await downloadCsv('orders-${ymd(p.start)}-to-${ymd(p.end)}.csv', [
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
      subtitle: 'Every order with its parcel status, money state and profit · click a column header to sort',
      actions: [
        OutlinedButton.icon(
          onPressed: () => runAction(context, _export, success: 'CSV downloaded'),
          icon: const Icon(Icons.download),
          label: const Text('Export CSV'),
        ),
      ],
      children: [
        SectionCard(
          padding: const EdgeInsets.all(12),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 300,
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Order #, customer, phone, tracking'),
                onChanged: (_) => _typed(),
              ),
            ),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _city,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.location_city, size: 18), hintText: 'City'),
                onChanged: (_) => _typed(),
              ),
            ),
            FilterMenu<String>(
              label: 'Money state',
              value: _state,
              items: {for (final s in MoneyState.flow) s.key: s.label},
              onChanged: (v) => _refilter(() => _state = v),
            ),
            FilterMenu<String>(
              label: 'Parcel status',
              value: _parcel,
              items: shipmentStatuses,
              onChanged: (v) => _refilter(() => _parcel = v),
            ),
            FilterMenu<String>(
              label: 'Courier',
              value: _courier,
              items: {for (final e in courierNames.entries.where((e) => e.key != 'other')) e.key: e.value},
              onChanged: (v) => _refilter(() => _courier = v),
            ),
            FilterMenu<bool>(
              label: 'Payment',
              value: _cod,
              items: const {true: 'Cash on delivery', false: 'Prepaid'},
              onChanged: (v) => _refilter(() => _cod = v),
            ),
            if (_hasFilters)
              TextButton.icon(
                onPressed: () => _refilter(() {
                  _state = _courier = _parcel = null;
                  _cod = null;
                  _search.clear();
                  _city.clear();
                }),
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Clear filters'),
              ),
          ]),
        ),
        SectionCard(
          padding: const EdgeInsets.all(8),
          child: Loader<({List<Rec> rows, int total})>(
            key: ValueKey(_version),
            load: () => _query(page: _page),
            builder: (context, res, _) {
              final pages = (res.total / _pageSize).ceil();
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                DataList(
                  rows: res.rows,
                  sortField: _sort,
                  sortAscending: _asc,
                  onSort: (f, asc) => _refilter(() {
                    _sort = f;
                    _asc = asc;
                  }),
                  onTap: (r) => context.go('/orders/${r['order_id']}'),
                  empty: const EmptyState(icon: Icons.receipt_long_outlined, title: 'No orders match', message: 'Try another period or clear filters.'),
                  columns: [
                    Col('Order', (r) => CopyText('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700)), sort: 'name'),
                    Col('Date', (r) => Text(dateShort(r['created_at_shop'])), sort: 'created_at_shop'),
                    Col('Customer', (r) => Text('${r['customer_name'] ?? ''}\n${r['city'] ?? ''}', maxLines: 2), sort: 'city'),
                    Col('Courier / tracking', (r) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(courierName(r['courier'])),
                          if (r['tracking_number'] != null) CopyText('${r['tracking_number']}', style: const TextStyle(fontSize: 12)),
                        ]), sort: 'courier'),
                    Col('Parcel', (r) => SizedBox(
                          width: 160,
                          child: Text(
                            '${r['is_manual'] == true ? '✎ ' : ''}${r['status_raw'] ?? shipmentStatuses[r['shipment_status']] ?? '—'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ), sort: 'status_at'),
                    Col('Money', (r) => StateChip(r['money_state']), sort: 'money_state'),
                    Col('Amount', (r) => Amount(r['current_total']), numeric: true, sort: 'current_total'),
                    Col('Courier cost', (r) => Amount(r['courier_cost']), numeric: true, sort: 'courier_cost'),
                    Col('Profit', (r) => Amount(r['contribution'], colored: true), numeric: true, sort: 'contribution'),
                  ],
                  tile: (r) => ListTile(
                    title: Row(children: [
                      Flexible(child: CopyText('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
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
                        tooltip: 'Previous page',
                        onPressed: _page == 0 ? null : () => setState(() {
                          _page--;
                          _version++;
                        }),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      IconButton(
                        tooltip: 'Next page',
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
