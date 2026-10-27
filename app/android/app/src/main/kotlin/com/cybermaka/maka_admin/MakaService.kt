package com.cybermaka.maka_admin

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * شغالة طول الوقت على موبايل المحل: كل 8 ثواني بتسأل السيرفر (device_pulse)
 * • فيه طلب جديد → إشعار وصوت حسب إعدادات الأدمن
 * • العميل قال حوّل الـ deposit → صوت بمدة محددة، والإشعار يفضل لحد ما الطلب يتعالج
 * • بتبعت التحويلات المتخزنة لو النت كان واقع
 */
class MakaService : Service() {
    companion object {
        const val ACTION_SNOOZE = "com.cybermaka.SNOOZE"
        const val ACTION_TEST_RING = "com.cybermaka.TEST_RING"
        const val ACTION_STOP = "com.cybermaka.STOP"
        private const val POLL_MS = 8000L
        @Volatile var isRunning = false

        fun start(ctx: Context, action: String? = null) {
            val i = Intent(ctx, MakaService::class.java)
            if (action != null) i.action = action
            ctx.startForegroundService(i)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, MakaService::class.java))
        }
    }

    private lateinit var thread: HandlerThread
    private lateinit var worker: Handler
    private var wakeLock: PowerManager.WakeLock? = null
    private var testRingUntil = 0L

    private val tick = object : Runnable {
        override fun run() {
            try {
                pulse()
                Sync.flush(this@MakaService)
            } catch (_: Exception) {
            }
            worker.postDelayed(this, POLL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Notifier.channels(this)
        val n = Notifier.service(
            this,
            if (MakaPrefs(this).receiveOrders) {
                "شغال — بيستقبل الحجوزات"
            } else {
                "شغال — استقبال الطلبات متوقف"
            },
        )
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(Notifier.ID_SERVICE, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(Notifier.ID_SERVICE, n)
        }
        // موبايل المحل غالبًا على الشاحن — بنمنع النوم عشان الرنة ماتتأخرش
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "maka:service").apply {
                setReferenceCounted(false)
                acquire()
            }
        thread = HandlerThread("maka-service").also { it.start() }
        worker = Handler(thread.looper)
        isRunning = true
        worker.post(tick)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SNOOZE -> worker.post {
                val prefs = MakaPrefs(this)
                prefs.snoozed = prefs.snoozed + prefs.ringingIds
                prefs.ringingIds = emptySet()
                testRingUntil = 0
                AlertAudio.stop("claim")
                Notifier.stopRing(this)
            }
            ACTION_TEST_RING -> worker.post {
                testRingUntil = System.currentTimeMillis() + 15000
                Notifier.ring(this, listOf("تجربة"))
                val prefs = MakaPrefs(this)
                AlertAudio.play(this, "test", "test-${System.currentTimeMillis()}", prefs.claimRingPath, "timed", 15)
                worker.postDelayed({
                    if (System.currentTimeMillis() >= testRingUntil) {
                        AlertAudio.stop("test")
                    }
                    if (System.currentTimeMillis() >= testRingUntil && MakaPrefs(this).ringingIds.isEmpty()) {
                        Notifier.stopRing(this)
                    }
                }, 15500)
            }
            else -> worker.post { Sync.flush(this) }
        }
        return START_STICKY
    }

    private fun pulse() {
        val prefs = MakaPrefs(this)
        if (!prefs.ready) return
        val res = Sync.post(prefs, "device_pulse", JSONObject().put("p_token", prefs.deviceToken))
        if (res == null) {
            prefs.lastError = "مفيش اتصال بالسيرفر"
            return
        }
        if (!res.optBoolean("ok")) {
            prefs.lastError = res.optString("error", "error")
            if (res.optString("error") == "bad_device") Notifier.stopRing(this)
            return
        }
        prefs.lastError = ""
        prefs.lastPulseAt = System.currentTimeMillis()
        val receiveOrders = res.optBoolean("receive_orders", false)
        if (prefs.receiveOrders != receiveOrders) {
            prefs.receiveOrders = receiveOrders
            Notifier.updateService(this, receiveOrders)
        }
        prefs.packages = toSet(res.optJSONArray("notif_packages")) ?: prefs.packages
        prefs.senders = toSet(res.optJSONArray("sms_senders")) ?: prefs.senders
        prefs.autoNotif = res.optBoolean("auto_notifications", true)
        prefs.autoSms = res.optBoolean("auto_sms", true)
        prefs.newRingPath = res.optString("new_ring_path").takeIf { it.isNotBlank() }
        prefs.newRingMode = res.optString("new_ring_mode", "once")
        prefs.newRingSeconds = res.optInt("new_ring_seconds", 10).coerceIn(1, 300)
        prefs.claimRingPath = res.optString("claim_ring_path").takeIf { it.isNotBlank() }
        prefs.claimRingMode = res.optString("claim_ring_mode", "timed")
        prefs.claimRingSeconds = res.optInt("claim_ring_seconds", 30).coerceIn(1, 300)

        // ── طلبات جديدة → إشعار وصوت حسب إعدادات الأدمن
        val pending = items(res.optJSONArray("pending"))
        val pendingIds = pending.map { it.first }.toSet()
        val fresh = pending.filter { it.first !in prefs.seenPending }
        if (prefs.receiveOrders && fresh.isNotEmpty()) {
            Notifier.newRequest(this, pending.map { it.second })
            AlertAudio.play(
                this,
                "new",
                "new:${fresh.map { it.first }.sorted().joinToString(",")}",
                prefs.newRingPath,
                prefs.newRingMode,
                prefs.newRingSeconds,
            )
        }
        if (pendingIds.isEmpty()) {
            AlertAudio.stop("new")
            Notifier.clearNewRequest(this)
        }
        prefs.seenPending = pendingIds

        // ── العميل قال حوّل الـ deposit → صوت محدود المدة مع إبقاء الإشعار
        val claimed = items(res.optJSONArray("claimed"))
        val claimedIds = claimed.map { it.first }.toSet()
        prefs.snoozed = prefs.snoozed.intersect(claimedIds)
        val active = if (prefs.receiveOrders) {
            claimed.filter { it.first !in prefs.snoozed }
        } else {
            emptyList()
        }
        val activeIds = active.map { it.first }.toSet()
        if (activeIds.isEmpty()) {
            if (prefs.ringingIds.isNotEmpty()) {
                AlertAudio.stop("claim")
                Notifier.stopRing(this)
            }
            prefs.ringingIds = emptySet()
        } else if (activeIds != prefs.ringingIds) {
            Notifier.ring(this, active.map { it.second })
            val newlyActive = activeIds - prefs.ringingIds
            if (newlyActive.isNotEmpty()) {
                AlertAudio.play(
                    this,
                    "claim",
                    "claim:${newlyActive.sorted().joinToString(",")}",
                    prefs.claimRingPath,
                    prefs.claimRingMode,
                    prefs.claimRingSeconds,
                )
            }
            prefs.ringingIds = activeIds
        }
    }

    private fun items(a: JSONArray?): List<Pair<String, String>> {
        if (a == null) return emptyList()
        return (0 until a.length()).map { a.getJSONObject(it).let { o -> o.optString("id") to o.optString("code") } }
    }

    private fun toSet(a: JSONArray?): Set<String>? {
        if (a == null) return null
        return (0 until a.length()).map { a.getString(it) }.toSet()
    }

    override fun onDestroy() {
        isRunning = false
        worker.removeCallbacksAndMessages(null)
        thread.quitSafely()
        AlertAudio.stop()
        Notifier.stopRing(this)
        wakeLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
