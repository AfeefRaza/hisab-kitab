import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'core/state.dart';
import 'core/theme.dart';
import 'features/alerts_page.dart';
import 'features/auth_pages.dart';
import 'features/bank_page.dart';
import 'features/dashboard_page.dart';
import 'features/expenses_page.dart';
import 'features/integrations_page.dart';
import 'features/order_detail_page.dart';
import 'features/orders_page.dart';
import 'features/profit_page.dart';
import 'features/settings_page.dart';
import 'features/settlements_page.dart';
import 'features/shipments_page.dart';
import 'ui/shell.dart';

final _router = GoRouter(
  initialLocation: '/',
  refreshListenable: AppState.session,
  redirect: (context, state) {
    final s = AppState.session;
    final loc = state.matchedLocation;
    final public = loc == '/login';
    if (!s.loaded) return null;
    if (!s.signedIn) return public ? null : '/login';
    if (!s.canView) return loc == '/pending' ? null : '/pending';
    if (public || loc == '/pending') return '/';
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
    GoRoute(path: '/pending', builder: (_, _) => const PendingPage()),
    ShellRoute(
      builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
      routes: [
        GoRoute(path: '/', builder: (_, _) => const DashboardPage()),
        GoRoute(
          path: '/orders',
          builder: (_, s) => OrdersPage(
            initialState: s.uri.queryParameters['state'],
            initialCourier: s.uri.queryParameters['courier'],
          ),
        ),
        GoRoute(path: '/orders/:id', builder: (_, s) => OrderDetailPage(orderId: int.parse(s.pathParameters['id']!))),
        GoRoute(path: '/shipments', builder: (_, _) => const ShipmentsPage()),
        GoRoute(path: '/settlements', builder: (_, _) => const SettlementsPage()),
        GoRoute(path: '/settlements/:id', builder: (_, s) => SettlementBatchPage(batchId: int.parse(s.pathParameters['id']!))),
        GoRoute(path: '/bank', builder: (_, _) => const BankPage()),
        GoRoute(path: '/expenses', builder: (_, _) => const ExpensesPage()),
        GoRoute(path: '/profit', builder: (_, _) => const ProfitPage()),
        GoRoute(path: '/alerts', builder: (_, _) => const AlertsPage()),
        GoRoute(path: '/settings', builder: (_, s) => SettingsPage(initialTab: s.uri.queryParameters['tab'])),
        GoRoute(path: '/integrations', builder: (_, _) => const IntegrationsPage()),
      ],
    ),
  ],
);

class HisabKitabApp extends StatelessWidget {
  const HisabKitabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Hisab Kitab',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: _router,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('en', 'GB'), Locale('en', 'US')],
      locale: const Locale('en', 'GB'), // day-first dates in pickers
    );
  }
}
