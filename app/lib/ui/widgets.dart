import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../data/api.dart';
import '../data/models.dart';

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 900;

/// Loads data and re-loads when the global period or data version changes.
class Loader<T> extends StatefulWidget {
  const Loader({super.key, required this.load, required this.builder, this.watchPeriod = true});
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, VoidCallback reload) builder;
  final bool watchPeriod;

  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  late Future<T> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
    if (widget.watchPeriod) AppState.period.addListener(_reload);
    AppState.dataVersion.addListener(_reload);
  }

  @override
  void dispose() {
    AppState.period.removeListener(_reload);
    AppState.dataVersion.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _future = widget.load());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return ErrorPanel(message: errorText(snap.error!), onRetry: _reload);
        }
        if (!snap.hasData) {
          return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()));
        }
        return widget.builder(context, snap.data as T, _reload);
      },
    );
  }
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline, size: 40, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
          ],
        ]),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: muted),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(message!, style: TextStyle(color: muted), textAlign: TextAlign.center),
        ],
        if (action != null) ...[const SizedBox(height: 16), action!],
      ]),
    );
  }
}

/// Standard page body: max width, padding, title row, scroll.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.title, this.subtitle, this.actions = const [], required this.children});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final pad = isWide(context) ? 24.0 : 16.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    if (subtitle != null)
                      Text(subtitle!, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ]),
                  if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              ),
              const SizedBox(height: 20),
              for (final c in children) ...[c, const SizedBox(height: 16)],
            ]),
          ),
        ),
      ],
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.trailing, required this.child, this.padding = const EdgeInsets.all(16)});
  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null || trailing != null) ...[
            Row(children: [
              if (title != null)
                Expanded(child: Text(title!, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              ?trailing,
            ]),
            const SizedBox(height: 12),
          ],
          child,
        ]),
      ),
    );
  }
}

class KpiCard extends StatelessWidget {
  const KpiCard({super.key, required this.label, required this.value, this.hint, this.icon, this.color, this.onTap});
  final String label;
  final String value;
  final String? hint;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                  child: Icon(icon, size: 18, color: c),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ]),
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Responsive grid of fixed-ish width tiles.
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.children, this.minTileWidth = 210});
  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minTileWidth).floor().clamp(1, 6);
      final w = (c.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(spacing: 12, runSpacing: 12, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
    });
  }
}

class StateChip extends StatelessWidget {
  const StateChip(this.stateKey, {super.key});
  final String? stateKey;

  @override
  Widget build(BuildContext context) {
    final s = MoneyState.fromKey(stateKey);
    if (s == null) return const Text('—');
    return Tooltip(
      message: s.description,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: s.color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(s.icon, size: 13, color: s.color),
          const SizedBox(width: 4),
          Text(s.label, style: TextStyle(color: s.color, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class Amount extends StatelessWidget {
  const Amount(this.value, {super.key, this.colored = false, this.bold = false, this.style});
  final dynamic value;
  final bool colored;
  final bool bold;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (value == null) return const Text('—');
    final n = toNum(value);
    final color = !colored ? null : (n < 0 ? Palette.negative : (n > 0 ? Palette.positive : null));
    return Text(rs(n),
        style: (style ?? const TextStyle()).copyWith(
            color: color, fontWeight: bold ? FontWeight.w700 : null, fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

/// A column for [DataList].
class Col {
  const Col(this.label, this.cell, {this.numeric = false});
  final String label;
  final Widget Function(Rec row) cell;
  final bool numeric;
}

/// Wide screens: a data table. Narrow screens: a card list.
class DataList extends StatelessWidget {
  const DataList({super.key, required this.rows, required this.columns, required this.tile, this.onTap, this.empty});
  final List<Rec> rows;
  final List<Col> columns;
  final Widget Function(Rec row) tile;
  final void Function(Rec row)? onTap;
  final Widget? empty;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return empty ?? const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing here yet');
    if (!isWide(context)) {
      return Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          InkWell(onTap: onTap == null ? null : () => onTap!(rows[i]), child: tile(rows[i])),
        ],
      ]);
    }
    return LayoutBuilder(builder: (context, c) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: c.maxWidth),
          child: DataTable(
            showCheckboxColumn: false,
            columnSpacing: 20,
            horizontalMargin: 8,
            columns: [for (final col in columns) DataColumn(label: Text(col.label), numeric: col.numeric)],
            rows: [
              for (final r in rows)
                DataRow(
                  onSelectChanged: onTap == null ? null : (_) => onTap!(r),
                  cells: [for (final col in columns) DataCell(col.cell(r))],
                ),
            ],
          ),
        ),
      );
    });
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? scheme.error : null,
    behavior: SnackBarBehavior.floating,
    duration: Duration(seconds: error ? 6 : 3),
  ));
}

Future<bool> confirm(BuildContext context, String title, String message, {String action = 'Confirm', bool danger = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

Future<String?> promptText(BuildContext context, String title, {String label = '', String initial = '', bool required = false}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctrl, autofocus: true, decoration: InputDecoration(labelText: label), maxLines: 3, minLines: 1),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (required && ctrl.text.trim().isEmpty) return;
            Navigator.pop(c, ctrl.text.trim());
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Runs an async action with a snackbar for success/failure. Returns true on success.
Future<bool> runAction(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) showSnack(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e), error: true);
    return false;
  }
}

class PeriodButton extends StatelessWidget {
  const PeriodButton({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTimeRange>(
      valueListenable: AppState.period,
      builder: (context, range, _) {
        final text = compact ? AppState.period.label : '${AppState.period.label} · ${dateShort(range.start)} – ${dateShort(range.end)}';
        return PopupMenuButton<String>(
          tooltip: 'Reporting period',
          onSelected: (key) async {
            if (key == '__custom') {
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 1)),
                initialDateRange: range,
              );
              if (picked != null) AppState.period.set(picked, 'Custom');
            } else {
              AppState.period.set(PeriodState.presets()[key]!, key);
            }
          },
          itemBuilder: (_) => [
            for (final k in PeriodState.presets().keys) PopupMenuItem(value: k, child: Text(k)),
            const PopupMenuDivider(),
            const PopupMenuItem(value: '__custom', child: Text('Custom range…')),
          ],
          child: Chip(
            avatar: const Icon(Icons.calendar_month, size: 18),
            label: Text(text, overflow: TextOverflow.ellipsis),
          ),
        );
      },
    );
  }
}
