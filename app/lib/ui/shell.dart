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
    AppState.dataVersion.addListener(_loadAlerts);
    AppState.store.addListener(_onStore);
    AppState.store.ensureLoaded().then((_) => _loadAlerts());
  }

  @override
  void dispose() {
    AppState.dataVersion.removeListener(_loadAlerts);
    AppState.store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAlerts() async {
    if (!AppState.store.ready) return;
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
    final store = AppState.store;
    final Widget body = store.ready
        // Keyed by store so every page reloads from scratch on a switch
        ? KeyedSubtree(key: ValueKey(store.currentId), child: widget.child)
        : Center(
            child: store.error == null
                ? const CircularProgressIndicator()
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('Could not load stores: ${store.error}'),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: store.load, child: const Text('Retry')),
                  ]),
          );
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
        if (wide) const StoreSwitcher(),
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
          Expanded(child: body),
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
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: StoreSwitcher(expanded: true)),
          const Divider(indent: 16, endIndent: 16),
          for (final d in _destinations) NavigationDrawerDestination(icon: _icon(d), label: Text(d.label)),
        ],
      ),
      body: body,
    );
  }
}

/// Shows the current store; switches stores and (admins) opens store management.
class StoreSwitcher extends StatelessWidget {
  const StoreSwitcher({super.key, this.expanded = false});
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final st = AppState.store;
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) {
        final label = Row(mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min, children: [
          const Icon(Icons.storefront_outlined, size: 20),
          const SizedBox(width: 8),
          Flexible(
            fit: expanded ? FlexFit.tight : FlexFit.loose,
            child: Text(st.currentName.isEmpty ? 'Store' : st.currentName,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Icon(Icons.arrow_drop_down),
        ]);
        return PopupMenuButton<String>(
          tooltip: 'Switch store',
          onSelected: (v) async {
            if (v == '__manage') {
              await showDialog(context: context, builder: (_) => const ManageStoresDialog());
              return;
            }
            final router = GoRouter.of(context);
            if (expanded) Navigator.of(context).maybePop(); // close the drawer
            await st.select(v);
            router.go('/');
          },
          itemBuilder: (_) => [
            for (final s in st.stores)
              CheckedPopupMenuItem(value: s['id'] as String, checked: s['id'] == st.currentId, child: Text('${s['name']}')),
            if (AppState.session.isAdmin) ...[
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: '__manage',
                child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.edit_outlined), title: Text('Manage stores…')),
              ),
            ],
          ],
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: label),
        );
      },
    );
  }
}

/// Admin: add and rename stores. A new store starts with no data and its own
/// integrations to connect; categories, rate cards and settings are copied as defaults.
class ManageStoresDialog extends StatefulWidget {
  const ManageStoresDialog({super.key});

  @override
  State<ManageStoresDialog> createState() => _ManageStoresDialogState();
}

class _ManageStoresDialogState extends State<ManageStoresDialog> {
  Future<void> _add() async {
    final name = await promptText(context, 'New store', label: 'Store name', required: true);
    if (name == null || name.isEmpty || !mounted) return;
    String? id;
    final ok = await runAction(context, () async {
      id = await Api.instance.createStore(name);
      await AppState.store.load();
    }, success: 'Store "$name" created');
    if (!ok || id == null || !mounted) return;
    final go = await confirm(context, 'Switch to $name?',
        'Open the new store now and connect its Shopify, couriers and Triple Whale under Integrations.',
        action: 'Switch & connect');
    if (!go || !mounted) return;
    final router = GoRouter.of(context);
    Navigator.pop(context);
    await AppState.store.select(id!);
    router.go('/integrations');
  }

  Future<void> _rename(Rec s) async {
    final name = await promptText(context, 'Rename store', label: 'Store name', initial: '${s['name']}', required: true);
    if (name == null || name.isEmpty || !mounted) return;
    await runAction(context, () async {
      await Api.instance.renameStore(s['id'] as String, name);
      await AppState.store.load();
    }, success: 'Renamed');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Stores'),
      content: SizedBox(
        width: 420,
        child: ListenableBuilder(
          listenable: AppState.store,
          builder: (_, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Each store has its own Shopify shop, courier and Triple Whale connections, orders, settlements, '
                'bank statements, expenses and settings. Users and roles are shared.'),
            const SizedBox(height: 12),
            for (final s in AppState.store.stores)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(s['id'] == AppState.store.currentId ? Icons.check_circle : Icons.storefront_outlined),
                title: Text('${s['name']}'),
                subtitle: Text('Created ${dateShort(s['created_at'])}'),
                trailing: IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(s)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add store')),
      ],
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
    var ads = '';
    try {
      status.value = 'Fetching ad spend (Triple Whale)…';
      final a = await Api.instance.syncAdSpend();
      ads = ' · ad spend ${a['synced_days']} days';
    } catch (_) {
      // Triple Whale not connected — not an error for the overall sync
    }
    result = 'Synced ${o['total_orders']} orders · tracked ${t['applied']} parcels · '
        '${p['settled'] ?? 0} payments checked$ads';
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
