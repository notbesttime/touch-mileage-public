package com.example.touch_mileage

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import kotlin.math.abs

/**
 * 触控里程 · 无障碍采集服务（手势计数 + 视频分账 + 账本结算）
 *
 * 隐私红线（设计文档 6.4，任何改动不得违反）：
 *   · 绝不申请 canRetrieveWindowContent —— 只数事件，绝不读屏幕内容
 *   · 只统计事件类型、次数与滚动像素量，不记录包名以外的任何上下文，更不记录文本
 *   · 不采集触摸坐标、不做轨迹累加（M3 的 onMotionEvent 通道已于 2026-10-11 整体
 *     删除，见《隐私政策》第三节「我们明确不收集什么」）
 *   · 被动接收系统广播的事件，不模拟点击、不注入输入
 *
 * 数据链下沉（2026-09-07）：手势发生 → 500ms 防抖把增量结算进 MileageLedger，
 * 记账独立于 FlutterActivity 生命周期——Activity 被回收后账本仍在累积，
 * Dart 回前台 drain 收走，增量不丢（详见 MileageLedger 头注释）。
 */
class MileageAccessibilityService : AccessibilityService() {

    companion object {
        const val TAG = "MileageA11y"

        /** 相邻事件间隔不超过此值视为同一次手势（毫秒）。 */
        const val kGestureGapMs = 300L

        /**
         * 命中白名单后的**粘滞窗口**（毫秒）：这段时间内非白名单窗口事件不改
         * videoHint 判定。存在的理由是被切走的应用会**补发**一条窗口事件，
         * 时序上晚于新应用到达（真机实测 0.5~0.6 秒，2026-10-11）。
         */
        const val kVideoHintStickyMs = 800L

        /** 手势后防抖结算窗口（毫秒）：窗口内新手势重置计时，连续滑动只结算一次。 */
        const val kSettleDebounceMs = 500L

        /**
         * 刷视频应用白名单（包名前缀匹配）——自动判定板块用。
         * 包名只用于判定，绝不存储、不随数据上报。
         */
        val kVideoPackages = listOf(
            "com.ss.android.ugc.aweme",        // 抖音
            "com.ss.android.ugc.aweme.lite",   // 抖音极速版
            "com.smile.gifmaker",              // 快手
            "com.kuaishou.nebula",             // 快手极速版
            "com.tencent.qqlive",              // 腾讯视频
            "tv.danmaku.bili",                 // 哔哩哔哩
            "com.baidu.BaiduVideo",            // 百度看看
            "com.huawei.video",                // 华为视频
        )

        /** 日常手势累计（按事件发生时的 videoHint 分账，替代旧单一 scrollCount）。 */
        @Volatile var dailyGestures: Long = 0
            private set

        /** 刷视频手势累计（一次翻页 ≈ 一条视频，Dart 侧记 shorts）。 */
        @Volatile var videoGestures: Long = 0
            private set

        /** 触摸累计（同聚合口径）。 */
        @Volatile var tapCount: Long = 0
            private set

        /** 滚动像素总量（|deltaY| 累加）。像素计价的分子，也是校准向导的观测量。 */
        @Volatile var scrollPx: Double = 0.0
            private set

        /**
         * 刷视频板块的滚动像素累计（事件发生时 videoHint=true 的那部分）。
         * 手势数早就分板块了（dailyGestures/videoGestures），像素此前只有一个总量，
         * 所以"日常走了多少 / 刷视频走了多少"各自多少算不出来——2026-09-26 补上。
         * 恒满足 videoScrollPx ≤ scrollPx，日常半边 = scrollPx - videoScrollPx。
         */
        @Volatile var videoScrollPx: Double = 0.0
            private set

        /** 自动判定：前台是否是刷视频应用（白名单命中）。仅判定用，不落盘。 */
        @Volatile var videoHint: Boolean = false
            private set

        /**
         * 刷视频应用**前台时长**累计（毫秒，2026-10-08 合并版抖音覆盖方案）。
         *
         * 坑 30 的正面回应：抖音自绘流不派发无障碍事件，「刷了几条」结构上数不出；
         * 但「前台在哪个应用」系统始终知道（TYPE_WINDOW_STATE_CHANGED）——
         * 所以记录白名单应用的合并前台时长（方案 A），不换算条数、不估每条秒数。
         *
         * 口径与边界：
         *   · 只按白名单命中计时，[manualVideo] 手动挡**不**扩它（在微信里手动挡
         *     分账是给视频号的娱乐口径，把聊天时间也记成"视频应用使用时长"就错了）；
         *   · 合并总量，不分应用——包名只判定、不存储（隐私红线 6.4）；
         *   · 熄屏立即停表，亮屏若仍在视频应用（videoHint 未翻转）自动续表；
         *   · 离开前台靠下一次窗口变化事件兜底，最后一次离开若系统没发事件，
         *     会多计到熄屏/结算为止——估算口径，宁可说明不准也不假装精确。
         */
        @Volatile var videoDwellMs: Long = 0
            private set

        /** 计时段开表时刻（elapsedRealtime）；0 = 没有正在进行的段。 */
        @Volatile private var videoEnteredAtMs = 0L

        /** 熄屏停表时 videoHint 是否仍命中（亮屏续表用）。 */
        @Volatile private var resumeDwellOnScreenOn = false

        /** 开表（幂等：已有进行中的段则不动）。 */
        private fun startVideoDwell() {
            if (videoEnteredAtMs == 0L) videoEnteredAtMs = SystemClock.elapsedRealtime()
        }

        /** 停表：把进行中的段折算进累计（幂等：没有进行中的段则不动）。 */
        fun sealVideoDwell() {
            if (videoEnteredAtMs != 0L) {
                videoDwellMs += SystemClock.elapsedRealtime() - videoEnteredAtMs
                videoEnteredAtMs = 0L
            }
        }

        /**
         * 含进行中段的累计快照（settle/结算用）。
         * 恒单调：进行中的段只会增长，折算后 videoDwellMs 接住，锚不回退。
         */
        fun dwellSnapshotMs(): Long =
            if (videoEnteredAtMs == 0L) videoDwellMs
            else videoDwellMs + (SystemClock.elapsedRealtime() - videoEnteredAtMs)

        /**
         * 手动板块覆盖（概览长按切换，2026-10-06）：null = 自动（按白名单判）、
         * true = 强制刷视频、false = 强制日常。
         *
         * 不落盘：权威的那份是 Dart 的 `config.activeProfileId`，启动与回前台时
         * Dart 会重新推一次，所以服务进程被回收也不会丢状态。存在意义是给白名单
         * 覆盖不到的视频入口（如微信视频号）一个手动挡。
         */
        @Volatile var manualVideo: Boolean? = null

        /**
         * 当前活着的服务实例（未连接 / 已解绑时为 null）。
         *
         * 为什么不是一个裸的 `@Volatile var connected`（坑 59）：`onUnbind` 是
         * **实例方法**，而 `connected` 是 companion（静态）——关闭再开启无障碍时，
         * 系统可能先建新实例（`onServiceConnected` 置 true）再跑旧实例的 `onUnbind`
         * （置 false）。结果是活实例在正常计数、静态标志却翻回 false，状态横幅就
         * 漏报「无障碍已关闭，里程不再增长」（实测 release 包，且元凶日志正好被
         * 坑 57 静默掉，极难查）。改存"活实例引用"后，被读取的永远是"当前实例在不在"，
         * 竞态消失。对外仍是 `MileageAccessibilityService.connected`，调用点不变。
         */
        @Volatile private var liveInstance: MileageAccessibilityService? = null

        /** 服务是否已连接（= 有活实例在采集中）。 */
        val connected: Boolean get() = liveInstance != null

        /** 计数总快照（channel 兼容口径：日常+视频）。 */
        fun snapshot(): List<Any> = listOf(
            dailyGestures + videoGestures, tapCount, scrollPx, videoHint
        )

        fun reset() {
            dailyGestures = 0
            videoGestures = 0
            tapCount = 0
            scrollPx = 0.0
            videoScrollPx = 0.0
            videoDwellMs = 0
            videoEnteredAtMs = 0
            resumeDwellOnScreenOn = false
        }
    }

    // —— 手势聚合状态（仅主线程事件回调访问）——
    private var lastScrollAt = 0L
    private var lastTapAt = 0L

    /** videoHint 的粘滞截止时刻（uptimeMillis，0 = 不在粘滞期）。 */
    private var videoHintStickyUntilMs = 0L

    /**
     * 仅 debug 包：收到的各类无障碍事件累计。
     *
     * 存在的理由：「刷抖音为什么不计入」这类反馈有三种完全不同的原因——
     * ① 该 App 根本不派发 TYPE_VIEW_SCROLLED（自定义翻页容器）② 派发了但
     * videoHint 没命中白名单 ③ 派发的是别的事件类型（翻页常见 TYPE_VIEW_SELECTED）。
     * 三者修法完全不同，光看里程数字分不出来，只能看事件构成。release 零输出。
     */
    private val eventTypes = HashMap<String, Int>()

    private fun tallyEventType(event: AccessibilityEvent) {
        if (!DebugLog.enabled) return
        val name = AccessibilityEvent.eventTypeToString(event.eventType)
            ?.replace("EventType", "")?.replace("type:", "")?.replace("!", "")
            ?: "code=${event.eventType}"
        eventTypes[name] = (eventTypes[name] ?: 0) + 1
    }

    private fun debugLogEventMix() {
        if (!DebugLog.enabled) return
        val mix = eventTypes.entries.sortedByDescending { it.value }
            .joinToString(" ") { "${it.key}=${it.value}" }
        DebugLog.i(TAG) { "event mix: ${if (mix.isEmpty()) "(none)" else mix}" }
    }

    /** 防抖结算：手势后 500ms 把增量结算进账本（连续滑动只结算末尾一次）。 */
    private val settleHandler = Handler(Looper.getMainLooper())
    private val settleTask = Runnable {
        MileageLedger.settleAndNotify(
            this,
            MileageLedger.Counters(
                dailyGestures, videoGestures, tapCount, scrollPx, videoScrollPx,
                dwellSnapshotMs()
            )
        )
        debugLogEventMix()
    }

    /**
     * 熄屏/亮屏广播：前台时长的可靠封口。
     * TYPE_WINDOW_STATE_CHANGED 只在应用切换时来——用户熄屏刷着抖音去睡觉，
     * 没有任何事件告诉服务「人走了」，不封口整晚都算在刷视频头上。
     * 熄屏 → 立即停表；亮屏 → 若熄屏时 videoHint 仍命中（没切过应用），自动续表，
     * 之后用户解锁进了别的应用会触发窗口事件正常停表。
     */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    sealVideoDwell()
                    resumeDwellOnScreenOn = videoHint
                }
                Intent.ACTION_SCREEN_ON -> {
                    if (resumeDwellOnScreenOn) {
                        startVideoDwell()
                        resumeDwellOnScreenOn = false
                    }
                }
            }
        }
    }

    /** 服务连接成功（用户在系统设置里开启后回调）。 */
    override fun onServiceConnected() {
        super.onServiceConnected()
        // 熄屏/亮屏广播是受保护系统广播，只收系统发的（NOT_EXPORTED，隐私口径）。
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(screenReceiver, filter)
        }
        // 2026-10-11：M3 的 onMotionEvent 坐标流通道（flagSendMotionEvents +
        // setMotionEventSources + onMotionEvent 回调）已整体删除。它自 2026-09-16
        // 起就是实验残留：ColorOS 16 真机零回调（坑 9），Shizuku 路线也按决策 21
        // 撤下。留着等于申请「接收全局触摸事件」的能力却没有用途，与隐私政策的
        // 「不采集触摸坐标」逐字矛盾——现在这件事在代码上可验证。
        liveInstance = this
        Log.i(TAG, "service connected — collecting scroll/tap events" +
                " (flags=0x${Integer.toHexString(serviceInfo.flags)})")
    }

    /** 用户在系统设置里关闭服务时回调。 */
    override fun onUnbind(intent: Intent?): Boolean {
        // 只清"自己"：旧实例的解绑不能顶掉新实例的连接（坑 59——裸静态曾在这里
        // 把新实例的连接状态一起清成 false，横幅因此漏报）。
        if (liveInstance === this) liveInstance = null
        // 时长计段封口（onUnbind 后广播收不到了，留在表里的段会漏）
        sealVideoDwell()
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: Exception) {
        }
        // 关闭前把最后的增量落账本，防丢
        settleHandler.removeCallbacks(settleTask)
        settleTask.run()
        // 2026-10-13：与 onServiceConnected 对称，改走 Log.i 而非 DebugLog。
        // DebugLog 由 BuildConfig.DEBUG 编译期门控，release 下静默；而 DebugLog.kt
        // 头注释明写「生命周期日志（服务连接/解绑）不走这里……是 release 真机排查
        // 『服务到底起来没』的唯一线索」。此前这里漏改 ⇒ release 只能看到 connected、
        // 看不到 unbound，用户报「里程不涨了」时无法判断是否被静默解绑（本次排查即
        // 卡在这里）。日志只含计数与能力位，无包名/坐标，符合隐私红线 6.4。
        Log.i(TAG, "service unbound — stopped (daily=$dailyGestures video=$videoGestures" +
                " taps=$tapCount dwellMs=$videoDwellMs)")
        return super.onUnbind(intent)
    }

    /**
     * 兜底：极少数情况下服务只走 destroy 不走 unbind，别让 [liveInstance] 悬空
     * （悬空会让 `connected` 永远为 true，横幅反向卡在"已开启"）。同样只清"自己"。
     */
    override fun onDestroy() {
        if (liveInstance === this) liveInstance = null
        super.onDestroy()
    }

    override fun onInterrupt() {
        // 系统要求实现；被动统计没有需要中断的动作，留空
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        tallyEventType(event)
        val now = SystemClock.uptimeMillis()
        when (event.eventType) {
            // 列表/页面滚动：聚合成手势后按 videoHint 分账（揉捏只算一次手势）
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> {
                // 手动板块覆盖优先于自动判定：概览长按切到「刷视频」后，
                // 白名单外的应用也按视频口径计（2026-10-06，见决策 17）
                val asVideo = manualVideo ?: videoHint
                // M3'（2026-09-18）：内容滚动像素（横+纵合计）——这次滑动实际
                // 滚过多长按像素占比估算，计价见 LedgerBatch.cm；部分 App
                // 不回报真实 delta（恒 1px），Dart 侧有退化检测回落手势计价
                val dPx = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    abs(event.scrollDeltaY.toDouble()) + abs(event.scrollDeltaX.toDouble())
                } else 0.0
                if (dPx > 0) {
                    scrollPx += dPx
                    // 板块归因：只有视频板块的像素单独存，
                    // Dart 侧才算得出「刷视频实际为今日距离带了多少」
                    if (asVideo) videoScrollPx += dPx
                }
                if (now - lastScrollAt > kGestureGapMs) {
                    if (asVideo) videoGestures++ else dailyGestures++
                    // pkg 是「谁在派发滚动事件」的第一手证据：坑 30 判定抖音零事件、
                    // 后来的复测却在 videoHint=true 下数到了手势，两者要分清楚
                    // 到底是抖音真的发了、还是 videoHint 过期后按另一个应用分的账。
                    DebugLog.d(TAG) {
                        "scroll gesture #${dailyGestures + videoGestures} video=$asVideo" +
                                " px=${dPx.toInt()} pkg=${event.packageName}" +
                                " (manual=$manualVideo, hint=$videoHint)"
                    }
                    scheduleSettle()
                }
                lastScrollAt = now
            }
            // 触摸交互开始：同样聚合（一次接触的多次回调只算一次）。
            // 注意：adb input swipe 注入不触发本事件（B0 预检实测），真机复验。
            // ColorOS 16 不派发本事件（坑 9 定案）——taps 兜底走下面的 CLICKED。
            AccessibilityEvent.TYPE_TOUCH_INTERACTION_START -> {
                if (now - lastTapAt > kGestureGapMs) {
                    tapCount++
                    DebugLog.d(TAG) { "tap #$tapCount" }
                    scheduleSettle()
                }
                lastTapAt = now
            }
            // 点击交互（taps 兜底信号源，2026-09-18）：ColorOS 不派发
            // TOUCH_INTERACTION_START，原生点击事件全系统照发——按钮/列表项/
            // 开关等可点击控件的点击都算一次。口径 =「点击交互」，不是原始触摸。
            // 只计数，不读控件内容（隐私红线：无 canRetrieveWindowContent）。
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                if (now - lastTapAt > kGestureGapMs) {
                    tapCount++
                    // 包名属"用户用了哪个应用"级信息，release 写进 logcat 等于外泄面
                    DebugLog.d(TAG) { "click #$tapCount pkg=${event.packageName}" }
                    scheduleSettle()
                }
                lastTapAt = now
            }
            // 前台应用变化：白名单命中 → videoHint（自动判定板块）。
            // 只读事件自带包名做判定，不读窗口内容、不落盘。
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                val pkg = event.packageName?.toString() ?: return
                val hit = kVideoPackages.any { pkg.startsWith(it) }
                // 诊断（debug-only，release 零输出）：白名单明明装了快手/抖音，
                // 可它在前台刷着时 `hint` 仍是 false——到底是窗口事件压根没带
                // 白名单包名、还是带了却被别的窗口冲掉，光看数字分不出来。
                // 这行把每次窗口事件的 pkg/className/hit 都记下来（坑 45 同批加）。
                DebugLog.d(TAG) {
                    "winstate pkg=$pkg cls=${event.className} hit=$hit"
                }
                // ① 自身包名**永不参与判定**：我们永远不可能是"视频应用"，而被切到
                //    后台时本应用会补发一条窗口事件——2026-10-11 真机底片抓到的
                //    凶手正是它：快手 hit=true 后 0.6 秒，本包（cls=FrameLayout）
                //    一条 hit=false 把 hint 打掉，视频应用里的滑动全被记成日常。
                //    这条是语义确定的，不是启发式，没有误判面。
                if (pkg == packageName) return
                if (hit) {
                    // ② 粘滞窗口：命中白名单后一段时间内，非白名单事件不改判定。
                    //    "被切走的应用补发一条"是时序竞态（晚于新应用到达），
                    //    光靠①挡不住别的应用来这一手。
                    videoHintStickyUntilMs =
                        SystemClock.uptimeMillis() + kVideoHintStickyMs
                } else if (SystemClock.uptimeMillis() < videoHintStickyUntilMs) {
                    DebugLog.d(TAG) { "winstate 粘滞期内忽略 pkg=$pkg" }
                    return
                }
                if (hit != videoHint) {
                    // 前台时长计段（方案 A 主信号，2026-10-08）：命中开表、离开停表。
                    // 手动挡不扩这里——"视频应用使用时长"只认白名单应用。
                    if (hit) startVideoDwell() else sealVideoDwell()
                    videoHint = hit
                    DebugLog.i(TAG) { "videoHint=$hit (pkg=$pkg)" }
                }
            }
        }
    }

    /** 手势后 500ms 防抖结算（连续滑动只结算一次，减少 IO）。 */
    private fun scheduleSettle() {
        settleHandler.removeCallbacks(settleTask)
        settleHandler.postDelayed(settleTask, kSettleDebounceMs)
    }
}
