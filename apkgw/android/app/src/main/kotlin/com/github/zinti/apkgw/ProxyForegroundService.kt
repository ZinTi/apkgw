package com.github.zinti.apkgw

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import java.net.NetworkInterface

class ProxyForegroundService : Service() {
    companion object {
        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"
        private const val CHANNEL_ID = "apk_gateway_channel"
        private const val NOTIFICATION_ID = 1234
    }

    private lateinit var wakeLock: PowerManager.WakeLock
    private var currentPort = 8888
    private var currentIp = "192.168.43.1"

    override fun onCreate() {
        super.onCreate()
        // 创建通知渠道（Android 8.0+）
        createNotificationChannel()

        // 获取唤醒锁，防止息屏后CPU进入深度睡眠导致Socket断流
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "APKGw::WakeLock"
        )
        // 注意：长时间持有唤醒锁会消耗电量，但代理服务必须保持网络活跃
        wakeLock.acquire(10 * 60 * 1000L) // 每次10分钟，Service运行时需周期性续期；或在stop时释放。
        // 更稳健做法：在onStartCommand中每次执行acquire，但我们以onDestroy释放为准。
        // 结合前台服务，实际大多数场景下屏幕熄灭网络仍可用。
        // 若要完全保险，可在onStartCommand中重新acquire，但本例为简单起见，在onCreate中acquire并在onDestroy释放。
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                currentPort = intent.getIntExtra("PORT", 8888)
                currentIp = getHotspotIp()
                startForeground(NOTIFICATION_ID, buildNotification(currentIp, currentPort))
                // 如果服务已启动但被系统回收，重新获取锁
                if (!wakeLock.isHeld) {
                    wakeLock.acquire(10 * 60 * 1000L)
                }
            }
            ACTION_STOP -> {
                stopForeground(true)
                stopSelf()
            }
        }
        // 返回 START_STICKY 使服务在被异常杀死后尝试重建（但重建后需Dart层重新绑定）
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        // 释放唤醒锁
        if (wakeLock.isHeld) {
            wakeLock.release()
        }
        // 确保前台通知移除
        stopForeground(true)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * 创建通知渠道（Android 8.0+必须）
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "代理网关服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持APK代理网关在后台运行"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    /**
     * 构建前台通知
     */
    private fun buildNotification(ip: String, port: Int): Notification {
        // 点击通知返回主Activity
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("APK 代理网关运行中")
            .setContentText("热点IP: $ip  端口: $port  点击管理")
            .setSmallIcon(android.R.drawable.ic_menu_share) // 可使用自己的图标，此处借用系统图标
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true) // 不可滑动清除
            .setContentIntent(pendingIntent)
            .build()
    }

    /**
     * 获取热点IP（与MainActivity逻辑一致，也可合并到工具类）
     */
    private fun getHotspotIp(): String {
        return try {
            val networkInterface = NetworkInterface.getByName("wlan0")
            networkInterface?.inetAddresses?.asSequence()
                ?.find { it.isSiteLocalAddress && !it.isLoopbackAddress && it.hostAddress?.contains(":") == false }
                ?.hostAddress ?: "192.168.43.1"
        } catch (e: Exception) {
            e.printStackTrace()
            "192.168.43.1"
        }
    }
}
