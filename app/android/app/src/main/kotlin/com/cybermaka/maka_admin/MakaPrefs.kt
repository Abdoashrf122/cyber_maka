package com.cybermaka.maka_admin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** إعدادات الجزء الأصلي (الخدمة + قراءة الإشعارات/SMS) — بتشتغل حتى والتطبيق نفسه مقفول. */
class MakaPrefs(ctx: Context) {
    private val p = ctx.applicationContext.getSharedPreferences("maka_native", Context.MODE_PRIVATE)

    var apiUrl: String
        get() = p.getString("api_url", "") ?: ""
        set(v) = p.edit().putString("api_url", v.trimEnd('/')).apply()
    var anonKey: String
        get() = p.getString("anon_key", "") ?: ""
        set(v) = p.edit().putString("anon_key", v).apply()
    var deviceToken: String
        get() = p.getString("device_token", "") ?: ""
        set(v) = p.edit().putString("device_token", v).apply()
    var enabled: Boolean
        get() = p.getBoolean("enabled", false)
        set(v) = p.edit().putBoolean("enabled", v).apply()
    var lastPulseAt: Long
        get() = p.getLong("last_pulse_at", 0)
        set(v) = p.edit().putLong("last_pulse_at", v).apply()
    var lastError: String
        get() = p.getString("last_error", "") ?: ""
        set(v) = p.edit().putString("last_error", v).apply()

    val ready: Boolean get() = enabled && apiUrl.isNotBlank() && anonKey.isNotBlank() && deviceToken.isNotBlank()

    // القوائم المسموحة بتيجي من السيرفر مع كل pulse (الأدمن بيعدّلها من الإعدادات)
    var packages: Set<String>
        get() = getSet("packages", setOf("com.egyptianbanks.instapay", "com.telda.app"))
        set(v) = putSet("packages", v)
    var senders: Set<String>
        get() = getSet("senders", setOf("InstaPay", "Telda", "CIB", "NBE", "BanqueMisr", "BM", "QNB"))
        set(v) = putSet("senders", v)
    var autoNotif: Boolean
        get() = p.getBoolean("auto_notif", true)
        set(v) = p.edit().putBoolean("auto_notif", v).apply()
    var autoSms: Boolean
        get() = p.getBoolean("auto_sms", true)
        set(v) = p.edit().putBoolean("auto_sms", v).apply()
    var newRingPath: String?
        get() = p.getString("new_ring_path", null)
        set(v) = p.edit().putString("new_ring_path", v).apply()
    var newRingMode: String
        get() = p.getString("new_ring_mode", "once") ?: "once"
        set(v) = p.edit().putString("new_ring_mode", v).apply()
    var newRingSeconds: Int
        get() = p.getInt("new_ring_seconds", 10)
        set(v) = p.edit().putInt("new_ring_seconds", v).apply()
    var claimRingPath: String?
        get() = p.getString("claim_ring_path", null)
        set(v) = p.edit().putString("claim_ring_path", v).apply()
    var claimRingMode: String
        get() = p.getString("claim_ring_mode", "timed") ?: "timed"
        set(v) = p.edit().putString("claim_ring_mode", v).apply()
    var claimRingSeconds: Int
        get() = p.getInt("claim_ring_seconds", 30)
        set(v) = p.edit().putInt("claim_ring_seconds", v).apply()

    // حجوزات «العميل حوّل» اللي الأدمن داس عليها «إسكات» — الرنة مابترجعش لها (بترن تاني لو عميل جديد حوّل)
    var snoozed: Set<String>
        get() = getSet("snoozed", emptySet())
        set(v) = putSet("snoozed", v)
    var ringingIds: Set<String>
        get() = getSet("ringing", emptySet())
        set(v) = putSet("ringing", v)
    var seenPending: Set<String>
        get() = getSet("seen_pending", emptySet())
        set(v) = putSet("seen_pending", v)

    private fun getSet(key: String, def: Set<String>): Set<String> {
        val raw = p.getString(key, null) ?: return def
        return try {
            val a = JSONArray(raw)
            (0 until a.length()).map { a.getString(it) }.toSet()
        } catch (_: Exception) { def }
    }
    private fun putSet(key: String, v: Set<String>) {
        p.edit().putString(key, JSONArray(v.toList()).toString()).apply()
    }

    // ── طابور التحويلات اللي لسه ماوصلتش للسيرفر (مفيش نت) — بيتبعت أول ما النت يرجع
    @Synchronized fun queue(): JSONArray = try { JSONArray(p.getString("queue", "[]")) } catch (_: Exception) { JSONArray() }
    @Synchronized fun setQueue(a: JSONArray) { p.edit().putString("queue", a.toString()).commit() }
    @Synchronized fun enqueue(o: JSONObject) {
        val a = queue()
        a.put(o)
        while (a.length() > 200) a.remove(0)
        setQueue(a)
    }

    // ── رسايل فيها مبالغ من تطبيقات/أسماء مش في القايمة (بتظهر للأدمن بس على الموبايل ده — مش بتتبعت للسيرفر)
    @Synchronized fun candidates(): JSONArray = try { JSONArray(p.getString("candidates", "[]")) } catch (_: Exception) { JSONArray() }
    @Synchronized fun addCandidate(kind: String, origin: String, label: String, text: String, note: String) {
        val old = candidates()
        val a = JSONArray()
        a.put(JSONObject().put("kind", kind).put("origin", origin).put("label", label)
            .put("text", text.take(220)).put("note", note).put("at", System.currentTimeMillis()))
        for (i in 0 until old.length()) {
            val o = old.getJSONObject(i)
            if (o.optString("origin") != origin && a.length() < 15) a.put(o)
        }
        p.edit().putString("candidates", a.toString()).apply()
    }
    @Synchronized fun clearCandidates() { p.edit().remove("candidates").apply() }
}
