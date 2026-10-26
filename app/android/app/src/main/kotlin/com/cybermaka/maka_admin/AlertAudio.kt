package com.cybermaka.maka_admin

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** Plays admin-configured alert sounds independently from the persistent notifications. */
object AlertAudio {
    private const val MAX_BYTES = 5 * 1024 * 1024
    private class Playback {
        var generation = 0
        var key: String? = null
        var player: MediaPlayer? = null
        var stopTimer: Runnable? = null
    }

    private val lock = Any()
    private val handler = Handler(Looper.getMainLooper())
    private val playbacks = mutableMapOf("new" to Playback(), "claim" to Playback())

    fun play(ctx: Context, category: String, key: String, path: String?, mode: String, seconds: Int) {
        val app = ctx.applicationContext
        val (state, runId) = synchronized(lock) {
            val playback = playbacks.getOrPut(category) { Playback() }
            if (playback.key == key) return
            playback.generation += 1
            playback.key = key
            playback.stopTimer?.let(handler::removeCallbacks)
            playback.stopTimer = null
            playback.player?.release()
            playback.player = null
            playback to playback.generation
        }

        Thread({
            try {
                val sound = if (path.isNullOrBlank()) null else cachedSound(app, path)
                val next = if (sound == null) {
                    MediaPlayer.create(app, R.raw.maka_ring)
                        ?: throw IllegalStateException("Unable to load built-in ringtone")
                } else {
                    MediaPlayer()
                }
                next.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                if (sound != null) {
                    next.setDataSource(sound.absolutePath)
                    next.prepare()
                }
                next.isLooping = mode == "timed"
                next.setOnCompletionListener { finished ->
                    synchronized(lock) {
                        if (state.generation == runId && state.player === finished) {
                            finished.release()
                            state.player = null
                        }
                    }
                }
                synchronized(lock) {
                    if (state.generation != runId) {
                        next.release()
                    } else {
                        state.player = next
                        next.start()
                        if (mode == "timed") {
                            val timer = Runnable {
                                synchronized(lock) {
                                    if (state.generation == runId) {
                                        state.player?.release()
                                        state.player = null
                                        state.stopTimer = null
                                    }
                                }
                            }
                            state.stopTimer = timer
                            handler.postDelayed(timer, seconds.coerceIn(1, 300) * 1000L)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e("MakaAlertAudio", "Unable to play configured alert sound", e)
                synchronized(lock) {
                    if (state.generation == runId) {
                        state.player?.release()
                        state.player = null
                    }
                }
            }
        }, "maka-alert-$category").start()
    }

    fun stop(category: String? = null) {
        synchronized(lock) {
            val targets = if (category == null) playbacks.values.toList() else listOfNotNull(playbacks[category])
            for (state in targets) {
                state.generation += 1
                state.key = null
                state.stopTimer?.let(handler::removeCallbacks)
                state.stopTimer = null
                state.player?.release()
                state.player = null
            }
        }
    }

    private fun cachedSound(ctx: Context, path: String): File {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(path.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        val ext = path.substringAfterLast('.', "audio").take(8).filter { it.isLetterOrDigit() }
        val dir = File(ctx.cacheDir, "ringtones").apply { mkdirs() }
        val target = File(dir, "$digest.$ext")
        if (target.exists() && target.length() in 1..MAX_BYTES.toLong()) return target

        val encodedPath = path.split('/').joinToString("/") {
            java.net.URLEncoder.encode(it, "UTF-8").replace("+", "%20")
        }
        val connection = (URL("${MakaPrefs(ctx).apiUrl}/storage/v1/object/public/ringtones/$encodedPath")
            .openConnection() as HttpURLConnection).apply {
            connectTimeout = 12000
            readTimeout = 15000
            requestMethod = "GET"
        }
        try {
            if (connection.responseCode !in 200..299) {
                throw IllegalStateException("Ringtone download failed: HTTP ${connection.responseCode}")
            }
            if (connection.contentLengthLong > MAX_BYTES) throw IllegalStateException("Ringtone exceeds size limit")
            val temp = File(dir, "$digest.tmp")
            connection.inputStream.use { input ->
                FileOutputStream(temp).use { output ->
                    val buffer = ByteArray(8192)
                    var total = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_BYTES) throw IllegalStateException("Ringtone exceeds size limit")
                        output.write(buffer, 0, count)
                    }
                }
            }
            if (!temp.renameTo(target)) {
                temp.delete()
                throw IllegalStateException("Unable to cache ringtone")
            }
            return target
        } finally {
            connection.disconnect()
        }
    }
}
