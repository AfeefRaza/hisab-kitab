import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../ui/widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.initialTab});
  final String? initialTab;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _tab = widget.initialTab ?? 'costs';

  @override
  Widget build(BuildContext context) {
    final admin = AppState.session.isAdmin;
    return PageBody(
      title: 'Settings',
      subtitle: 'Business costs, rules, sync, users and audit trail',
      actions: [
        if (admin)
          FilledButton.tonalIcon(onPressed: () => context.go('/integrations'), icon: const Icon(Icons.hub_outlined), label: const Text('Integrations')),
      ],
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<String>(
            segments: [
              const ButtonSegment(value: 'costs', label: Text('Costs & rules'), icon: Icon(Icons.calculate_outlined)),
              const ButtonSegment(value: 'sync', label: Text('Sync'), icon: Icon(Icons.sync)),
              if (admin) const ButtonSegment(value: 'users', label: Text('Users'), icon: Icon(Icons.group_outlined)),
              if (admin) const ButtonSegment(value: 'audit', label: Text('Audit log'), icon: Icon(Icons.history)),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
        ),
        switch (_tab) {
          'sync' => const _SyncTab(),
          'users' => const _UsersTab(),
          'audit' => const _AuditTab(),
          _ => const _CostsTab(),
        },
      ],
    );
  }
}

// ------------------------------------------------------------------ costs
class _CostsTab extends StatelessWidget {
  const _CostsTab();

  @override
  Widget build(BuildContext context) {
    return const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _BusinessSettings(),
      SizedBox(height: 16),
      _CostRules(),
      SizedBox(height: 16),
      _RateCards(),
    ]);
  }
}

class _BusinessSettings extends StatelessWidget {
  const _BusinessSettings();

  static const _fields = <(String, String, String, String)>[
    ('packaging', 'flyer_per_parcel', 'Flyer / box per parcel', 'Rs'),
    ('packaging', 'polybag_per_unit', 'Polybag per unit', 'Rs'),
    ('tax', 'income_tax_percent', 'Income tax on net profit', '%'),
    ('returns', 'inventory_loss_percent', 'Product value lost on a return', '%'),
    ('returns', 'count_packaging_on_return', 'Count packaging as lost on returns (1 = yes, 0 = no)', ''),
    ('reconciliation', 'settlement_overdue_days', 'Alert if delivered COD unsettled after', 'days'),
    ('reconciliation', 'bank_match_window_days', 'Bank deposit expected within', 'days'),
    ('reconciliation', 'bank_match_tolerance', 'Bank match tolerance', 'Rs'),
    ('reconciliation', 'cod_mismatch_tolerance', 'COD mismatch tolerance', 'Rs'),
    ('reconciliation', 'stuck_days', 'Parcel is stuck after no update for', 'days'),
  ];

  @override
  Widget build(BuildContext context) {
    return Loader<Map<String, Rec>>(
      watchPeriod: false,
      load: Api.instance.settings,
      builder: (context, settings, reload) {
        final ctrls = {
          for (final f in _fields) '${f.$1}.${f.$2}': TextEditingController(text: '${settings[f.$1]?[f.$2] ?? 0}'),
        };
        return SectionCard(
          title: 'Business costs & thresholds',
          trailing: AppState.session.isAdmin
              ? FilledButton(
                  onPressed: () async {
                    final updated = <String, Rec>{};
                    for (final f in _fields) {
                      final v = num.tryParse(ctrls['${f.$1}.${f.$2}']!.text.trim());
                      if (v == null || v < 0) {
                        showSnack(context, '${f.$3}: enter a non-negative number', error: true);
                        return;
                      }
                      updated.putIfAbsent(f.$1, () => {...?settings[f.$1]})[f.$2] = v;
                    }
                    final ok = await runAction(context, () async {
                      for (final e in updated.entries) {
                        await Api.instance.saveSetting(e.key, e.value);
                      }
                    }, success: 'Settings saved — all figures recalculated');
                    if (ok) AppState.dataChanged();
                  },
                  child: const Text('Save'),
                )
              : null,
          child: Wrap(spacing: 16, runSpacing: 16, children: [
            for (final f in _fields)
              SizedBox(
                width: 300,
                child: TextField(
                  controller: ctrls['${f.$1}.${f.$2}'],
                  enabled: AppState.session.isAdmin,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: f.$3, suffixText: f.$4),
                ),
              ),
          ]),
        );
      },
    );
  }
}

class _CostRules extends StatelessWidget {
  const _CostRules();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.costRules,
      builder: (context, rules, reload) => SectionCard(
        title: 'Product cost rules',
        trailing: AppState.session.canOperate
            ? TextButton.icon(onPressed: () => _edit(context, {}, reload), icon: const Icon(Icons.add), label: const Text('Add rule'))
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Used only when a product has no "Cost per item" in Shopify. Most specific match wins: variant → SKU → keyword → default.',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          DataList(
            rows: rules,
            onTap: AppState.session.canOperate ? (r) => _edit(context, r, reload) : null,
            columns: [
              Col('Name', (r) => Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
              Col('Match', (r) => Text('${titleCase('${r['match_type']}')}${r['match_value'] != null ? ': ${r['match_value']}' : ''}')),
              Col('Unit cost', (r) => Amount(r['unit_cost']), numeric: true),
              Col('From', (r) => Text(dateShort(r['effective_from']))),
              Col('Active', (r) => Icon(r['active'] == true ? Icons.check : Icons.close, size: 18)),
            ],
            tile: (r) => ListTile(
              title: Text('${r['name']}'),
              subtitle: Text('${r['match_type']}: ${r['match_value'] ?? 'everything'}'),
              trailing: Amount(r['unit_cost']),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _edit(BuildContext context, Rec r, VoidCallback reload) async {
    final name = TextEditingController(text: r['name'] ?? '');
    final value = TextEditingController(text: r['match_value'] ?? '');
    final cost = TextEditingController(text: r['unit_cost']?.toString() ?? '');
    final priority = TextEditingController(text: '${r['priority'] ?? 100}');
    var type = (r['match_type'] as String?) ?? 'keyword';
    var active = r['active'] != false;
    var from = DateTime.tryParse('${r['effective_from']}') ?? DateTime(2000);
    final res = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(r['id'] == null ? 'Add cost rule' : 'Edit cost rule'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Match by'),
                  items: const [
                    DropdownMenuItem(value: 'keyword', child: Text('Title keywords (comma-separated)')),
                    DropdownMenuItem(value: 'sku', child: Text('Exact SKU')),
                    DropdownMenuItem(value: 'variant', child: Text('Shopify variant ID')),
                    DropdownMenuItem(value: 'default', child: Text('Default (everything else)')),
                  ],
                  onChanged: (v) => set(() => type = v!),
                ),
                if (type != 'default') ...[
                  const SizedBox(height: 12),
                  TextField(controller: value, decoration: const InputDecoration(labelText: 'Match value')),
                ],
                const SizedBox(height: 12),
                TextField(controller: cost, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Unit cost (Rs)')),
                const SizedBox(height: 12),
                TextField(controller: priority, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Priority (lower wins)')),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    final d = await showDatePicker(context: c, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDate: from);
                    if (d != null) set(() => from = d);
                  },
                  child: Text('Effective from ${dateShort(from)}'),
                ),
                SwitchListTile(title: const Text('Active'), value: active, onChanged: (v) => set(() => active = v)),
              ]),
            ),
          ),
          actions: [
            if (r['id'] != null) TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == null || !context.mounted) return;
    bool ok;
    if (res == 'delete') {
      ok = await runAction(context, () => Api.instance.deleteCostRule(r['id'] as int), success: 'Rule deleted');
    } else {
      final c = num.tryParse(cost.text);
      if (name.text.trim().isEmpty || c == null || c < 0) {
        showSnack(context, 'Name and a valid cost are required', error: true);
        return;
      }
      ok = await runAction(
        context,
        () => Api.instance.saveCostRule({
          'id': r['id'],
          'name': name.text.trim(),
          'match_type': type,
          'match_value': type == 'default' ? null : value.text.trim(),
          'unit_cost': c,
          'priority': int.tryParse(priority.text) ?? 100,
          'effective_from': ymd(from),
          'active': active,
        }),
        success: 'Rule saved',
      );
    }
    if (ok) {
      reload();
      AppState.dataChanged();
    }
  }
}

class _RateCards extends StatelessWidget {
  const _RateCards();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.rateCards,
      builder: (context, rows, reload) => SectionCard(
        title: 'Courier rate cards',
        trailing: AppState.session.canOperate
            ? TextButton.icon(onPressed: () => _edit(context, {}, reload), icon: const Icon(Icons.add), label: const Text('Add rate'))
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Courier charges come per parcel from the courier (PostEx API / statements). These rates are only a fallback when the courier gives no figure. '
              'COD tax % is deducted from every delivered parcel COD. Add a new row with a later date when rates change.',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          DataList(
            rows: rows,
            onTap: AppState.session.canOperate ? (r) => _edit(context, r, reload) : null,
            columns: [
              Col('Courier', (r) => Text(courierName(r['courier']), style: const TextStyle(fontWeight: FontWeight.w700))),
              Col('Delivery', (r) => Amount(r['delivery_charge']), numeric: true),
              Col('Extra on return', (r) => Amount(r['return_charge']), numeric: true),
              Col('COD fee', (r) => Text(pct(r['cod_fee_percent'], digits: 2)), numeric: true),
              Col('COD tax', (r) => Text(pct(r['cod_tax_percent'], digits: 2)), numeric: true),
              Col('From', (r) => Text(dateShort(r['effective_from']))),
            ],
            tile: (r) => ListTile(
              title: Text(courierName(r['courier'])),
              subtitle: Text('Delivery ${rs(r['delivery_charge'])} · return +${rs(r['return_charge'])} · COD tax ${pct(r['cod_tax_percent'], digits: 2)} · from ${dateShort(r['effective_from'])}'),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _edit(BuildContext context, Rec r, VoidCallback reload) async {
    var courier = (r['courier'] as String?) ?? 'postex';
    final del = TextEditingController(text: '${r['delivery_charge'] ?? ''}');
    final ret = TextEditingController(text: '${r['return_charge'] ?? ''}');
    final fee = TextEditingController(text: '${r['cod_fee_percent'] ?? 0}');
    final tax = TextEditingController(text: '${r['cod_tax_percent'] ?? 0}');
    var from = DateTime.tryParse('${r['effective_from']}') ?? DateTime.now();
    final res = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Courier rate'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: courier,
                decoration: const InputDecoration(labelText: 'Courier'),
                items: [for (final k in ['postex', 'blueex', 'mnp', 'tranzo', 'xps', 'unknown']) DropdownMenuItem(value: k, child: Text(courierName(k)))],
                onChanged: (v) => set(() => courier = v!),
              ),
              const SizedBox(height: 12),
              TextField(controller: del, decoration: const InputDecoration(labelText: 'Delivery charge (incl. GST/fuel)', prefixText: 'Rs ')),
              const SizedBox(height: 12),
              TextField(controller: ret, decoration: const InputDecoration(labelText: 'Additional return charge', prefixText: 'Rs ')),
              const SizedBox(height: 12),
              TextField(controller: fee, decoration: const InputDecoration(labelText: 'COD handling fee', suffixText: '% of COD')),
              const SizedBox(height: 12),
              TextField(controller: tax, decoration: const InputDecoration(labelText: 'COD withholding tax (deducted per parcel)', suffixText: '% of COD')),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  final d = await showDatePicker(context: c, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDate: from);
                  if (d != null) set(() => from = d);
                },
                child: Text('Effective from ${dateShort(from)}'),
              ),
            ]),
          ),
          actions: [
            if (r['id'] != null) TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == null || !context.mounted) return;
    final ok = res == 'delete'
        ? await runAction(context, () => Api.instance.deleteRateCard(r['id'] as int), success: 'Deleted')
        : await runAction(
            context,
            () => Api.instance.saveRateCard({
              'id': r['id'],
              'courier': courier,
              'delivery_charge': num.tryParse(del.text) ?? 0,
              'return_charge': num.tryParse(ret.text) ?? 0,
              'cod_fee_percent': num.tryParse(fee.text) ?? 0,
              'cod_tax_percent': num.tryParse(tax.text) ?? 0,
              'effective_from': ymd(from),
            }),
            success: 'Rate saved',
          );
    if (ok) {
      reload();
      AppState.dataChanged();
    }
  }
}

// ------------------------------------------------------------------ sync
class _SyncTab extends StatelessWidget {
  const _SyncTab();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.syncRuns,
      builder: (context, runs, reload) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionCard(
          title: 'Automatic sync',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('• Shopify orders: every 30 minutes (only changed orders)\n'
                '• Courier tracking: hourly (only parcels that are not delivered/returned yet)\n'
                '• PostEx payments (CPRs): every 3 hours — creates one settlement statement per CPR automatically\n'
                '• Ad spend (Triple Whale): every 6 hours, last 3 days — one marketing expense per channel per day\n'
                '• Bank matching & alerts: every 2 hours, and after every import'),
            const SizedBox(height: 12),
            if (AppState.session.canOperate)
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.history),
                  label: const Text('Backfill older orders…'),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      helpText: 'Sync all orders changed since',
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                      initialDate: DateTime.now().subtract(const Duration(days: 180)),
                    );
                    if (d == null || !context.mounted) return;
                    final ok = await runAction(context, () async {
                      final r = await Api.instance.syncOrders(from: ymd(d));
                      if (context.mounted) showSnack(context, 'Backfill done: ${r['total_orders']} orders');
                    });
                    if (ok) {
                      reload();
                      AppState.dataChanged();
                    }
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.campaign_outlined),
                  label: const Text('Backfill ad spend…'),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      helpText: 'Import Triple Whale ad spend since',
                      firstDate: DateTime.now().subtract(const Duration(days: 400)),
                      lastDate: DateTime.now(),
                      initialDate: DateTime(DateTime.now().year, DateTime.now().month - 2, 1),
                    );
                    if (d == null || !context.mounted) return;
                    await importAdSpend(context, d, DateTime.now());
                    reload();
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.local_shipping_outlined),
                  label: const Text('Run tracking now'),
                  onPressed: () async {
                    final ok = await runAction(context, () async {
                      final r = await Api.instance.syncTracking();
                      if (context.mounted) showSnack(context, 'Tracked ${r['applied']} of ${r['due']} due parcels');
                    });
                    if (ok) reload();
                  },
                ),
              ]),
          ]),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Recent sync runs',
          padding: const EdgeInsets.all(8),
          child: DataList(
            rows: runs,
            columns: [
              Col('Started', (r) => Text(dateTime(r['started_at'])), sort: 'started_at'),
              Col('Type', (r) => Text(titleCase('${r['kind']}')), sort: 'kind'),
              Col('Trigger', (r) => Text('${r['trigger']}')),
              Col('Status', (r) => Pill('${r['status']}', color: switch (r['status']) {
                    'ok' => Palette.positive,
                    'partial' => Palette.warning,
                    'error' => Palette.negative,
                    _ => Palette.info,
                  })),
              Col('Details', (r) => SizedBox(
                    width: 380,
                    child: Text('${r['error'] ?? ''} ${_stats(r['stats'])}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  )),
            ],
            tile: (r) => ListTile(
              title: Text('${titleCase('${r['kind']}')} · ${r['status']}'),
              subtitle: Text('${dateTime(r['started_at'])} · ${r['error'] ?? _stats(r['stats'])}'),
            ),
          ),
        ),
      ]),
    );
  }

  static String _stats(dynamic s) {
    if (s is! Map) return '';
    return s.entries.where((e) => e.value is! Map && e.value is! List).map((e) => '${e.key}: ${e.value}').join(', ');
  }
}

// ------------------------------------------------------------------ users
class _UsersTab extends StatelessWidget {
  const _UsersTab();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.profiles,
      builder: (context, users, reload) => SectionCard(
        title: 'Users & roles',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('New people sign up on the login screen and wait as "pending" until you give them a role.\n'
              'Viewer: read-only · Finance: imports, matching, expenses, overrides · Admin: settings, integrations, users.'),
          const SizedBox(height: 12),
          for (final u in users)
            ListTile(
              leading: CircleAvatar(child: Text('${u['email']}'.isEmpty ? '?' : '${u['email']}'[0].toUpperCase())),
              title: Text('${u['full_name'] ?? u['email']}'),
              subtitle: Text('${u['email']} · joined ${dateShort(u['created_at'])}'),
              trailing: u['id'] == AppState.session.profile?['id']
                  ? Pill(titleCase('${u['role']}'))
                  : DropdownButton<String>(
                      value: u['role'] as String,
                      items: [for (final r in AppRole.values) DropdownMenuItem(value: r.name, child: Text(titleCase(r.name)))],
                      onChanged: (v) async {
                        if (v == null) return;
                        final ok = await runAction(context, () => Api.instance.setRole(u['id'] as String, v), success: 'Role updated');
                        if (ok) reload();
                      },
                    ),
            ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ audit
class _AuditTab extends StatelessWidget {
  const _AuditTab();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.auditLog,
      builder: (context, rows, _) => SectionCard(
        title: 'Audit log (latest 300)',
        padding: const EdgeInsets.all(8),
        child: DataList(
          rows: rows,
          onTap: (r) => showDialog(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('${r['action']} ${r['table_name']} #${r['record_id']}'),
              content: SizedBox(
                width: 640,
                child: SingleChildScrollView(
                  child: SelectableText(
                    'By ${r['actor_email'] ?? 'system'} at ${dateTime(r['at'])}\n\n'
                    'Before:\n${const JsonEncoder.withIndent('  ').convert(r['old_data'])}\n\n'
                    'After:\n${const JsonEncoder.withIndent('  ').convert(r['new_data'])}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
              actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
            ),
          ),
          columns: [
            Col('When', (r) => Text(dateTime(r['at']))),
            Col('Who', (r) => Text('${r['actor_email'] ?? 'system'}')),
            Col('Action', (r) => Text('${r['action']}')),
            Col('Table', (r) => Text('${r['table_name']}')),
            Col('Record', (r) => Text('${r['record_id'] ?? ''}')),
          ],
          tile: (r) => ListTile(
            title: Text('${r['action']} ${r['table_name']} #${r['record_id'] ?? ''}'),
            subtitle: Text('${r['actor_email'] ?? 'system'} · ${dateTime(r['at'])}'),
          ),
        ),
      ),
    );
  }
}
