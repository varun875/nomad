package com.finn.nomad

import android.speech.RecognitionService
import android.content.Intent
import android.os.Bundle

class AssistantRecognitionService : RecognitionService() {
    override fun onStartListening(intent: Intent?, listener: Callback?) {
        // This is a stub for the assistant's recognition service
    }

    override fun onCancel(listener: Callback?) {
        // Stub
    }

    override fun onStopListening(listener: Callback?) {
        // Stub
    }
}
