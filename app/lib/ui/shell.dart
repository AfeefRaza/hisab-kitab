import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../data/api.dart';
import 'widgets.dart';

class _Dest {
  const _Dest(this.path, this.label, this.icon);
  final String path;
  final String label;
  final IconData icon;
}

const _destinations = [
  _Dest('/', 'Dashboard', Icons.space_dashboard_outlined),
  _Dest('/orders', 'Orders', Icons.receipt_long_outlined),
  _Dest('/shipments', 'Shipments', Icons.local_shipping_outlined),
  _Dest('/settlements', 'Settlements', Icons.request_quote_outlined),
  _Dest('/bank', 'Bank', Icons.account_balance_outlined),
  _Dest('/expenses', 'Expenses', Icons.payments_outlined),
  _Dest('/profit', 'Profitability', Icons.insights_outlined),
  _Dest('/alerts', 'Alerts', Icons.notifications_active_outlined),
  _Dest('/settings', 'Settings', Icons.settings_outlined),
];

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _alerts = 0;

  @override
  void initState() {
    super.initState();
    _loadAlerts();
    AppState.dataVersion.addListener(_loadAlerts);
  }

  @override
  void dispose() {
    AppState.dataVersion.removeListener(_loadAlerts);
    super.dispose();
  }

  Future<void> _loadAlerts() async {
    try {
      final n = await Api.instance.openAlertCount();
      if (mounted) setState(() => _alerts = n);
    } catch (_) {}
  }

  int get _index {
    final loc = widget.location;
    for (var i = _destinations.length - 1; i >= 0; i--) {
      final p = _destinations[i].path;
      if (p == '/' ? loc == '/' : loc.startsWith(p)) return i;
    }
    if (loc.startsWith('/integrations')) return _destinations.length - 1;
    return 0;
  }

  Widget _icon(_Dest d) {
    final icon = Icon(d.icon);
    if (d.path == '/alerts' && _alerts > 0) {
      return Badge(label: Text(_alerts > 99 ? '99+' : '$_alerts'), child: icon);
    }
    return icon;
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final title = _destinations[_index].label;
    final appBar = AppBar(
      title: Row(children: [
        if (wide) ...[
          const Icon(Icons.menu_book_rounded, color: Color(0xFF0F766E)),
          const SizedBox(width: 8),
          const Text('Hisab Kitab'),
        ] else
          Text(title),
      ]),
      actions: [
        if (wide) const PeriodButton() else const PeriodButton(compact: true),
        IconButton(tooltip: 'Search (orders, tracking, settlements, bank)', icon: const Icon(Icons.search), onPressed: () => openSearch(context)),
        if (AppState.session.canOperate)
          IconButton(tooltip: 'Sync Shopify & couriers now', icon: const Icon(Icons.sync), onPressed: () => runFullSync(context)),
        _UserMenu(),
        const SizedBox(width: 8),
      ],
    );

    if (wide) {
      return Scaffold(
        appBar: appBar,
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => context.go(_destinations[i].path),
            destinations: [
              for (final d in _destinations) NavigationRailDestination(icon: _icon(d), label: Text(d.label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: widget.child),
        ]),
      );
    }
    return Scaffold(
      appBar: appBar,
      drawer: NavigationDrawer(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          Navigator.pop(context);
          context.go(_destinations[i].path);
        },
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(28, 20, 16, 12),
            child: Row(children: [
              Icon(Icons.menu_book_rounded, color: Color(0xFF0F766E)),
              SizedBox(width: 8),
              Text('Hisab Kitab', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
          ),
          for (final d in _destinations) NavigationDrawerDestination(icon: _icon(d), label: Text(d.label)),
        ],
      ),
      body: widget.child,
    );
  }
}

class _UserMenu extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = AppState.session;
    return PopupMenuButton<String>(
      tooltip: s.email,
      icon: CircleAvatar(radius: 15, child: Text(s.email.isEmpty ? '?' : s.email[0].toUpperCase())),
      onSelected: (v) async {
        if (v == 'out') await Supabase.instance.client.auth.signOut();
        if (v == 'integrations' && context.mounted) context.go('/integrations');
      },
      itemBuilder: (_) => [
        PopupMenuItem(enabled: false, child: Text('${s.email}\nRole: ${titleCase(s.role.name)}')),
        if (s.isAdmin) const PopupMenuItem(value: 'integrations', child: Text('Integrations')),
        const PopupMenuItem(value: 'out', child: Text('Sign out')),
      ],
    );
  }
}

/// Shopify order sync (looped until caught up) followed by courier tracking.
Future<void> runFullSync(BuildContext context) async {
  final status = ValueNotifier<String>('Syncing Shopify orders…');
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      content: Row(children: [
        const CircularProgressIndicator(),
        const SizedBox(width: 20),
        Expanded(child: ValueListenableBuilder(valueListenable: status, builder: (_, v, _) => Text(v))),
      ]),
    ),
  );
  String result;
  var failed = false;
  try {
    final o = await Api.instance.syncOrders(onProgress: (p) => status.value = 'Syncing Shopify orders… ${p['total_orders']} updated');
    status.value = 'Checking courier tracking…';
    final t = await Api.instance.syncTracking();
    status.value = 'Fetching courier payments (CPRs)…';
    final p = await Api.instance.syncPayments();
    result = 'Synced ${o['total_orders']} orders · tracked ${t['applied']} parcels · '
        '${p['settled'] ?? 0} payments checked';
  } catch (e) {
    failed = true;
    result = errorText(e);
  }
  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
    showSnack(context, result, error: failed);
  }
  AppState.dataChanged();
}

void openSearch(BuildContext context) {
  showDialog(context: context, builder: (_) => const _SearchDialog());
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog();

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Rec> _results = [];
  bool _loading = false;
  String? _error;

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await Api.instance.globalSearch(q);
      if (mounted) {
        setState(() {
          _results = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(Rec r) {
    Navigator.pop(context);
    switch (r['kind']) {
      case 'order':
        context.go('/orders/${r['id']}');
      case 'settlement':
        context.go('/settlements/${r['id']}');
      case 'bank':
        context.go('/bank');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const icons = {'order': Icons.receipt_long, 'settlement': Icons.request_quote, 'bank': Icons.account_balance};
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              onChanged: _onChanged,
              onSubmitted: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Order #, customer, phone, tracking number, statement, bank text…',
                suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
              ),
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final r in _results)
                ListTile(
                  leading: Icon(icons[r['kind']] ?? Icons.circle),
                  title: Text('${r['title']}'),
                  subtitle: Text('${r['subtitle'] ?? ''} · ${dateShort(r['at'])}'),
                  trailing: Amount(r['amount']),
                  onTap: () => _open(r),
                ),
              if (!_loading && _results.isEmpty && _ctrl.text.trim().length >= 2)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No matches'))),
            ]),
          ),
        ]),
      ),
    );
  }
}
