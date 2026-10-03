import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/api.dart';
import '../data/models.dart';

/// Signed-in user + role. Drives router redirects and role-gated UI.
class SessionState extends ChangeNotifier {
  SessionState() {
    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((e) {
      if (e.event == AuthChangeEvent.signedOut) {
        profile = null;
        loaded = true;
        notifyListeners();
      } else if (e.session != null) {
        reload();
      }
    });
    if (Supabase.instance.client.auth.currentSession != null) {
      reload();
    } else {
      loaded = true;
    }
  }

  late final StreamSubscription<AuthState> _sub;
  Rec? profile;
  bool loaded = false;

  bool get signedIn => Supabase.instance.client.auth.currentSession != null;
  AppRole get role => roleFrom(profile?['role'] as String?);
  String get email => (profile?['email'] as String?) ?? Supabase.instance.client.auth.currentUser?.email ?? '';
  bool get canView => role.index >= AppRole.viewer.index;
  bool get canOperate => role.index >= AppRole.finance.index;
  bool get isAdmin => role == AppRole.admin;

  Future<void> reload() async {
    try {
      profile = await Api.instance.myProfile();
    } catch (_) {
      profile = null;
    }
    loaded = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// Global reporting period shared by every page (PKT calendar dates).
class PeriodState extends ValueNotifier<DateTimeRange> {
  PeriodState() : super(_thisMonth());

  String label = 'This month';

  static DateTimeRange _thisMonth() {
    final n = DateTime.now();
    return DateTimeRange(start: DateTime(n.year, n.month, 1), end: DateTime(n.year, n.month, n.day));
  }

  static DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static Map<String, DateTimeRange> presets() {
    final today = _today;
    final q = ((today.month - 1) ~/ 3) * 3 + 1;
    return {
      'Today': DateTimeRange(start: today, end: today),
      'Yesterday': DateTimeRange(start: today.subtract(const Duration(days: 1)), end: today.subtract(const Duration(days: 1))),
      'Last 7 days': DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today),
      'Last 30 days': DateTimeRange(start: today.subtract(const Duration(days: 29)), end: today),
      'This month': DateTimeRange(start: DateTime(today.year, today.month, 1), end: today),
      'Last month': DateTimeRange(start: DateTime(today.year, today.month - 1, 1), end: DateTime(today.year, today.month, 0)),
      'This quarter': DateTimeRange(start: DateTime(today.year, q, 1), end: today),
      'Last 90 days': DateTimeRange(start: today.subtract(const Duration(days: 89)), end: today),
      'This year': DateTimeRange(start: DateTime(today.year, 1, 1), end: today),
    };
  }

  /// The last [n] calendar months, newest first (current month ends today).
  static List<DateTimeRange> recentMonths(int n) {
    final today = _today;
    return [
      for (var i = 0; i < n; i++)
        DateTimeRange(
          start: DateTime(today.year, today.month - i, 1),
          end: i == 0 ? today : DateTime(today.year, today.month - i + 1, 0),
        ),
    ];
  }

  static const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String monthLabel(DateTime d) => '${_monthNames[d.month - 1]} ${d.year}';

  static String rangeText(DateTimeRange r) {
    String f(DateTime d, {bool year = true}) => '${d.day} ${_monthNames[d.month - 1]}${year ? ' ${d.year}' : ''}';
    if (r.start == r.end) return f(r.start);
    return '${f(r.start, year: r.start.year != r.end.year)} – ${f(r.end)}';
  }

  bool get _isWholeMonth {
    final s = value.start, e = value.end;
    final monthEnd = DateTime(s.year, s.month + 1, 0);
    return s.day == 1 && e.year == s.year && e.month == s.month && (e == monthEnd || e == _today);
  }

  bool get canShiftForward => value.end.isBefore(_today);

  /// ◀ / ▶: months step by month, other ranges by their own length.
  void shift(int direction) {
    if (_isWholeMonth) {
      final start = DateTime(value.start.year, value.start.month + direction, 1);
      var end = DateTime(start.year, start.month + 1, 0);
      if (end.isAfter(_today)) end = _today;
      if (start.isAfter(_today)) return;
      set(DateTimeRange(start: start, end: end), monthLabel(start));
      return;
    }
    final days = value.end.difference(value.start).inDays + 1;
    var start = value.start.add(Duration(days: days * direction));
    var end = value.end.add(Duration(days: days * direction));
    if (start.isAfter(_today)) return;
    if (end.isAfter(_today)) end = _today;
    set(DateTimeRange(start: start, end: end), 'Custom');
  }

  void set(DateTimeRange range, String name) {
    label = name;
    if (value == range) {
      notifyListeners(); // same dates, new label (e.g. "This month" → "Oct 2026")
    } else {
      value = range;
    }
  }
}

/// App-wide singletons (simple service locator; the app is small enough).
class AppState {
  AppState._();
  static final session = SessionState();
  static final period = PeriodState();
  /// Bumped after imports/syncs so open pages reload.
  static final dataVersion = ValueNotifier<int>(0);
  static void dataChanged() => dataVersion.value++;
}
