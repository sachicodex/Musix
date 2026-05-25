package com.sachicodex.musix

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object MediaActionBridge {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingActions = ArrayDeque<Map<String, String>>()
    private var eventSink: EventChannel.EventSink? = null

    @Synchronized
    fun attachSink(sink: EventChannel.EventSink) {
        eventSink = sink
        while (pendingActions.isNotEmpty()) {
            val payload = pendingActions.removeFirst()
            mainHandler.post { sink.success(payload) }
        }
    }

    @Synchronized
    fun detachSink() {
        eventSink = null
    }

    @Synchronized
    fun emit(command: String) {
        val payload = mapOf("action" to command)
        val sink = eventSink
        if (sink == null) {
            pendingActions.addLast(payload)
            return
        }
        mainHandler.post { sink.success(payload) }
    }
}
