package com.lhht.ai_assistant

import android.content.Intent
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.lhht.ai_assistant/wake"
        private const val CALL_CHANNEL = "com.lhht.ai_assistant/call"
    }

    override fun configureFlutterEngine(
        @NonNull flutterEngine: FlutterEngine,
    ) {
        super.configureFlutterEngine(flutterEngine)
        val channel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CHANNEL,
            )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startWakeService" -> {
                    startWakeService()
                    result.success(null)
                }
                "stopWakeService" -> {
                    stopWakeService()
                    result.success(null)
                }
                "bringToFront" -> {
                    bringToFront()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val callChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CALL_CHANNEL,
            )
        callChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startCallService" -> {
                    startCallService()
                    result.success(null)
                }
                "stopCallService" -> {
                    stopCallService()
                    result.success(null)
                }
                "bringToFront" -> {
                    bringToFront()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startWakeService() {
        val intent = Intent(this, WakeForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopWakeService() {
        val intent = Intent(this, WakeForegroundService::class.java)
        stopService(intent)
    }

    private fun startCallService() {
        val intent = Intent(this, CallForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopCallService() {
        val intent = Intent(this, CallForegroundService::class.java)
        stopService(intent)
    }

    private fun bringToFront() {
        val intent = Intent(this, MainActivity::class.java)
        intent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK
                or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                or Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
        startActivity(intent)
    }
}
