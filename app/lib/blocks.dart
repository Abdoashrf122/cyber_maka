import 'package:flutter/material.dart';

import 'core.dart';

/// بلوك لطلب مزعج: الرقم + المتصفح (+ الشبكة اختياري). الطلبات المستنية منه بتترفض.
Future<bool> blockBooking(BuildContext context, Booking b) async {
  String reason = 'إزعاج / هزار';
  int? days = 7;
  bool ip = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        icon: const Icon(Icons.block, color: Color(0xFFF87171), size: 36),
        title: Text('بلوك ${b.customerName ?? ''}'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('الرقم ${b.phone ?? '—'} والمتصفح اللي حجز منه مش هيقدروا يبعتوا طلبات تاني، '
                  'والطلب ده وأي طلبات مستنية منهم هتترفض.', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              const Text('السبب', style: TextStyle(fontWeight: FontWeight.bold)),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final r in const ['إزعاج / هزار', 'حجز وهمي متكرر', 'ماجاش أكتر من مرة', 'سلوك سيء'])
                  ChoiceChip(label: Text(r), selected: reason == r, onSelected: (_) => setS(() => reason = r)),
              ]),
              const SizedBox(height: 12),
              const Text('المدة', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('يوم')),
                  ButtonSegment(value: 7, label: Text('أسبوع')),
                  ButtonSegment(value: 0, label: Text('على طول')),
                ],
                selected: {days ?? 0},
                onSelectionChanged: (s) => setS(() => days = s.first),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: ip,
                onChanged: (v) => setS(() => ip = v == true),
                title: const Text('اقفل الشبكة كمان (IP)'),
                subtitle: const Text('للي بيغيّر رقمه ومتصفحه. أسبوع بالكتير — ممكن تقفل ناس تانية على نفس الشبكة.', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.block),
            label: const Text('بلوك'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return false;
  return run(context, () => rpcOk('admin_block_booking', {'p_booking': b.id, 'p_reason': reason, 'p_days': days, 'p_ip': ip}),
      ok: 'اتعمله بلوك');
}

/// قايمة المحظورين — فك البلوك / إضافة رقم بإيدك
class BlocksScreen extends StatefulWidget {
  const BlocksScreen({super.key});
  @override
  State<BlocksScreen> createState() => _BlocksScreenState();
}

class _BlocksScreenState extends State<BlocksScreen> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await rpc('admin_blocks').catchError((_) => const []);
    if (mounted) setState(() => _items = (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
  }

  Future<void> _add() async {
    final phone = TextEditingController();
    int days = 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('بلوك رقم'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'رقم الموبايل', hintText: '01xxxxxxxxx'),
            ),
            const SizedBox(height: 10),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('يوم')),
                ButtonSegment(value: 7, label: Text('أسبوع')),
                ButtonSegment(value: 0, label: Text('على طول')),
              ],
              selected: {days},
              onSelectionChanged: (s) => setS(() => days = s.first),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بلوك')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await run(context, () => rpcOk('admin_block_phone', {'p_phone': phone.text.trim(), 'p_reason': 'إزعاج', 'p_days': days}),
        ok: 'اتعمله بلوك');
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('المحظورين')),
        floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('بلوك رقم')),
        body: _items == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(12), children: [
                if (_items!.isEmpty) const Padding(padding: EdgeInsets.all(40), child: Center(child: Text('مفيش حد محظور'))),
                for (final b in _items!)
                  Card(
                    child: ListTile(
                      leading: Icon(switch (b['kind']) { 'phone' => Icons.phone_disabled, 'device' => Icons.phonelink_erase, _ => Icons.wifi_off },
                          color: const Color(0xFFF87171)),
                      title: Text('${b['value']}', textDirection: b['kind'] == 'phone' ? TextDirection.ltr : null),
                      subtitle: Text([
                        '${b['reason'] ?? ''}',
                        if (b['booking_code'] != null) 'حجز #${b['booking_code']}',
                        b['expires_at'] == null ? 'على طول' : 'لحد ${_date(b['expires_at'])}',
                      ].where((s) => s.isNotEmpty).join(' · ')),
                      trailing: TextButton(
                        onPressed: () async {
                          if (!await confirmDialog(context, 'فك البلوك؟',
                              b['booking_code'] != null ? 'هيتفك الرقم والمتصفح والشبكة بتوع الحجز ده مع بعض.' : 'الرقم هيقدر يحجز تاني.',
                              yes: 'فك')) {
                            return;
                          }
                          if (!context.mounted) return;
                          await run(context, () => rpcOk('admin_unblock', {'p_id': b['id']}), ok: 'اتفك');
                          _load();
                        },
                        child: const Text('فك'),
                      ),
                    ),
                  ),
              ]),
      );

  static String _date(dynamic iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    return d == null ? '' : '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
