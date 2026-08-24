package com.varun.nomad

import android.app.ActivityManager
import android.content.Context
import android.os.StatFs
import android.os.Environment
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.varun.nomad/storage"
    private val oldVolumes = mutableMapOf<Int, Int>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStorageSpace" -> {
                    try {
                        val stat = StatFs(Environment.getDataDirectory().path)
                        val totalBytes = stat.totalBytes
                        val freeBytes = stat.availableBytes
                        result.success(mapOf("total" to totalBytes, "free" to freeBytes))
                    } catch (e: Exception) {
                        result.error("STORAGE_ERROR", e.message, null)
                    }
                }
                "getDeviceRAM" -> {
                    try {
                        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val memoryInfo = ActivityManager.MemoryInfo()
                        activityManager.getMemoryInfo(memoryInfo)
                        result.success(memoryInfo.totalMem)
                    } catch (e: Exception) {
                        result.error("RAM_ERROR", e.message, null)
                    }
                }
                "checkAssistantTrigger" -> {
                    val wasAssistant = intent.getBooleanExtra("assistant", false)
                    // Clear the extra so it doesn't trigger again on configuration change
                    intent.removeExtra("assistant")
                    result.success(wasAssistant)
                }
                "muteSystemSounds" -> {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val streams = intArrayOf(
                            AudioManager.STREAM_SYSTEM,
                            AudioManager.STREAM_NOTIFICATION,
                            AudioManager.STREAM_ALARM,
                            AudioManager.STREAM_RING,
                            AudioManager.STREAM_DTMF
                        )
                        for (stream in streams) {
                            if (!oldVolumes.containsKey(stream)) {
                                oldVolumes[stream] = audioManager.getStreamVolume(stream)
                            }
                            audioManager.setStreamVolume(stream, 0, 0)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "unmuteSystemSounds" -> {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val streams = intArrayOf(
                            AudioManager.STREAM_SYSTEM,
                            AudioManager.STREAM_NOTIFICATION,
                            AudioManager.STREAM_ALARM,
                            AudioManager.STREAM_RING,
                            AudioManager.STREAM_DTMF
                        )
                        for (stream in streams) {
                            val oldVol = oldVolumes[stream] ?: audioManager.getStreamMaxVolume(stream) / 2
                            audioManager.setStreamVolume(stream, oldVol, 0)
                            oldVolumes.remove(stream)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "muteMusicStream" -> {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        if (!oldVolumes.containsKey(AudioManager.STREAM_MUSIC)) {
                            oldVolumes[AudioManager.STREAM_MUSIC] = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        }
                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "unmuteMusicStream" -> {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val oldVol = oldVolumes[AudioManager.STREAM_MUSIC] ?: audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC) / 2
                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, oldVol, 0)
                        oldVolumes.remove(AudioManager.STREAM_MUSIC)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
