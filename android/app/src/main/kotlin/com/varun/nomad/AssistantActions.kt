package com.varun.nomad

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.AlarmClock
import android.provider.MediaStore
import android.provider.Settings
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

    private fun normalized(value: String) = value.lowercase(Locale.ROOT)
        .replace(Regex("[^\\p{L}\\p{N} ]"), "").replace(Regex("\\s+"), " ").trim()

    private fun open(intent: Intent, message: String): Map<String, Any> {
        activity.startActivity(intent)
        return mapOf("success" to true, "message" to message)
    }

    private fun failure(message: String): Map<String, Any> = mapOf("success" to false, "message" to message)
}
