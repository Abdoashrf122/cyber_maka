package com.cybermaka.maka_admin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * رسايل SMS: بيقبل بس اللي جاية من اسم شركة (فيه حروف) ومن القايمة المسموحة (InstaPay / البنوك / Telda).
 * أي رسالة من رقم موبايل بتتجاهل خالص — حد ممكن يبعت «تم استلام 50 جنيه» من رقمه عشان ينصب.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val prefs = MakaPrefs(ctx)
        if (!prefs.ready) return
        val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        var queued = false
        for ((sender, parts) in msgs.groupBy { it.originatingAddress ?: "" }) {
            val body = parts.joinToString("") { it.messageBody ?: "" }.trim()
            if (body.isEmpty()) continue
            if (!sender.any { it in 'A'..'Z' || it in 'a'..'z' }) continue // رقم موبايل → تجاهل
            val amount = PaymentParser.amount(body)
            if (prefs.senders.none { it.equals(sender, ignoreCase = true) }) {
                if (amount != null) prefs.addCandidate("sms", sender, sender, body, "اسم مش في القايمة")
                continue
            }
            if (amount == null || !PaymentParser.isIncoming(body)) {
                prefs.addCandidate("sms", sender, sender, body, if (amount == null) "مالقيناش مبلغ" else "مش تحويل وارد")
                continue
            }
            Sync.enqueuePayment(ctx, "sms", sender, null, body, amount, PaymentParser.payer(body), parts[0].timestampMillis)
            queued = true
        }
        if (!queued) return
        val pending = goAsync()
        Thread {
            try {
                Sync.flush(ctx)
            } finally {
                pending.finish()
            }
        }.start()
    }
}
