package com.varun.nomad

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.StatFs
import android.os.Environment
import android.media.AudioManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.varun.nomad/storage"
    private val oldVolumes = mutableMapOf<Int, Int>()

    // Set from onNewIntent() so a warm-start assistant launch can be consumed by Dart
    // on app resume (the cold-start path still reads getIntent() directly below).
    private var pendingAssistant = false
    private var pendingAssistantPrompt: String? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingAssistant = intent.getBooleanExtra("assistant", false)
        pendingAssistantPrompt = intent.getStringExtra("assistant_prompt")
        // Consume-once: don't re-fire on the next config change / resume.
        intent.removeExtra("assistant")
        intent.removeExtra("assistant_prompt")
    }

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
                    // Cold start reads the launch intent; warm start reads the stash from
                    // onNewIntent(). Both consume-once so a config change / resume doesn't
                    // re-trigger the assistant.
                    val wasAssistant = pendingAssistant || intent.getBooleanExtra("assistant", false)
                    val prompt = when {
                        pendingAssistantPrompt != null -> pendingAssistantPrompt
                        else -> intent.getStringExtra("assistant_prompt")
                    }
                    pendingAssistant = false
                    pendingAssistantPrompt = null
                    intent.removeExtra("assistant")
                    intent.removeExtra("assistant_prompt")
                    result.success(mapOf("assistant" to wasAssistant, "prompt" to prompt))
                }
                "openAssistantSettings" -> {
                    // Best-effort jump to the system assistant picker so the user can pick
                    // Nomad as the default assistant. No local state is implied by this row.
                    val targets = arrayOf(
                        Intent("android.settings.VOICE_INPUT_SETTINGS"),
                        Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
                        Intent(Settings.ACTION_SETTINGS),
                    )
                    for (target in targets) {
                        try {
                            target.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(target)
                            result.success(true)
                            return@setMethodCallHandler
                        } catch (_: Exception) {
                            // Try the next fallback.
                        }
                    }
                    result.success(false)
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
