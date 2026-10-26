package com.cybermaka.maka_admin

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.util.concurrent.Executors

/**
 * بيقرا إشعارات التحويل من التطبيقات المسموحة بس (InstaPay / Telda / …) — اسم الباكدج مايتزوّرش.
 * أي تطبيق تاني: مابيتبعتش حاجة للسيرفر؛ لو فيه مبلغ بيظهر للأدمن على الموبايل ده بس عشان يعتمده لو حب.
 */
class PaymentListener : NotificationListenerService() {
    private val io = Executors.newSingleThreadExecutor()

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            handle(sbn)
        } catch (_: Exception) {
        }
    }

    private fun handle(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val n = sbn.notification ?: return
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val prefs = MakaPrefs(this)
        if (!prefs.ready) return
        val ex = n.extras
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""
        val text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: ex.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString()?.trim() ?: ""
        val full = listOf(title, text).filter { it.isNotEmpty() }.joinToString("\n")
        if (full.isBlank()) return
        val amount = PaymentParser.amount(full)
        val pkg = sbn.packageName

        if (pkg !in prefs.packages) {
            if (amount != null) prefs.addCandidate("notification", pkg, appLabel(pkg), full, "تطبيق مش في القايمة")
            return
        }
        if (amount == null || !PaymentParser.isIncoming(full)) {
            prefs.addCandidate("notification", pkg, appLabel(pkg), full, if (amount == null) "مالقيناش مبلغ" else "مش تحويل وارد")
            return
        }
        Sync.enqueuePayment(this, "notification", pkg, title, full, amount, PaymentParser.payer(full), sbn.postTime)
        io.execute { Sync.flush(this) }
    }

    private fun appLabel(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        pkg
    }
}
