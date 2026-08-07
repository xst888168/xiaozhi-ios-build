package com.lhht.ai_assistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * 后台语音唤醒保活服务。
 *
 * 作用：
 * 1. 以「前台服务 + microphone 类型」运行，使应用在退到后台 / 锁屏时仍能采集麦克风；
 * 2. 持有一个 PARTIAL_WAKE_LOCK，保证 CPU 在息屏后不休眠，离线唤醒引擎可持续监听；
 * 3. 常驻通知栏，用户可点通知回到应用。
 *
 * 真正的唤醒检测仍在 Dart 层 [WakeWordService]（主 isolate）运行；本服务只负责“保活”，
 * 让主 isolate 在后台不被系统回收，从而麦克风监听不中断。
 */
class WakeForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification())
        acquireWakeLock()
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val chan =
                NotificationChannel(
                    CHANNEL_ID,
                    "语音唤醒",
                    NotificationManager.IMPORTANCE_LOW,
                )
            chan.description = "后台语音唤醒常驻"
            val mgr = getSystemService(NotificationManager::class.java)
            mgr.createNotificationChannel(chan)
        }
    }

    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        val pi =
            PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_IMMUTABLE,
            )
        return NotificationCompat
            .Builder(this, CHANNEL_ID)
            .setContentTitle("小智AI 正在后台聆听")
            .setContentText("说“小智”或“你好小智”即可唤醒")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pi)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock =
            pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "xiaozhi:wake",
            )
        // 最长持锁 6 小时，超时自动释放避免耗电异常
        wakeLock?.acquire(6L * 60 * 60 * 1000)
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    companion object {
        const val NOTIF_ID = 1001
        const val CHANNEL_ID = "wake_service_channel"
    }
}
