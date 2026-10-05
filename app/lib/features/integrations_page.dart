import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../ui/widgets.dart';

/// Field definitions per provider. Secret fields are sent once to the
/// `integrations` edge function, stored in Supabase Vault and never shown again.
class _Field {
  const _Field(this.key, this.label, {this.secret = false, this.help, this.required = false});
  final String key;
  final String label;
  final bool secret;
  final String? help;
  final bool required;
}

const _fields = <String, List<_Field>>{
  'shopify': [
    _Field('shop_domain', 'Store domain', help: 'your-store.myshopify.com', required: true),
    _Field('access_token', 'Admin API access token', secret: true, help: 'shpat_… (custom app with read_orders, read_products, read_inventory)'),
    _Field('client_id', 'Client ID (Dev Dashboard app)', help: 'Use instead of an access token for newer apps'),
    _Field('client_secret', 'Client secret (Dev Dashboard app)', secret: true),
    _Field('api_version', 'API version', help: 'Default 2026-07'),
  ],
  'postex': [_Field('token', 'API token', secret: true, required: true), _Field('account_id', 'Merchant / account ID')],
  'blueex': [
    _Field('username', 'API username', secret: true, required: true),
    _Field('password', 'API password', secret: true, required: true),
    _Field('account_no', 'Account number'),
  ],
  'mnp': [_Field('account_no', 'Account number', help: 'M&P tracking is public; no key needed')],
  'tranzo': [_Field('api_token', 'API token', secret: true, required: true), _Field('account_id', 'Account ID')],
  'xps': [_Field('auth_key', 'API auth key', secret: true, required: true), _Field('account_id', 'Account ID')],
  'triplewhale': [
    _Field('shop_domain', 'Shopify store domain', help: 'your-store.myshopify.com (as connected in Triple Whale)', required: true),
    _Field('api_key', 'Triple Whale API key', secret: true, required: true, help: 'Triple Whale → Settings → API Keys, scope summary-page:read'),
  ],
};

class IntegrationsPage extends StatelessWidget {
  const IntegrationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AppState.session.isAdmin) {
      return const EmptyState(icon: Icons.lock_outline, title: 'Admins only', message: 'Ask an admin to manage integrations.');
    }
    return Loader<List<Rec>>(
      watchPeriod: false,
      load: Api.instance.integrations,
      builder: (context, rows, reload) => PageBody(
        title: 'Integrations',
        subtitle: 'Credentials are tested and stored server-side (Supabase Vault). Saved secrets are never shown again.',
        children: [
          TileGrid(minTileWidth: 340, children: [
            _SupabaseCard(),
            for (final r in rows) _IntegrationCard(row: r, onChanged: reload),
          ]),
        ],
      ),
    );
  }
}

Widget _statusPill(String status) => switch (status) {
      'connected' => const Pill('Connected', color: Palette.positive),
      'error' => const Pill('Error', color: Palette.negative),
      'disabled' => const Pill('Disabled', color: Palette.muted),
      _ => const Pill('Not configured', color: Palette.warning),
    };

class _SupabaseCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(AppConfig.supabaseUrl)?.host ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.storage_rounded, color: Color(0xFF3ECF8E)),
            const SizedBox(width: 8),
            const Expanded(child: Text('Supabase', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
            const Pill('Connected', color: Palette.positive),
          ]),
          const SizedBox(height: 8),
          Text('Database, auth & server functions\n$host\nEnvironment: ${AppConfig.appEnv}'),
          const SizedBox(height: 8),
          const Text('Configured at build time (URL + publishable key only). Service keys never reach this app.',
              style: TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}

class _IntegrationCard extends StatelessWidget {
  const _IntegrationCard({required this.row, required this.onChanged});
  final Rec row;
  final VoidCallback onChanged;

  String get provider => row['provider'] as String;

  @override
  Widget build(BuildContext context) {
    final hint = (row['secret_hint'] as Map?)?.cast<String, dynamic>() ?? {};
    final config = (row['config'] as Map?)?.cast<String, dynamic>() ?? {};
    final configured = row['status'] != 'not_configured';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(switch (row['kind']) { 'store' => Icons.storefront, 'marketing' => Icons.campaign_outlined, _ => Icons.local_shipping_outlined }),
            const SizedBox(width: 8),
            Expanded(child: Text('${row['display_name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
            _statusPill('${row['status']}'),
          ]),
          const SizedBox(height: 8),
          for (final e in config.entries.where((e) => e.value != null && '${e.value}'.isNotEmpty))
            Text('${titleCase(e.key)}: ${e.value}', style: const TextStyle(fontSize: 13)),
          for (final e in hint.entries) Text('${titleCase(e.key)}: ${e.value}', style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
          const SizedBox(height: 4),
          Text(
            [
              if (row['last_test_message'] != null) 'Last test: ${row['last_test_message']}',
              if (row['last_tested_at'] != null) dateTime(row['last_tested_at']),
              'Last sync: ${ago(row['last_sync_at'])}',
            ].join('\n'),
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonal(onPressed: () => _configure(context), child: Text(configured ? 'Reconfigure' : 'Configure')),
            if (configured)
              OutlinedButton(
                onPressed: () async {
                  final r = await Api.instance.integrationAction('test', provider);
                  if (context.mounted) showSnack(context, '${r['message'] ?? r['error']}', error: r['ok'] != true);
                },
                child: const Text('Test connection'),
              ),
            if (configured)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                onPressed: () async {
                  if (!await confirm(context, 'Disconnect ${row['display_name']}?',
                      'The stored credentials will be deleted. Syncing for this integration stops until you reconnect.',
                      action: 'Disconnect', danger: true)) {
                    return;
                  }
                  if (!context.mounted) return;
                  final ok = await runAction(context, () => Api.instance.integrationAction('disconnect', provider), success: 'Disconnected');
                  if (ok) onChanged();
                },
                child: const Text('Disconnect'),
              ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _configure(BuildContext context) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _ConfigureDialog(row: row));
    if (saved == true) onChanged();
  }
}

class _ConfigureDialog extends StatefulWidget {
  const _ConfigureDialog({required this.row});
  final Rec row;

  @override
  State<_ConfigureDialog> createState() => _ConfigureDialogState();
}

class _ConfigureDialogState extends State<_ConfigureDialog> {
  late final String provider = widget.row['provider'] as String;
  late final Map<String, dynamic> _hint = (widget.row['secret_hint'] as Map?)?.cast<String, dynamic>() ?? {};
  late final Map<String, dynamic> _config = (widget.row['config'] as Map?)?.cast<String, dynamic>() ?? {};
  late final Map<String, TextEditingController> _ctrls = {
    for (final f in _fields[provider]!) f.key: TextEditingController(text: f.secret ? '' : '${_config[f.key] ?? ''}'),
  };
  final _sample = TextEditingController();
  bool _busy = false;
  bool? _ok;
  String? _message;

  ({Map<String, String> config, Map<String, String> credentials}) _values() {
    final config = <String, String>{}, creds = <String, String>{};
    for (final f in _fields[provider]!) {
      final v = _ctrls[f.key]!.text.trim();
      if (v.isEmpty) continue;
      // client_id and username are not secret but are part of the credential set
      if (f.secret || f.key == 'client_id') {
        creds[f.key] = v;
      } else {
        config[f.key] = v;
      }
    }
    return (config: config, credentials: creds);
  }

  Future<void> _run(String action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final v = _values();
    try {
      final r = await Api.instance.integrationAction(action, provider,
          config: v.config, credentials: v.credentials, sampleTracking: _sample.text.trim());
      setState(() {
        _ok = r['ok'] == true;
        _message = '${r['message'] ?? r['error'] ?? ''}';
      });
      if (action == 'save' && r['ok'] == true && mounted) {
        final nav = Navigator.of(context);
        final rootContext = nav.context;
        nav.pop(true);
        if (rootContext.mounted) showSnack(rootContext, 'Saved \u2014 ${r['message']}');
        if (provider == 'triplewhale' && rootContext.mounted) {
          final now = DateTime.now();
          await importAdSpend(rootContext, DateTime(now.year, now.month, now.day).subtract(const Duration(days: 89)), now);
        }
      }
    } catch (e) {
      setState(() {
        _ok = false;
        _message = errorText(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Configure ${widget.row['display_name']}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final f in _fields[provider]!) ...[
              TextField(
                controller: _ctrls[f.key],
                obscureText: f.secret,
                autocorrect: false,
                enableSuggestions: !f.secret,
                decoration: InputDecoration(
                  labelText: f.label + (f.required ? ' *' : ''),
                  helperText: f.secret && _hint[f.key] != null ? 'Saved: ${_hint[f.key]} — leave blank to keep it' : f.help,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.row['kind'] == 'courier')
              TextField(
                controller: _sample,
                decoration: const InputDecoration(labelText: 'Sample tracking number (optional, for a real test)'),
              ),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(children: [
                  Icon(_ok == true ? Icons.check_circle : Icons.error, color: _ok == true ? Palette.positive : Palette.negative),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_message!)),
                ]),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        OutlinedButton(onPressed: _busy ? null : () => _run('test'), child: const Text('Test connection')),
        FilledButton(onPressed: _busy ? null : () => _run('save'), child: const Text('Test & save')),
      ],
    );
  }
}
