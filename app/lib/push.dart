import 'package:flutter/foundation.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:win_toast/win_toast.dart';

import 'core.dart';

String? _initializedAppId;
bool _desktopNotificationsReady = false;

/// Initializes Windows toast notifications; their sound is played by Ringer
/// so the admin's selected ringtone is used instead of the Windows default.
Future<bool> initDesktopNotifications() async {
  if (!isWindows) return false;
  if (_desktopNotificationsReady) return true;

  try {
    _desktopNotificationsReady = await WinToast.instance().initialize(
      aumId: 'CyberMaka.Admin',
      displayName: 'سيبر مكة',
      iconPath: '',
      clsid: '5A27C8D1-760A-4C8D-9F81-22A6B7F04E31',
    );
    return _desktopNotificationsReady;
  } catch (e) {
    debugPrint('Could not initialize Windows notifications: $e');
    return false;
  }
}

Future<void> showDesktopOrderNotification({
  required String id,
  required bool isClaim,
}) async {
  if (!isWindows || !_desktopNotificationsReady) return;

  try {
    final title = isClaim ? 'عربون حجز جديد' : 'طلب حجز جديد';
    final body = isClaim
        ? 'فيه عربون محتاج تأكيد من لوحة الأدمن.'
        : 'فيه طلب حجز جديد محتاج مراجعة.';
    await WinToast.instance().showCustomToast(
      xml:
          '''
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$title</text>
      <text>$body</text>
    </binding>
  </visual>
  <audio silent="true"/>
</toast>
''',
      tag: '${isClaim ? 'claim' : 'booking'}-$id',
      group: 'maka-orders',
    );
  } catch (e) {
    debugPrint('Could not show Windows order notification: $e');
  }
}

/// Links this Android device to the signed-in admin without requesting permission.
Future<bool> initPush() async {
  if (!isAndroid) return false;
  final appId = await rpc('admin_push_app_id');
  if (appId is! String || appId.isEmpty) return false;
  if (_initializedAppId != appId) {
    await OneSignal.initialize(appId);
    _initializedAppId = appId;
  }
  final uid = sb.auth.currentUser?.id;
  if (uid == null) return false;
  await OneSignal.login(uid);
  return true;
}

/// Requests permission only when the admin enables order notifications.
Future<bool> requestOrderPushPermission() async {
  if (!isAndroid) return true;
  if (!await initPush()) return false;
  return OneSignal.Notifications.requestPermission(true);
}

Future<void> requestOrderPushPermissionIfNeeded() async {
  if (!isAndroid || _initializedAppId == null) return;
  if (OneSignal.Notifications.permission) return;
  if (await OneSignal.Notifications.canRequest()) {
    await OneSignal.Notifications.requestPermission(true);
  }
}

/// Stops this device from receiving pushes after the admin signs out.
Future<void> pushLogout() async {
  if (!isAndroid || _initializedAppId == null) return;
  await OneSignal.logout();
}
