import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../ui/widgets.dart';
import 'csv_export.dart';

class ProfitPage extends StatefulWidget {
  const ProfitPage({super.key});

  @override
  State<ProfitPage> createState() => _ProfitPageState();
}

class _ProfitPageState extends State<ProfitPage> {
  String _dim = 'courier';

  @override
  Widget build(BuildContext context) {
    return PageBody(
      title: 'Profitability',
      subtitle: 'Which couriers, cities and products actually make money (orders placed in the period)',
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'courier', label: Text('By courier'), icon: Icon(Icons.local_shipping_outlined)),
            ButtonSegment(value: 'city', label: Text('By city'), icon: Icon(Icons.location_city)),
            ButtonSegment(value: 'product', label: Text('By product'), icon: Icon(Icons.checkroom)),
          ],
          selected: {_dim},
          onSelectionChanged: (s) => setState(() => _dim = s.first),
        ),
        Loader<List<Rec>>(
          key: ValueKey(_dim),
          load: () => Api.instance.profitBreakdown(AppState.period.value.start, AppState.period.value.end, _dim),
          builder: (context, rows, _) {
            final label = {'courier': 'Courier', 'city': 'City', 'product': 'Product'}[_dim]!;
            String name(Rec r) => _dim == 'courier' ? courierName(r['key']) : '${r['key']}';
            return SectionCard(
              title: '${rows.length} ${label.toLowerCase()}${rows.length == 1 ? '' : 's'}',
              trailing: TextButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('CSV'),
                onPressed: () => downloadCsv('profit-by-$_dim.csv',
                    [label, 'Orders', 'Delivered', 'Returned', 'Delivery %', 'Revenue', 'COGS', 'Courier cost', 'Contribution', 'Open COD'], [
                  for (final r in rows)
                    [name(r), r['orders'], r['delivered'], r['returned'], r['delivery_rate'], r['revenue'], r['cogs'], r['courier_cost'], r['contribution'], r['expected_open']],
                ]),
              ),
              padding: const EdgeInsets.all(8),
              child: DataList(
                rows: rows,
                onTap: _dim == 'courier' ? (r) => context.go('/orders?courier=${r['key']}') : null,
                empty: const EmptyState(icon: Icons.insights_outlined, title: 'No orders in this period'),
                columns: [
                  Col(label, (r) => SizedBox(width: 220, child: Text(name(r), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)))),
                  Col('Orders', (r) => Text(count(r['orders'])), numeric: true),
                  Col('Delivered', (r) => Text(count(r['delivered'])), numeric: true),
                  Col('Returned', (r) => Text(count(r['returned'])), numeric: true),
                  Col('Delivery %', (r) {
                    final v = toNumOrNull(r['delivery_rate']);
                    return Text(pct(v), style: TextStyle(fontWeight: FontWeight.w700, color: v == null ? null : (v < 70 ? Palette.negative : (v < 85 ? Palette.warning : Palette.positive))));
                  }, numeric: true),
                  Col('Revenue', (r) => Amount(r['revenue']), numeric: true),
                  Col('Courier cost', (r) => Amount(r['courier_cost']), numeric: true),
                  Col('Contribution', (r) => Amount(r['contribution'], colored: true, bold: true), numeric: true),
                  Col('Margin', (r) => Text(toNum(r['revenue']) == 0 ? '—' : pct(toNum(r['contribution']) / toNum(r['revenue']) * 100)), numeric: true),
                  Col('Open COD', (r) => Amount(r['expected_open']), numeric: true),
                ],
                tile: (r) => ListTile(
                  title: Text(name(r), maxLines: 2),
                  subtitle: Text('${r['orders']} orders · delivery ${pct(r['delivery_rate'])} · revenue ${rs(r['revenue'])}'),
                  trailing: Amount(r['contribution'], colored: true, bold: true),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
