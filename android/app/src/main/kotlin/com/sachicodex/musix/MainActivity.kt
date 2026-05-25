package com.sachicodex.musix

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var mediaServiceStarted = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler(::handleMethodCall)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    MediaActionBridge.attachSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    MediaActionBridge.detachSink()
                }
            }
        )
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "updateNotification" -> {
                val args = call.arguments as? Map<*, *>
                if (args == null) {
                    result.error("invalid_args", "Expected map arguments.", null)
                    return
                }
                startMediaService(args)
                result.success(null)
            }
            "stopNotification" -> {
                val intent = Intent(this, MediaNotificationService::class.java).apply {
                    action = MediaNotificationService.ACTION_STOP_NOTIFICATION
                }
                startService(intent)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startMediaService(args: Map<*, *>) {
        val intent =
            Intent(this, MediaNotificationService::class.java).apply {
                action = MediaNotificationService.ACTION_UPDATE_NOTIFICATION
                putExtra(MediaNotificationService.EXTRA_TITLE, args["title"] as? String ?: "")
                putExtra(MediaNotificationService.EXTRA_ARTIST, args["artist"] as? String ?: "")
                putExtra(MediaNotificationService.EXTRA_ALBUM, args["album"] as? String ?: "")
                putExtra(MediaNotificationService.EXTRA_ART_URI, args["artUri"] as? String)
                putExtra(MediaNotificationService.EXTRA_IS_PLAYING, args["isPlaying"] as? Boolean ?: false)
                putExtra(MediaNotificationService.EXTRA_IS_LOADING, args["isLoading"] as? Boolean ?: false)
                putExtra(MediaNotificationService.EXTRA_POSITION_MS, (args["positionMs"] as? Number)?.toLong() ?: 0L)
                putExtra(MediaNotificationService.EXTRA_DURATION_MS, (args["durationMs"] as? Number)?.toLong() ?: 0L)
            }
        if (!mediaServiceStarted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
            mediaServiceStarted = true
            return
        }
        startService(intent)
        mediaServiceStarted = true
    }

    companion object {
        private const val METHOD_CHANNEL = "com.sachicodex.musix/media_notification"
        private const val EVENT_CHANNEL = "com.sachicodex.musix/media_notification_actions"
    }
}
