import 'package:flutter/material.dart';

import 'core.dart';

/// التحويلات اللي موبايل المحل قراها (إشعارات InstaPay/Telda ورسايل البنوك)
/// اللي ماتربطتش تلقائي (مبلغين زي بعض / مبلغ غلط) → الأدمن يربطها بحجز بإيده
class PaymentsScreen extends StatefulWidget {
  final int reload;
  final VoidCallback onChanged;
  const PaymentsScreen({super.key, required this.reload, required this.onChanged});
  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

const _resultLabels = {
  'matched': 'اتربط تلقائي ✓',
  'linked': 'اتربط يدوي ✓',
  'unmatched': 'مش لاقيين حجز بالمبلغ ده',
  'ambiguous': 'أكتر من حجز بنفس المبلغ',
  'no_amount': 'مالقيناش مبلغ',
  'auto_off': 'التأكيد التلقائي مقفول',
};

class _PaymentsScreenState extends State<PaymentsScreen> {
  List<Map<String, dynamic>>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PaymentsScreen old) {
    super.didUpdateWidget(old);
    if (old.reload != widget.reload) _load();
  }

  Future<void> _load() async {
    try {
      final r = await rpc('admin_payment_events', {'p_limit': 150});
      if (!mounted) return;
      setState(() {
        _items = (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _link(Map<String, dynamic> ev) async {
    final r1 = await rpc('admin_bookings', {'p_scope': 'action'}).catchError((_) => const []);
    final r2 = await rpc('admin_bookings', {'p_scope': 'history', 'p_limit': 120}).catchError((_) => const []);
    final seen = <String>{};
    final all = [...(r1 as List), ...(r2 as List)]
        .map((e) => Booking(Map<String, dynamic>.from(e as Map)))
        .where((b) => seen.add(b.id))
        .where((b) => ['awaiting_payment', 'payment_claimed', 'expired'].contains(b.status) && b.depositAmount != null)
        .toList();
    final amount = ev['amount'] as num?;
    all.sort((a, b) => ((a.depositAmount == amount) ? 0 : 1).compareTo((b.depositAmount == amount) ? 0 : 1));
    if (!mounted) return;
    final chosen = await showModalBottomSheet<Booking>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .7,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('اربط تحويل ${money(amount)} بحجز', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            if (all.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('مفيش حجوزات مستنية deposit.')),
            Expanded(
              child: ListView(children: [
                for (final b in all)
                  ListTile(
                    leading: Icon(b.depositAmount == amount ? Icons.check_circle : Icons.circle_outlined,
                        color: b.depositAmount == amount ? const Color(0xFF22C55E) : null),
                    title: Text('#${b.code} — ${b.customerName ?? ''}'),
                    subtitle: Text('${b.branchName} · ${dayText(b.date)} ${time12(b.time)} · deposit ${money(b.depositAmount)} · ${statusLabels[b.status]}'),
                    onTap: () => Navigator.pop(ctx, b),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen.depositAmount != amount &&
        !await confirmDialog(context, 'المبلغ مختلف', 'التحويل ${money(amount)} والـ deposit ${money(chosen.depositAmount)}. تربطهم برضو؟', yes: 'اربط')) {
      return;
    }
    if (!mounted) return;
    if (await run(context, () => rpcOk('admin_link_payment', {'p_event': ev['id'], 'p_booking': chosen.id}), ok: 'الحجز #${chosen.code} اتأكد')) {
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items == null) return Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'دي التحويلات اللي موبايل المحل قراها من إشعارات InstaPay/Telda ورسايل البنوك (من القايمة المسموحة بس). '
                'لو التحويل ماتربطش تلقائي، اربطه بالحجز بإيدك — أو أكّد الحجز من «الطلبات» بعد ما تشوف الفلوس بعينك.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ),
          if (_items!.isEmpty)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: Text('مفيش تحويلات لسه'))),
          for (final ev in _items!) _tile(ev),
        ],
      ),
    );
  }

  Widget _tile(Map<String, dynamic> ev) {
    final result = ev['result'] as String;
    final done = result == 'matched' || result == 'linked';
    final at = DateTime.tryParse('${ev['received_at']}')?.toLocal();
    return Card(
      child: ExpansionTile(
        leading: Icon(ev['source'] == 'sms' ? Icons.sms_outlined : Icons.notifications_outlined,
            color: done ? const Color(0xFF22C55E) : const Color(0xFFF59E0B)),
        title: Text('${money(ev['amount'] as num?)} — ${ev['payer'] ?? ev['origin']}'),
        subtitle: Text('${_resultLabels[result] ?? result}${ev['booking_code'] != null ? ' · حجز #${ev['booking_code']}' : ''} · ${agoText(at)}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${ev['origin']}${ev['device'] != null ? ' · ${ev['device']}' : ''}', style: const TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 6),
          SelectableText('${ev['body']}'),
          if (!done) ...[
            const SizedBox(height: 10),
            FilledButton.icon(onPressed: () => _link(ev), icon: const Icon(Icons.link), label: const Text('اربط بحجز')),
          ],
        ],
      ),
    );
  }
}
