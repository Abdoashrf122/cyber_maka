package com.cybermaka.maka_admin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri

/** الإشعارات: خدمة شغالة (هادي) + رنة طلب جديد (بتفضل ترن لحد ما حد يرد) + معلومات */
object Notifier {
    const val CH_SERVICE = "maka_service"
    const val CH_RING = "maka_ring_v1"
    const val CH_NEW = "maka_new_v1"
    const val CH_INFO = "maka_info"
    const val ID_SERVICE = 1
    const val ID_RING = 2
    const val ID_NEW = 3
    private var infoId = 100

    fun channels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_SERVICE, "تشغيل في الخلفية", NotificationManager.IMPORTANCE_MIN).apply {
                description = "بيوضح إن التطبيق بيستقبل الحجوزات"
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_NEW, "طلبات حجز جديدة", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "إشعار عادي (صوت مرة واحدة) لما يوصل طلب حجز"
                setSound(
                    Uri.parse("android.resource://${ctx.packageName}/raw/maka_ring"),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_RING, "العميل حوّل الـ deposit", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "رنة طويلة لحد ما تأكد إن الفلوس وصلت (أو تقول ماوصلتش)"
                setSound(
                    Uri.parse("android.resource://${ctx.packageName}/raw/maka_ring"),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 400, 600)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_INFO, "تحديثات الحجز", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "العميل حوّل / اتأكد تلقائي"
            }
        )
    }

    private fun openApp(ctx: Context): PendingIntent = PendingIntent.getActivity(
        ctx, 0,
        Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun service(ctx: Context, text: String): Notification =
        Notification.Builder(ctx, CH_SERVICE)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("سيبر مكة")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(openApp(ctx))
            .build()

    /** طلب جديد: إشعار عادي بصوت مرة واحدة */
    fun newRequest(ctx: Context, codes: List<String>) {
        val n = Notification.Builder(ctx, CH_NEW)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (codes.size == 1) "طلب حجز جديد" else "${codes.size} طلبات حجز جديدة")
            .setContentText(codes.joinToString("، ") { "#$it" } + " — افتح واقبل أو ارفض")
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setContentIntent(openApp(ctx))
            .setAutoCancel(true)
            .build()
        ctx.getSystemService(NotificationManager::class.java).notify(ID_NEW, n)
    }

    fun clearNewRequest(ctx: Context) {
        ctx.getSystemService(NotificationManager::class.java).cancel(ID_NEW)
    }

    /** العميل قال حوّل: رنة طويلة (FLAG_INSISTENT) لحد ما الأدمن يأكد/يرفض أو يسكّت */
    fun ring(ctx: Context, codes: List<String>) {
        val snooze = PendingIntent.getService(
            ctx, 1, Intent(ctx, MakaService::class.java).setAction(MakaService.ACTION_SNOOZE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(ctx, CH_RING)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (codes.size == 1) "العميل حوّل الـ deposit 💰" else "${codes.size} عملاء حوّلوا الـ deposit 💰")
            .setContentText(codes.joinToString("، ") { "#$it" } + " — اتأكد إن الفلوس وصلت وأكّد الحجز")
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setContentIntent(openApp(ctx))
            .setAutoCancel(false)
            .addAction(Notification.Action.Builder(null, "إسكات", snooze).build())
            .build()
        n.flags = n.flags or Notification.FLAG_INSISTENT
        ctx.getSystemService(NotificationManager::class.java).notify(ID_RING, n)
    }

    fun stopRing(ctx: Context) {
        ctx.getSystemService(NotificationManager::class.java).cancel(ID_RING)
    }

    fun info(ctx: Context, title: String, text: String) {
        val n = Notification.Builder(ctx, CH_INFO)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openApp(ctx))
            .setAutoCancel(true)
            .build()
        ctx.getSystemService(NotificationManager::class.java).notify(infoId++, n)
    }
}
