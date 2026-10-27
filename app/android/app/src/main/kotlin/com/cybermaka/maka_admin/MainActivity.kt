package com.cybermaka.maka_admin

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** الجسر بين Flutter والجزء الأصلي (الخدمة / الصلاحيات / قراية الإشعارات والرسايل) */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "maka/native").setMethodCallHandler { call, result ->
            val prefs = MakaPrefs(this)
            when (call.method) {
                "configure" -> {
                    prefs.apiUrl = call.argument<String>("url") ?: ""
                    prefs.anonKey = call.argument<String>("anonKey") ?: ""
                    prefs.deviceToken = call.argument<String>("token") ?: ""
                    prefs.enabled = true
                    Notifier.channels(this)
                    MakaService.start(this)
                    result.success(true)
                }
                "disable" -> {
                    prefs.enabled = false
                    prefs.deviceToken = ""
                    prefs.ringingIds = emptySet()
                    MakaService.stop(this)
                    Notifier.stopRing(this)
                    result.success(true)
                }
                "setReceiveOrders" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    prefs.receiveOrders = enabled
                    if (MakaService.isRunning) Notifier.updateService(this, enabled)
                    if (!enabled) {
                        prefs.ringingIds = emptySet()
                        AlertAudio.stop("new")
                        AlertAudio.stop("claim")
                        Notifier.clearNewRequest(this)
                        Notifier.stopRing(this)
                    }
                    result.success(true)
                }
                "ensureRunning" -> {
                    if (prefs.ready && !MakaService.isRunning) MakaService.start(this)
                    result.success(prefs.ready)
                }
                "status" -> result.success(
                    mapOf(
                        "configured" to prefs.ready,
                        "apiUrl" to prefs.apiUrl,
                        "running" to MakaService.isRunning,
                        "lastPulseAt" to prefs.lastPulseAt,
                        "lastError" to prefs.lastError,
                        "queue" to prefs.queue().length(),
                        "notificationAccess" to notificationAccess(),
                        "sms" to granted(Manifest.permission.RECEIVE_SMS),
                        "postNotifications" to (Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS)),
                        "batteryIgnored" to batteryIgnored(),
                        "packages" to prefs.packages.toList(),
                        "senders" to prefs.senders.toList(),
                    )
                )
                "openNotificationAccess" -> {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(true)
                }
                "openAppSettings" -> {
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                    result.success(true)
                }
                "requestSms" -> {
                    requestPermissions(arrayOf(Manifest.permission.RECEIVE_SMS), 11)
                    result.success(true)
                }
                "requestPostNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 12)
                    result.success(true)
                }
                "requestBatteryExemption" -> {
                    try {
                        startActivity(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
                        )
                    } catch (_: Exception) {
                        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    }
                    result.success(true)
                }
                "testRing" -> {
                    MakaService.start(this, MakaService.ACTION_TEST_RING)
                    result.success(true)
                }
                "snooze" -> {
                    if (MakaService.isRunning) MakaService.start(this, MakaService.ACTION_SNOOZE)
                    result.success(true)
                }
                "candidates" -> result.success(prefs.candidates().toString())
                "clearCandidates" -> {
                    prefs.clearCandidates()
                    result.success(true)
                }
                "parseTest" -> {
                    val text = call.argument<String>("text") ?: ""
                    result.success(
                        JSONObject()
                            .put("amount", PaymentParser.amount(text) ?: JSONObject.NULL)
                            .put("payer", PaymentParser.payer(text) ?: JSONObject.NULL)
                            .put("incoming", PaymentParser.isIncoming(text))
                            .toString()
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        val prefs = MakaPrefs(this)
        if (prefs.ready && !MakaService.isRunning) MakaService.start(this)
    }

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun notificationAccess(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        val me = ComponentName(this, PaymentListener::class.java).flattenToString()
        return flat.split(":").any { it == me }
    }

    private fun batteryIgnored(): Boolean =
        (getSystemService(POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(packageName)
}
