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

  static Map<String, DateTimeRange> presets() {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    return {
      'Today': DateTimeRange(start: today, end: today),
      'Last 7 days': DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today),
      'Last 30 days': DateTimeRange(start: today.subtract(const Duration(days: 29)), end: today),
      'This month': DateTimeRange(start: DateTime(n.year, n.month, 1), end: today),
      'Last month': DateTimeRange(start: DateTime(n.year, n.month - 1, 1), end: DateTime(n.year, n.month, 0)),
      'Last 90 days': DateTimeRange(start: today.subtract(const Duration(days: 89)), end: today),
      'This year': DateTimeRange(start: DateTime(n.year, 1, 1), end: today),
    };
  }

  void set(DateTimeRange range, String name) {
    label = name;
    value = range;
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
