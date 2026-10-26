import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';
import 'settings.dart';

/// «الموقع»: اللي العميل بيشوفه — إظهار/إخفاء الأسعار، كل جهاز/غرفة ظاهر ولا مخفي، والسعر بلمسة.
class SiteScreen extends StatefulWidget {
  final int reload;
  const SiteScreen({super.key, required this.reload});
  @override
  State<SiteScreen> createState() => _SiteScreenState();
}

class _SiteScreenState extends State<SiteScreen> {
  List<Map<String, dynamic>>? _branches;
  bool _showPrices = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await rpc('admin_branches');
      final s = Map<String, dynamic>.from(await rpc('admin_get_settings') as Map);
      if (!mounted) return;
      setState(() {
        _branches = (b as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _showPrices = s['show_prices'] != false;
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.toString(), error: true);
    }
  }

  Future<void> _toggle(Map<String, dynamic> o, bool v) async {
    setState(() => o['is_active'] = v);
    final ok = await run(context, () => rpcOk('admin_offering_quick', {'p_id': o['id'], 'p_active': v}),
        ok: v ? '«${o['name']}» ظاهر على الموقع' : '«${o['name']}» اتخفى من الموقع');
    if (!ok && mounted) setState(() => o['is_active'] = !v);
  }

  Future<num?> _askAmount(String title, num? current, String suffix, {String? hint}) {
    final c = TextEditingController(text: current == null ? '' : money(current).replaceAll(' ج', ''));
    return showDialog<num>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            decoration: InputDecoration(suffixText: suffix),
            onSubmitted: (t) => Navigator.pop(ctx, num.tryParse(t)),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(hint, style: const TextStyle(color: Colors.white60, fontSize: 13)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(ctx, num.tryParse(c.text)), child: const Text('حفظ')),
        ],
      ),
    );
  }

  Future<void> _price(Map<String, dynamic> o) async {
    final v = await _askAmount('سعر الساعة — ${o['name']}', o['price_per_hour'] as num?, o['kind'] == 'pc' ? 'ج / جهاز' : 'ج');
    if (v == null || !mounted) return;
    if (await run(context, () => rpcOk('admin_offering_quick', {'p_id': o['id'], 'p_price': v}), ok: 'السعر اتغير')) {
      setState(() => o['price_per_hour'] = v);
    }
  }

  Future<void> _deposit(Map<String, dynamic> o) async {
    final v = await _askAmount('الـ deposit — ${o['name']}', o['deposit'] as num?, 'ج',
        hint: 'اكتب 0 لو مش عايز deposit (الحجز بيتأكد أول ما توافق). المبلغ الجديد بيسري على الطلبات الجديدة بس.');
    if (v == null || !mounted) return;
    if (await run(context, () => rpcOk('admin_offering_quick', {'p_id': o['id'], 'p_deposit': v}), ok: 'الـ deposit اتغير')) {
      setState(() => o['deposit'] = v);
    }
  }

  Future<void> _depositAll() async {
    final v = await _askAmount('الـ deposit لكل الأجهزة والغرف', null, 'ج',
        hint: 'هيتغير لكل الأنواع في كل الفروع مرة واحدة. 0 = من غير deposit. الطلبات اللي اتقبلت بالفعل بتفضل بمبلغها.');
    if (v == null || !mounted) return;
    if (await run(context, () => rpcOk('admin_set_deposit_all', {'p_deposit': v}), ok: 'الـ deposit اتغير للكل')) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final branches = _branches;
    if (branches == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Card(
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    secondary: Icon(_showPrices ? Icons.sell : Icons.sell_outlined, color: const Color(0xFFA78BFA)),
                    title: const Text('إظهار الأسعار على الموقع', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    subtitle: Text(_showPrices ? 'العميل شايف سعر الساعة' : 'الأسعار مخفية — العميل بيشوف الـ deposit بس بعد الموافقة'),
                    value: _showPrices,
                    onChanged: (v) async {
                      setState(() => _showPrices = v);
                      if (!await run(context, () => rpcOk('admin_set_show_prices', {'p_show': v}),
                          ok: v ? 'الأسعار ظاهرة' : 'الأسعار اتخفت')) {
                        if (mounted) setState(() => _showPrices = !v);
                      }
                    },
                  ),
                ),
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: const Icon(Icons.payments_outlined, color: Color(0xFFA78BFA)),
                    title: const Text('الـ deposit لكل الحجوزات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    subtitle: Text(_depositSummary(branches)),
                    trailing: const Icon(Icons.edit),
                    onTap: _depositAll,
                  ),
                ),
                for (final b in branches) ..._branch(b),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  String _depositSummary(List<Map<String, dynamic>> branches) {
    final all = {
      for (final b in branches)
        for (final o in (b['offerings'] as List? ?? const [])) (o as Map)['deposit'] as num? ?? 0,
    };
    if (all.isEmpty) return 'دوس عشان تحدد الـ deposit';
    if (all.length == 1) return all.first == 0 ? 'من غير deposit — دوس للتغيير' : '${money(all.first)} لكل حجز — دوس للتغيير';
    return 'مختلف حسب النوع (تحت) — دوس عشان توحّده';
  }

  List<Widget> _branch(Map<String, dynamic> b) {
    final offerings = ((b['offerings'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
        child: Row(children: [
          Text('${b['name']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton.icon(
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => BranchEditor(branch: b)));
              _load();
            },
            icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
            label: const Text('العنوان والصور'),
          ),
        ]),
      ),
      for (final o in offerings) _offering(o),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () async {
            if (await editOffering(context, {'branch_id': b['id'], 'kind': 'ps_room', 'units': 1, 'max_per_booking': 1, 'deposit': 50, 'is_active': true})) {
              _load();
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('إضافة جهاز أو غرفة'),
        ),
      ),
    ];
  }

  Widget _offering(Map<String, dynamic> o) {
    final on = o['is_active'] == true;
    return Opacity(
      opacity: on ? 1 : .55,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(children: [
            CircleAvatar(
              backgroundColor: const Color(0xFF2A1D52),
              child: Icon(o['kind'] == 'pc' ? Icons.computer : Icons.sports_esports, color: const Color(0xFFC4B5FD)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: () async {
                  if (await editOffering(context, o)) _load();
                },
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${o['name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(on ? 'ظاهر على الموقع · العدد ${o['units']}' : 'مخفي من الموقع',
                      style: TextStyle(fontSize: 13, color: on ? const Color(0xFF86EFAC) : Colors.white54)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.sell_outlined, size: 16),
                      label: Text('${money(o['price_per_hour'] as num?)}/ساعة'),
                      onPressed: () => _price(o),
                    ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.payments_outlined, size: 16),
                      label: Text((o['deposit'] as num? ?? 0) == 0 ? 'من غير deposit' : 'deposit ${money(o['deposit'] as num?)}'),
                      onPressed: () => _deposit(o),
                    ),
                  ]),
                ]),
              ),
            ),
            Switch(value: on, onChanged: (v) => _toggle(o, v)),
          ]),
        ),
      ),
    );
  }
}
