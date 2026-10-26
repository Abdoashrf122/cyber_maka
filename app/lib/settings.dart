import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'account.dart';
import 'blocks.dart';
import 'config.dart';
import 'core.dart';
import 'push.dart';
import 'team.dart';

class SettingsScreen extends StatefulWidget {
  final String adminName;
  const SettingsScreen({super.key, required this.adminName});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _s;
  final _c = <String, TextEditingController>{};
  bool _dirty = false;
  int _meVersion = 0;

  static const _textKeys = [
    'closed_message', 'deposit_policy', 'instapay_address', 'instapay_phone', 'telda_handle', 'wallet_phone', 'pay_note',
  ];
  static const _intKeys = [
    'approve_minutes', 'pay_minutes', 'min_lead_minutes', 'max_days_ahead', 'slot_minutes', 'min_duration_min', 'max_duration_min',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = Map<String, dynamic>.from(await rpc('admin_get_settings') as Map);
      if (!mounted) return;
      for (final k in [..._textKeys, ..._intKeys]) {
        (_c[k] ??= TextEditingController()).text = '${s[k] ?? ''}';
      }
      setState(() {
        _s = s;
        _dirty = false;
      });
    } on ApiError catch (e) {
      if (mounted) toast(context, e.toString(), error: true);
    }
  }

  Future<void> _save([Map<String, dynamic>? only]) async {
    final p = only ??
        {
          for (final k in _textKeys) k: _c[k]!.text.trim(),
          for (final k in _intKeys) k: int.tryParse(_c[k]!.text.trim()),
          'booking_enabled': _s!['booking_enabled'],
          'unique_amount': _s!['unique_amount'],
          'auto_confirm_notifications': _s!['auto_confirm_notifications'],
          'auto_confirm_sms': _s!['auto_confirm_sms'],
          'notif_packages': _s!['notif_packages'],
          'sms_senders': _s!['sms_senders'],
        }..removeWhere((k, v) => v == null);
    final ok = await run(context, () => rpcOk('admin_update_settings', {'p': p}), ok: 'اتحفظ');
    if (ok) await _load();
  }

  void _set(String k, dynamic v) => setState(() {
        _s![k] = v;
        _dirty = true;
      });

  Widget _field(String k, String label, {bool number = false, int lines = 1, String? hint, TextDirection? dir}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: _c[k],
          keyboardType: number ? TextInputType.number : null,
          inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
          maxLines: lines,
          textDirection: dir,
          onChanged: (_) => setState(() => _dirty = true),
          decoration: InputDecoration(labelText: label, helperText: hint),
        ),
      );

  Widget _section(String title, List<Widget> children, {IconData? icon}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, color: const Color(0xFFA78BFA)), const SizedBox(width: 8)],
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  Widget _list(String key, String label, String hint) {
    final items = ((_s![key] as List?) ?? const []).map((e) => '$e').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      Text(hint, style: const TextStyle(color: Colors.white54, fontSize: 13)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final i in items)
          InputChip(label: Text(i), onDeleted: () => _set(key, [...items]..remove(i))),
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: const Text('إضافة'),
          onPressed: () async {
            final c = TextEditingController();
            final v = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(label),
                content: TextField(controller: c, autofocus: true, textDirection: TextDirection.ltr),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('رجوع')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('إضافة')),
                ],
              ),
            );
            if (v != null && v.isNotEmpty && !items.contains(v)) _set(key, [...items, v]);
          },
        ),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) return const Center(child: CircularProgressIndicator());
    return Stack(children: [
      ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (isAndroid) ThisPhoneCard(onApprove: (kind, origin) async {
                  final key = kind == 'sms' ? 'sms_senders' : 'notif_packages';
                  final list = [...((s[key] as List?) ?? const []).map((e) => '$e')];
                  if (!list.contains(origin)) list.add(origin);
                  await _save({key: list});
                }),
                _section('الحجز من الموقع', icon: Icons.public, [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('الحجز من الموقع شغال'),
                    subtitle: const Text('لو قفلته، الموقع بيعرض الرسالة اللي تحت بدل فورم الحجز'),
                    value: s['booking_enabled'] == true,
                    onChanged: (v) => _set('booking_enabled', v),
                  ),
                  _field('closed_message', 'رسالة لما الحجز يكون واقف', lines: 2),
                  Row(children: [
                    Expanded(child: _field('approve_minutes', 'مهلة رد المحل (دقيقة)', number: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _field('pay_minutes', 'مهلة تحويل الـ deposit (دقيقة)', number: true)),
                  ]),
                  Row(children: [
                    Expanded(child: _field('min_lead_minutes', 'أقل وقت قبل الميعاد (دقيقة)', number: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _field('max_days_ahead', 'الحجز لحد كام يوم قدام', number: true)),
                  ]),
                  Row(children: [
                    Expanded(child: _field('min_duration_min', 'أقل مدة (دقيقة)', number: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _field('max_duration_min', 'أطول مدة (دقيقة)', number: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _field('slot_minutes', 'المواعيد كل (15/30/60)', number: true)),
                  ]),
                  _field('deposit_policy', 'سياسة الـ deposit (بتظهر للعميل)', lines: 3),
                ]),
                _section('بيانات تحويل الـ deposit', icon: Icons.account_balance_wallet_outlined, [
                  const Text('بتظهر للعميل بس بعد ما توافق على طلبه.', style: TextStyle(color: Colors.white54)),
                  _field('instapay_address', 'عنوان InstaPay (مثلاً name@instapay)', dir: TextDirection.ltr),
                  _field('instapay_phone', 'رقم موبايل InstaPay', number: true, dir: TextDirection.ltr),
                  _field('telda_handle', 'Telda (@username)', dir: TextDirection.ltr),
                  _field('wallet_phone', 'محفظة (فودافون كاش …) — اختياري', number: true, dir: TextDirection.ltr),
                  _field('pay_note', 'ملاحظة للعميل — اختياري', lines: 2),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('deposit مميّز لكل حجز'),
                    subtitle: const Text('لو حجزين مستنيين نفس المبلغ، التاني بيدفع جنيه زيادة (بيتخصم من حسابه) عشان التأكيد التلقائي يفرّق بينهم'),
                    value: s['unique_amount'] == true,
                    onChanged: (v) => _set('unique_amount', v),
                  ),
                ]),
                _section('التأكيد التلقائي للـ deposit', icon: Icons.bolt, [
                  const Text(
                    'موبايل المحل بيقرا التحويلات الواردة من التطبيقات والأسماء دي بس. أي رسالة جاية من رقم موبايل بتتجاهل (ضد النصب)، '
                    'والمبلغ لازم يطابق deposit حجز مستني بالظبط.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('من إشعارات التطبيقات'),
                    value: s['auto_confirm_notifications'] == true,
                    onChanged: (v) => _set('auto_confirm_notifications', v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('من رسايل SMS (أسماء شركات بس)'),
                    value: s['auto_confirm_sms'] == true,
                    onChanged: (v) => _set('auto_confirm_sms', v),
                  ),
                  _list('notif_packages', 'التطبيقات المسموحة', 'اسم الباكدج (من «اعتمد» في كارت الموبايل أسهل)'),
                  _list('sms_senders', 'أسماء الراسل المسموحة في الـ SMS', 'زي InstaPay, CIB, NBE — لازم فيها حروف'),
                ]),
                _section('الفروع والأسعار والصور', icon: Icons.store_outlined, [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('إدارة الفروع'),
                    subtitle: const Text('العنوان، اللوكيشن، المواعيد، الأجهزة والغرف وأسعارها، الصور'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BranchesScreen())),
                  ),
                ]),
                _section('المحظورين', icon: Icons.block, [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('أرقام ومتصفحات عليها بلوك'),
                    subtitle: const Text('فك البلوك، أو اعمل بلوك لرقم بإيدك'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BlocksScreen())),
                  ),
                ]),
                _section('الأجهزة المسجلة', icon: Icons.devices_other, [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('موبايلات المحل'),
                    subtitle: const Text('اللي بترن وبتقرا التحويلات — تقدر توقف أي واحد'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DevicesScreen())),
                  ),
                ]),
                _section('الفريق', icon: Icons.group_outlined, [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('الأدمنز'),
                    subtitle: const Text('إضافة أدمن جديد، إعادة كلمة سر، أو مسح حساب — أي أدمن يقدر'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TeamScreen())),
                  ),
                ]),
                _section('الحساب', icon: Icons.person_outline, [
                  FutureBuilder<dynamic>(
                    key: ValueKey(_meVersion),
                    future: rpc('admin_me'),
                    builder: (context, snap) {
                      final me = snap.data is Map ? Map<String, dynamic>.from(snap.data as Map) : const <String, dynamic>{};
                      final name = '${me['name'] ?? widget.adminName}';
                      final user = '${me['username'] ?? ''}';
                      final phone = me['phone'] as String?;
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text('الاسم: $name'),
                        Text('اسم المستخدم: $user', style: const TextStyle(color: Colors.white70)),
                        Text('الموبايل: ${phone ?? '—'}', style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          OutlinedButton.icon(
                            onPressed: () => changePassword(context),
                            icon: const Icon(Icons.password),
                            label: const Text('تغيير كلمة السر'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              if (await changeUsername(context, user)) setState(() => _meVersion++);
                            },
                            icon: const Icon(Icons.badge_outlined),
                            label: const Text('تغيير اسم المستخدم'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              if (await editProfile(context, name, phone)) setState(() => _meVersion++);
                            },
                            icon: const Icon(Icons.person_outline),
                            label: const Text('الاسم والموبايل'),
                          ),
                        ]),
                      ]);
                    },
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (!await confirmDialog(context, 'خروج', isAndroid ? 'الموبايل ده هيبطل يرن ويقرا التحويلات.' : 'متأكد؟', yes: 'خروج')) return;
                      await pushLogout();
                      await Native.disable();
                      await sb.auth.signOut();
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('خروج'),
                  ),
                ]),
              ]),
            ),
          ),
        ],
      ),
      if (_dirty)
        PositionedDirectional(
          bottom: 16,
          start: 16,
          end: 16,
          child: Center(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
              onPressed: () => _save(),
              icon: const Icon(Icons.save),
              label: const Text('حفظ التغييرات'),
            ),
          ),
        ),
    ]);
  }
}

// ═════════ الموبايل ده (أندرويد) ═════════

class ThisPhoneCard extends StatefulWidget {
  final Future<void> Function(String kind, String origin) onApprove;
  const ThisPhoneCard({super.key, required this.onApprove});
  @override
  State<ThisPhoneCard> createState() => _ThisPhoneCardState();
}

class _ThisPhoneCardState extends State<ThisPhoneCard> with WidgetsBindingObserver {
  Map<String, dynamic> _st = const {};
  List<Map<String, dynamic>> _cand = const [];
  Timer? _t;
  final _test = TextEditingController();
  String? _testResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _t = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _t?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final st = await Native.status();
    final c = await Native.candidates();
    if (!mounted) return;
    setState(() {
      _st = st;
      _cand = c;
    });
  }

  Widget _row(bool ok, String title, String hint, {String? button, VoidCallback? onTap}) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(ok ? Icons.check_circle : Icons.error_outline, color: ok ? const Color(0xFF22C55E) : const Color(0xFFF59E0B)),
        title: Text(title),
        subtitle: ok ? null : Text(hint, style: const TextStyle(fontSize: 13)),
        trailing: ok || button == null ? null : TextButton(onPressed: onTap, child: Text(button)),
      );

  @override
  Widget build(BuildContext context) {
    final last = (_st['lastPulseAt'] as num? ?? 0).toInt();
    final lastAt = last == 0 ? null : DateTime.fromMillisecondsSinceEpoch(last);
    final online = lastAt != null && DateTime.now().difference(lastAt).inSeconds < 40;
    final err = '${_st['lastError'] ?? ''}';
    return Card(
      color: const Color(0xFF1B1B3A),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            Icon(Icons.phone_android, color: Color(0xFFA78BFA)),
            SizedBox(width: 8),
            Text('الموبايل ده', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ]),
          _row(online, online ? 'شغال — بيستقبل الحجوزات (${agoText(lastAt)})' : 'الخدمة مش متصلة',
              err.isEmpty ? 'لسه بيبدأ…' : err, button: 'شغّل', onTap: () async {
            await ensureDeviceRegistered().catchError((_) {});
            _refresh();
          }),
          _row(_st['postNotifications'] == true, 'الإشعارات مسموحة', 'من غيرها الرنة مش هتظهر',
              button: 'اسمح', onTap: () => Native.call('requestPostNotifications')),
          _row(_st['batteryIgnored'] == true, 'مستثنى من توفير البطارية', 'عشان الرنة ماتتأخرش والموبايل مقفول',
              button: 'استثني', onTap: () => Native.call('requestBatteryExemption')),
          const Divider(),
          const Text('التأكيد التلقائي للـ deposit (اختياري — على الموبايل اللي عليه InstaPay/Telda)',
              style: TextStyle(color: Colors.white70)),
          _row(_st['notificationAccess'] == true, 'قراية إشعارات التحويل',
              'افتح الإعدادات وفعّل «أدمن سيبر مكة». لو الاختيار رمادي: من معلومات التطبيق ⋮ ← «السماح بالإعدادات المحظورة» الأول.',
              button: 'فعّل', onTap: () => Native.call('openNotificationAccess')),
          _row(_st['sms'] == true, 'استقبال رسايل البنوك (SMS)', 'لو الطلب مارجعش: من معلومات التطبيق ⋮ ← «السماح بالإعدادات المحظورة».',
              button: 'اسمح', onTap: () => Native.call('requestSms')),
          if (_st['sms'] != true || _st['notificationAccess'] != true)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => Native.call('openAppSettings'),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('معلومات التطبيق'),
              ),
            ),
          if ((_st['queue'] as num? ?? 0) > 0)
            Text('${_st['queue']} تحويل مستني النت عشان يتبعت', style: const TextStyle(color: Color(0xFFFBBF24))),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(onPressed: () => Native.call('testRing'), icon: const Icon(Icons.volume_up), label: const Text('جرّب الرنة')),
            OutlinedButton.icon(onPressed: () => Native.call('snooze'), icon: const Icon(Icons.volume_off), label: const Text('اسكت')),
          ]),
          if (_cand.isNotEmpty) ...[
            const Divider(),
            const Text('رسايل فيها مبالغ اتجاهلت (بتظهر هنا بس — ماتبعتتش للسيرفر):', style: TextStyle(color: Colors.white70)),
            for (final c in _cand)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(c['kind'] == 'sms' ? Icons.sms_outlined : Icons.notifications_none),
                title: Text('${c['label']}  ·  ${c['note']}'),
                subtitle: Text('${c['text']}', maxLines: 3, overflow: TextOverflow.ellipsis),
                trailing: (c['note'] as String).contains('مش في القايمة')
                    ? TextButton(
                        onPressed: () async {
                          final origin = '${c['origin']}';
                          final ok = await confirmDialog(context, 'اعتمد المصدر ده؟',
                              'هيتقري منه التحويلات الواردة بعد كده:\n$origin\n\nاعتمد التطبيقات/البنوك الحقيقية بس.', yes: 'اعتمد');
                          if (ok) await widget.onApprove('${c['kind']}', origin);
                        },
                        child: const Text('اعتمد'),
                      )
                    : null,
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () async {
                  await Native.call('clearCandidates');
                  _refresh();
                },
                child: const Text('امسح القايمة'),
              ),
            ),
          ],
          const Divider(),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('جرّب قراية رسالة'),
            children: [
              TextField(controller: _test, maxLines: 3, decoration: const InputDecoration(hintText: 'الصق نص رسالة/إشعار تحويل')),
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton(
                  onPressed: () async {
                    final r = await Native.parseTest(_test.text);
                    setState(() => _testResult = r == null
                        ? '—'
                        : 'المبلغ: ${r['amount'] ?? 'مش لاقيه'} · من: ${r['payer'] ?? '—'} · ${r['incoming'] == true ? 'وارد ✓' : 'مش وارد ✗'}');
                  },
                  child: const Text('اقرا'),
                ),
              ),
              if (_testResult != null) Padding(padding: const EdgeInsets.all(8), child: Text(_testResult!)),
            ],
          ),
        ]),
      ),
    );
  }
}

// ═════════ الأجهزة ═════════

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await rpc('admin_devices').catchError((_) => const []);
    if (mounted) setState(() => _items = (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('موبايلات المحل')),
        body: _items == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(12), children: [
                if (_items!.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(30), child: Text('مفيش أجهزة'))),
                for (final d in _items!)
                  Card(
                    child: ListTile(
                      leading: Icon(Icons.phone_android, color: d['revoked_at'] == null ? const Color(0xFF22C55E) : Colors.grey),
                      title: Text('${d['name']}'),
                      subtitle: Text(d['revoked_at'] != null
                          ? 'متوقف'
                          : 'آخر ظهور: ${agoText(DateTime.tryParse('${d['last_seen']}')?.toLocal())}'),
                      trailing: d['revoked_at'] != null
                          ? null
                          : TextButton(
                              onPressed: () async {
                                if (!await confirmDialog(context, 'توقيف الجهاز؟', 'هيبطل يرن ويقرا التحويلات (لو عايزه يرجع، سجّل دخول عليه تاني).', yes: 'وقّف', danger: true)) return;
                                if (!context.mounted) return;
                                await run(context, () => rpcOk('admin_revoke_device', {'p_id': d['id']}), ok: 'اتوقف');
                                _load();
                              },
                              child: const Text('وقّف', style: TextStyle(color: Color(0xFFFCA5A5))),
                            ),
                    ),
                  ),
              ]),
      );
}

// ═════════ الفروع ═════════

String photoUrl(String path) => '$kApiUrl/storage/v1/object/public/photos/$path';

class BranchesScreen extends StatefulWidget {
  const BranchesScreen({super.key});
  @override
  State<BranchesScreen> createState() => _BranchesScreenState();
}

class _BranchesScreenState extends State<BranchesScreen> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await rpc('admin_branches').catchError((_) => const []);
    if (mounted) setState(() => _items = (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
  }

  Future<void> _open(Map<String, dynamic>? b) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => BranchEditor(branch: b)));
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('الفروع')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _open(null),
          icon: const Icon(Icons.add),
          label: const Text('فرع جديد'),
        ),
        body: _items == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(12), children: [
                for (final b in _items!)
                  Card(
                    child: ListTile(
                      leading: Icon(Icons.store, color: b['is_active'] == true ? const Color(0xFFA78BFA) : Colors.grey),
                      title: Text('${b['name']}${b['is_active'] == true ? '' : ' (مخفي)'}'),
                      subtitle: Text('${(b['offerings'] as List).length} نوع حجز · ${(b['photos'] as List).length} صورة'),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () => _open(b),
                    ),
                  ),
              ]),
      );
}

class BranchEditor extends StatefulWidget {
  final Map<String, dynamic>? branch;
  const BranchEditor({super.key, this.branch});
  @override
  State<BranchEditor> createState() => _BranchEditorState();
}

class _BranchEditorState extends State<BranchEditor> {
  late Map<String, dynamic> _b = Map<String, dynamic>.from(widget.branch ?? {'open_24h': true, 'is_active': true});
  final _c = <String, TextEditingController>{};
  bool _busy = false;

  static const _keys = ['name', 'address', 'maps_url', 'phone', 'whatsapp', 'hours_text', 'open_time', 'close_time', 'sort'];

  @override
  void initState() {
    super.initState();
    for (final k in _keys) {
      _c[k] = TextEditingController(text: _b[k] == null ? '' : '${_b[k]}');
    }
  }

  Future<void> _reload() async {
    final r = await rpc('admin_branches').catchError((_) => const []);
    final found = (r as List).map((e) => Map<String, dynamic>.from(e as Map)).where((e) => e['id'] == _b['id']);
    if (found.isNotEmpty && mounted) setState(() => _b = found.first);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final p = {
      if (_b['id'] != null) 'id': _b['id'],
      for (final k in _keys) k: _c[k]!.text.trim(),
      'open_24h': _b['open_24h'] == true,
      'is_active': _b['is_active'] == true,
      'sort': int.tryParse(_c['sort']!.text.trim()) ?? 0,
    };
    await run(context, () async {
      final r = await rpcOk('admin_save_branch', {'p': p});
      _b['id'] = r['id'];
    }, ok: 'اتحفظ');
    if (mounted) setState(() => _busy = false);
    await _reload();
  }

  Future<void> _addPhoto() async {
    if (_b['id'] == null) return toast(context, 'احفظ الفرع الأول', error: true);
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 82);
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      if (mounted) toast(context, 'الصورة أكبر من 5 ميجا', error: true);
      return;
    }
    final name = x.name.toLowerCase();
    final ext = name.endsWith('.png') ? 'png' : name.endsWith('.webp') ? 'webp' : 'jpg';
    final type = ext == 'png' ? 'image/png' : ext == 'webp' ? 'image/webp' : 'image/jpeg';
    final path = '${_b['slug'] ?? 'branch'}/${DateTime.now().millisecondsSinceEpoch}.$ext';
    if (!mounted) return;
    await run(context, () async {
      await sb.storage.from('photos').uploadBinary(path, bytes, fileOptions: FileOptions(contentType: type));
      await rpcOk('admin_add_photo', {'p_branch': _b['id'], 'p_path': path});
    }, ok: 'الصورة اترفعت');
    await _reload();
  }

  Future<void> _deletePhoto(Map<String, dynamic> p) async {
    if (!await confirmDialog(context, 'مسح الصورة؟', 'هتختفي من الموقع.', yes: 'امسح', danger: true)) return;
    if (!mounted) return;
    await run(context, () async {
      final r = await rpcOk('admin_delete_photo', {'p_id': p['id']});
      if (r['path'] != null) await sb.storage.from('photos').remove(['${r['path']}']);
    });
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    Widget f(String k, String label, {String? hint, TextDirection? dir, TextInputType? type}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: _c[k],
            textDirection: dir,
            keyboardType: type,
            decoration: InputDecoration(labelText: label, helperText: hint),
          ),
        );
    final offerings = ((_b['offerings'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final photos = ((_b['photos'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

    return Scaffold(
      appBar: AppBar(title: Text(_b['id'] == null ? 'فرع جديد' : '${_b['name']}')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    f('name', 'اسم الفرع (مثلاً فرع فلمنج)'),
                    f('address', 'العنوان'),
                    f('maps_url', 'لينك اللوكيشن على جوجل مابس', hint: 'من جوجل مابس: مشاركة ← نسخ الرابط (لازم يبدأ بـ https://)', dir: TextDirection.ltr),
                    Row(children: [
                      Expanded(child: f('phone', 'تليفون الفرع', dir: TextDirection.ltr, type: TextInputType.phone)),
                      const SizedBox(width: 10),
                      Expanded(child: f('whatsapp', 'واتساب الفرع', dir: TextDirection.ltr, type: TextInputType.phone)),
                    ]),
                    f('hours_text', 'المواعيد (نص بيظهر للعميل)', hint: 'مثلاً: مفتوح 24 ساعة'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('مفتوح 24 ساعة'),
                      value: _b['open_24h'] == true,
                      onChanged: (v) => setState(() => _b['open_24h'] = v),
                    ),
                    if (_b['open_24h'] != true)
                      Row(children: [
                        Expanded(child: f('open_time', 'بيفتح (HH:MM)', hint: 'مثلاً 10:00', dir: TextDirection.ltr)),
                        const SizedBox(width: 10),
                        Expanded(child: f('close_time', 'بيقفل (HH:MM)', hint: 'مثلاً 02:00 (بعد نص الليل عادي)', dir: TextDirection.ltr)),
                      ]),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('ظاهر في الموقع'),
                      value: _b['is_active'] == true,
                      onChanged: (v) => setState(() => _b['is_active'] = v),
                    ),
                    f('sort', 'الترتيب', type: TextInputType.number),
                    const SizedBox(height: 8),
                    FilledButton.icon(onPressed: _busy ? null : _save, icon: const Icon(Icons.save), label: const Text('حفظ الفرع')),
                  ]),
                ),
              ),
              if (_b['id'] != null) ...[
                const SizedBox(height: 8),
                Row(children: [
                  const Text('الأجهزة والغرف', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      if (await editOffering(context, {'branch_id': _b['id'], 'kind': 'pc', 'units': 1, 'max_per_booking': 1, 'deposit': 50, 'is_active': true})) _reload();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة'),
                  ),
                ]),
                for (final o in offerings)
                  Card(
                    child: ListTile(
                      leading: Icon(o['kind'] == 'pc' ? Icons.computer : Icons.sports_esports,
                          color: o['is_active'] == true ? const Color(0xFFA78BFA) : Colors.grey),
                      title: Text('${o['name']}${o['is_active'] == true ? '' : ' (مخفي)'}'),
                      subtitle: Text('العدد ${o['units']} · ${money(o['price_per_hour'] as num?)}/ساعة${o['kind'] == 'pc' ? ' للجهاز' : ''} · deposit ${money(o['deposit'] as num?)}'),
                      trailing: const Icon(Icons.edit),
                      onTap: () async {
                        if (await editOffering(context, o)) _reload();
                      },
                    ),
                  ),
                const SizedBox(height: 8),
                Row(children: [
                  const Text('صور الفرع', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(onPressed: _addPhoto, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('إضافة صورة')),
                ]),
                const Text('صوّر المكان والأجهزة والأجواء — من غير وشوش زباين.', style: TextStyle(color: Colors.white54)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final p in photos)
                    Stack(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(photoUrl('${p['path']}'), width: 160, height: 110, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(width: 160, height: 110, color: Colors.black26, child: const Icon(Icons.broken_image))),
                      ),
                      PositionedDirectional(
                        top: 4,
                        end: 4,
                        child: IconButton.filledTonal(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _deletePhoto(p),
                          icon: const Icon(Icons.delete_outline, size: 18),
                        ),
                      ),
                    ]),
                ]),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

Future<bool> editOffering(BuildContext context, Map<String, dynamic> o) async {
  final m = Map<String, dynamic>.from(o);
  final name = TextEditingController(text: '${m['name'] ?? ''}');
  final details = TextEditingController(text: '${m['details'] ?? ''}');
  final units = TextEditingController(text: '${m['units'] ?? 1}');
  final maxPer = TextEditingController(text: '${m['max_per_booking'] ?? 1}');
  final price = TextEditingController(text: '${m['price_per_hour'] ?? ''}');
  final deposit = TextEditingController(text: '${m['deposit'] ?? 50}');
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(m['id'] == null ? 'نوع حجز جديد' : 'تعديل'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'pc', label: Text('أجهزة PC'), icon: Icon(Icons.computer)),
                  ButtonSegment(value: 'ps_room', label: Text('غرفة بلايستيشن'), icon: Icon(Icons.sports_esports)),
                ],
                selected: {'${m['kind']}'},
                onSelectionChanged: (s) => setS(() => m['kind'] = s.first),
              ),
              const SizedBox(height: 10),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم (مثلاً غرفة بلايستيشن 5)')),
              const SizedBox(height: 8),
              TextField(controller: details, maxLines: 2, decoration: const InputDecoration(labelText: 'وصف قصير')),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: units, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: m['kind'] == 'pc' ? 'عدد الأجهزة' : 'عدد الغرف'))),
                const SizedBox(width: 8),
                if (m['kind'] == 'pc')
                  Expanded(child: TextField(controller: maxPer, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'أقصى أجهزة في الحجز'))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: price, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: m['kind'] == 'pc' ? 'سعر الساعة للجهاز' : 'سعر الساعة للغرفة'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: deposit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الـ deposit (0 = من غير)'))),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('ظاهر للحجز'),
                value: m['is_active'] != false,
                onChanged: (v) => setS(() => m['is_active'] = v),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
          FilledButton(
            onPressed: () async {
              final p = {
                if (m['id'] != null) 'id': m['id'],
                'branch_id': m['branch_id'],
                'kind': m['kind'],
                'name': name.text.trim(),
                'details': details.text.trim(),
                'units': int.tryParse(units.text.trim()) ?? 1,
                'max_per_booking': m['kind'] == 'pc' ? (int.tryParse(maxPer.text.trim()) ?? 1) : 1,
                'price_per_hour': num.tryParse(price.text.trim()) ?? 0,
                'deposit': num.tryParse(deposit.text.trim()) ?? 0,
                'is_active': m['is_active'] != false,
              };
              final ok = await run(ctx, () => rpcOk('admin_save_offering', {'p': p}), ok: 'اتحفظ');
              if (ok && ctx.mounted) Navigator.pop(ctx, true);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );
  return saved == true;
}
