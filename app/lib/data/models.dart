import 'package:flutter/material.dart';

/// Where an order's money currently is. Mirrors public.v_order_finance.money_state.
enum MoneyState {
  unfulfilled('Not shipped', 'Order placed, not handed to a courier yet', Color(0xFF94A3B8), Icons.inventory_2_outlined),
  booked('Booked', 'Label created, courier has not moved it', Color(0xFF64748B), Icons.local_post_office_outlined),
  inTransit('In transit', 'On the way to the customer', Color(0xFF2563EB), Icons.local_shipping_outlined),
  withCourier('With courier', 'Delivered — cash collected, courier has not settled it', Color(0xFFD97706), Icons.account_balance_wallet_outlined),
  settledUnbanked('Settled, not in bank', 'In a courier statement, deposit not matched in bank yet', Color(0xFFEA580C), Icons.receipt_long_outlined),
  inBank('In bank', 'Settled and matched to a bank deposit', Color(0xFF16A34A), Icons.account_balance_outlined),
  prepaid('Prepaid', 'Paid online through a payment gateway', Color(0xFF0D9488), Icons.credit_card),
  returning('Returning', 'Return in transit back to us', Color(0xFFDB2777), Icons.u_turn_left),
  returned('Returned', 'Back with us — no revenue, shipping lost', Color(0xFFDC2626), Icons.assignment_return_outlined),
  lost('Lost', 'Lost by courier — claim needed', Color(0xFF7C3AED), Icons.report_outlined),
  cancelled('Cancelled', 'Cancelled before delivery', Color(0xFF9CA3AF), Icons.block);

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
    unfulfilled, booked, inTransit, withCourier, settledUnbanked, inBank, prepaid, returning, returned, lost, cancelled,
  ];
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
