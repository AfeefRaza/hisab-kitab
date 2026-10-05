import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    // SelectionArea: any text on a page can be selected and copied
    return SelectionArea(
        child: ListView(
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
    ));
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

/// A column for [DataList]. [sort] is the row field used for sorting
/// (and the database column name when the list is sorted server-side).
class Col {
  const Col(this.label, this.cell, {this.numeric = false, this.sort});
  final String label;
  final Widget Function(Rec row) cell;
  final bool numeric;
  final String? sort;
}

/// Compares two cell values: numbers numerically, everything else as
/// case-insensitive text (ISO dates sort correctly as text). Nulls last.
int compareValues(dynamic a, dynamic b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  final na = a is num ? a : (a is String ? num.tryParse(a) : null);
  final nb = b is num ? b : (b is String ? num.tryParse(b) : null);
  if (na != null && nb != null) return na.compareTo(nb);
  return a.toString().toLowerCase().compareTo(b.toString().toLowerCase());
}

/// Wide screens: a sortable data table. Narrow screens: a card list with a sort menu.
/// Sorting is local unless [onSort] is given (then the parent sorts, e.g. server-side).
class DataList extends StatefulWidget {
  const DataList({
    super.key,
    required this.rows,
    required this.columns,
    required this.tile,
    this.onTap,
    this.empty,
    this.sortField,
    this.sortAscending = true,
    this.onSort,
  });
  final List<Rec> rows;
  final List<Col> columns;
  final Widget Function(Rec row) tile;
  final void Function(Rec row)? onTap;
  final Widget? empty;
  final String? sortField;
  final bool sortAscending;
  final void Function(String field, bool ascending)? onSort;

  @override
  State<DataList> createState() => _DataListState();
}

class _DataListState extends State<DataList> {
  String? _field;
  bool _asc = true;

  bool get _external => widget.onSort != null;
  String? get field => _external ? widget.sortField : _field;
  bool get asc => _external ? widget.sortAscending : _asc;

  void _sort(String f, bool ascending) {
    if (_external) {
      widget.onSort!(f, ascending);
    } else {
      setState(() {
        _field = f;
        _asc = ascending;
      });
    }
  }

  List<Rec> get _rows {
    if (_external || _field == null) return widget.rows;
    final sorted = [...widget.rows];
    sorted.sort((a, b) {
      final c = compareValues(a[_field], b[_field]);
      return _asc ? c : -c;
    });
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows.isEmpty) return widget.empty ?? const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing here yet');
    final sortable = widget.columns.where((c) => c.sort != null).toList();

    if (!isWide(context)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (sortable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Row(children: [
              const Icon(Icons.sort, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: sortable.any((c) => c.sort == field) ? field : null,
                  hint: const Text('Sort by'),
                  underline: const SizedBox.shrink(),
                  items: [for (final c in sortable) DropdownMenuItem(value: c.sort, child: Text(c.label))],
                  onChanged: (v) => v == null ? null : _sort(v, field == v ? asc : !sortable.firstWhere((c) => c.sort == v).numeric),
                ),
              ),
              IconButton(
                tooltip: asc ? 'Ascending' : 'Descending',
                icon: Icon(asc ? Icons.arrow_upward : Icons.arrow_downward, size: 18),
                onPressed: field == null ? null : () => _sort(field!, !asc),
              ),
            ]),
          ),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          InkWell(onTap: widget.onTap == null ? null : () => widget.onTap!(rows[i]), child: widget.tile(rows[i])),
        ],
      ]);
    }

    final sortIndex = widget.columns.indexWhere((c) => c.sort != null && c.sort == field);
    return LayoutBuilder(builder: (context, c) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: c.maxWidth),
          child: DataTable(
            showCheckboxColumn: false,
            columnSpacing: 20,
            horizontalMargin: 8,
            sortColumnIndex: sortIndex < 0 ? null : sortIndex,
            sortAscending: asc,
            columns: [
              for (final col in widget.columns)
                DataColumn(
                  label: Text(col.label),
                  numeric: col.numeric,
                  tooltip: col.sort == null ? null : 'Sort by ${col.label.toLowerCase()}',
                  onSort: col.sort == null
                      ? null
                      // first click: numbers high→low, text A→Z; next click flips
                      : (_, _) => _sort(col.sort!, col.sort == field ? !asc : !col.numeric),
                ),
            ],
            rows: [
              for (final r in rows)
                DataRow(
                  onSelectChanged: widget.onTap == null ? null : (_) => widget.onTap!(r),
                  cells: [for (final col in widget.columns) DataCell(col.cell(r))],
                ),
            ],
          ),
        ),
      );
    });
  }
}

/// Small copy-to-clipboard button for order numbers, tracking numbers, phones.
class CopyButton extends StatelessWidget {
  const CopyButton(this.value, {super.key, this.label});
  final String? value;
  final String? label;

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.isEmpty) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Copy ${label ?? value}',
      visualDensity: VisualDensity.compact,
      iconSize: 15,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.copy_rounded),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: value!));
        if (context.mounted) showSnack(context, 'Copied ${label ?? value}');
      },
    );
  }
}

/// Text plus a copy button, e.g. an order number in a table cell.
class CopyText extends StatelessWidget {
  const CopyText(this.text, {super.key, this.style, this.label});
  final String? text;
  final TextStyle? style;
  final String? label;

  @override
  Widget build(BuildContext context) {
    if (text == null || text!.isEmpty) return const Text('—');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Text(text!, style: style, overflow: TextOverflow.ellipsis)),
      CopyButton(text, label: label ?? text),
    ]);
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

/// Runs [work] behind a modal progress dialog; [work] gets a callback to update the message.
Future<T?> withProgress<T>(BuildContext context, String initial, Future<T> Function(void Function(String) update) work) async {
  final msg = ValueNotifier<String>(initial);
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(children: [
        const CircularProgressIndicator(),
        const SizedBox(width: 20),
        Expanded(child: ValueListenableBuilder(valueListenable: msg, builder: (_, v, _) => Text(v))),
      ]),
    ),
  );
  try {
    return await work((m) => msg.value = m);
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e), error: true);
    return null;
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// Imports Triple Whale ad spend for a date range with progress, then refreshes the app.
Future<void> importAdSpend(BuildContext context, DateTime from, DateTime to) async {
  final r = await withProgress(context, 'Importing ad spend\u2026', (update) => Api.instance.syncAdSpendRange(from, to,
      onProgress: (d, t) => update('Importing ad spend from Triple Whale\u2026 ${t == 0 ? 0 : (100 * d / t).round()}%')));
  if (r == null) return;
  AppState.dataChanged();
  if (context.mounted) {
    showSnack(context, 'Ad spend imported for ${r.synced} of ${r.days} days (${dateShort(from)} \u2013 ${dateShort(to)}): ${rs(r.total)}'
        '${r.synced < r.days ? ' \u2014 some days failed, try again' : ''}', error: r.synced < r.days);
  }
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

/// Period control for the app bar: ◀  [This month · 1 Oct – 3 Oct]  ▶
class PeriodButton extends StatelessWidget {
  const PeriodButton({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTimeRange>(
      valueListenable: AppState.period,
      builder: (context, range, _) {
        final p = AppState.period;
        final text = compact ? p.label : '${p.label} · ${PeriodState.rangeText(range)}';
        return Row(mainAxisSize: MainAxisSize.min, children: [
          if (!compact)
            IconButton(tooltip: 'Previous period', icon: const Icon(Icons.chevron_left), onPressed: () => p.shift(-1)),
          ActionChip(
            avatar: const Icon(Icons.calendar_month, size: 18),
            label: Text(text, overflow: TextOverflow.ellipsis),
            onPressed: () => showPeriodPicker(context),
          ),
          if (!compact)
            IconButton(
              tooltip: 'Next period',
              icon: const Icon(Icons.chevron_right),
              onPressed: p.canShiftForward ? () => p.shift(1) : null,
            ),
        ]);
      },
    );
  }
}

Future<void> showPeriodPicker(BuildContext context) {
  if (isWide(context)) {
    return showDialog(
      context: context,
      builder: (_) => const Dialog(child: SizedBox(width: 520, child: _PeriodPicker())),
    );
  }
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _PeriodPicker(),
  );
}

class _PeriodPicker extends StatefulWidget {
  const _PeriodPicker();

  @override
  State<_PeriodPicker> createState() => _PeriodPickerState();
}

class _PeriodPickerState extends State<_PeriodPicker> {
  late DateTime _from = AppState.period.value.start;
  late DateTime _to = AppState.period.value.end;

  void _apply(DateTimeRange r, String label) {
    AppState.period.set(r, label);
    Navigator.pop(context);
  }

  Future<void> _pick(bool from) async {
    final d = await showDatePicker(
      context: context,
      initialDate: from ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 366)),
      helpText: from ? 'From date' : 'To date',
    );
    if (d == null) return;
    setState(() {
      if (from) {
        _from = d;
        if (_to.isBefore(d)) _to = d;
      } else {
        _to = d;
        if (_from.isAfter(d)) _from = d;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = AppState.period.label;
    final scheme = Theme.of(context).colorScheme;
    Widget section(String t) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(t, style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
        );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text('Reporting period', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Applies to every page. Orders are counted by the date they were placed (Pakistan time).',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          section('Quick'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in PeriodState.presets().entries)
              ChoiceChip(label: Text(e.key), selected: current == e.key, onSelected: (_) => _apply(e.value, e.key)),
          ]),
          section('Month'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in PeriodState.recentMonths(12))
              ChoiceChip(
                label: Text(PeriodState.monthLabel(m.start)),
                selected: current == PeriodState.monthLabel(m.start),
                onSelected: (_) => _apply(m, PeriodState.monthLabel(m.start)),
              ),
          ]),
          section('Custom dates'),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pick(true),
                icon: const Icon(Icons.event, size: 18),
                label: Text('From  ${dateShort(_from)}'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pick(false),
                icon: const Icon(Icons.event, size: 18),
                label: Text('To  ${dateShort(_to)}'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _apply(DateTimeRange(start: _from, end: _to), 'Custom'),
            child: const Text('Apply custom dates'),
          ),
        ]),
      ),
    );
  }
}

/// Compact dropdown filter with an "All" option.
class FilterMenu<T> extends StatelessWidget {
  const FilterMenu({super.key, required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final T? value;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<T?>(
      key: ValueKey('$label-$value'),
      initialSelection: value,
      label: Text(label),
      width: 190,
      onSelected: onChanged,
      dropdownMenuEntries: [
        DropdownMenuEntry<T?>(value: null, label: 'All'),
        for (final e in items.entries) DropdownMenuEntry<T?>(value: e.key, label: e.value),
      ],
    );
  }
}
