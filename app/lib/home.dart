import 'dart:async';

import 'package:flutter/material.dart';

import 'blocks.dart';
import 'core.dart';
import 'payments.dart';
import 'push.dart';
import 'settings.dart';
import 'site.dart';

/// الشاشة الرئيسية: بتسأل السيرفر كل 5 ثواني — طلب جديد = رنة (ويندوز) + نافذة قبول/رفض
class HomeScreen extends StatefulWidget {
  final String adminName;
  const HomeScreen({super.key, required this.adminName});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  Timer? _poll;
  Map<String, dynamic> _pulse = const {};
  String? _lastChange;
  int _reload = 0;
  bool _offline = false;
  bool _pushEnabled = false;
  bool _pushLoading = true;
  bool _pushPreferenceLoaded = false;
  bool _pushBusy = false;
  String? _pushError;
  final Set<String> _snoozed = {};
  final Set<String> _seenPending = {};
  final Set<String> _seenClaimed = {};
  String? _dialogFor;

  @override
  void initState() {
    super.initState();
    ensureDeviceRegistered().catchError((_) {});
    _loadPushPreference();
    _tick();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    Ringer.stopAll();
    super.dispose();
  }

  void refresh() {
    setState(() => _reload++);
    _tick();
  }

  Future<void> _loadPushPreference() async {
    try {
      if (isAndroid) await initPush();
      if (isWindows && !await initDesktopNotifications()) {
        throw StateError('تعذر تهيئة إشعارات سطح المكتب.');
      }
      final enabled = await rpc('admin_push_enabled');
      if (enabled is! bool) throw StateError('تعذر قراءة إعداد استقبال الطلبات.');
      if (isAndroid) {
        if (enabled) await requestOrderPushPermissionIfNeeded();
        await Native.call('setReceiveOrders', {'enabled': enabled});
      }
      if (!mounted) return;
      setState(() {
        _pushEnabled = enabled;
        _pushError = null;
        _pushLoading = false;
      });
      _pushPreferenceLoaded = true;
      _handleRing();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pushError = 'تعذر تحميل حالة استقبال الطلبات: $e';
        _pushLoading = false;
      });
    }
  }

  Future<void> _setPushEnabled(bool enabled) async {
    if (_pushBusy || _pushLoading) return;
    setState(() => _pushBusy = true);
    try {
      if (enabled && !await requestOrderPushPermission()) {
        if (mounted) {
          toast(
            context,
            'تعذر تفعيل الإشعارات. تأكد من إعداد OneSignal واسمح بالإشعارات.',
            error: true,
          );
        }
        return;
      }
      await rpcOk('admin_set_push_enabled', {'p_enabled': enabled});
      if (isAndroid) {
        await Native.call('setReceiveOrders', {'enabled': enabled});
      }
      if (!mounted) return;
      setState(() {
        _pushEnabled = enabled;
        _pushError = null;
      });
      toast(
        context,
        enabled ? 'استقبال طلبات الحجز اتفعل' : 'استقبال طلبات الحجز اتوقف',
      );
    } catch (e) {
      if (mounted) {
        toast(context, 'مقدرناش نغيّر استقبال الطلبات: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _pushBusy = false);
    }
  }

  Future<void> _tick() async {
    try {
      final p = Map<String, dynamic>.from(await rpc('admin_pulse') as Map);
      if (!mounted) return;
      setState(() {
        _pulse = p;
        _offline = false;
        if (p['last_change'] != _lastChange) {
          _lastChange = p['last_change'] as String?;
          _reload++;
        }
      });
      _handleRing();
    } on ApiError catch (e) {
      if (e.code == 'auth') await sb.auth.signOut();
      if (mounted) setState(() => _offline = true);
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    }
  }

  List<Map<String, dynamic>> _list(String k) =>
      ((_pulse[k] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  String? _ringSource(String key) {
    final path = _pulse[key] as String?;
    return path == null || path.isEmpty
        ? null
        : sb.storage.from('ringtones').getPublicUrl(path);
  }

  /// طلب جديد → صوت مرة واحدة + نافذة الطلب.
  /// العميل قال حوّل الـ deposit → رنة موقوتة (ويندوز هنا، أندرويد من الخدمة) + نافذة التأكيد.
  void _handleRing() {
    if (!_pushPreferenceLoaded) return;

    final pending = _list('pending');
    final fresh = pending
        .where((e) => !_seenPending.contains(e['id']))
        .toList();
    _seenPending
      ..retainAll(pending.map((e) => e['id'] as String))
      ..addAll(fresh.map((e) => e['id'] as String));

    final claimed = _list('claimed');
    final claimedIds = claimed.map((e) => e['id'] as String).toSet();
    final freshClaims = claimed
        .where((e) => !_seenClaimed.contains(e['id']))
        .toList();
    _seenClaimed
      ..retainAll(claimedIds)
      ..addAll(claimedIds);
    if (!_pushEnabled) {
      Ringer.stopAll();
      return;
    }
    if (isWindows) {
      for (final booking in fresh) {
        unawaited(
          showDesktopOrderNotification(
            id: booking['id'] as String,
            isClaim: false,
          ),
        );
      }
      for (final claim in freshClaims) {
        unawaited(
          showDesktopOrderNotification(
            id: claim['id'] as String,
            isClaim: true,
          ),
        );
      }
    }
    _snoozed.retainAll(claimed.map((e) => e['id'] as String).toSet());
    final active = claimed.where((e) => !_snoozed.contains(e['id'])).toList();
    if (active.isEmpty) {
      Ringer.stop();
    } else {
      Ringer.start(
        key: (active.map((e) => e['id'] as String).toList()..sort()).join(','),
        source: _ringSource('claim_ring_path'),
        mode: '${_pulse['claim_ring_mode'] ?? 'timed'}',
        seconds: (_pulse['claim_ring_seconds'] as num? ?? 30).toInt(),
      );
    }

    if (active.isEmpty && fresh.isNotEmpty) {
      Ringer.notifyOnce(
        source: _ringSource('new_ring_path'),
        mode: '${_pulse['new_ring_mode'] ?? 'once'}',
        seconds: (_pulse['new_ring_seconds'] as num? ?? 10).toInt(),
      );
    }
    if (_dialogFor != null) return;
    if (active.isNotEmpty) {
      _show(active.first['id'] as String, claim: true);
    } else if (fresh.isNotEmpty) {
      _show(fresh.first['id'] as String, claim: false);
    }
  }

  Future<void> _show(String id, {required bool claim}) async {
    _dialogFor = id;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: !claim,
      builder: (_) =>
          claim ? PaymentClaimDialog(id: id) : NewBookingDialog(id: id),
    );
    _dialogFor = null;
    if (result == 'later' && claim) {
      _snoozed.addAll(_list('claimed').map((e) => e['id'] as String));
      Ringer.stop();
      Native.call('snooze');
    }
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _list('pending').length;
    final claimed = _list('claimed').length;
    final unmatched = (_pulse['unmatched_events'] as num? ?? 0).toInt();
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final pages = <Widget>[
      BookingsList(
        scope: 'action',
        reload: _reload,
        onChanged: refresh,
        empty: 'مفيش طلبات محتاجة رد دلوقتي 👌',
      ),
      SchedulePage(reload: _reload, onChanged: refresh),
      SiteScreen(reload: _reload),
      PaymentsScreen(reload: _reload, onChanged: refresh),
      SettingsScreen(adminName: widget.adminName),
    ];
    final dests = [
      _Dest(Icons.notifications_active_outlined, 'الطلبات', pending + claimed),
      const _Dest(Icons.event_note_outlined, 'المواعيد', 0),
      const _Dest(Icons.storefront_outlined, 'الموقع', 0),
      _Dest(Icons.account_balance_wallet_outlined, 'التحويلات', unmatched),
      const _Dest(Icons.settings_outlined, 'الإعدادات', 0),
    ];

    final body = Column(
      children: [
        if (_offline)
          Container(
            width: double.infinity,
            color: const Color(0xFF7F1D1D),
            padding: const EdgeInsets.all(8),
            child: const Text(
              'مفيش اتصال بالسيرفر — بنحاول تاني…',
              textAlign: TextAlign.center,
            ),
          ),
        _pushControl(),
        Expanded(child: pages[_tab]),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(dests[_tab].label),
        actions: [
          if (pending > 0)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Chip(
                avatar: const Icon(Icons.notifications_active, size: 18),
                label: Text('$pending طلب جديد'),
                backgroundColor: const Color(0xFF9A3412),
              ),
            ),
          IconButton(
            tooltip: 'تحديث',
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _tab,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  destinations: [
                    for (final d in dests)
                      NavigationRailDestination(
                        icon: _badge(d),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (final d in dests)
                  NavigationDestination(icon: _badge(d), label: d.label),
              ],
            ),
    );
  }

  Widget _pushControl() => Card(
    margin: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 4),
    color: _pushEnabled
        ? const Color(0xFF172D2A)
        : const Color(0xFF1B1B30),
    child: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 8, 4),
      child: Row(
        children: [
          Icon(
            _pushEnabled
                ? Icons.notifications_active_rounded
                : Icons.notifications_off_outlined,
            color: _pushEnabled
                ? const Color(0xFF4ADE80)
                : Colors.white54,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'استلام طلبات الحجز',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  _pushError ??
                      (_pushEnabled
                          ? (isWindows
                                ? 'مفعّل — تنبيهات محلية أثناء تشغيل التطبيق'
                                : 'مفعّل — هتوصلك إشعارات الطلبات والتحويلات')
                          : 'متوقف — فعّله عشان توصلك إشعارات الطلبات'),
                  style: TextStyle(
                    color: _pushError != null
                        ? const Color(0xFFFCA5A5)
                        : Colors.white60,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (_pushLoading || _pushBusy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_pushError != null)
            IconButton(
              tooltip: 'إعادة المحاولة',
              onPressed: _loadPushPreference,
              icon: const Icon(Icons.refresh),
            )
          else
            Switch.adaptive(
              value: _pushEnabled,
              onChanged: _setPushEnabled,
            ),
        ],
      ),
    ),
  );

  Widget _badge(_Dest d) => Badge(
    isLabelVisible: d.count > 0,
    label: Text('${d.count}'),
    child: Icon(d.icon),
  );
}

class _Dest {
  final IconData icon;
  final String label;
  final int count;
  const _Dest(this.icon, this.label, this.count);
}

// ═════════ نافذة الطلب الجديد ═════════

class NewBookingDialog extends StatefulWidget {
  final String id;
  const NewBookingDialog({super.key, required this.id});
  @override
  State<NewBookingDialog> createState() => _NewBookingDialogState();
}

class _NewBookingDialogState extends State<NewBookingDialog> {
  Booking? _b;
  bool _busy = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _load();
    // لو حد رد عليه من جهاز تاني (الموبايل مثلاً) النافذة تقفل لوحدها
    _t = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await rpc('admin_booking', {'p_id': widget.id});
      if (!mounted || r == null) return;
      final b = Booking(Map<String, dynamic>.from(r as Map));
      if (_b != null && b.status != 'pending' && !_busy) {
        Navigator.pop(context, 'done');
        return;
      }
      setState(() => _b = b);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    return AlertDialog(
      icon: const Icon(
        Icons.notifications_active,
        size: 40,
        color: Color(0xFFF97316),
      ),
      title: const Text('طلب حجز جديد'),
      content: b == null
          ? const SizedBox(
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            )
          : (b.status != 'pending'
                ? Text(
                    'الطلب ده اتعامل معاه بالفعل (${statusLabels[b.status]}).',
                  )
                : SingleChildScrollView(child: BookingSummary(b: b))),
      actions: b == null || b.status != 'pending'
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context, 'done'),
                child: const Text('تمام'),
              ),
            ]
          : [
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        _busy = true;
                        final ok = await blockBooking(context, b);
                        _busy = false;
                        if (ok && context.mounted)
                          Navigator.pop(context, 'done');
                      },
                icon: const Icon(
                  Icons.block,
                  size: 18,
                  color: Color(0xFFF87171),
                ),
                label: const Text(
                  'بلوك',
                  style: TextStyle(color: Color(0xFFF87171)),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context, 'later'),
                child: const Text('بعدين'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final ok = await rejectBooking(context, b);
                        if (ok && context.mounted)
                          Navigator.pop(context, 'done');
                      },
                child: const Text('رفض'),
              ),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        final ok = await acceptBooking(context, b);
                        if (!context.mounted) return;
                        setState(() => _busy = false);
                        if (ok) Navigator.pop(context, 'done');
                      },
                icon: const Icon(Icons.check),
                label: const Text('قبول'),
              ),
            ],
    );
  }
}

// ═════════ نافذة «العميل حوّل الـ deposit» (مع الرنة الطويلة) ═════════

class PaymentClaimDialog extends StatefulWidget {
  final String id;
  const PaymentClaimDialog({super.key, required this.id});
  @override
  State<PaymentClaimDialog> createState() => _PaymentClaimDialogState();
}

class _PaymentClaimDialogState extends State<PaymentClaimDialog> {
  Booking? _b;
  bool _busy = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _load();
    // لو اتأكد تلقائي (إشعار InstaPay) أو حد رد من جهاز تاني → النافذة تقفل لوحدها
    _t = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await rpc('admin_booking', {'p_id': widget.id});
      if (!mounted || r == null) return;
      final b = Booking(Map<String, dynamic>.from(r as Map));
      if (_b != null && b.status != 'payment_claimed' && !_busy) {
        Navigator.pop(context, 'done');
        return;
      }
      setState(() => _b = b);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    return AlertDialog(
      icon: const Icon(Icons.payments, size: 40, color: Color(0xFF22C55E)),
      title: const Text('العميل حوّل الـ deposit'),
      content: b == null
          ? const SizedBox(
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'افتح InstaPay/Telda واتأكد إن ${money(b.depositAmount)} وصلت'
                    '${b.payerName != null ? ' من «${b.payerName}»' : ''}.',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF86EFAC),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '#${b.code}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  BookingSummary(b: b),
                ],
              ),
            ),
      actions: b == null
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context, 'later'),
                child: const Text('بعدين (إسكات)'),
              ),
            ]
          : [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context, 'later'),
                child: const Text('بعدين (إسكات)'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final reason = await askReason(
                          context,
                          'الـ deposit ماوصلش؟',
                          const ['الـ deposit ماوصلش', 'المبلغ غلط — كلّمنا'],
                        );
                        if (reason == null || !context.mounted) return;
                        setState(() => _busy = true);
                        final ok = await run(
                          context,
                          () => rpcOk('admin_set_status', {
                            'p_id': b.id,
                            'p_status': 'rejected',
                            'p_reason': reason,
                          }),
                          ok: 'اتلغى',
                        );
                        if (!context.mounted) return;
                        setState(() => _busy = false);
                        if (ok) Navigator.pop(context, 'done');
                      },
                child: const Text('ماوصلش'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF15803D),
                ),
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        final ok = await run(
                          context,
                          () => rpcOk('admin_confirm_payment', {'p_id': b.id}),
                          ok: 'الحجز اتأكد ✓',
                        );
                        if (!context.mounted) return;
                        setState(() => _busy = false);
                        if (ok) Navigator.pop(context, 'done');
                      },
                icon: const Icon(Icons.verified),
                label: const Text('وصلت — أكّد'),
              ),
            ],
    );
  }
}

// ═════════ الإجراءات ═════════

Future<bool> acceptBooking(BuildContext context, Booking b) => run(
  context,
  () async {
    final r = await rpcOk('admin_decide', {'p_id': b.id, 'p_accept': true});
    if (r['status'] == 'confirmed') return;
  },
  ok: b.depositBase > 0
      ? 'اتقبل — العميل بيحوّل الـ deposit دلوقتي'
      : 'اتقبل واتأكد',
);

Future<bool> rejectBooking(BuildContext context, Booking b) async {
  final reason = await askReason(context, 'سبب الرفض (بيظهر للعميل)', const [
    'الميعاد ده محجوز',
    'الفرع مقفول في الوقت ده',
    'الأجهزة مش متاحة',
    'الرقم مش واضح — كلّمنا',
  ]);
  if (reason == null || !context.mounted) return false;
  return run(
    context,
    () => rpcOk('admin_decide', {
      'p_id': b.id,
      'p_accept': false,
      'p_reason': reason,
    }),
    ok: 'اترفض',
  );
}

Future<String?> askReason(
  BuildContext context,
  String title,
  List<String> quick,
) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final q in quick)
                ActionChip(
                  label: Text(q),
                  onPressed: () => Navigator.pop(ctx, q),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'أو اكتب السبب'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('رجوع'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            ctx,
            c.text.trim().isEmpty ? quick.first : c.text.trim(),
          ),
          child: const Text('تمام'),
        ),
      ],
    ),
  );
}

// ═════════ القوايم ═════════

class SchedulePage extends StatefulWidget {
  final int reload;
  final VoidCallback onChanged;
  const SchedulePage({
    super.key,
    required this.reload,
    required this.onChanged,
  });
  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  String _scope = 'today';

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'today',
              label: Text('النهارده'),
              icon: Icon(Icons.today),
            ),
            ButtonSegment(
              value: 'upcoming',
              label: Text('الجاية'),
              icon: Icon(Icons.upcoming),
            ),
            ButtonSegment(
              value: 'history',
              label: Text('السجل'),
              icon: Icon(Icons.history),
            ),
          ],
          selected: {_scope},
          onSelectionChanged: (s) => setState(() => _scope = s.first),
        ),
      ),
      Expanded(
        child: BookingsList(
          key: ValueKey(_scope),
          scope: _scope,
          reload: widget.reload,
          onChanged: widget.onChanged,
          empty: switch (_scope) {
            'today' => 'مفيش حجوزات النهارده',
            'upcoming' => 'مفيش حجوزات متأكدة جاية',
            _ => 'مفيش حجوزات لسه',
          },
        ),
      ),
    ],
  );
}

class BookingsList extends StatefulWidget {
  final String scope;
  final int reload;
  final VoidCallback onChanged;
  final String empty;
  const BookingsList({
    super.key,
    required this.scope,
    required this.reload,
    required this.onChanged,
    required this.empty,
  });
  @override
  State<BookingsList> createState() => _BookingsListState();
}

class _BookingsListState extends State<BookingsList> {
  List<Booking>? _items;
  String? _error;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _load();
    // العدّادات (باقي كام دقيقة) تتحدّث
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant BookingsList old) {
    super.didUpdateWidget(old);
    if (old.reload != widget.reload || old.scope != widget.scope) _load();
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await rpc('admin_bookings', {
        'p_scope': widget.scope,
        'p_limit': widget.scope == 'history' ? 300 : 200,
      });
      if (!mounted) return;
      setState(() {
        _items = (r as List)
            .map((e) => Booking(Map<String, dynamic>.from(e as Map)))
            .toList();
        _error = null;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Text(_error!),
      );
    }
    if (_items!.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            Center(
              child: Text(
                widget.empty,
                style: const TextStyle(fontSize: 17, color: Colors.white70),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
        itemCount: _items!.length,
        itemBuilder: (_, i) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: BookingCard(b: _items![i], onChanged: widget.onChanged),
          ),
        ),
      ),
    );
  }
}

// ═════════ كارت الحجز ═════════

class BookingSummary extends StatelessWidget {
  final Booking b;
  const BookingSummary({super.key, required this.b});

  @override
  Widget build(BuildContext context) {
    Widget line(IconData i, String t, {Color? color, bool bold = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(i, size: 18, color: color ?? Colors.white60),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t,
                  style: TextStyle(
                    color: color,
                    fontWeight: bold ? FontWeight.bold : null,
                  ),
                ),
              ),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line(Icons.store, b.branchName),
        line(
          b.kind == 'pc' ? Icons.computer : Icons.sports_esports,
          b.what,
          bold: true,
        ),
        line(
          Icons.schedule,
          '${dayText(b.date)} — ${time12(b.time)} لـ ${time12(b.endTime)} (${durationText(b.durationMin)})',
          bold: true,
        ),
        line(Icons.person, b.customerName ?? '—'),
        if (b.phone != null) line(Icons.phone, b.phone!),
        if (b.note != null) line(Icons.notes, b.note!),
        line(
          Icons.payments_outlined,
          'الحساب ${money(b.priceTotal)} · الـ deposit ${money(b.depositAmount ?? b.depositBase)}',
        ),
      ],
    );
  }
}

class BookingCard extends StatelessWidget {
  final Booking b;
  final VoidCallback onChanged;
  const BookingCard({super.key, required this.b, required this.onChanged});

  Future<void> _act(BuildContext context, Future<bool> Function() f) async {
    if (await f()) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final color = statusColor(b.status);
    final ev = b.paymentEvent;
    String? timer;
    if (b.status == 'pending')
      timer = 'باقي للرد: ${minutesLeft(b.approveDeadline)}';
    if (b.status == 'awaiting_payment')
      timer = 'مهلة الدفع: ${minutesLeft(b.payDeadline)}';

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: color.withValues(alpha: b.status == 'pending' ? .9 : .35),
          width: b.status == 'pending' ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '#${b.code}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    statusLabels[b.status] ?? b.status,
                    style: TextStyle(color: color, fontWeight: FontWeight.bold),
                  ),
                ),
                const Spacer(),
                Text(
                  agoText(b.createdAt),
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 8),
            BookingSummary(b: b),
            if (timer != null) ...[
              const SizedBox(height: 6),
              Text(
                timer,
                style: const TextStyle(
                  color: Color(0xFFFBBF24),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            if (b.payerName != null)
              Text(
                'اسم المحوِّل حسب العميل: ${b.payerName}',
                style: const TextStyle(color: Color(0xFF7DD3FC)),
              ),
            if (b.paidVia != null)
              Text(
                'اتأكد: ${paidViaLabels[b.paidVia] ?? b.paidVia}',
                style: const TextStyle(color: Color(0xFF86EFAC)),
              ),
            if (ev != null)
              Text(
                'التحويل: ${money(ev['amount'] as num?)} من ${ev['payer'] ?? ev['origin']}',
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
            if (b.reason != null &&
                ![
                  'pending',
                  'awaiting_payment',
                  'payment_claimed',
                  'confirmed',
                ].contains(b.status))
              Text(
                'السبب: ${b.reason}',
                style: const TextStyle(color: Colors.white60),
              ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: _actions(context)),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    final list = <Widget>[];
    switch (b.status) {
      case 'pending':
        list.add(
          FilledButton.icon(
            onPressed: () => _act(context, () => acceptBooking(context, b)),
            icon: const Icon(Icons.check),
            label: const Text('قبول'),
          ),
        );
        list.add(
          OutlinedButton(
            onPressed: () => _act(context, () => rejectBooking(context, b)),
            child: const Text('رفض'),
          ),
        );
      case 'awaiting_payment':
      case 'payment_claimed':
        list.add(
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF15803D),
            ),
            onPressed: () => _act(context, () async {
              if (!await confirmDialog(
                context,
                'الفلوس وصلت؟',
                'اتأكد بنفسك إن ${money(b.depositAmount)} وصلت في InstaPay/Telda قبل ما تأكد.',
                yes: 'أيوه وصلت',
              )) {
                return false;
              }
              if (!context.mounted) return false;
              return run(
                context,
                () => rpcOk('admin_confirm_payment', {'p_id': b.id}),
                ok: 'الحجز اتأكد',
              );
            }),
            icon: const Icon(Icons.verified),
            label: const Text('الفلوس وصلت — أكّد'),
          ),
        );
        if (b.status == 'awaiting_payment') {
          list.add(
            OutlinedButton(
              onPressed: () => _act(
                context,
                () => run(
                  context,
                  () => rpcOk('admin_extend_payment', {
                    'p_id': b.id,
                    'p_minutes': 10,
                  }),
                  ok: 'اتزودت 10 دقايق',
                ),
              ),
              child: const Text('+10 دقايق'),
            ),
          );
        }
        list.add(
          OutlinedButton(
            onPressed: () => _act(context, () async {
              final reason = await askReason(
                context,
                'الـ deposit ماوصلش؟',
                const ['الـ deposit ماوصلش', 'المبلغ غلط — كلّمنا'],
              );
              if (reason == null || !context.mounted) return false;
              return run(
                context,
                () => rpcOk('admin_set_status', {
                  'p_id': b.id,
                  'p_status': 'rejected',
                  'p_reason': reason,
                }),
                ok: 'اتلغى',
              );
            }),
            child: const Text('ماوصلش'),
          ),
        );
      case 'expired':
        if (b.depositAmount != null) {
          list.add(
            OutlinedButton(
              onPressed: () => _act(
                context,
                () => run(
                  context,
                  () => rpcOk('admin_extend_payment', {
                    'p_id': b.id,
                    'p_minutes': 15,
                  }),
                  ok: 'رجع يستنى الـ deposit 15 دقيقة',
                ),
              ),
              child: const Text('رجّعه يستنى الدفع'),
            ),
          );
          list.add(
            OutlinedButton(
              onPressed: () => _act(context, () async {
                if (!await confirmDialog(
                  context,
                  'الفلوس وصلت؟',
                  'هيتأكد الحجز لو المكان لسه فاضي.',
                  yes: 'أكّد',
                ))
                  return false;
                if (!context.mounted) return false;
                return run(
                  context,
                  () => rpcOk('admin_confirm_payment', {'p_id': b.id}),
                  ok: 'الحجز اتأكد',
                );
              }),
              child: const Text('الفلوس وصلت متأخر'),
            ),
          );
        }
      case 'confirmed':
        list.add(
          FilledButton.tonal(
            onPressed: () => _act(
              context,
              () => run(
                context,
                () => rpcOk('admin_set_status', {
                  'p_id': b.id,
                  'p_status': 'completed',
                }),
                ok: 'تمام',
              ),
            ),
            child: const Text('حضر وخلص'),
          ),
        );
        list.add(
          OutlinedButton(
            onPressed: () => _act(context, () async {
              if (!await confirmDialog(
                context,
                'ماجاش؟',
                'هيتسجل غياب والمكان يفضى.',
                yes: 'ماجاش',
              ))
                return false;
              if (!context.mounted) return false;
              return run(
                context,
                () => rpcOk('admin_set_status', {
                  'p_id': b.id,
                  'p_status': 'no_show',
                }),
              );
            }),
            child: const Text('ماجاش'),
          ),
        );
    }
    if ([
      'pending',
      'awaiting_payment',
      'payment_claimed',
      'confirmed',
    ].contains(b.status)) {
      list.add(
        TextButton(
          onPressed: () => _act(context, () async {
            final reason = await askReason(context, 'إلغاء الحجز', const [
              'المحل لغى الحجز',
              'العميل طلب الإلغاء',
            ]);
            if (reason == null || !context.mounted) return false;
            return run(
              context,
              () => rpcOk('admin_set_status', {
                'p_id': b.id,
                'p_status': 'cancelled',
                'p_reason': reason,
              }),
              ok: 'اتلغى',
            );
          }),
          child: const Text(
            'إلغاء',
            style: TextStyle(color: Color(0xFFFCA5A5)),
          ),
        ),
      );
    }
    if (b.phone != null) {
      list.add(
        IconButton(
          tooltip: 'بلوك (إزعاج)',
          onPressed: () => _act(context, () => blockBooking(context, b)),
          icon: const Icon(Icons.block, color: Color(0xFFF87171)),
        ),
      );
      list.add(
        IconButton(
          tooltip: 'اتصال',
          onPressed: () => callPhone(b.phone!),
          icon: const Icon(Icons.call),
        ),
      );
      list.add(
        IconButton(
          tooltip: 'واتساب',
          onPressed: () => openWhatsApp(
            b.phone!,
            'أهلاً ${b.customerName ?? ''}، بخصوص حجزك #${b.code} في سيبر مكة',
          ),
          icon: const Icon(Icons.chat),
        ),
      );
    }
    return list;
  }
}
