package com.varun.nomad

import android.app.ActivityManager
import android.app.SearchManager
import android.app.role.RoleManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var assistantChannel: MethodChannel? = null
    private var pendingLaunch: Bundle? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasAssistantFocus = false
    private val audioManager by lazy { getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private val actions by lazy { AssistantActions(this) }
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change < 0 && hasAssistantFocus) {
            releaseAssistantFocus()
            assistantChannel?.invokeMethod("audioFocusLost", null)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        if (savedInstanceState == null) captureAssistantLaunch(intent)
        else pendingLaunch = savedInstanceState.getBundle("nomad.pendingAssistant")
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureAssistantLaunch(intent)
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // TRIM_MEMORY_RUNNING_CRITICAL: hand the pressure signal to Flutter so
        // WidgetsBindingObservers can drop caches and release the model once
        // inference is idle.
        if (level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) {
            flutterEngine?.dartExecutor?.binaryMessenger?.let {
                MethodChannel(it, "flutter/system").invokeMethod("memoryPressure", null)
            }
        }
    }

    private fun captureAssistantLaunch(launchIntent: Intent?) {
        if (launchIntent == null) return
        val assistant = launchIntent.getBooleanExtra("assistant", false) ||
            launchIntent.action == Intent.ACTION_ASSIST ||
            launchIntent.action == Intent.ACTION_VOICE_COMMAND
        if (!assistant) return // An ordinary intent must not erase a pending invocation.
        pendingLaunch = Bundle().apply {
            putString("id", UUID.randomUUID().toString())
            putBoolean("voice", launchIntent.getBooleanExtra("assistant_voice", true))
            putString("prompt", launchIntent.getStringExtra("assistant_prompt")
                ?: launchIntent.getStringExtra(SearchManager.QUERY))
        }
        launchIntent.removeExtra("assistant")
        launchIntent.removeExtra("assistant_voice")
        launchIntent.removeExtra("assistant_prompt")
        launchIntent.removeExtra(SearchManager.QUERY)
        launchIntent.action = Intent.ACTION_MAIN // Do not replay after activity recreation.
        assistantChannel?.invokeMethod("assistantInvoked", null)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        pendingLaunch?.let { outState.putBundle("nomad.pendingAssistant", it) }
        super.onSaveInstanceState(outState)
    }

    private fun consumeLaunch(): Map<String, Any?>? {
        val launch = pendingLaunch ?: return null
        pendingLaunch = null
        return mapOf("id" to launch.getString("id"), "voice" to launch.getBoolean("voice", true),
            "prompt" to launch.getString("prompt"))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        assistantChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.varun.nomad/assistant").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeLaunch" -> result.success(consumeLaunch())
                    "isSpeechRecognitionAvailable" -> result.success(NomadRecognitionService.resolveSpeechProvider(this) != null)
                    "requestAudioFocus" -> result.success(requestAssistantFocus())
                    "releaseAudioFocus" -> {
                        releaseAssistantFocus()
                        result.success(null)
                    }
                    "openSettings" -> {
                        try {
                            startActivity(actions.settingsIntent(call.argument<String>("kind") ?: "app"))
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "executeAction" -> {
                        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                        result.success(actions.execute(arguments["action"] as? String, arguments))
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.varun.nomad/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "getStorageSpace" -> {
                    try {
                        val stat = StatFs(Environment.getDataDirectory().path)
                        result.success(mapOf("total" to stat.totalBytes, "free" to stat.availableBytes))
                    } catch (e: Exception) {
                        result.error("STORAGE_ERROR", e.message, null)
                    }
                }
                "getDeviceRAM", "getMemoryInfo" -> {
                    try {
                        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val info = ActivityManager.MemoryInfo()
                        manager.getMemoryInfo(info)
                        if (call.method == "getDeviceRAM") result.success(info.totalMem)
                        else result.success(mapOf("availableBytes" to info.availMem, "lowMemory" to info.lowMemory))
                    } catch (e: Exception) {
                        result.error("RAM_ERROR", e.message, null)
                    }
                }
                "openAssistantSettings" -> result.success(openAssistantSettings())
                else -> result.notImplemented()
            }
        }
    }

    private fun openAssistantSettings(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roles = getSystemService(RoleManager::class.java)
            if (roles.isRoleAvailable(RoleManager.ROLE_ASSISTANT) && !roles.isRoleHeld(RoleManager.ROLE_ASSISTANT)) {
                try {
                    startActivityForResult(roles.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT), 8191)
                    return true
                } catch (_: Exception) { /* Fall back to the system picker. */ }
            }
        }
        for (action in arrayOf(Settings.ACTION_VOICE_INPUT_SETTINGS, Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS, Settings.ACTION_SETTINGS)) {
            try {
                startActivity(Intent(action))
                return true
            } catch (_: Exception) { /* Try the next settings activity. */ }
        }
        return false
    }

    private fun requestAssistantFocus(): Boolean {
        if (hasAssistantFocus) return true
        return try {
            val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                    .setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setOnAudioFocusChangeListener(focusListener).build()
                focusRequest = request
                audioManager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            }
            hasAssistantFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            hasAssistantFocus
        } catch (_: Exception) {
            false
        }
    }

    private fun releaseAssistantFocus() {
        hasAssistantFocus = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
                focusRequest = null
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(focusListener)
            }
        } catch (_: Exception) { /* Already released by Android. */ }
    }

    override fun onStop() {
        if (hasAssistantFocus) assistantChannel?.invokeMethod("audioFocusLost", null)
        releaseAssistantFocus()
        super.onStop()
    }

    override fun onDestroy() {
        releaseAssistantFocus()
        assistantChannel?.setMethodCallHandler(null)
        assistantChannel = null
        super.onDestroy()
    }
}
