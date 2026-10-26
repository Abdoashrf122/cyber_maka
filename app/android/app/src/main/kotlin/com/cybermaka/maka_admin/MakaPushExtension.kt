package com.cybermaka.maka_admin

import com.onesignal.notifications.INotificationReceivedEvent
import com.onesignal.notifications.INotificationServiceExtension

/**
 * إشعار OneSignal جاي من السيرفر (sql/07_push.sql) — بيشتغل حتى والتطبيق مقفول خالص:
 * • kind=new   → إشعار طلب جديد وصوته حسب إعدادات الأدمن
 * • kind=claim → إشعار تحويل وصوت محدود المدة حسب الإعدادات
 * • kind=clear → الطلب اتعامل معاه من أي جهاز → نشيل الإشعار/نوقّف الصوت المناسب
 * بنستخدم نفس أرقام الإشعارات بتاعة خدمة الخلفية، فلو الاتنين وصلوا مفيش تكرار.
 * أي حاجة غريبة → OneSignal يعرض الإشعار عادي (أحسن من إنه مايوصلش).
 */
class MakaPushExtension : INotificationServiceExtension {
    override fun onNotificationReceived(event: INotificationReceivedEvent) {
        val data = event.notification.additionalData ?: return
        val ctx = event.context
        try {
            val prefs = MakaPrefs(ctx)
            val id = data.optString("id")
            val code = data.optString("code")
            Notifier.channels(ctx)
            when (data.optString("kind")) {
                "new" -> {
                    if (id.isNotEmpty() && id in prefs.seenPending) {
                        event.preventDefault() // خدمة الخلفية لحقته بالفعل
                        return
                    }
                    Notifier.newRequest(ctx, listOf(code))
                    AlertAudio.play(
                        ctx,
                        "new",
                        "new:$id",
                        prefs.newRingPath,
                        prefs.newRingMode,
                        prefs.newRingSeconds,
                    )
                    if (id.isNotEmpty()) prefs.seenPending = prefs.seenPending + id
                }
                "claim" -> {
                    if (id.isNotEmpty() && (id in prefs.snoozed || id in prefs.ringingIds)) {
                        event.preventDefault()
                        return
                    }
                    Notifier.ring(ctx, listOf(code))
                    AlertAudio.play(
                        ctx,
                        "claim",
                        "claim:$id",
                        prefs.claimRingPath,
                        prefs.claimRingMode,
                        prefs.claimRingSeconds,
                    )
                    if (id.isNotEmpty()) prefs.ringingIds = prefs.ringingIds + id
                }
                "clear" -> {
                    prefs.seenPending = prefs.seenPending - id
                    AlertAudio.stop("new")
                    val left = prefs.ringingIds - id
                    prefs.ringingIds = left
                    if (left.isEmpty()) {
                        AlertAudio.stop("claim")
                        Notifier.stopRing(ctx)
                    }
                    Notifier.clearNewRequest(ctx)
                }
                else -> return
            }
            event.preventDefault() // عرضناه بنفسنا
            // لو خدمة الخلفية اتقفلت (توفير بطارية) → نرجّعها (مسموح بعد إشعار FCM عالي الأولوية)
            if (prefs.ready && !MakaService.isRunning) {
                try { MakaService.start(ctx) } catch (_: Exception) { }
            }
        } catch (_: Exception) {
        }
    }
}
