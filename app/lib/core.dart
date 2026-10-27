import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'config.dart';

SupabaseClient get sb => Supabase.instance.client;
bool get isAndroid => !kIsWeb && Platform.isAndroid;
bool get isWindows => !kIsWeb && Platform.isWindows;

// ═════════ السيرفر ═════════

class ApiError implements Exception {
  final String code;
  ApiError(this.code);
  @override
  String toString() => errorText(code);
}

Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) async {
  try {
    return await sb.rpc(fn, params: params ?? const {});
  } on PostgrestException catch (e) {
    if (e.message.contains('not_admin')) throw ApiError('not_admin');
    if (e.code == 'PGRST301' || e.code == '401') throw ApiError('auth');
    throw ApiError('server');
  } on AuthException {
    throw ApiError('auth');
  } catch (e) {
    if (e is ApiError) rethrow;
    throw ApiError('network');
  }
}

/// دوال بترجع {ok:false, error:...} → بترمي ApiError
Future<Map<String, dynamic>> rpcOk(
  String fn, [
  Map<String, dynamic>? params,
]) async {
  final m = Map<String, dynamic>.from(await rpc(fn, params) as Map);
  if (m['ok'] == false) throw ApiError('${m['error']}');
  return m;
}

String errorText(String code) =>
    const {
      'network': 'مفيش اتصال بالسيرفر — اتأكد من النت.',
      'server': 'حصلت مشكلة في السيرفر — جرّب تاني.',
      'auth': 'الدخول انتهى — سجّل دخول تاني.',
      'not_admin': 'الحساب ده مش أدمن.',
      'bad_state': 'حالة الطلب اتغيرت — اتحدّثت القايمة.',
      'full': 'المكان اتحجز بالفعل في الميعاد ده.',
      'not_found': 'مش موجود (ممكن اتمسح).',
      'push_not_configured':
          'إشعارات OneSignal مش متوصلة على السيرفر لسه.',
      'already_linked': 'التحويل ده متربط بحجز بالفعل.',
      'bad_name': 'الاسم قصير أوي.',
      'bad_username':
          'اسم المستخدم لازم حروف إنجليزي/أرقام من 3 لـ 30، يبدأ بحرف أو رقم.',
      'username_taken': 'اسم المستخدم ده معمول بيه حساب بالفعل.',
      'bad_password': 'كلمة السر لازم 8 حروف على الأقل.',
      'cannot_self': 'مش من هنا — ده حسابك إنت.',
      'last_admin': 'مينفعش تمسح آخر أدمن — لازم يفضل حد يقدر يدخل.',
      'bad_hours': 'مواعيد الفتح والقفل مش صحيحة.',
      'bad_kind': 'النوع مش صحيح.',
      'bad_minutes': 'عدد الدقايق مش صحيح.',
      'bad_input': 'البيانات ناقصة.',
    }[code] ??
    'حصلت مشكلة ($code)';

// ═════════ الحجز ═════════

class Booking {
  final Map<String, dynamic> j;
  Booking(this.j);

  String get id => j['id'] as String;
  String get code => j['code'] as String;
  String get status => j['status'] as String;
  String? get reason => j['reason'] as String?;
  String get branchName => (j['branch_name'] ?? '') as String;
  String get offeringName => (j['offering_name'] ?? '') as String;
  String get kind => (j['kind'] ?? '') as String;
  int get units => (j['units'] as num? ?? 1).toInt();
  String get date => (j['date'] ?? '') as String;
  String get time => (j['time'] ?? '00:00') as String;
  String get endTime => (j['end_time'] ?? '00:00') as String;
  int get durationMin => (j['duration_min'] as num? ?? 0).toInt();
  String? get customerName => j['customer_name'] as String?;
  String? get phone => j['customer_phone'] as String?;
  String? get note => j['note'] as String?;
  num get priceTotal => j['price_total'] as num? ?? 0;
  num get depositBase => j['deposit_base'] as num? ?? 0;
  num? get depositAmount => j['deposit_amount'] as num?;
  String? get payerName => j['payer_name'] as String?;
  String? get paidVia => j['paid_via'] as String?;
  DateTime? _dt(String k) =>
      j[k] == null ? null : DateTime.tryParse(j[k] as String)?.toLocal();
  DateTime? get approveDeadline => _dt('approve_deadline');
  DateTime? get payDeadline => _dt('pay_deadline');
  DateTime? get createdAt => _dt('created_at');
  Map<String, dynamic>? get paymentEvent => j['payment_event'] == null
      ? null
      : Map<String, dynamic>.from(j['payment_event'] as Map);

  String get what => kind == 'pc' ? '$offeringName × $units' : offeringName;
}

const statusLabels = {
  'pending': 'طلب جديد',
  'awaiting_payment': 'مستني الـ deposit',
  'payment_claimed': 'العميل قال حوّل',
  'confirmed': 'متأكد',
  'rejected': 'مرفوض',
  'expired': 'انتهى',
  'cancelled': 'ملغي',
  'completed': 'خلص',
  'no_show': 'ماجاش',
};

Color statusColor(String s) => switch (s) {
  'pending' => const Color(0xFFF97316),
  'awaiting_payment' => const Color(0xFFEAB308),
  'payment_claimed' => const Color(0xFF38BDF8),
  'confirmed' => const Color(0xFF22C55E),
  'completed' => const Color(0xFF14B8A6),
  _ => const Color(0xFF9CA3AF),
};

const paidViaLabels = {
  'manual': 'تأكيد يدوي',
  'notification': 'إشعار تحويل (تلقائي)',
  'sms': 'رسالة بنك (تلقائي)',
  'none': 'من غير deposit',
};

// ═════════ تنسيق ═════════

String money(num? n) {
  if (n == null) return '—';
  final s = n == n.roundToDouble()
      ? n.toInt().toString()
      : n.toStringAsFixed(2);
  return '$s ج';
}

String durationText(int min) {
  final h = min ~/ 60, m = min % 60;
  final hours = h == 0
      ? ''
      : h == 1
      ? 'ساعة'
      : h == 2
      ? 'ساعتين'
      : '$h ساعات';
  if (m == 0) return hours;
  final rest = m == 30 ? 'نص' : '$m دقيقة';
  return hours.isEmpty ? '$m دقيقة' : '$hours و$rest';
}

String time12(String hhmm) {
  final p = hhmm.split(':');
  final h = int.tryParse(p[0]) ?? 0, m = p.length > 1 ? p[1] : '00';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$m ${h < 12 ? 'ص' : 'م'}';
}

String dayText(String isoDate) {
  final d = DateTime.tryParse(isoDate);
  if (d == null) return isoDate;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'النهارده';
  if (diff == 1) return 'بكرة';
  if (diff == -1) return 'امبارح';
  const names = [
    'الاتنين',
    'التلات',
    'الأربع',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];
  return '${names[d.weekday - 1]} ${d.day}/${d.month}';
}

String minutesLeft(DateTime? t) {
  if (t == null) return '';
  final s = t.difference(DateTime.now()).inSeconds;
  if (s <= 0) return 'خلصت';
  if (s < 60) return 'أقل من دقيقة';
  return '${(s / 60).ceil()} دقيقة';
}

String agoText(DateTime? t) {
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'دلوقتي';
  if (d.inMinutes < 60) return 'من ${d.inMinutes} دقيقة';
  if (d.inHours < 24) return 'من ${d.inHours} ساعة';
  return '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

Future<void> callPhone(String phone) => launchUrl(Uri.parse('tel:$phone'));

Future<void> openWhatsApp(String phone, [String? text]) {
  var d = phone.replaceAll(RegExp(r'\D'), '');
  if (d.startsWith('0')) d = '2$d';
  final q = text == null ? '' : '?text=${Uri.encodeComponent(text)}';
  return launchUrl(
    Uri.parse('https://wa.me/$d$q'),
    mode: LaunchMode.externalApplication,
  );
}

void toast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? const Color(0xFFB91C1C) : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
}

/// زرار بيعمل حاجة على السيرفر: بيعرض الخطأ بالعربي
Future<bool> run(
  BuildContext context,
  Future<void> Function() f, {
  String? ok,
}) async {
  try {
    await f();
    if (ok != null && context.mounted) toast(context, ok);
    return true;
  } on ApiError catch (e) {
    if (context.mounted) toast(context, e.toString(), error: true);
  } catch (_) {
    if (context.mounted) toast(context, errorText('network'), error: true);
  }
  return false;
}

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String body, {
  String yes = 'أيوه',
  bool danger = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('لأ'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C))
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(yes),
        ),
      ],
    ),
  );
  return r == true;
}

// ═════════ الأندرويد (الخدمة الأصلية) ═════════

class Native {
  static const _ch = MethodChannel('maka/native');

  static Future<T?> call<T>(String method, [Map<String, dynamic>? args]) async {
    if (!isAndroid) return null;
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  static Future<void> configure(String token) =>
      call('configure', {'url': kApiUrl, 'anonKey': kAnonKey, 'token': token});
  static Future<void> disable() => call('disable');

  static Future<Map<String, dynamic>> status() async {
    final m = await call<Map>('status');
    return m == null ? {} : Map<String, dynamic>.from(m);
  }

  static Future<List<Map<String, dynamic>>> candidates() async {
    final s = await call<String>('candidates');
    if (s == null) return [];
    return (jsonDecode(s) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  static Future<Map<String, dynamic>?> parseTest(String text) async {
    final s = await call<String>('parseTest', {'text': text});
    return s == null ? null : Map<String, dynamic>.from(jsonDecode(s) as Map);
  }
}

/// تسجيل موبايل الأندرويد كجهاز للمحل (رنة في الخلفية + قراية التحويلات) — مرة واحدة
Future<void> ensureDeviceRegistered() async {
  if (!isAndroid) return;
  final st = await Native.status();
  // متسجّل على نفس السيرفر؟ (لو التطبيق اتحدّث لسيرفر تاني، توكن الجهاز القديم مالوش لازمة)
  if (st['configured'] == true &&
      st['apiUrl'] == kApiUrl.replaceAll(RegExp(r'/+$'), '')) {
    await Native.call('ensureRunning');
    return;
  }
  final r = await rpcOk('admin_register_device', {'p_name': 'موبايل الأدمن'});
  await Native.configure(r['token'] as String);
  await Native.call('requestPostNotifications');
}

// ═════════ الرنة على الويندوز ═════════

class Ringer {
  static final AudioPlayer _player = AudioPlayer();
  static final AudioPlayer _once = AudioPlayer();
  static bool _on = false;
  static String? _claimKey;
  static Timer? _claimTimer;
  static Timer? _onceTimer;

  static Source _source(String? url) => url == null || url.isEmpty
      ? AssetSource('sounds/ring.wav')
      : UrlSource(url);

  /// طلب جديد: صوت مرة واحدة + يجيب الشباك قدام
  static Future<void> notifyOnce({
    String? source,
    String mode = 'once',
    int seconds = 10,
  }) async {
    if (!isWindows) return;
    try {
      _onceTimer?.cancel();
      await _once.stop();
      await _once.setReleaseMode(
        mode == 'timed' ? ReleaseMode.loop : ReleaseMode.stop,
      );
      await _once.play(_source(source));
      if (mode == 'timed') {
        _onceTimer = Timer(
          Duration(seconds: seconds.clamp(1, 300)),
          () => _once.stop(),
        );
      }
    } catch (e) {
      debugPrint('Could not play new-booking sound: $e');
    }
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  /// العميل حوّل الـ deposit: صوت مرة أو لمدة محددة، مع بقاء نافذة التأكيد.

  static Future<void> start({
    required String key,
    String? source,
    String mode = 'timed',
    int seconds = 30,
  }) async {
    if (!isWindows || _claimKey == key) return;
    _claimTimer?.cancel();
    await _player.stop();
    _claimKey = key;
    _on = true;
    try {
      await _player.setReleaseMode(
        mode == 'timed' ? ReleaseMode.loop : ReleaseMode.stop,
      );
      await _player.play(_source(source));
      if (mode == 'timed') {
        _claimTimer = Timer(Duration(seconds: seconds.clamp(1, 300)), () async {
          await _player.stop();
          _on = false;
        });
      }
    } catch (e) {
      debugPrint('Could not play deposit-claim sound: $e');
    }
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
      await Future<void>.delayed(const Duration(seconds: 2));
      await windowManager.setAlwaysOnTop(false);
    } catch (_) {}
  }

  static Future<void> stop() async {
    _claimTimer?.cancel();
    _claimKey = null;
    if (!_on) return;
    _on = false;
    try {
      await _player.stop();
    } catch (_) {}
  }

  static Future<void> stopAll() async {
    _onceTimer?.cancel();
    await _once.stop();
    await stop();
  }
}
