package com.varun.nomad

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.service.voice.VoiceInteractionSession
import android.view.LayoutInflater
import android.view.View
import android.view.animation.Animation
import android.view.animation.ScaleAnimation
import android.widget.TextView
import java.util.Locale

class AssistantSession(context: Context) : VoiceInteractionSession(context) {

    private val handler = Handler(Looper.getMainLooper())
    private var pulseRunnable: Runnable? = null
    private var contentRoot: View? = null
    private var recognizer: SpeechRecognizer? = null
    private var restartAttempts = 0
    private var launched = false

    override fun onCreateContentView(): View {
        val root = LayoutInflater.from(context).inflate(R.layout.assistant_popup, null)
        contentRoot = root

        // Entry animation on the sheet
        root.findViewById<View>(R.id.sheet)?.let { sheet ->
            sheet.post {
                sheet.translationY = sheet.height.toFloat() * 0.4f
                sheet.alpha = 0f
                sheet.animate()
                    .translationY(0f)
                    .alpha(1f)
                    .setDuration(260)
                    .setInterpolator(android.view.animation.DecelerateInterpolator())
                    .start()
            }
        }

        // Tap outside dismisses; taps inside the sheet do not bubble.
        root.setOnClickListener { finish() }
        root.findViewById<View>(R.id.sheet)?.setOnClickListener { }

        // Manual path: keyboard / chip -> open the app in LiveMode.
        root.findViewById<View>(R.id.chip_talk)?.setOnClickListener { launchNomad(null) }
        root.findViewById<View>(R.id.btn_keyboard)?.setOnClickListener { launchNomad(null) }
        root.findViewById<View>(R.id.chip_open_twitter)?.setOnClickListener { launchTwitter() }
        root.findViewById<View>(R.id.chip_open_messages)?.setOnClickListener { launchMessages() }
        root.findViewById<View>(R.id.btn_close)?.setOnClickListener { finish() }

        startDotPulse(root)

        // GA-style flow: listen immediately and show the live transcript.
        if (SpeechRecognizer.isRecognitionAvailable(context)) {
            try {
                recognizer = SpeechRecognizer.createSpeechRecognizer(context)
                recognizer?.setRecognitionListener(recognitionListener)
                handler.postDelayed({ startListening() }, 350)
            } catch (_: Exception) {
                recognizer = null
            }
        } else {
            statusText()?.text = "Tap Talk to Nomad"
        }
        return root
    }

    private fun startListening() {
        if (launched || recognizer == null) return
        statusText()?.text = "Listening…"
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
        }
        try {
            recognizer?.startListening(intent)
        } catch (_: Exception) {}
    }

    private fun restartListening() {
        if (launched || restartAttempts >= 3) return
        restartAttempts++
        handler.postDelayed({ startListening() }, 900)
    }

    private fun stopListening() {
        try { recognizer?.stopListening() } catch (_: Exception) {}
    }

    private fun releaseRecognizer() {
        pulseRunnable?.let { handler.removeCallbacks(it) }
        try {
            recognizer?.stopListening()
            recognizer?.destroy()
        } catch (_: Exception) {}
        recognizer = null
    }

    private fun launchTwitter() {
        try {
            val intent = context.packageManager.getLaunchIntentForPackage("com.twitter.android")
                ?: Intent(Intent.ACTION_VIEW).apply {
                    data = android.net.Uri.parse("https://twitter.com")
                }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (_: Exception) {}
        finish()
    }

    private fun launchMessages() {
        try {
            val intent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_APP_MESSAGING)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } catch (_: Exception) {}
        finish()
    }

    private fun launchNomad(prompt: String?) {
        if (launched) return
        launched = true
        stopListening()
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("assistant", true)
            if (!prompt.isNullOrBlank()) putExtra("assistant_prompt", prompt)
        }
        context.startActivity(intent)
        finish()
    }

    private fun statusText(): TextView? =
        contentRoot?.findViewById(R.id.status_text)

    private fun startDotPulse(root: View) {
        val dots = listOfNotNull<View>(
            root.findViewById(R.id.dot1),
            root.findViewById(R.id.dot2),
            root.findViewById(R.id.dot3)
        )
        if (dots.isEmpty()) return
        var step = 0
        val r = object : Runnable {
            override fun run() {
                dots.forEachIndexed { i, dot ->
                    val active = i == step % 3
                    val scale = if (active) 1.25f else 1.0f
                    val anim = ScaleAnimation(
                        1f, scale, 1f, scale,
                        Animation.RELATIVE_TO_SELF, 0.5f,
                        Animation.RELATIVE_TO_SELF, 0.5f
                    ).apply {
                        duration = 180
                        fillAfter = true
                    }
                    dot.clearAnimation()
                    dot.startAnimation(anim)
                    dot.animate().alpha(if (active) 1f else 0.45f).setDuration(150).start()
                }
                step++
                handler.postDelayed(this, 380)
            }
        }
        pulseRunnable = r
        handler.post(r)
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            statusText()?.text = "Listening…"
        }

        override fun onBeginningOfSpeech() {}

        override fun onRmsChanged(rmsdB: Float) {}

        override fun onBufferReceived(buffer: ByteArray) {}

        override fun onEndOfSpeech() {
            statusText()?.text = "…"
        }

        override fun onError(error: Int) {
            if (launched) return
            statusText()?.text = when (error) {
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                    "Didn't catch that…"
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Mic permission needed"
                else -> "Mic error — retrying"
            }
            restartListening()
        }

        override fun onPartialResults(partialResults: Bundle) {
            val text = firstText(partialResults)
            if (!text.isNullOrBlank()) statusText()?.text = text
        }

        override fun onResults(results: Bundle?) {
            val text = firstText(results)
            if (text.isNullOrBlank()) {
                statusText()?.text = "Didn't catch that…"
                restartListening()
                return
            }
            launchNomad(text)
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun firstText(bundle: Bundle?): String? {
        val list = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: return null
        return list.firstOrNull { !it.isNullOrBlank() }?.trim()
    }

    override fun finish() {
        releaseRecognizer()
        super.finish()
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        // Keep session alive so the popup stays interactive until dismissed.
    }
}
