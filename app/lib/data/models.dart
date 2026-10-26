import 'package:flutter/material.dart';

/// Where an order's money currently is. Mirrors public.v_order_finance.money_state.
enum MoneyState {
  unfulfilled('Not shipped', 'Order placed, not handed to a courier yet', Color(0xFF94A3B8), Icons.inventory_2_outlined),
  booked('Booked', 'Label created, courier has not moved it', Color(0xFF64748B), Icons.local_post_office_outlined),
  inTransit('In transit', 'On the way to the customer', Color(0xFF2563EB), Icons.local_shipping_outlined),
  withCourier('With courier', 'Delivered — cash collected, courier has not settled it', Color(0xFFD97706), Icons.account_balance_wallet_outlined),
  settledUnbanked('Settled, not in bank', 'In a courier statement, deposit not matched in bank yet', Color(0xFFEA580C), Icons.receipt_long_outlined),
  inBank('In bank', 'Settled and matched to a bank deposit', Color(0xFF16A34A), Icons.account_balance_outlined),
  prepaid('Prepaid', 'Shopify shows it paid (online, or bank transfer marked paid)', Color(0xFF0D9488), Icons.credit_card),
  returning('Returning', 'Return in transit back to us', Color(0xFFDB2777), Icons.u_turn_left),
  returned('Returned', 'Back with us — no revenue, shipping lost', Color(0xFFDC2626), Icons.assignment_return_outlined),
  lost('Lost', 'Lost by courier — claim needed', Color(0xFF7C3AED), Icons.report_outlined),
  cancelled('Cancelled', 'Cancelled before dispatch (Shopify, "Cancelled" tag, or label cancelled)', Color(0xFF9CA3AF), Icons.block),
  notConfirmed('Not confirmed', 'Customer never confirmed ("Not Confirmed" tag) — not dispatched', Color(0xFFA8A29E), Icons.phone_disabled_outlined);

  const MoneyState(this.label, this.description, this.color, this.icon);
  final String label;
  final String description;
  final Color color;
  final IconData icon;

  String get key => switch (this) {
        MoneyState.inTransit => 'in_transit',
        MoneyState.withCourier => 'with_courier',
        MoneyState.settledUnbanked => 'settled_unbanked',
        MoneyState.inBank => 'in_bank',
        MoneyState.notConfirmed => 'not_confirmed',
        _ => name,
      };

  static MoneyState? fromKey(String? key) {
    for (final s in MoneyState.values) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// Order the money flows in, for the "Where is our money?" view.
  static const flow = [
    unfulfilled, booked, inTransit, withCourier, settledUnbanked, inBank, prepaid, returning, returned, lost, cancelled, notConfirmed,
  ];
}

/// Bank transaction categories (bank_transactions.category). [dir]: 'in', 'out' or 'both'.
class BankCategory {
  const BankCategory(this.key, this.label, this.icon, this.color, this.dir);
  final String key;
  final String label;
  final IconData icon;
  final Color color;
  final String dir;

  static const all = [
    BankCategory('courier_settlement', 'PostEx / courier COD', Icons.local_shipping_outlined, Color(0xFF16A34A), 'in'),
    BankCategory('customer_payment', 'Customer transfer (prepaid order)', Icons.person_outline, Color(0xFF0D9488), 'in'),
    BankCategory('meta_ads', 'Meta / Facebook ads', Icons.campaign_outlined, Color(0xFF2563EB), 'out'),
    BankCategory('other_ads', 'Other ads (Google, TikTok…)', Icons.ads_click, Color(0xFF3B82F6), 'out'),
    BankCategory('supplier', 'Supplier', Icons.factory_outlined, Color(0xFF9333EA), 'out'),
    BankCategory('dtf_printing', 'DTF printing', Icons.print_outlined, Color(0xFFA855F7), 'out'),
    BankCategory('inventory', 'Inventory / production', Icons.inventory_2_outlined, Color(0xFF7C3AED), 'out'),
    BankCategory('shopify_apps', 'Shopify & apps', Icons.apps, Color(0xFF0EA5E9), 'out'),
    BankCategory('salaries', 'Salaries', Icons.badge_outlined, Color(0xFFEA580C), 'out'),
    BankCategory('operational', 'Operational (rent, bills…)', Icons.home_work_outlined, Color(0xFFD97706), 'out'),
    BankCategory('taxes', 'Taxes', Icons.account_balance_outlined, Color(0xFFB45309), 'out'),
    BankCategory('bank_charges', 'Bank charges', Icons.receipt_outlined, Color(0xFF94A3B8), 'out'),
    BankCategory('owner_transfer', 'Own account / owner', Icons.swap_horiz, Color(0xFF64748B), 'both'),
    BankCategory('loan', 'Loan', Icons.handshake_outlined, Color(0xFF78716C), 'both'),
    BankCategory('refund', 'Refund / reversal', Icons.undo, Color(0xFFDB2777), 'both'),
    BankCategory('other_income', 'Other income', Icons.add_circle_outline, Color(0xFF22C55E), 'in'),
    BankCategory('other_expense', 'Other expense', Icons.remove_circle_outline, Color(0xFFEF4444), 'out'),
  ];

  static BankCategory? of(String? key) {
    for (final c in all) {
      if (c.key == key) return c;
    }
    return null;
  }

  static String labelOf(String? key) => key == null || key == 'needs_review' ? 'Needs review' : (of(key)?.label ?? key);
}

const shipmentStatuses = <String, String>{
  'booked': 'Booked',
  'in_transit': 'In transit',
  'out_for_delivery': 'Out for delivery',
  'delivery_failed': 'Delivery failed / attempt',
  'delivered': 'Delivered',
  'return_in_transit': 'Return in transit',
  'returned': 'Returned to us',
  'cancelled': 'Cancelled',
  'lost': 'Lost',
  'unknown': 'Unknown',
};

const courierNames = <String, String>{
  'postex': 'PostEx',
  'blueex': 'BlueEx',
  'mnp': 'M&P',
  'tranzo': 'Tranzo',
  'xps': 'XPS',
  'unknown': 'Unknown',
  'other': 'Other',
};

String courierName(String? key) => courierNames[key] ?? (key ?? '—');

enum AppRole { pending, viewer, finance, admin }

AppRole roleFrom(String? s) =>
    AppRole.values.firstWhere((r) => r.name == s, orElse: () => AppRole.pending);
