package com.example.touch_mileage

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * 触控里程 · 常驻通知服务（里程速览 + 保活 + 账本心跳）
 *
 * 三职责：
 *   · 状态栏常驻速览：今日距离 / 视频翻页次数 / 点击次数
 *   · 前台服务降低系统回收——无障碍服务被杀 = 采集停摆
 *   · 数据链下沉的"心脏"：30s 心跳兜底结算账本（防抖窗口丢失时补记账）
 *
 * 通知内容 Kotlin 自理（refreshFromLedger）：day 基线 + pending 增量，
 * 不依赖 Flutter 推送——Activity 回收期间通知照样随账本增长。
 *
 * 隐私：通知只显示统计数字，无任何内容性信息。
 */
class MileageNotificationService : Service() {

    companion object {
        const val CHANNEL_ID = "mileage_status"
        const val NOTIFICATION_ID = 1

        /** 心跳周期（毫秒）：防抖结算丢失时的兜底 + 通知刷新。 */
        const val kHeartbeatMs = 30_000L

        /**
         * ⚠️ 与 app/lib/engine/engine_android.dart 的同名常量保持一致：
         * 日常手势折算系数（保守估算）。此副本仅用于通知显示的临时折算，
         * 落盘真值由 Dart 侧折算——改系数时两处同步。
         */
        const val kGestureCmRatioKt = 0.35
        const val kVideoGestureScreenRatioKt = 1.0

        /** 从账本刷新通知内容（day 基线 + pending 增量，守恒公式）。 */
        fun refreshFromLedger(context: Context, pend: MileageLedger.Pending? = null) {
            val s = MileageLedger.readForNotification(context)
            // pend 参数为空时（如心跳路径）直接读账本里的值
            val pDaily = pend?.daily ?: s.pendDaily
            val pVideo = pend?.video ?: s.pendVideo
            val pTaps = pend?.taps ?: s.pendTaps
            val pPx = pend?.scrollPx ?: s.pendScrollPx
            val dm = context.resources.displayMetrics
            val screenCm =
                if (dm.ydpi > 0f) dm.heightPixels / dm.ydpi * 2.54 else 0.0
            // 优先用 Dart 收账时回写的「1 像素 = 多少厘米」（含用户校准屏长）——
            // 与 App 内今日距离同一个换算系数，任务栏和界面数字不会打架。
            // 只有从未收过账（刚装包、没打开过界面）时才回落老的手势系数公式。
            val pendCm = if (s.cmPerPx > 0.0) {
                pPx * s.cmPerPx
            } else {
                pDaily * screenCm * kGestureCmRatioKt +
                        pVideo * screenCm * kVideoGestureScreenRatioKt
            }
            val text = buildText(
                s.dayCm + pendCm, s.dayShorts + pVideo, s.dayTaps + pTaps)
            notify(context, text)
        }

        /** 用服务启动时的初始文案（无账本数据）更新通知。 */
        fun update(context: Context, distance: String, shorts: Int, taps: Int) {
            notify(context, buildText2(distance, shorts.toLong(), taps.toLong()))
        }

        private fun buildText(cm: Double, shorts: Long, taps: Long): String {
            val distance = if (cm >= 100000) {
                String.format("%.1f 公里", cm / 100000)
            } else if (cm >= 100) {
                String.format("%.0f 米", cm / 100)
            } else {
                String.format("%.1f 厘米", cm)
            }
            return buildText2(distance, shorts, taps)
        }

        private fun buildText2(distance: String, shorts: Long, taps: Long): String =
            buildString {
                append("今日 $distance")
                // 口径同界面：这是**翻页次数**（滚动手势数），不是视频条数。
                // 一次上滑算一次，抖音这类自绘流数不到——别写成"条"（P2-2）。
                if (shorts > 0) append(" · 视频翻页 $shorts 次")
                if (taps > 0) append(" · 点击 $taps 次")
            }.ifEmpty { "正在记录你的触控里程" }

        private fun notify(context: Context, text: String) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(context, text))
        }

        private fun buildNotification(context: Context, text: String): Notification {
            val tapIntent = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_compass)
                .setContentTitle("触控里程")
                .setContentText(text)
                .setOngoing(true)
                .setSilent(true)
                .setContentIntent(tapIntent)
                .setOnlyAlertOnce(true)
                .build()
        }
    }

    private val heartbeatHandler = Handler(Looper.getMainLooper())

    /** 心跳：兜底结算（覆盖无手势但防抖丢失的窗口）+ 通知刷新。 */
    private val heartbeat = object : Runnable {
        override fun run() {
            // ⚠️ 坑 45（2026-10-11 修）：这里原先只传 4 个参数，`videoScrollPx`
            // 与 `videoDwellMs` 走默认值 0 被悄悄漏掉。settle 会把 base 前移到
            // cur —— 于是每次心跳（30s）都把 `base_video_px`/`base_video_dwell_ms`
            // **清零**，紧接着的真实手势结算再把「本进程以来的累计值」当成增量灌进
            // pend → `pend_video_px ≫ pend_scroll_px`（视频像素大于总像素，本不可能）、
            // 前台时长也成倍虚高（真机实测 video_cm 199.9 米 > 今日 59.2 米、
            // video_dwell_s 157442 秒 ≈ 43.7 小时）。**必须与 settle 的字段一一对应**。
            MileageLedger.settleAndNotify(
                this@MileageNotificationService,
                MileageLedger.Counters(
                    MileageAccessibilityService.dailyGestures,
                    MileageAccessibilityService.videoGestures,
                    MileageAccessibilityService.tapCount,
                    MileageAccessibilityService.scrollPx,
                    MileageAccessibilityService.videoScrollPx,
                    MileageAccessibilityService.dwellSnapshotMs(),
                )
            )
            heartbeatHandler.postDelayed(this, kHeartbeatMs)
        }
    }

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "里程速览",
                NotificationManager.IMPORTANCE_LOW  // 低优先级：不响铃不弹横幅，常驻不打扰
            ).apply { description = "状态栏速览今日里程与点击" }
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = buildNotification(this, "正在记录你的触控里程")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        // 首拍立刻结算+刷一次（启动恢复路径），之后 30s 心跳
        heartbeatHandler.removeCallbacks(heartbeat)
        heartbeat.run()
        return START_STICKY
    }

    override fun onDestroy() {
        heartbeatHandler.removeCallbacks(heartbeat)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
