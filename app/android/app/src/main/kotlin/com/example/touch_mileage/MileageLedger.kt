package com.example.touch_mileage

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * 触控里程 · Kotlin 侧账本（数据链下沉的落点）
 *
 * 为什么需要它：FlutterActivity 随时被系统回收，Dart 采样循环会断流——
 * 但无障碍服务（Kotlin）后台仍在计数。账本让"计数→记账"独立于 Activity 生命周期：
 * 服务每次手势结算增量进账本，Dart 前台时收走；Activity 回收期间账本持续累积，
 * 回来一笔不丢（2026-09-07 实测丢增量的修复）。
 *
 * 文件（files/mileage_ledger.json）双职责字段组：
 *   base*  —— 已结算进 pending 的服务计数基线（算增量的锚）
 *   pend*  —— 尚未被 Dart 收走的增量（Kotlin 写）
 *   day*   —— Dart 收账后写回的今日基线（Kotlin 读，通知显示用）
 *
 * 守恒性：通知显示 = day* + pend* 折算。Dart drain 把 pend 挪进 day，
 * 和不变——所以通知只在手势结算时更新，drain 无需通知刷新。
 *
 * 并发：服务写（settle）、通知心跳写（settle）、Dart 写（drain/dayTotal）
 * 三方都在主线程或单线程 Handler 上，再加 synchronized 双保险。
 * 写入走 tmp+rename 原子换名，进程被杀最多丢一次防抖窗口（500ms）。
 */
object MileageLedger {

    private const val FILE_NAME = "mileage_ledger.json"
    private val lock = Any()

    /**
     * 当前计数快照（settle 用）：日常手势 / 视频手势 / 触摸 / 滚动像素。
     *
     * ⚠️ 坑 45（2026-10-11）：这 6 个字段**一律不给默认值**。原先
     * `scrollPx`/`videoScrollPx`/`videoDwellMs` 带 `= 0.0`/`= 0` 默认值，
     * 通知心跳那处只传了前 4 个参数，编译期毫无提示，运行期把两个 base 清零 →
     * 「视频像素 > 总像素」「前台时长 43.7 小时」两个不可能的数字同时上屏。
     * 去掉默认值后，任何漏参都在**编译期**报错，这类事故不会再复发。
     */
    data class Counters(
        val daily: Long,
        val video: Long,
        val taps: Long,
        val scrollPx: Double,
        /** 视频板块像素（scrollPx 的子集，服务侧按 videoHint 归因）。 */
        val videoScrollPx: Double,
        /** 视频应用前台时长累计（毫秒，方案 A；服务侧 dwellSnapshotMs 传入）。 */
        val videoDwellMs: Long,
    )

    /** 一笔待收账的增量批。ts 是最后结算时刻（Dart 按它归日归小时）。 */
    data class Pending(
        val daily: Long, val video: Long, val taps: Long, val ts: Long,
        val screenHeightCm: Double,
        /** M3 真值轨迹增量（厘米）：Shizuku 通道已删除（决策 21），恒 0，仅留字段兼容。 */
        val trackCm: Double = 0.0,
        /** M3' 内容滚动像素增量（2026-09-18）：本次滑过的内容像素量，
         *  Dart 侧 ×（校准屏长÷屏高像素）折算厘米——「这一次滑了多长」
         *  按实际滚过占比估算，与用户校准屏长配合使用。 */
        val scrollPx: Double = 0.0,
        /** 刷视频板块的像素增量（[scrollPx] 的子集）：Dart 侧据此把距离按板块拆开。 */
        val videoScrollPx: Double = 0.0,
        /** 视频应用前台时长增量（毫秒，方案 A）：Dart 侧按秒记入 DayRecord.videoDwellS。 */
        val videoDwellMs: Long = 0,
    )

    /** 通知用：今日基线 + 未收账增量（守恒公式的两半）。 */
    data class NotifStats(
        val dayCm: Double, val dayShorts: Long, val dayTaps: Long,
        val pendDaily: Long, val pendVideo: Long, val pendTaps: Long,
        /** 未收账的滚动像素总量，像素口径折算用。 */
        val pendScrollPx: Double = 0.0,
        /** Dart 收账时回写的「1 滚动像素 = 多少厘米」（含用户校准屏长）；≤0 = 未提供。 */
        val cmPerPx: Double = 0.0,
    )

    private fun file(ctx: Context): File = File(ctx.filesDir, FILE_NAME)

    private fun read(ctx: Context): JSONObject = try {
        JSONObject(file(ctx).readText())
    } catch (_: Exception) {
        JSONObject()
    }

    private fun write(ctx: Context, j: JSONObject) {
        val f = file(ctx)
        val tmp = File(f.parentFile, "$FILE_NAME.tmp")
        tmp.writeText(j.toString())
        if (!tmp.renameTo(f)) {
            // rename 失败（极少数文件系统）：退化为直接写，非原子但内容正确
            f.writeText(j.toString())
            tmp.delete()
        }
    }

    /**
     * 结算：把「服务计数 - base」的增量累进 pend，base 前移，pendTs=now。返回结算后的 pend。
     *
     * 倒挂自愈：服务进程重启后 companion 计数器归零，而 base 还是上一进程的锚 —— 此时
     * `cur` 本身就是重启以来真实发生的计数，故按 `cur` 计增量并**强制落盘重锚**。
     * 少了这次落盘，base 永远追不上 cur，之后每拍差值都被 clamp 成 0 → 计数永久静默停摆
     * （2026-09-22 真机发现：09-18 的「空增量不写盘」优化把原本就承诺的重锚一起跳过了）。
     * 只有「无增量且无倒挂」才跳过 IO。
     *
     * 注：原先还有一个 `countTaps` 形参，用于「只前移 base 锚、增量不入 pend」——
     * 那时 taps 有两个源（无障碍 tapCount 与 Shizuku 的 TRACKING_ID），同账会双计
     * （P1 修复 2026-09-17；ColorOS 16 上 TYPE_TOUCH_INTERACTION_START 不派发所以
     * 此前未暴露，原生系统/模拟器上照发）。Shizuku 通道 2026-10-09 整体移除（决策 21）
     * 后只剩无障碍一个源，互斥条件消失，形参随之退场。
     */
    fun settle(ctx: Context, cur: Counters): Pending {
        synchronized(lock) {
            val j = read(ctx)
            val bD = j.optLong("base_daily", 0)
            val bV = j.optLong("base_video", 0)
            val bT = j.optLong("base_taps", 0)
            val bPx = j.optDouble("base_scroll_px", 0.0)
            val bVPx = j.optDouble("base_video_px", 0.0)
            val bDw = j.optLong("base_video_dwell_ms", 0)
            // 倒挂（cur < base）= 服务进程重启后 companion 计数器归零，而 base 还是
            // 上一进程留下的锚。此时 cur 本身就是"重启以来真实发生的计数"，所以按 cur
            // 计增量而不是丢弃——否则差值被 clamp 成 0，且下面的"空增量不写盘"会在
            // base 重锚之前早退，base 永远追不上 cur，计数从此永久静默停摆（2026-09-22 真机发现）。
            val regressed = cur.daily < bD || cur.video < bV ||
                    cur.taps < bT || cur.scrollPx < bPx || cur.videoScrollPx < bVPx ||
                    cur.videoDwellMs < bDw
            val dD = if (cur.daily < bD) cur.daily else (cur.daily - bD).coerceAtLeast(0)
            val dV = if (cur.video < bV) cur.video else (cur.video - bV).coerceAtLeast(0)
            val dT = if (cur.taps < bT) cur.taps else (cur.taps - bT).coerceAtLeast(0)
            val dPx = if (cur.scrollPx < bPx) cur.scrollPx else (cur.scrollPx - bPx).coerceAtLeast(0.0)
            val dVPx = if (cur.videoScrollPx < bVPx) cur.videoScrollPx
            else (cur.videoScrollPx - bVPx).coerceAtLeast(0.0)
            val dDw = if (cur.videoDwellMs < bDw) cur.videoDwellMs
            else (cur.videoDwellMs - bDw).coerceAtLeast(0)
            // 不变量守卫（坑 45）：视频像素是总像素的子集，增量也必须保持。
            // 上游任一计数器被漏传/清零都会让这里倒挂，那是记账故障——
            // 早暴露胜过月底才发现里程虚高（debug 包打日志，release 静默）。
            if (dVPx > dPx) {
                DebugLog.i("MileageLedger") {
                    "视频像素增量超过总像素增量（dVPx=$dVPx > dPx=$dPx）——上游计数不一致"
                }
            }
            // 空增量不写盘（P2）：采样循环 150ms 一拍 + 通知 30s 心跳都走这里，
            // 用户不动手机时每天白写 5 万+ 次盘；无增量只回快照不落 IO。
            // 但倒挂时必须落盘——那一次写就是"把锚拉回来"，跳过它就等于永久停摆。
            if (dD == 0L && dV == 0L && dT == 0L && dPx == 0.0 && dVPx == 0.0 &&
                dDw == 0L && !regressed) {
                return snapshotPending(ctx, j)
            }
            j.put("base_daily", cur.daily)
            j.put("base_video", cur.video)
            j.put("base_taps", cur.taps)
            j.put("base_scroll_px", cur.scrollPx)
            j.put("base_video_px", cur.videoScrollPx)
            j.put("base_video_dwell_ms", cur.videoDwellMs)
            j.put("pend_daily", j.optLong("pend_daily", 0) + dD)
            j.put("pend_video", j.optLong("pend_video", 0) + dV)
            j.put("pend_taps", j.optLong("pend_taps", 0) + dT)
            j.put("pend_scroll_px", j.optDouble("pend_scroll_px", 0.0) + dPx)
            j.put("pend_video_px", j.optDouble("pend_video_px", 0.0) + dVPx)
            j.put("pend_video_dwell_ms", j.optLong("pend_video_dwell_ms", 0) + dDw)
            j.put("pend_ts", System.currentTimeMillis())
            write(ctx, j)
            return snapshotPending(ctx, j)
        }
    }

    // 原 settleTrack（真值轨迹厘米）与 settleTrackTaps（真值 taps）两个写入口已于
    // 2026-10-09 随 Shizuku 通道移除（决策 21）——它们的唯一调用方是 trackDrain。
    // ⚠️ `pend_track_cm` 的**读取**必须保留（见 drain / Pending.trackCm）：
    // 历史账本里可能还压着未收账的 track 增量，删掉会让那部分里程凭空消失。

    /** Dart 收账：返回 pend 批并清零。[screenHeightCm] 由调用方传入随批带回。 */
    fun drain(ctx: Context, screenHeightCm: Double): Pending {
        synchronized(lock) {
            val j = read(ctx)
            val p = snapshotPending(ctx, j).copy(screenHeightCm = screenHeightCm)
            // 空批不写盘（P2）：空闲采样高频调用，避免无意义 IO
            if (p.daily == 0L && p.video == 0L && p.taps == 0L &&
                p.trackCm <= 0.0 && p.scrollPx <= 0.0 && p.videoScrollPx <= 0.0 &&
                p.videoDwellMs == 0L) {
                return p
            }
            j.put("pend_daily", 0)
            j.put("pend_video", 0)
            j.put("pend_taps", 0)
            j.put("pend_track_cm", 0.0)
            j.put("pend_scroll_px", 0.0)
            j.put("pend_video_px", 0.0)
            j.put("pend_video_dwell_ms", 0)
            write(ctx, j)
            return p
        }
    }

    /**
     * Dart 收账后写回今日基线（通知显示的 day* 部分）。
     * [cmPerPx] = Dart 本次计价真正用到的「1 滚动像素 = 多少厘米」（含用户校准屏长），
     * 存下来让通知的 pending 折算与 App 内用同一把尺子——否则任务栏与界面数字会打架。
     */
    fun writeDayTotal(
        ctx: Context, cm: Double, shorts: Long, taps: Long, cmPerPx: Double,
    ) {
        synchronized(lock) {
            val j = read(ctx)
            j.put("day_cm", cm)
            j.put("day_shorts", shorts)
            j.put("day_taps", taps)
            j.put("cm_per_px", cmPerPx)
            write(ctx, j)
        }
    }

    /** 通知用：今日基线 + 未收账增量（守恒公式的两半）。 */
    fun readForNotification(ctx: Context): NotifStats {
        synchronized(lock) {
            val j = read(ctx)
            return NotifStats(
                dayCm = j.optDouble("day_cm", 0.0),
                dayShorts = j.optLong("day_shorts", 0),
                dayTaps = j.optLong("day_taps", 0),
                pendDaily = j.optLong("pend_daily", 0),
                pendVideo = j.optLong("pend_video", 0),
                pendTaps = j.optLong("pend_taps", 0),
                pendScrollPx = j.optDouble("pend_scroll_px", 0.0),
                cmPerPx = j.optDouble("cm_per_px", 0.0),
            )
        }
    }

    private fun snapshotPending(ctx: Context, j: JSONObject): Pending {
        val dm = ctx.resources.displayMetrics
        val sh = if (dm.ydpi > 0f) dm.heightPixels / dm.ydpi * 2.54 else 0.0
        return Pending(
            daily = j.optLong("pend_daily", 0),
            video = j.optLong("pend_video", 0),
            taps = j.optLong("pend_taps", 0),
            ts = j.optLong("pend_ts", System.currentTimeMillis()),
            screenHeightCm = sh,
            trackCm = j.optDouble("pend_track_cm", 0.0),
            scrollPx = j.optDouble("pend_scroll_px", 0.0),
            videoScrollPx = j.optDouble("pend_video_px", 0.0),
            videoDwellMs = j.optLong("pend_video_dwell_ms", 0),
        )
    }

    /** 手势发生 → 500ms 防抖结算 + 通知刷新（服务内 Handler 驱动）。 */
    fun settleAndNotify(ctx: Context, cur: Counters) {
        val pend = settle(ctx, cur)
        MileageNotificationService.refreshFromLedger(ctx, pend)
    }
}
