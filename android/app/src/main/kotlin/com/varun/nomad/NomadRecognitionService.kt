package com.varun.nomad

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * RecognitionService required by Android for the system-assistant role.
 * Recognition is delegated to the device's configured speech provider so
 * selecting Nomad as assistant does not require a Nomad-owned STT model.
 */
class NomadRecognitionService : RecognitionService() {
    private val recognizers = ConcurrentHashMap<Callback, SpeechRecognizer>()

    override fun onStartListening(intent: Intent, callback: Callback) {
        onCancel(callback)

        val provider = resolveSpeechProvider(this)
        if (provider == null) {
            try { callback.error(SpeechRecognizer.ERROR_CLIENT) } catch (_: Exception) { }
            return
        }

        try {
            val recognizer = SpeechRecognizer.createSpeechRecognizer(this, provider)
            recognizers[callback] = recognizer
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = forward(callback, recognizer) { readyForSpeech(params) }
                override fun onBeginningOfSpeech() = forward(callback, recognizer) { beginningOfSpeech() }
                override fun onRmsChanged(rmsdB: Float) = forward(callback, recognizer) { rmsChanged(rmsdB) }
                override fun onBufferReceived(buffer: ByteArray?) {
                    if (buffer != null) forward(callback, recognizer) { bufferReceived(buffer) }
                }
                override fun onEndOfSpeech() = forward(callback, recognizer) { endOfSpeech() }
                override fun onError(error: Int) {
                    if (recognizers[callback] !== recognizer) return
                    release(callback, cancelRecognition = false)
                    try { callback.error(error) } catch (_: Exception) { }
                }
                override fun onResults(results: Bundle?) {
                    if (recognizers[callback] !== recognizer) return
                    release(callback, cancelRecognition = false)
                    try {
                        if (results != null) callback.results(results)
                        else callback.error(SpeechRecognizer.ERROR_NO_MATCH)
                    } catch (_: Exception) { }
                }
                override fun onPartialResults(partialResults: Bundle?) {
                    if (partialResults != null) forward(callback, recognizer) { this.partialResults(partialResults) }
                }
                override fun onEvent(eventType: Int, params: Bundle?) = Unit
            })
            recognizer.startListening(intent)
        } catch (error: Exception) {
            Log.e(TAG, "Could not start the configured speech provider", error)
            release(callback)
            try { callback.error(SpeechRecognizer.ERROR_CLIENT) } catch (_: Exception) { }
        }
    }

    override fun onStopListening(callback: Callback) {
        try {
            recognizers[callback]?.stopListening()
        } catch (_: Exception) {
            release(callback)
            try { callback.error(SpeechRecognizer.ERROR_CLIENT) } catch (_: Exception) { }
        }
    }

    override fun onCancel(callback: Callback) {
        release(callback)
    }

    override fun onDestroy() {
        recognizers.keys.toList().forEach(::release)
        super.onDestroy()
    }

    private fun forward(callback: Callback, recognizer: SpeechRecognizer, action: Callback.() -> Unit) {
        // Results from a destroyed/replaced recognizer belong to its old caller.
        if (recognizers[callback] !== recognizer) return
        try { callback.action() } catch (_: Exception) { release(callback) }
    }

    private fun release(callback: Callback, cancelRecognition: Boolean = true) {
        recognizers.remove(callback)?.let {
            if (cancelRecognition) {
                try {
                    it.cancel()
                } catch (_: Exception) {
                }
            }
            try {
                it.destroy()
            } catch (_: Exception) {
            }
        }
    }

    companion object {
        private const val TAG = "NomadRecognition"

        fun resolveSpeechProvider(context: Context): ComponentName? {
            val configured = runCatching {
                android.provider.Settings.Secure.getString(
                    context.contentResolver, "voice_recognition_service",
                )?.let(ComponentName::unflattenFromString)
            }.getOrNull()
            // Nomad's proxy must never select itself. Real recognition services
            // do not have to advertise CATEGORY_DEFAULT.
            @Suppress("DEPRECATION")
            val providers = runCatching {
                context.packageManager.queryIntentServices(
                    Intent(RecognitionService.SERVICE_INTERFACE), 0,
                ).asSequence()
                    .mapNotNull { it.serviceInfo }
                    .filter { it.packageName != context.packageName && it.enabled && it.exported && it.applicationInfo.enabled }
                    .map { ComponentName(it.packageName, it.name) }.toList()
            }.getOrDefault(emptyList())
            return configured?.takeIf { it in providers } ?: providers.firstOrNull()
        }
    }
}
