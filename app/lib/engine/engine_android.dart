// -*- coding: utf-8 -*-
// 触控里程 · Android 采集引擎绑定（手势化按屏计数 / taps / 板块计价）
//
// 与 mileage_ffi.dart 接口同型（设计文档 6.2）：open / start / stop / snapshot。
// 底层走 platform channel → MainActivity → MileageAccessibilityService 的静态计数
// （无障碍服务由用户在系统设置开启，见步骤 1-2）。
//
// 与 Windows 版的差异（有意为之）：
//   · 采集量是"手势数（滚动事件按 300ms 间隙聚合）/ 触摸次数"，距离由板块计价：
//     手势 × 屏高 × 板块系数（见 kGestureCmRatio / kVideoGestureScreenRatio）
//   · 方法是 async 的（跨 channel 必然异步），Windows 版是同步 FFI
//   · 桌面专属能力（托盘/Mica/覆层/IME/自启/按键统计）在 Android 不存在，不在此暴露

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 日常滑动板块：一次滚动手势折算多少屏高（保守系数）。
///
/// 手势 = 间隔 >300ms 切分（Kotlin 侧聚合），一次"从下到上划到底"约 1~3 手势。
/// 此系数贴近真实位移量级（真机实测反馈按事件计价暴涨数倍后回缩）。
/// ⚠️ 模拟器粗标值，真机重标方法：滑已知距离（尺子量过），对比应用累计值按比例调整。
const double kGestureCmRatio = 0.35;

/// 刷视频板块：一次翻页手势 ≈ 一屏内容（系数 1.0），记录"视频走过的距离"。
const double kVideoGestureScreenRatio = 1.0;

/// 按「屏幕对角线英寸 + 面板像素」算出一屏的物理长度（厘米）。
///
/// 手机规格里的「6.78 英寸」指的是**对角线**，不是屏长。用它先把对角线换算成厘米，
/// 再按长边占对角线的比例取出滑动方向那一边的长度：
///   屏长 = 长边像素 ÷ √(长边² + 短边²) × 对角线英寸 × 2.54
/// 好处是**完全不依赖 ydpi**——那是厂商填的（本机反推是 450.94，不少机型只写整数档），
/// 正是「系统估算」偏差的来源。取长边是为了横竖屏给同一块屏时结果一致。
/// 面板像素还没读到、或用户没填规格时返回 0，调用方回落「直接填屏长」。
double screenCmFromDiagonal({
  required int panelWidthPx,
  required int panelHeightPx,
  required double diagonalInch,
}) {
  if (diagonalInch <= 0) return 0;
  final long =
      (panelWidthPx > panelHeightPx ? panelWidthPx : panelHeightPx).toDouble();
  final short =
      (panelWidthPx > panelHeightPx ? panelHeightPx : panelWidthPx).toDouble();
  if (long <= 0 || short <= 0) return 0;
  final diagPx = math.sqrt(long * long + short * short);
  return long / diagPx * diagonalInch * 2.54;
}

/// 「一滚动像素 ≈ 多少厘米」——分母与计价用的屏高像素保持一致。
double cmPerScrollPx(double screenCm, int heightPx) =>
    (screenCm > 0 && heightPx > 0) ? screenCm / heightPx : 0;


/// 由厂商上报的 xdpi/ydpi 反推屏幕**对角线英寸**（自动填用）。
///
/// Android 没有「物理尺寸」API，只有厂商填的 xdpi/ydpi。多数现代机型填得挺准
/// （本机反推 6.77 英寸，规格 6.78，差 0.1%），但也有机型直接填成密度档（320/560），
/// 那就会偏出一大截。所以这里**除了算，还要给可信度警告**：向导会把结果显示出来并
/// 允许用户改成规格值——能自动填，但不假装它一定对。
/// 返回值：(.inch, 警告文案)；警告非空 = 这个自动值可疑，建议用户按规格填。
(double, String?) screenDiagonalInch({
  required int panelWidthPx,
  required int panelHeightPx,
  required double xdpi,
  required double ydpi,
  required int densityDpi,
}) {
  if (panelWidthPx <= 0 || panelHeightPx <= 0 || xdpi <= 0 || ydpi <= 0) {
    return (0, '屏幕像素或厂商 dpi 读不到');
  }
  final w = panelWidthPx / xdpi;
  final h = panelHeightPx / ydpi;
  final inch = math.sqrt(w * w + h * h);
  if (inch < 3.0 || inch > 9.0) {
    return (inch, '按厂商 dpi 推出来是 ${inch.toStringAsFixed(1)} 英寸，明显不合理');
  }
  if ((xdpi - ydpi).abs() / xdpi > 0.02) {
    return (inch, '厂商上报的横竖 dpi 差得较多');
  }
  if (densityDpi > 0 &&
      (xdpi - densityDpi).abs() < 0.5 &&
      (ydpi - densityDpi).abs() < 0.5) {
    return (inch, '厂商 dpi 看着就是密度档 $densityDpi');
  }
  return (inch, null);
}

/// 「1 厘米 ≈ 多少滚动像素」——比例的另一种写法，供用户直接改。
double scrollPxPerCm(double screenCm, int heightPx) =>
    (screenCm > 0 && heightPx > 0) ? heightPx / screenCm : 0;

/// 一次 Android 采集快照。手势/触摸累计与滚动像素总量（服务进程存活期间持续累加）。
class AndroidCounters {
  const AndroidCounters({
    required this.scrolls,
    required this.taps,
    required this.scrollPx,
    required this.screenHeightCm,
    required this.videoHint,
    this.heightPixels = 0,
    this.panelWidthPx = 0,
    this.panelHeightPx = 0,
    this.xdpi = 0,
    this.ydpi = 0,
    this.densityDpi = 0,
  });

  /// 滚动手势数（Kotlin 侧已按 300ms 间隙聚合，不是原始事件数）。
  final int scrolls;

  /// 触摸次数（同聚合口径）。ColorOS 上信号源 = 点击交互（TYPE_VIEW_CLICKED
  /// 兜底，2026-09-18），原生系统 = TOUCH_INTERACTION_START。
  final int taps;

  /// 滚动像素总量。仅作事件质量观察（真机标定参考），不参与计价。
  final double scrollPx;

  /// 屏幕物理高度（厘米）= heightPixels ÷ ydpi × 2.54，按屏计价的基准。
  final double screenHeightCm;

  /// 屏幕像素高（当前窗口；计价的分母）。
  final int heightPixels;

  /// 面板像素尺寸（整屏物理分辨率）。分屏与「显示大小」缩放都不影响它，
  /// 「按机型规格换算屏长」用它取宽高比；读不到时为 0。
  final int panelWidthPx;
  final int panelHeightPx;

  /// 厂商上报的物理 dpi（每英寸像素）。只用来**自动推算**对角线英寸，
  /// 不可全信：有的机型直接把密度档填进来（见 [screenDiagonalInch] 的可信度检查）。
  final double xdpi;
  final double ydpi;
  final int densityDpi;

  /// 滑动方向的整屏像素（竖屏的屏高）。面板尺寸读不到时回落当前窗口高度。
  int get panelLongPx {
    if (panelWidthPx <= 0 || panelHeightPx <= 0) return heightPixels;
    return panelWidthPx > panelHeightPx ? panelWidthPx : panelHeightPx;
  }

  /// 自动判定：前台是否是刷视频应用（白名单命中）。仅判定用，不落盘。
  final bool videoHint;

  /// 按板块计价的累计厘米。[videoMode] 为 true 时走刷视频口径
  /// （一次翻页 ≈ 一屏），否则走日常保守系数。
  double scrollCm({bool videoMode = false}) =>
      scrolls *
      screenHeightCm *
      (videoMode ? kVideoGestureScreenRatio : kGestureCmRatio);

  @override
  String toString() =>
      'AndroidCounters(scrolls: $scrolls, taps: $taps, scrollPx: $scrollPx)';
}

/// 账本收账批（Kotlin 侧账本 drain 出的增量，数据链下沉 2026-09-07）。
class LedgerBatch {
  const LedgerBatch({
    required this.daily,
    required this.video,
    required this.taps,
    required this.ts,
    required this.screenHeightCm,
    this.trackCm = 0,
    this.calibratedScreenCm,
    this.scrollPx = 0,
    this.videoScrollPx = 0,
    this.videoDwellMs = 0,
    this.heightPixels = 0,
  });

  /// 日常手势增量（记 screens）。
  final int daily;

  /// 刷视频手势增量（记 shorts —— 是**翻页次数**，不是视频条数，见 models.dart 说明）。
  final int video;

  /// 触摸增量（记 taps）。
  final int taps;

  /// 最后结算时刻（毫秒），ingest 按它归日归小时。
  final int ts;

  /// 屏幕物理高度（厘米，系统估算），计价基准。
  final double screenHeightCm;

  /// M3 真值轨迹增量（厘米）：Shizuku 通道已于 2026-10-09 整体删除（决策 21），
  /// 此字段不再有写入方（恒 0），保留仅为协议/旧存档兼容。
  final double trackCm;

  /// 用户校准的屏长（厘米，屏长校准向导实测填入；null = 未校准）。
  /// 校准后估算计价用手填屏长替换系统估的屏高——与桌面 CPI 校准同构。
  final double? calibratedScreenCm;

  /// M3'（2026-09-18）：本批内容滚动像素增量（横+纵合计）。
  /// 「这一次滑了多长」按实际滚过占比估算的主信号。
  final double scrollPx;

  /// 刷视频板块的滚动像素增量（[scrollPx] 的子集，Kotlin 侧按 videoHint 归因）。
  /// 有了它才能回答「刷视频这些滑动，实际为今日距离带了多少厘米」。
  final double videoScrollPx;

  /// 视频应用前台时长增量（毫秒，方案 A 2026-10-08）：白名单视频应用
  /// 的合并前台时间，记录使用时长本身，不换算条数、不估每条秒数。
  final int videoDwellMs;

  /// 屏幕像素高（像素→厘米换算的分母）。
  final int heightPixels;

  /// 计价用的屏长：校准值优先，未校准用系统估算。
  double get effectiveScreenCm => calibratedScreenCm ?? screenHeightCm;

  /// 每滚动像素折算多少厘米 = 屏长 ÷ 屏幕像素高。
  ///
  /// 公开是因为收账后要把它回写给 Kotlin 账本（`cm_per_px`）——常驻通知折算
  /// 未收账增量时必须用同一把尺子，否则任务栏和界面数字会打架。
  double get cmPerPx => heightPixels > 0 ? effectiveScreenCm / heightPixels : 0;

  /// 像素数据是否可用作计价：**只要有像素就用像素**。
  ///
  /// ⚠️ 2026-10-07 改口径（坑 32）。旧规则是「均次滚动 < 2% 屏高视为退化 → 回落
  /// 手势计价」，而 2% 屏高在本机 = 55.6 像素/手势，比用户真实的「小滑动」大得多：
  /// 真机实测一次 70 像素的慢拖动（按像素应记 0.39 厘米）被判成退化，改按
  /// 「一次手势 = 0.35 屏」收费，**记成 5.82 厘米，放大 15 倍**——用户感受就是
  /// 「没怎么动就涨里程」。现在真退化的应用（滚动事件恒报 1px，如 Flutter 自家页面）
  /// 会**少算**，这符合本项目一贯口径「判不准的不计，宁可少算不算错」；
  /// 手势兜底只留给**一点像素都没有**（scrollPx == 0）的情况。
  bool get _hasPixelData => scrollPx > 0 && heightPixels > 0;

  bool get isEmpty =>
      daily == 0 && video == 0 && taps == 0 && trackCm <= 0 && scrollPx <= 0 &&
      videoDwellMs <= 0;

  /// 本批折算厘米。计价优先级：
  ///   1. trackCm > 0（真值通道，已休眠仅兼容旧批）→ 只用真值；
  ///   2. 像素流可信 → scrollPx × cmPerPx：滑 40% 屏算 0.4 屏长，
  ///      抖音吸附流小蹭也吸附一整屏 = 1 屏长——「这次滑了多长」；
  ///   3. 像素退化/缺席 → 手势 × 屏长 × 板块系数（M2 老口径兜底）。
  double get cm {
    if (trackCm > 0) return trackCm;
    if (_hasPixelData) return scrollPx * cmPerPx;
    return daily * effectiveScreenCm * kGestureCmRatio +
        video * effectiveScreenCm * kVideoGestureScreenRatio;
  }

  /// 刷视频板块实际贡献的厘米（[cm] 的一部分，不是另一套算法）。
  ///
  /// 两条路径与 [cm] 一一对应：像素可信 → 视频板块像素 × 尺子；
  /// 像素退化 → 视频手势 × 屏长 × 1.0（一次翻页 ≈ 一屏的娱乐口径）。
  /// 真值通道（trackCm）没有板块归因，记 0。
  double get videoCm {
    if (trackCm > 0) return 0;
    final raw = _hasPixelData
        ? videoScrollPx * cmPerPx
        : video * effectiveScreenCm * kVideoGestureScreenRatio;
    // 视频距离**定义上**是今日距离的子集：上游计数器一旦给出
    // 「视频像素 > 总像素」（坑 45：通知心跳漏传 videoScrollPx 把 base 清零，
    // 下一次结算把累计值当增量灌入），这里夹回 [cm]——否则卡片会出现
    // 「刷视频 199.9 米」大于「今日 59.2 米」的自相矛盾。
    // 夹回同时保证 dailyCm = cm - videoCm ≥ 0（board_pricing_test 锁的不变量）。
    return raw > cm ? cm : raw;
  }

  /// 日常滑动板块贡献的厘米 = 总距离里扣掉视频那半。
  /// 用减法而不是另算一遍，才能保证 dailyCm + videoCm == cm 恒成立。
  double get dailyCm => cm - videoCm;

  /// 回写给 Kotlin 通知复用的尺子。**只在像素计价真的生效时**才给——
  /// 一点像素都没有时，本批距离是按手势估的，`cm / scrollPx` 无从谈起，
  /// 给 0 让通知也回落手势系数公式，两边口径一致。
  double get cmPerPxForNotif => _hasPixelData ? cmPerPx : 0;
}

// （原 TrackBatch 类随 M3 精确模式通道于 2026-10-09 移除，决策 21。
//  ⚠️ 注意区分：`LedgerBatch.trackCm` 字段**保留**——它是历史账本的数据兼容口
//  （旧账本里可能压着未收账的 track 增量），与这条通道不是一回事。）

/// Android 采集引擎。整个应用只应存在一个实例。
class AndroidMileageEngine {
  AndroidMileageEngine._();

  static const _channel = MethodChannel('touch_mileage/engine');

  /// 无障碍服务连接状态（main.dart 采样时更新，设置页/引导页监听展示）。
  static final ValueNotifier<bool> connectedNotifier =
      ValueNotifier<bool>(false);

  factory AndroidMileageEngine.open() => AndroidMileageEngine._();

  /// 无障碍服务是否已连接（= 采集中）。对应 mileage_ffi 的 isRunning。
  Future<bool> isRunning() async =>
      await _channel.invokeMethod<bool>('isServiceConnected') ?? false;

  /// Android 端没有"启动"动作——服务由用户在系统设置里开启，连接即视为已启动。
  /// 接口与 Windows 版同型，调用方可以无差别对待。
  Future<bool> start() => isRunning();

  /// 服务生命周期归系统设置管，这里无事可做（对应 Windows 版 stop）。
  void stop() {}

  /// 当前累计计数快照。
  Future<AndroidCounters> snapshot() async {
    final m = await _channel.invokeMethod<Map<dynamic, dynamic>>('snapshot');
    return AndroidCounters(
      scrolls: (m?['scrolls'] as num?)?.toInt() ?? 0,
      taps: (m?['taps'] as num?)?.toInt() ?? 0,
      scrollPx: (m?['scrollPx'] as num?)?.toDouble() ?? 0,
      screenHeightCm: (m?['screenHeightCm'] as num?)?.toDouble() ?? 0,
      videoHint: m?['videoHint'] == true,
      heightPixels: (m?['heightPixels'] as num?)?.toInt() ?? 0,
      panelWidthPx: (m?['panelWidthPx'] as num?)?.toInt() ?? 0,
      panelHeightPx: (m?['panelHeightPx'] as num?)?.toInt() ?? 0,
      xdpi: (m?['xdpi'] as num?)?.toDouble() ?? 0,
      ydpi: (m?['ydpi'] as num?)?.toDouble() ?? 0,
      densityDpi: (m?['densityDpi'] as num?)?.toInt() ?? 0,
    );
  }

  /// 每日结算时归零（与 store 的跨天结算对齐，避免隔天累加错账）。
  Future<void> reset() => _channel.invokeMethod('reset');

  // —— 数据链下沉：账本收账（2026-09-07）——
  // 记账在 Kotlin 服务层（Activity 回收不丢账），Dart 启动/回前台/采样时收走。

  /// 收账：拉走账本里全部未收增量批（先触发一次结算再整批取走）。
  /// [calibratedScreenCm] 由调用方从激活的手机档案取（null = 未校准），
  /// 随批带回供计价——计价公式收在 [LedgerBatch.cm] 一处。
  Future<LedgerBatch> drainLedger({double? calibratedScreenCm}) async {
    final m =
        await _channel.invokeMethod<Map<dynamic, dynamic>>('drainLedger');
    return LedgerBatch(
      daily: (m?['daily'] as num?)?.toInt() ?? 0,
      video: (m?['video'] as num?)?.toInt() ?? 0,
      taps: (m?['taps'] as num?)?.toInt() ?? 0,
      ts: (m?['ts'] as num?)?.toInt() ?? 0,
      screenHeightCm: (m?['screenHeightCm'] as num?)?.toDouble() ?? 0,
      trackCm: (m?['trackCm'] as num?)?.toDouble() ?? 0,
      calibratedScreenCm: calibratedScreenCm,
      scrollPx: (m?['scrollPx'] as num?)?.toDouble() ?? 0,
      videoScrollPx: (m?['videoScrollPx'] as num?)?.toDouble() ?? 0,
      videoDwellMs: (m?['videoDwellMs'] as num?)?.toInt() ?? 0,
      heightPixels: (m?['heightPixels'] as num?)?.toInt() ?? 0,
    );
  }

  /// 收账后写回今日基线（Kotlin 通知显示用；守恒公式 day+pending 的 day 半边）。
  /// [cmPerPx] 一并回写：通知算 pending 那半截时用同一把尺子，数字才对得上界面。
  static Future<void> writeDayTotal({
    required double cm,
    required int shorts,
    required int taps,
    required double cmPerPx,
  }) =>
      _channel.invokeMethod('writeDayTotal', {
        'cm': cm,
        'shorts': shorts,
        'taps': taps,
        'cmPerPx': cmPerPx,
      });

  /// 手动板块覆盖（概览长按切换）：推给 Kotlin 决定接下来怎么分账。
  ///
  /// `video` = 之后所有滑动都按刷视频口径算（用来救白名单覆盖不到的视频入口，
  /// 如微信视频号）；`auto` = 恢复按白名单自动判定。**不落盘**——权威状态是
  /// [MileageStore] 里的 `activeProfileId`，启动与回前台时会重新推一次，
  /// 所以服务进程被回收也不会丢。
  static Future<void> setBoardOverride(String mode) =>
      _channel.invokeMethod('setBoardOverride', {'mode': mode});

  // —— M3 精确模式（Shizuku 真值采集）已于 2026-10-09 整体移除（决策 21）——
  //
  // 这里原有 5 个方法：trackStatus / trackStart / trackRequestPermission /
  // trackStop / trackDrain。它们从 2026-09-18 起就**没有任何调用点**：
  // Shizuku 在 ColorOS 16 上被系统层拦截（点"允许"也判拒绝），激活门槛过不了，
  // 遂从产品撤下、通道休眠。休眠期间它们随包发布却永不执行，还让"删了会不会
  // 影响功能"这个问题一直悬着——2026-10-09 连同 Kotlin 侧一起删净。
  //
  // 需要复活 M3 分支 A 时：从**删除本通道的那个提交的父提交**取回本段——
  // `git show <删除提交>^:app/lib/engine/engine_android.dart`（提交号见
  // `git log --oneline -- app/lib/engine/engine_android.dart` 最新一条）。Kotlin
  // 侧同理（`MileageShizukuCollector.kt` / `TrackServiceImpl.kt` / `ITrackService.aidl`，
  // 用 `git log --diff-filter=D -- <路径>` 可定位删除提交）。在此之前请先过
  // `docs/B-Shizuku可行性测试.md` 的真机清单。

  // —— 常驻通知（里程速览）——

  /// 开启速览通知：请求权限（Android 13+）→ 启动前台服务。
  /// 返回是否成功（权限被拒返回 false，调用方据此回退开关）。
  static Future<bool> enableStatusNotification() async {
    final granted = await requestNotificationPermission();
    if (!granted) return false;
    await startStatusNotification();
    return true;
  }

  /// Android 13+ 通知运行时权限：已授予/用户同意返回 true，拒绝返回 false。
  /// 13- 设备无需运行时权限，恒 true。
  static Future<bool> requestNotificationPermission() async =>
      await _channel.invokeMethod<bool>('requestNotificationPermission') ?? false;

  /// 启动前台通知服务（设置开关打开时调用；先 [requestNotificationPermission]）。
  static Future<void> startStatusNotification() =>
      _channel.invokeMethod('startStatusNotification');

  /// 停止速览通知。
  static Future<void> stopStatusNotification() =>
      _channel.invokeMethod('stopStatusNotification');

  /// 更新速览文案：今日距离（已格式化）/ 视频条数 / 点击次数。
  static Future<void> updateStatusNotification({
    required String distance,
    required int shorts,
    required int taps,
  }) =>
      _channel.invokeMethod('updateStatusNotification', {
        'distance': distance,
        'shorts': shorts,
        'taps': taps,
      });

  /// 跳系统无障碍设置页（引导第 2 步 / 设置页入口）。
  static Future<void> openA11ySettings() =>
      _channel.invokeMethod('openA11ySettings');
}
