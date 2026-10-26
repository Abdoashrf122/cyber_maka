import 'package:onesignal_flutter/onesignal_flutter.dart';

import 'core.dart';

/// إشعارات OneSignal (أندرويد بس) — عشان الطلب/الرنة يوصلوا حتى والتطبيق مقفول.
/// الـ App ID بييجي من السيرفر (admin_push_app_id) → لو OneSignal لسه مش متظبط على السيرفر، مفيش حاجة بتحصل،
/// وأول ما يتظبط بيشتغل لوحده مع أول فتحة للتطبيق (من غير تحديث).
bool _ready = false;

Future<void> initPush() async {
  if (!isAndroid) return;
  try {
    final appId = await rpc('admin_push_app_id');
    if (appId is! String || appId.isEmpty) return;
    if (!_ready) {
      OneSignal.initialize(appId);
      _ready = true;
    }
    final uid = sb.auth.currentUser?.id;
    if (uid != null) await OneSignal.login(uid); // السيرفر بيبعت للأدمنز بالـ user id
    await OneSignal.Notifications.requestPermission(true);
  } catch (_) {
    // الإشعارات إضافية — خدمة الخلفية شغالة برضو
  }
}

/// خروج: الموبايل ده مايستقبلش إشعارات الحجوزات تاني
Future<void> pushLogout() async {
  if (!isAndroid || !_ready) return;
  try {
    await OneSignal.logout();
  } catch (_) {}
}
