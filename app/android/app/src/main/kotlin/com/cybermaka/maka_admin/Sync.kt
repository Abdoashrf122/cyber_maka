package com.cybermaka.maka_admin

import android.content.Context
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** الكلام مع السيرفر (RPC بتوكن الجهاز) — من الخدمة ومن مستقبل الإشعارات/SMS */
object Sync {
    private val lock = Any()

    /** null = مفيش اتصال (نحاول بعدين) */
    fun post(prefs: MakaPrefs, fn: String, body: JSONObject): JSONObject? {
        if (prefs.apiUrl.isBlank()) return null
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL("${prefs.apiUrl}/rest/v1/rpc/$fn").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 12000
                readTimeout = 15000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Accept", "application/json")
                setRequestProperty("apikey", prefs.anonKey)
                setRequestProperty("Authorization", "Bearer ${prefs.anonKey}")
            }
            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            val text = (if (code < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            if (code >= 500) return null
            try { JSONObject(text) } catch (_: Exception) { JSONObject().put("ok", false).put("error", "http_$code") }
        } catch (_: IOException) {
            null
        } finally {
            conn?.disconnect()
        }
    }

    fun enqueuePayment(ctx: Context, source: String, origin: String, title: String?, body: String,
                       amount: Double, payer: String?, receivedAt: Long) {
        val prefs = MakaPrefs(ctx)
        prefs.enqueue(
            JSONObject()
                .put("p_source", source).put("p_origin", origin).put("p_title", title ?: JSONObject.NULL)
                .put("p_body", body).put("p_amount", amount).put("p_payer", payer ?: JSONObject.NULL)
                .put("p_received_at", isoTime(receivedAt))
        )
    }

    /** يبعت التحويلات المتخزنة بالترتيب؛ لو النت وقع بيقف ويكمل المرة الجاية */
    fun flush(ctx: Context) {
        synchronized(lock) {
            val prefs = MakaPrefs(ctx)
            if (prefs.deviceToken.isBlank()) return
            while (true) {
                val q = prefs.queue()
                if (q.length() == 0) return
                val item = q.getJSONObject(0)
                val res = post(prefs, "device_ingest_payment", JSONObject(item.toString()).put("p_token", prefs.deviceToken)) ?: return
                q.remove(0)
                prefs.setQueue(q)
                if (res.optString("result") == "matched") {
                    Notifier.info(ctx, "اتأكد تلقائي ✓", "وصل الـ deposit — حجز #${res.optString("booking_code")} اتأكد")
                }
            }
        }
    }

    fun isoTime(ms: Long): String {
        val f = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", java.util.Locale.US)
        return f.format(java.util.Date(ms))
    }
}
