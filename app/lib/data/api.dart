import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/format.dart';

typedef Rec = Map<String, dynamic>;

/// All database / edge-function access lives here so screens stay thin.
/// Reads go through RLS-protected tables, views and RPCs; anything touching
/// external APIs or secrets goes through edge functions.
class Api {
  Api._();
  static final Api instance = Api._();

  SupabaseClient get _db => Supabase.instance.client;

  List<Rec> _rows(dynamic data) => (data as List).cast<Rec>();

  // ---------------------------------------------------------------- profile
  Future<Rec?> myProfile() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    return await _db.from('profiles').select().eq('id', uid).maybeSingle();
  }

  // ---------------------------------------------------------------- finance
  Future<Rec> financeSummary(DateTime from, DateTime to) async =>
      (await _db.rpc('finance_summary', params: {'p_from': ymd(from), 'p_to': ymd(to)})) as Rec;

  Future<List<Rec>> financeDaily(DateTime from, DateTime to) async =>
      _rows(await _db.rpc('finance_daily', params: {'p_from': ymd(from), 'p_to': ymd(to)}));

  Future<List<Rec>> profitBreakdown(DateTime from, DateTime to, String dimension) async => _rows(
      await _db.rpc('profit_breakdown', params: {'p_from': ymd(from), 'p_to': ymd(to), 'p_dimension': dimension}));

  Future<List<Rec>> expensesInPeriod(DateTime from, DateTime to) async =>
      _rows(await _db.rpc('expenses_in_period', params: {'p_from': ymd(from), 'p_to': ymd(to)}));

  // ---------------------------------------------------------------- orders
  Future<({List<Rec> rows, int total})> orders({
    required DateTime from,
    required DateTime to,
    String? moneyState,
    String? courier,
    String? search,
    String sort = 'created_at_shop',
    bool ascending = false,
    int page = 0,
    int pageSize = 50,
  }) async {
    var q = _db.from('v_order_profit').select(
        'order_id,name,order_date,created_at_shop,customer_name,phone,city,is_cod,current_total,units,courier,'
        'tracking_number,shipment_status,status_raw,status_at,money_state,expected_cod,settled_cod,courier_cost,'
        'courier_cost_source,revenue,contribution,is_manual,check_error');
    q = q.gte('order_date', ymd(from)).lte('order_date', ymd(to));
    if (moneyState != null) q = q.eq('money_state', moneyState);
    if (courier != null) q = q.eq('courier', courier);
    final s = search?.trim().replaceAll(RegExp(r'[,()]'), ' ') ?? '';
    if (s.isNotEmpty) {
      q = q.or('name.ilike.%$s%,customer_name.ilike.%$s%,phone.ilike.%$s%,tracking_number.ilike.%$s%,city.ilike.%$s%');
    }
    final res = await q
        .order(sort, ascending: ascending)
        .range(page * pageSize, page * pageSize + pageSize - 1)
        .count(CountOption.exact);
    return (rows: _rows(res.data), total: res.count);
  }

  Future<Rec?> order(int id) async => await _db.from('v_order_profit').select().eq('order_id', id).maybeSingle();

  Future<List<Rec>> orderLines(int id) async =>
      _rows(await _db.from('v_line_costs').select().eq('order_id', id).order('id'));

  Future<List<Rec>> orderTimeline(int id) async =>
      _rows(await _db.rpc('order_timeline', params: {'p_order_id': id}));

  Future<void> setShipmentStatus(int shipmentId, String? status, String? note) =>
      _db.rpc('set_shipment_status', params: {'p_shipment_id': shipmentId, 'p_status': status, 'p_note': note});

  Future<List<Rec>> openShipments({String? courier}) async {
    var q = _db.from('v_order_finance').select(
        'order_id,name,city,courier,tracking_number,shipment_id,shipment_status,status_raw,status_at,fulfilled_at,'
        'money_state,expected_cod,check_error,current_total');
    q = q.inFilter('money_state', ['booked', 'in_transit', 'returning']);
    if (courier != null) q = q.eq('courier', courier);
    return _rows(await q.order('status_at', ascending: true, nullsFirst: true).limit(1000));
  }

  Future<List<Rec>> globalSearch(String query) async =>
      _rows(await _db.rpc('global_search', params: {'p_query': query, 'p_limit': 8}));

  // ---------------------------------------------------------------- sync
  /// Runs the Shopify sync until caught up (each call has a ~110s budget).
  Future<Rec> syncOrders({String? from, void Function(Rec progress)? onProgress}) async {
    var total = 0;
    Rec last = {};
    for (var i = 0; i < 40; i++) {
      final res = await _db.functions.invoke('sync-orders', body: {if (from != null && i == 0) 'from': from});
      last = (res.data as Map).cast<String, dynamic>();
      total += toNum(last['orders']).toInt();
      onProgress?.call({...last, 'total_orders': total});
      if (last['has_more'] != true) break;
    }
    return {...last, 'total_orders': total};
  }

  Future<Rec> syncTracking({List<int>? shipmentIds}) async {
    final res = await _db.functions.invoke('sync-tracking', body: {'shipment_ids': ?shipmentIds});
    return (res.data as Map).cast<String, dynamic>();
  }

  /// Pulls courier payment status / CPRs (PostEx API) and builds settlement batches.
  Future<Rec> syncPayments() async {
    final res = await _db.functions.invoke('sync-payments', body: {});
    return (res.data as Map).cast<String, dynamic>();
  }

  Future<List<Rec>> syncRuns({int limit = 30}) async =>
      _rows(await _db.from('sync_runs').select().order('started_at', ascending: false).limit(limit));

  // ---------------------------------------------------------------- settlements
  Future<List<Rec>> settlementBatches() async {
    final batches = _rows(await _db.from('settlement_batches').select().order('imported_at', ascending: false).limit(500));
    final status = _rows(await _db.from('v_batch_bank_status').select('batch_id,matched_amount,is_banked,banked_on'));
    final byId = {for (final s in status) s['batch_id']: s};
    return [for (final b in batches) {...b, ...?byId[b['id']]}];
  }

  Future<List<Rec>> batchLines(int batchId) async =>
      _rows(await _db.from('settlement_lines').select().eq('batch_id', batchId).order('id'));

  Future<List<Rec>> previewSettlement(List<Map<String, dynamic>> lines) async =>
      _rows(await _db.rpc('preview_settlement', params: {'p_lines': lines}));

  Future<Rec> importSettlement({
    required String courier,
    required String fileName,
    required String sha256,
    String? statementRef,
    DateTime? statementDate,
    required List<Map<String, dynamic>> lines,
    String? note,
  }) async =>
      (await _db.rpc('import_settlement', params: {
        'p_courier': courier,
        'p_file_name': fileName,
        'p_file_sha256': sha256,
        'p_statement_ref': statementRef,
        'p_statement_date': statementDate == null ? null : ymd(statementDate),
        'p_lines': lines,
        'p_note': note,
      })) as Rec;

  Future<List<Rec>> ordersByTracking(List<String> tracking) async {
    final out = <Rec>[];
    for (var i = 0; i < tracking.length; i += 200) {
      final chunk = tracking.sublist(i, i + 200 > tracking.length ? tracking.length : i + 200);
      out.addAll(_rows(await _db
          .from('v_order_finance')
          .select('order_id,name,tracking_number,current_total,money_state')
          .inFilter('tracking_number', chunk)));
    }
    return out;
  }

  Future<void> voidBatch(int id, String reason) =>
      _db.rpc('void_settlement_batch', params: {'p_batch_id': id, 'p_reason': reason});

  /// Delivered COD not yet in any courier statement, grouped by courier with ageing.
  Future<List<Rec>> unsettled() async => _rows(await _db
      .from('v_order_finance')
      .select('order_id,name,courier,tracking_number,expected_cod,delivered_at,status_at')
      .eq('money_state', 'with_courier')
      .order('delivered_at', ascending: true)
      .limit(2000));

  // ---------------------------------------------------------------- bank
  Future<List<Rec>> bankAccounts() async => _rows(await _db.from('bank_accounts').select().order('name'));

  Future<void> saveBankAccount(Rec data) async {
    final id = data.remove('id');
    if (id == null) {
      await _db.from('bank_accounts').insert(data);
    } else {
      await _db.from('bank_accounts').update(data).eq('id', id);
    }
  }

  Future<Rec> importBankStatement(int accountId, String fileName, String sha256, List<Map<String, dynamic>> rows) async =>
      (await _db.rpc('import_bank_statement', params: {
        'p_account_id': accountId,
        'p_file_name': fileName,
        'p_file_sha256': sha256,
        'p_rows': rows,
      })) as Rec;

  Future<List<Rec>> bankTransactions({int? accountId, String? filter, DateTime? from, DateTime? to}) async {
    var q = _db.from('bank_transactions').select('*, settlement_bank_matches(id,batch_id,amount,method), expenses(id)');
    if (accountId != null) q = q.eq('account_id', accountId);
    if (from != null) q = q.gte('txn_date', ymd(from));
    if (to != null) q = q.lte('txn_date', ymd(to));
    if (filter == 'credits') q = q.gt('credit', 0);
    if (filter == 'debits') q = q.gt('debit', 0);
    return _rows(await q.order('txn_date', ascending: false).order('id', ascending: false).limit(1000));
  }

  Future<void> updateBankTxn(int id, {String? category, String? note}) =>
      _db.from('bank_transactions').update({'category': category, 'note': note}).eq('id', id);

  Future<void> matchSettlement(int batchId, int txnId, double amount) => _db.from('settlement_bank_matches').insert({
        'batch_id': batchId,
        'bank_transaction_id': txnId,
        'amount': amount,
        'method': 'manual',
        'matched_by': _db.auth.currentUser?.id,
      });

  Future<void> unmatch(int matchId) => _db.from('settlement_bank_matches').delete().eq('id', matchId);

  Future<int> autoMatch() async => toNum(await _db.rpc('auto_match_settlements')).toInt();

  // ---------------------------------------------------------------- expenses
  Future<List<Rec>> expenseCategories() async =>
      _rows(await _db.from('expense_categories').select().order('kind').order('name'));

  Future<void> saveCategory(Rec data) async {
    final id = data.remove('id');
    if (id == null) {
      await _db.from('expense_categories').insert(data);
    } else {
      await _db.from('expense_categories').update(data).eq('id', id);
    }
  }

  Future<List<Rec>> expenses(DateTime from, DateTime to) async => _rows(await _db
      .from('expenses')
      .select('*, expense_categories(name,kind)')
      .gte('expense_date', ymd(from))
      .lte('expense_date', ymd(to))
      .order('expense_date', ascending: false)
      .limit(2000));

  Future<void> saveExpense(Rec data) async {
    final id = data.remove('id');
    if (id == null) {
      await _db.from('expenses').insert({...data, 'created_by': _db.auth.currentUser?.id});
    } else {
      await _db.from('expenses').update(data).eq('id', id);
    }
  }

  Future<void> deleteExpense(int id) => _db.from('expenses').delete().eq('id', id);

  // ---------------------------------------------------------------- alerts
  Future<List<Rec>> alerts({String status = 'open'}) async => _rows(await _db
      .from('alerts')
      .select()
      .eq('status', status)
      .order('severity')
      .order('last_seen_at', ascending: false)
      .limit(1000));

  Future<int> openAlertCount() async {
    final res = await _db.from('alerts').select('id').eq('status', 'open').count(CountOption.exact);
    return res.count;
  }

  Future<void> setAlertStatus(int id, String status, String? note) => _db.from('alerts').update({
        'status': status,
        'resolution_note': note,
        'resolved_at': DateTime.now().toUtc().toIso8601String(),
        'resolved_by': _db.auth.currentUser?.id,
      }).eq('id', id);

  Future<Rec> refreshAlerts() async => (await _db.rpc('refresh_alerts')) as Rec;

  // ---------------------------------------------------------------- settings
  Future<Map<String, Rec>> settings() async {
    final rows = _rows(await _db.from('app_settings').select());
    return {for (final r in rows) r['key'] as String: (r['value'] as Map).cast<String, dynamic>()};
  }

  Future<void> saveSetting(String key, Rec value) => _db
      .from('app_settings')
      .update({'value': value, 'updated_by': _db.auth.currentUser?.id}).eq('key', key);

  Future<List<Rec>> rateCards() async =>
      _rows(await _db.from('courier_rate_cards').select().order('courier').order('effective_from', ascending: false));

  Future<void> saveRateCard(Rec data) async {
    final id = data.remove('id');
    if (id == null) {
      await _db.from('courier_rate_cards').insert(data);
    } else {
      await _db.from('courier_rate_cards').update(data).eq('id', id);
    }
  }

  Future<void> deleteRateCard(int id) => _db.from('courier_rate_cards').delete().eq('id', id);

  Future<List<Rec>> costRules() async =>
      _rows(await _db.from('product_cost_rules').select().order('priority').order('name'));

  Future<void> saveCostRule(Rec data) async {
    final id = data.remove('id');
    if (id == null) {
      await _db.from('product_cost_rules').insert(data);
    } else {
      await _db.from('product_cost_rules').update(data).eq('id', id);
    }
  }

  Future<void> deleteCostRule(int id) => _db.from('product_cost_rules').delete().eq('id', id);

  /// Products sold recently that have no Shopify cost (so rules matter).
  Future<List<Rec>> productsMissingCost() async => _rows(await _db
      .from('v_line_costs')
      .select('title,sku,variant_id,cost_source')
      .neq('cost_source', 'shopify')
      .order('order_date', ascending: false)
      .limit(500));

  // ---------------------------------------------------------------- integrations
  Future<List<Rec>> integrations() async =>
      _rows(await _db.from('integrations').select().order('kind', ascending: false).order('display_name'));

  Future<Rec> integrationAction(String action, String provider,
      {Map<String, String>? config, Map<String, String>? credentials, String? sampleTracking}) async {
    try {
      final res = await _db.functions.invoke('integrations', body: {
        'action': action,
        'provider': provider,
        'config': ?config,
        'credentials': ?credentials,
        if (sampleTracking != null && sampleTracking.isNotEmpty) 'sample_tracking': sampleTracking,
      });
      return (res.data as Map).cast<String, dynamic>();
    } on FunctionException catch (e) {
      final d = e.details;
      if (d is Map) return d.cast<String, dynamic>();
      rethrow;
    }
  }

  // ---------------------------------------------------------------- admin
  Future<List<Rec>> profiles() async => _rows(await _db.from('profiles').select().order('created_at'));

  Future<void> setRole(String userId, String role) => _db.from('profiles').update({'role': role}).eq('id', userId);

  Future<List<Rec>> auditLog({int limit = 300}) async =>
      _rows(await _db.from('audit_log').select().order('at', ascending: false).limit(limit));
}

/// Human-readable message for any error thrown by the API layer.
String errorText(Object e) {
  if (e is PostgrestException) {
    if (e.code == '42501') return 'You do not have permission to do that.';
    return e.message;
  }
  if (e is FunctionException) {
    final d = e.details;
    if (d is Map && d['error'] != null) return d['error'].toString();
    if (d is Map && d['message'] != null) return d['message'].toString();
    return 'Server function failed (${e.status})';
  }
  if (e is AuthException) return e.message;
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}
