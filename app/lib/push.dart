import 'package:onesignal_flutter/onesignal_flutter.dart';

import 'core.dart';

String? _initializedAppId;

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
