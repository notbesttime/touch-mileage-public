package com.example.touch_mileage

import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        /** 与 engine_android.dart 约定的 channel 名。 */
        const val ENGINE_CHANNEL = "touch_mileage/engine"

        /** 与 secure_store.dart 约定的凭据通道名（P1-2）。 */
        const val SECURE_CHANNEL = "touch_mileage/secure"

        /** 通知权限请求码与挂起的 channel 回调（13+ 运行时权限异步回包用）。 */
        const val PERMISSION_RC = 4101
        var pendingPermissionResult: MethodChannel.Result? = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_RC) {
            pendingPermissionResult?.success(
                grantResults.isNotEmpty() &&
                    grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            )
            pendingPermissionResult = null
        }
    }

    /**
     * 面板像素尺寸（整屏物理分辨率）。
     *
     * 用 maximumWindowMetrics（API 30+）而不是 displayMetrics：前者是**面板**尺寸，
     * 不受「显示大小/分辨率」设置与分屏影响；后者是当前窗口尺寸，用户调过显示大小
     * 就会偏小，宽高比一偏，按规格换算出来的屏长也跟着偏。
     * 取不到时返回 0，Dart 侧回落到当前窗口尺寸。
     */
    private fun panelPixels(): Pair<Int, Int> {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val b = getSystemService(android.view.WindowManager::class.java)
                    .maximumWindowMetrics.bounds
                b.width() to b.height()
            } else {
                @Suppress("DEPRECATION")
                val real = android.util.DisplayMetrics().also {
                    windowManager.defaultDisplay.getRealMetrics(it)
                }
                real.widthPixels to real.heightPixels
            }
        } catch (e: Exception) {
            0 to 0
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // —— 凭据安全存储（P1-2）：独立通道，与采集引擎互不影响 ——
        // 两个方法都是同步的 Keystore 操作，但放在非主线程会更快返回；
        // 不过令牌只在登录/启动时读写各一次，主线程开销可忽略，保持简单。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "protect" -> {
                        val plain = call.argument<String>("plain") ?: ""
                        result.success(SecureKeyStore.protect(plain))
                    }
                    "unprotect" -> {
                        val cipher = call.argument<String>("cipher") ?: ""
                        result.success(SecureKeyStore.unprotect(cipher))
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENGINE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 无障碍服务是否已连接（= 采集中）
                    "isServiceConnected" -> result.success(MileageAccessibilityService.connected)
                    // 累计计数快照（含屏幕物理高度厘米，Dart 侧按屏估算距离）
                    "snapshot" -> {
                        val s = MileageAccessibilityService.snapshot()
                        val dm = resources.displayMetrics
                        // 屏幕物理高度（厘米）= 像素高 ÷ 每英寸像素(y) × 2.54。
                        // ydpi 在个别设备上可能为 0，防除零。
                        val screenHeightCm =
                            if (dm.ydpi > 0f) dm.heightPixels / dm.ydpi * 2.54 else 0.0
                        val (panelW, panelH) = panelPixels()
                        result.success(mapOf(
                            "scrolls" to s[0],
                            "taps" to s[1],
                            "scrollPx" to s[2],
                            "screenHeightCm" to screenHeightCm,
                            "videoHint" to s[3],
                            // 屏幕像素高（当前窗口）：计价的分母
                            "heightPixels" to dm.heightPixels,
                            // 面板像素（整屏）：屏长校准按机型规格换算宽高比用
                            "panelWidthPx" to panelW,
                            "panelHeightPx" to panelH,
                            // 厂商上报的物理 dpi：用来**自动推算**「对角线英寸」。
                            // 不可全信（有的机型直接填成密度档），所以 Dart 侧会做可信度
                            // 检查并在可疑时提示用户按规格改。
                            "xdpi" to dm.xdpi.toDouble(),
                            "ydpi" to dm.ydpi.toDouble(),
                            "densityDpi" to dm.densityDpi,
                        ))
                    }
                    // 每日结算归零
                    "reset" -> {
                        MileageAccessibilityService.reset()
                        result.success(true)
                    }
                    // —— 数据链下沉：账本收账（Dart 启动/回前台时拉走增量批）——
                    "drainLedger" -> {
                        val dm = resources.displayMetrics
                        val sh = if (dm.ydpi > 0f) dm.heightPixels / dm.ydpi * 2.54 else 0.0
                        // 先把防抖窗口内的增量结算进账本，再整批取走
                        // （前台时长传含进行中段的快照，恒单调，段不因收账被截断）
                        MileageLedger.settle(
                            this,
                            MileageLedger.Counters(
                                MileageAccessibilityService.dailyGestures,
                                MileageAccessibilityService.videoGestures,
                                MileageAccessibilityService.tapCount,
                                MileageAccessibilityService.scrollPx,
                                MileageAccessibilityService.videoScrollPx,
                                MileageAccessibilityService.dwellSnapshotMs(),
                            )
                        )
                        val p = MileageLedger.drain(this, sh)
                        result.success(mapOf(
                            "daily" to p.daily,
                            "video" to p.video,
                            "taps" to p.taps,
                            "ts" to p.ts,
                            "screenHeightCm" to p.screenHeightCm,
                            "trackCm" to p.trackCm,
                            // M3'：内容滚动像素 + 屏幕像素高（像素计价主模型用）
                            "scrollPx" to p.scrollPx,
                            // 刷视频板块的像素（scrollPx 的子集）——距离按板块拆分的依据
                            "videoScrollPx" to p.videoScrollPx,
                            // 视频应用前台时长增量（毫秒，方案 A）
                            "videoDwellMs" to p.videoDwellMs,
                            "heightPixels" to dm.heightPixels,
                        ))
                    }
                    // Dart 收账后写回今日基线（通知显示的 day 部分）
                    "writeDayTotal" -> {
                        val cm = (call.argument<Any?>("cm") as? Number)?.toDouble() ?: 0.0
                        val shorts = (call.argument<Any?>("shorts") as? Number)?.toLong() ?: 0
                        val taps = (call.argument<Any?>("taps") as? Number)?.toLong() ?: 0
                        val cmPerPx =
                            (call.argument<Any?>("cmPerPx") as? Number)?.toDouble() ?: 0.0
                        MileageLedger.writeDayTotal(this, cm, shorts, taps, cmPerPx)
                        result.success(true)
                    }
                    // 手动板块覆盖（概览长按切换，决策 17）：不进账本，
                    // 只改服务里的分账口径；权威状态在 Dart 的 activeProfileId
                    "setBoardOverride" -> {
                        val mode = call.argument<String>("mode") ?: "auto"
                        MileageAccessibilityService.manualVideo = when (mode) {
                            "video" -> true
                            "daily" -> false
                            else -> null
                        }
                        result.success(true)
                    }
                    // M3 精确模式的 5 个 channel 方法（trackStart / trackStop /
                    // trackStatus / trackRequestPermission / trackDrain）已于 2026-10-09
                    // 随 Shizuku 通道整体移除（决策 21）。它们是休眠能力：Shizuku 在
                    // ColorOS 16 上被系统层拦截、激活门槛过不了（2026-09-18 从产品撤下），
                    // 而 Dart 侧对这几个方法**零调用点**。账本的 track 字段读取保留，
                    // 只为兼容历史账本里已有的 track 增量。
                    // 跳系统无障碍设置页（引导/设置入口用）。
                    // 优先直达本服务的详情开关页（Android 12+ 隐藏 action
                    // ACCESSIBILITY_DETAILS_SETTINGS + 组件名参数，省去
                    // 「已下载的应用 → 找到触控里程」两层点击）；ROM 不支持
                    // 时回落顶层无障碍列表页（原有行为）。
                    "openA11ySettings" -> {
                        val cn = android.content.ComponentName(
                            this, MileageAccessibilityService::class.java
                        )
                        val direct = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
                            .putExtra(Intent.EXTRA_COMPONENT_NAME, cn)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        val directOk = try {
                            startActivity(direct)
                            true
                        } catch (e: Exception) {
                            false
                        }
                        if (!directOk) {
                            startActivity(
                                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        }
                        result.success(true)
                    }
                    // —— 常驻通知（里程速览）——
                    // Android 13+ 通知运行时权限（Flutter 侧开启开关时请求一次）。
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            val p = android.Manifest.permission.POST_NOTIFICATIONS
                            if (checkSelfPermission(p) ==
                                android.content.pm.PackageManager.PERMISSION_GRANTED) {
                                result.success(true)
                            } else {
                                pendingPermissionResult = result
                                requestPermissions(arrayOf(p), PERMISSION_RC)
                            }
                        } else {
                            result.success(true) // 13- 通知无需运行时权限
                        }
                    }
                    // 启动前台服务。Android 13+ 通知运行时权限由 Flutter 侧先行请求。
                    "startStatusNotification" -> {
                        val i = Intent(this, MileageNotificationService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(i)
                        } else {
                            startService(i)
                        }
                        result.success(true)
                    }
                    // 停止速览通知
                    "stopStatusNotification" -> {
                        stopService(Intent(this, MileageNotificationService::class.java))
                        result.success(true)
                    }
                    // 更新速览文案。[distance] 已格式化，[shorts]/[taps] 为今日累计。
                    "updateStatusNotification" -> {
                        val distance = call.argument<String>("distance") ?: ""
                        val shorts = call.argument<Int>("shorts") ?: 0
                        val taps = call.argument<Int>("taps") ?: 0
                        MileageNotificationService.update(this, distance, shorts, taps)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
