package com.varun.nomad

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.view.LayoutInflater
import android.view.View
import android.widget.TextView

/** The system gesture hands off to the SAME voice session as the in-app mic.
 * There is no second recognizer stealing the mic or running before permission. */
class AssistantSession(context: Context) : VoiceInteractionSession(context) {
    private var launched = false
    private var contentRoot: View? = null

    override fun onCreateContentView(): View {
        val root = LayoutInflater.from(context).inflate(R.layout.assistant_popup, null)
        contentRoot = root
        root.findViewById<TextView>(R.id.status_text)?.text = "Opening Nomad…"
        root.setOnClickListener { finish() }
        root.findViewById<View>(R.id.sheet)?.setOnClickListener { }
        root.findViewById<View>(R.id.chip_talk)?.setOnClickListener { launchNomad(true) }
        root.findViewById<View>(R.id.btn_keyboard)?.setOnClickListener { launchNomad(false) }
        root.findViewById<View>(R.id.btn_close)?.setOnClickListener { finish() }
        root.findViewById<View>(R.id.chip_open_twitter)?.visibility = View.GONE
        root.findViewById<View>(R.id.chip_open_messages)?.visibility = View.GONE
        return root
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        launched = false
        launchNomad(true)
    }

    private fun launchNomad(voice: Boolean) {
        if (launched) return
        launched = true
        try {
            val intent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_ASSIST
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra("assistant", true)
                putExtra("assistant_voice", voice)
            }
            // The session-aware API is permitted for a user-invoked assistant
            // even on Android versions that restrict background startActivity.
            startAssistantActivity(intent)
            finish()
        } catch (_: Exception) {
            launched = false
            contentRoot?.findViewById<TextView>(R.id.status_text)?.text = "Tap Talk to Nomad to try again"
        }
    }
}
