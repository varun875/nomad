package com.varun.nomad

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.provider.AlarmClock
import android.provider.MediaStore
import android.provider.Settings
import android.view.KeyEvent
import java.util.Locale

/** OS-owned actions: opening an intent never claims that a call was made,
 * a setting was changed, or an alarm was saved without a result from that app. */
class AssistantActions(private val activity: Activity) {
    fun execute(action: String?, arguments: Map<*, *>): Map<String, Any> {
        return try {
            when (action) {
                "openApp" -> openApp(arguments["name"] as? String ?: "")
                "settings" -> {
                    val kind = arguments["kind"] as? String ?: "app"
                    open(settingsIntent(kind), "Here are your $kind settings.")
                }
                "timer" -> {
                    val seconds = (arguments["seconds"] as? Number)?.toInt()
                    if (seconds != null && seconds !in 1..86400) return failure("That timer duration is not valid.")
                    val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
                        if (seconds != null) putExtra(AlarmClock.EXTRA_LENGTH, seconds)
                        putExtra(AlarmClock.EXTRA_SKIP_UI, false)
                    }
                    open(intent, "Opening Clock with your timer request.")
                }
                "alarm" -> {
                    val hour = (arguments["hour"] as? Number)?.toInt()
                    val minute = (arguments["minute"] as? Number)?.toInt() ?: 0
                    if ((hour != null && hour !in 0..23) || minute !in 0..59) return failure("That alarm time is not valid.")
                    val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                        if (hour != null) {
                            putExtra(AlarmClock.EXTRA_HOUR, hour)
                            putExtra(AlarmClock.EXTRA_MINUTES, minute)
                        }
                        putExtra(AlarmClock.EXTRA_SKIP_UI, false)
                    }
                    open(intent, "Opening Clock with your alarm request.")
                }
                "directions" -> {
                    val destination = arguments["destination"] as? String ?: ""
                    if (destination.isBlank()) return failure("Where would you like to go?")
                    val uri = Uri.parse("https://www.google.com/maps/dir/").buildUpon()
                        .appendQueryParameter("api", "1")
                        .appendQueryParameter("destination", destination).build()
                    open(Intent(Intent.ACTION_VIEW, uri), "Opening directions to $destination.")
                }
                "webSearch" -> {
                    val query = arguments["query"] as? String ?: ""
                    if (query.isBlank()) return failure("What would you like to search for?")
                    val uri = Uri.parse("https://www.google.com/search").buildUpon()
                        .appendQueryParameter("q", query).build()
                    open(Intent(Intent.ACTION_VIEW, uri), "Opening search results for $query.")
                }
                "openUrl" -> {
                    val raw = (arguments["url"] as? String ?: "").trim()
                    if (raw.isBlank()) return failure("Which web page would you like?")
                    val url = if (raw.startsWith("http://") || raw.startsWith("https://")) raw else "https://$raw"
                    open(Intent(Intent.ACTION_VIEW, Uri.parse(url)), "Opening $url.")
                }
                "call" -> {
                    val number = phoneNumber(arguments["number"] as? String) ?: return failure("I need a phone number to call.")
                    open(Intent(Intent.ACTION_DIAL, Uri.parse("tel:$number")), "Opening the dialer for $number.")
                }
                "message" -> {
                    val number = phoneNumber(arguments["number"] as? String) ?: return failure("I need a phone number to text.")
                    val body = arguments["body"] as? String
                    val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$number"))
                    if (!body.isNullOrBlank()) intent.putExtra("sms_body", body)
                    open(intent, "Opening Messages with a text to $number.")
                }
                "mediaPlay" -> mediaKey(KeyEvent.KEYCODE_MEDIA_PLAY, "Sent play to your music app.")
                "mediaPause" -> mediaKey(KeyEvent.KEYCODE_MEDIA_PAUSE, "Sent pause to your music app.")
                "mediaNext" -> mediaKey(KeyEvent.KEYCODE_MEDIA_NEXT, "Skipping to the next track.")
                "mediaPrevious" -> mediaKey(KeyEvent.KEYCODE_MEDIA_PREVIOUS, "Going back a track.")
                "volumeUp" -> adjustVolume(AudioManager.ADJUST_RAISE, "Turning the volume up.")
                "volumeDown" -> adjustVolume(AudioManager.ADJUST_LOWER, "Turning the volume down.")
                "volumeMute" -> adjustVolume(AudioManager.ADJUST_MUTE, "Muting the volume.")
                "volumeUnmute" -> adjustVolume(AudioManager.ADJUST_UNMUTE, "Unmuting the volume.")
                "battery" -> batteryStatus()
                else -> failure("That phone action is not available.")
            }
        } catch (_: Exception) {
            failure("Your phone couldn't open that action. Please try it from the app directly.")
        }
    }

    fun settingsIntent(kind: String): Intent = when (kind) {
        "wifi" -> Intent(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS)
        "bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
        "sound", "speech" -> Intent(if (kind == "speech") "com.android.settings.TTS_SETTINGS" else Settings.ACTION_SOUND_SETTINGS)
        "recognition" -> Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
        "display" -> Intent(Settings.ACTION_DISPLAY_SETTINGS)
        "battery" -> Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
        "location" -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
        "assistant" -> Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
        "app", "permission" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}"))
        else -> Intent(Settings.ACTION_SETTINGS)
    }

    private fun openApp(name: String): Map<String, Any> {
        if (name.isBlank()) return failure("Which app would you like to open?")
        val category = when (name) {
            "browser" -> Intent.CATEGORY_APP_BROWSER
            "messages", "messaging" -> Intent.CATEGORY_APP_MESSAGING
            "maps" -> Intent.CATEGORY_APP_MAPS
            "photos", "gallery" -> Intent.CATEGORY_APP_GALLERY
            "email", "mail" -> Intent.CATEGORY_APP_EMAIL
            "calendar" -> Intent.CATEGORY_APP_CALENDAR
            "calculator" -> Intent.CATEGORY_APP_CALCULATOR
            else -> null
        }
        if (category != null) return open(Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, category), "Opening $name.")
        if (name == "settings") return open(Intent(Settings.ACTION_SETTINGS), "Opening Settings.")
        if (name == "phone" || name == "dialer") return open(Intent(Intent.ACTION_DIAL), "Opening Phone.")
        if (name == "camera") return open(Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA), "Opening Camera.")

        val manager = activity.packageManager
        val aliases = mapOf("youtube" to "com.google.android.youtube", "whatsapp" to "com.whatsapp",
            "spotify" to "com.spotify.music", "chrome" to "com.android.chrome", "gmail" to "com.google.android.gm",
            "twitter" to "com.twitter.android", "x" to "com.twitter.android")
        aliases[name]?.let { packageName ->
            manager.getLaunchIntentForPackage(packageName)?.let { return open(it, "Opening $name.") }
        }
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val apps = manager.queryIntentActivities(launcher, 0)
            .filter { it.activityInfo.exported && it.activityInfo.enabled }
        val target = normalized(name)
        val exact = apps.filter { normalized(it.loadLabel(manager).toString()) == target }
        val matches = (if (exact.isNotEmpty()) exact else apps.filter {
            normalized(it.loadLabel(manager).toString()).startsWith("$target ")
        }).distinctBy { it.activityInfo.packageName }
        if (matches.size > 1) return failure("More than one app matches $name. Please say the app's full name.")
        val match = matches.singleOrNull() ?: return failure("I couldn't find an installed app called $name.")
        val intent = manager.getLaunchIntentForPackage(match.activityInfo.packageName)
            ?: return failure("That app doesn't have a launch screen.")
        return open(intent, "Opening ${match.loadLabel(manager)}.")
    }

    /** Keeps digits and a leading + so the dialer and messaging apps can parse it. */
    private fun phoneNumber(value: String?): String? {
        val trimmed = value?.trim().orEmpty()
        if (!Regex("^\\+?[\\d\\s().-]+$").matches(trimmed)) return null
        val digits = trimmed.filter { it.isDigit() }
        if (digits.length < 3 || digits.length > 15) return null
        return if (trimmed.startsWith("+")) "+$digits" else digits
    }

    private fun mediaKey(keyCode: Int, message: String): Map<String, Any> {
        val audio = activity.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return failure("This device can't control playback.")
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
        return success(message)
    }

    private fun adjustVolume(direction: Int, message: String): Map<String, Any> {
        val audio = activity.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return failure("This device can't change the volume.")
        audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI)
        return success(message)
    }

    private fun batteryStatus(): Map<String, Any> {
        val manager = activity.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            ?: return failure("I couldn't read the battery level.")
        val level = manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (level !in 0..100) return failure("I couldn't read the battery level.")
        val status = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        return success("Your battery is at $level%${if (charging) " and charging." else "."}")
    }

    private fun success(message: String): Map<String, Any> =
        mapOf("success" to true, "message" to message)

    private fun normalized(value: String) = value.lowercase(Locale.ROOT)
        .replace(Regex("[^\\p{L}\\p{N} ]"), "").replace(Regex("\\s+"), " ").trim()

    private fun open(intent: Intent, message: String): Map<String, Any> {
        activity.startActivity(intent)
        return mapOf("success" to true, "message" to message)
    }

    private fun failure(message: String): Map<String, Any> = mapOf("success" to false, "message" to message)
}
