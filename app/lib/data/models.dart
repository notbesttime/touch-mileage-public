// -*- coding: utf-8 -*-
// 触控里程 · 数据模型
//
// 三份数据，对应《设计文档》第二节：
//   AppConfig   config.json           目标、当前档案、开关
//   Profile     profiles.json         鼠标精度档案（可多份，可增删改）
//   DayRecord   daily/YYYY-MM.json    每日里程
//
// 一个贯穿全部设计的决定：**同时存原始计数和厘米**。
// 计数是设备直接给出的真值，永不失效；厘米依赖用户设的鼠标精度。
//
// ⚠️ 计数**不等于**"随时该拿它重算历史"（2026-10-18 决策）。
// 历史是「当时发生了什么」的记录：那天显示 5000cm、用户看到的是 5000、
// 上云的也是 5000。事后按新 CPI 重算成 2470 等于改写已经发生的事实，
// 而且会和云端已有的值冲突（服务端不许静默降值）。
// 换鼠标的正确做法是新建档案，旧天挂旧档案，互不影响。
// 计数的现役用途是**校准时验证一致性**，不是回填历史。

import 'dart:convert';

import 'quick_cpi.dart';

/// 当前数据格式版本。以后改结构时靠它做迁移。
const int kSchemaVersion = 1;

/// 一次精确测量的原始记录。保留它是为了能回看和复核，
/// 而不是只留一个算出来的结果。
class CalibrationSample {
  const CalibrationSample({
    required this.axis,
    required this.cm,
    required this.counts,
    required this.cpi,
  });

  /// 'X' 或 'Y'
  final String axis;

  /// 用尺子量出的实际距离（厘米）
  final double cm;

  /// 这段距离内设备报告的计数
  final double counts;

  /// 由上面两项算出的每英寸计数
  final double cpi;

  Map<String, dynamic> toJson() =>
      {'axis': axis, 'cm': cm, 'counts': counts, 'cpi': cpi};

  factory CalibrationSample.fromJson(Map<String, dynamic> j) =>
      CalibrationSample(
        axis: (j['axis'] as String?) ?? 'X',
        cm: (j['cm'] as num?)?.toDouble() ?? 0,
        counts: (j['counts'] as num?)?.toDouble() ?? 0,
        cpi: (j['cpi'] as num?)?.toDouble() ?? 800,
      );
}

/// 鼠标精度的来源。界面上不显示这三个词，只用于内部判断
/// （比如"未实测"时提示用户去做精确测量）。
enum ProfileSource {
  /// 从常见值里选的
  preset,

  /// 用户手动输入的
  manual,

  /// 拿尺子实测出来的
  measured,
}

/// 一份精度档案。
///
/// 手机端将来复用同一个结构：那时 cpiX/cpiY 存的是"一屏长度对应的像素数"，
/// kind 为 'phone'。这样两端的数据层不用分叉。
class Profile {
  Profile({
    required this.id,
    required this.name,
    required this.cpiX,
    required this.cpiY,
    this.kind = 'mouse',
    this.videoMode = false,
    this.screenLengthCm,
    this.source = ProfileSource.preset,
    this.device = '',
    this.created,
    List<CalibrationSample>? samples,
  }) : samples = samples ?? <CalibrationSample>[];

  final String id;
  String name;
  double cpiX;
  double cpiY;

  /// 'mouse' / 'touchpad' / 'phone'
  String kind;

  /// 手机专属（板块语义）：true = 刷视频板块（一次翻页 ≈ 一屏内容，
  /// 手势 × 屏高 × 1.0 计价）；false = 日常滑动板块（保守系数计价）。
  /// 桌面档案恒为 false。
  bool videoMode;

  /// 手机屏长校准（厘米，M3' 2026-09-18）：用户在屏长校准向导里
  /// 实测填入（量尺或机型规格）。null = 未校准，按系统估算值计价。
  /// 校准后估算计价用「手势 × 此值 × 板块系数」替换系统估的屏高——
  /// 与桌面 CPI 校准同构（kind: phone 档案的自测）。屏幕是设备属性，
  /// 校准时写入全部手机板块档案。
  double? screenLengthCm;

  ProfileSource source;

  /// 设备标识，用于"检测到新鼠标，要不要新建档案"
  String device;
  DateTime? created;
  List<CalibrationSample> samples;

  /// 是否经过实测。没实测过的档案在界面上应提示"建议精确测量"。
  bool get isMeasured => source == ProfileSource.measured;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        // 非默认值才写，保持旧数据文件干净
        if (videoMode) 'video_mode': true,
        if (screenLengthCm != null) 'screen_length_cm': screenLengthCm,
        'cpi_x': cpiX,
        'cpi_y': cpiY,
        'source': source.name,
        'device': device,
        'created': created?.toIso8601String(),
        'samples': samples.map((s) => s.toJson()).toList(),
      };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: (j['id'] as String?) ?? 'p_unknown',
        name: (j['name'] as String?) ?? '未命名',
        kind: (j['kind'] as String?) ?? 'mouse',
        videoMode: (j['video_mode'] as bool?) ?? false,
        screenLengthCm: (j['screen_length_cm'] as num?)?.toDouble(),
        cpiX: (j['cpi_x'] as num?)?.toDouble() ?? 800,
        cpiY: (j['cpi_y'] as num?)?.toDouble() ?? 800,
        source: ProfileSource.values.firstWhere(
          (e) => e.name == j['source'],
          orElse: () => ProfileSource.preset,
        ),
        device: (j['device'] as String?) ?? '',
        created: DateTime.tryParse((j['created'] as String?) ?? ''),
        samples: ((j['samples'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(CalibrationSample.fromJson)
            .toList(),
      );

  /// 默认档案：未校准，仅作占位，让应用零配置也能跑起来。
  factory Profile.defaultProfile() => Profile(
        id: 'p_default',
        name: '默认（未测量）',
        cpiX: 800,
        cpiY: 800,
        source: ProfileSource.preset,
        created: DateTime.now(),
      );

  /// 手机种子板块：日常滑动（默认激活）。
  factory Profile.phoneDaily() => Profile(
        id: 'p_phone_daily',
        name: '日常滑动',
        kind: 'phone',
        cpiX: 0,
        cpiY: 0,
        source: ProfileSource.preset,
        created: DateTime.now(),
      );

  /// 手机种子板块：刷视频（一次翻页 ≈ 一屏）。
  factory Profile.phoneVideo() => Profile(
        id: 'p_phone_video',
        name: '刷视频',
        kind: 'phone',
        videoMode: true,
        cpiX: 0,
        cpiY: 0,
        source: ProfileSource.preset,
        created: DateTime.now(),
      );

  /// 手机板块（kind=phone）不计 CPI，cpi 恒 0，距离走板块系数计价。
  bool get isPhoneProfile => kind == 'phone';
}

/// 一天的记录。
class DayRecord {
  DayRecord({
    required this.date,
    this.counts = 0,
    this.cm = 0,
    this.wheel = 0,
    this.clicks = 0,
    this.screens = 0,
    this.taps = 0,
    this.shorts = 0,
    this.videoCm = 0,
    this.videoDwellS = 0,
    this.profileId = '',
    this.ownerId = '',
    List<double>? byHour,
    Map<String, int>? keys,
  })  : byHour = byHour ?? List<double>.filled(24, 0),
        keys = keys ?? <String, int>{};

  /// 形如 2026-08-18
  final String date;

  /// 原始设备计数累计（真值）。
  ///
  /// ⚠️ **不参与计价**：cm 已由引擎逐事件换算好（每段用当时灵敏度），
  /// 这个字段只是留档。同一天内换鼠标时它会把两种 CPI 的计数加在一起，
  /// 但那**不影响任何数字**——`recomputeFromCounts` 已停用（坑 83）。
  double counts;

  /// 换算出的厘米
  double cm;

  /// 滚轮格数
  double wheel;

  /// 左键点击次数
  int clicks;

  /// 翻屏/手势次数（手机专属）。无障碍滚动事件聚合后的手势数，桌面端恒为 0。
  /// 刷视频板块的手势不记这里（记 [shorts]），避免日常与视频混账。
  int screens;

  /// 触摸交互次数（手机专属）。只计数，不记点了哪里和什么应用。
  int taps;

  /// 刷视频**翻页次数**（手机专属）。实为刷视频板块下的滚动手势数。
  ///
  /// ⚠️ 它**不是"视频条数"**：一次上滑无论那条视频多长、尽头是否惯性滚动，都只算一次；
  /// 抖音这类自绘信息流更是一个事件都不派发（见坑 30/坑 43），压根数不到。
  /// 所以界面与通知对外统一说「翻页 N 次」，不承诺"条数"（整改清单 P2-2）。
  /// 日常板块不产生此字段。
  int shorts;

  /// 刷视频板块为当天 [cm] 实际贡献的厘米数（手机专属，是 cm 的一个子集而非另算）。
  /// 「概览·视频耍起!」用它回答"刷视频到底带我走了多远"。
  /// 2026-09-26 之前的数据没有这个维度，恒为 0（历史无法回溯拆分）。
  double videoCm;

  /// 视频应用前台使用时长（秒，手机专属，方案 A 2026-10-08）。
  ///
  /// 坑 30 的落点：抖音不派发无障碍事件，「刷了几条」（[shorts]）数不准；
  /// 前台时长系统始终知道，记**时长本身**而不是换算条数——无 ÷20s 转换。
  /// 用 double 存秒：毫秒逐批取整丢尾数，采样循环频繁收账累计误差能到两成。
  /// 2026-10-08 之前的数据没有此字段。
  double videoDwellS;

  /// 当天使用的档案。
  ///
  /// ⚠️ 它是「当时启用哪个档案」的**指针**，不是物理设备的身份证明——
  /// 档案可以改名、可以原地改 CPI，同一天也可能前后换过鼠标。
  /// 所以它不足以支撑"按档案重算历史"（2026-10-18 决策，见 store.dart）。
  /// 现役用途：多档案并存时区分是哪套精度记的，供展示与将来按档案统计。
  String profileId;

  /// 这一天归哪个账号（云端 `cloud_id`）。空 = 匿名（从没登录过）。
  ///
  /// 为什么归属要下沉到「天」（坑 90，2026-10-19）：
  /// 原来归属只有 `AppConfig.dataOwnerId` 一个值，只能表达「整台机器归谁」。
  /// 于是换号后只有两种结果——新号一天也传不上去（归属永远不匹配），
  /// 或者换回原号时把「在别的账号期间记的数据」一起带走。
  /// 两个毛病是同一个模型缺陷的两面：**本机数据只能整体归一个账号**。
  ///
  /// 现在按天记：A 用的那几天归 A，换到 B 之后新记的天归 B，各传各的。
  ///
  /// ⚠️ 边界：同一天内换号，那天的归属是「当天首次记录时」的账号，
  /// 之后无论换到哪个号，当天的增量都算给第一个 —— 按天归属的最小代价。
  /// 要彻底精确得把粒度改成「(账号, 日期)」，那是另一个量级的改动。
  String ownerId;

  /// 24 个小时各自的厘米数，用于时段分布图
  final List<double> byHour;

  /// 各按键按下次数（键名 -> 次数）。只存次数，不存顺序和内容。
  /// 仅在用户开启"按键统计"后才有数据。
  final Map<String, int> keys;

  /// 滚轮圈数（常见滚轮一圈 24 格）
  double get wheelRevolutions => wheel.abs() / 24.0;

  /// 滚轮滚动的物理距离（米）。
  /// 常见滚轮周长约 2.6 毫米/格，把格数换成米，和"手走了多少米"同一套语言。
  double get scrollMeters => wheel.abs() * 0.0026;

  /// 当天按键总次数
  int get totalKeys {
    var sum = 0;
    keys.forEach((_, v) => sum += v);
    return sum;
  }

  Map<String, dynamic> toJson() => {
        'counts': counts,
        'cm': cm,
        'wheel': wheel,
        'clicks': clicks,
        // 手机专属字段：有值才写，桌面端不出现，保持旧数据文件干净。
        // 服务端 payload 原样存储，两端数据互不缺失。
        if (screens > 0) 'screens': screens,
        if (taps > 0) 'taps': taps,
        if (shorts > 0) 'shorts': shorts,
        if (videoCm > 0) 'video_cm': double.parse(videoCm.toStringAsFixed(2)),
        if (videoDwellS > 0)
          'video_dwell_s': double.parse(videoDwellS.toStringAsFixed(1)),
        'profile_id': profileId,
        // 归属账号：空不写（匿名 / 老数据），保持旧文件干净。
        if (ownerId.isNotEmpty) 'owner_id': ownerId,
        // 存成整数化的小数，避免 JSON 里出现一长串浮点尾数
        'by_hour': byHour.map((v) => double.parse(v.toStringAsFixed(2))).toList(),
        // 按键只存次数。为空时不写这个字段，保持旧数据文件干净。
        if (keys.isNotEmpty) 'keys': keys,
      };

  factory DayRecord.fromJson(String date, Map<String, dynamic> j) {
    final raw = (j['by_hour'] as List?) ?? const [];
    final hours = List<double>.filled(24, 0);
    for (var i = 0; i < 24 && i < raw.length; i++) {
      hours[i] = (raw[i] as num?)?.toDouble() ?? 0;
    }
    final rawKeys = (j['keys'] as Map?) ?? const {};
    final keys = <String, int>{};
    rawKeys.forEach((k, v) {
      if (v is num) keys[k.toString()] = v.toInt();
    });
    return DayRecord(
      date: date,
      counts: (j['counts'] as num?)?.toDouble() ?? 0,
      cm: (j['cm'] as num?)?.toDouble() ?? 0,
      wheel: (j['wheel'] as num?)?.toDouble() ?? 0,
      clicks: (j['clicks'] as num?)?.toInt() ?? 0,
      screens: (j['screens'] as num?)?.toInt() ?? 0,
      taps: (j['taps'] as num?)?.toInt() ?? 0,
      shorts: (j['shorts'] as num?)?.toInt() ?? 0,
      videoCm: (j['video_cm'] as num?)?.toDouble() ?? 0,
      videoDwellS: (j['video_dwell_s'] as num?)?.toDouble() ?? 0,
      profileId: (j['profile_id'] as String?) ?? '',
      ownerId: (j['owner_id'] as String?) ?? '',
      byHour: hours,
      keys: keys,
    );
  }
}

/// 用户自定义的旅途目的地。
///
/// 只持久化「名字 + 距离」这一份真值；把自定义目的地合并进固定路线、
/// 按累计距离排序，是渲染时的派生计算。删掉一条，路线自动恢复原样，
/// 不会在数据里留下任何痕迹。
class CustomLeg {
  CustomLeg({
    required this.id,
    required this.name,
    required this.km,
    this.from = '',
    this.to = '',
    DateTime? created,
  }) : created = created ?? DateTime.now();

  /// 'c_<毫秒时间戳>'，仅用于列表 key 与删除定位
  final String id;

  /// 显示名，默认生成「从→到」，用户可改
  String name;

  /// 到达此目的地所需的累计里程（公里）
  double km;

  /// 起点/终点地名。只作展示与重查参考，距离以 km 为准
  String from;
  String to;

  final DateTime created;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'km': km,
        'from': from,
        'to': to,
        'created': created.toIso8601String(),
      };

  factory CustomLeg.fromJson(Map<String, dynamic> j) => CustomLeg(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '未命名',
        km: (j['km'] as num?)?.toDouble() ?? 0,
        from: (j['from'] as String?) ?? '',
        to: (j['to'] as String?) ?? '',
        created: DateTime.tryParse((j['created'] as String?) ?? ''),
      );
}

/// 全局配置。
class AppConfig {
  AppConfig({
    this.goalCm = 100000, // 默认每日目标 1 公里
    this.activeProfileId = 'p_default',
    this.autostart = false,
    this.trayEnabled = true,
    this.keyStatsEnabled = false,
    this.onboarded = false,
    this.privacyAgreedVersion = '',
    this.privacyAgreedAt = '',
    this.a11yLastOkAt = '',
    this.cloudRestoreNoticeShown = false,
    this.weeklyNoticeSunday = '',
    this.statusNotification = false,
    this.autoBoard = true,
    this.themeMode = 'light',
    this.themePalette = 'classic',
    this.micaEnabled = false,
    this.rangeDays = 7,
    this.aiEnabled = false,
    this.aiProvider = '',
    this.aiEndpoint = '',
    this.aiModel = '',
    this.geocodeEnabled = false,
    this.overlayEnabled = false,
    this.overlayClickThrough = false,
    this.cloudEnabled = false,
    this.cloudPromptDismissed = false,
    this.cloudAccount = '',
    this.cloudToken = '',
    this.cloudId = '',
    this.nickname = '',
    this.reportSeq = 0,
    this.reportSeqDate = '',
    this.avatarVersion = 0,
    this.avatarPending = false,
    this.bio = '',
    this.bioPendingText = '',
    this.bioStatus = 'none',
    this.intro = '',
    this.statusMode = 1,
    this.statusText = '',
    this.frame = '',
    this.qqBound = '',
    this.rememberAccount = false,
    this.autoLogin = false,
    this.deviceId = '',
    this.syncSince = 0,
    this.reportedUpTo = '',
    this.uploadedDatesJson = '',
    this.dataOwnerId = '',
    List<CustomLeg>? customLegs,
    List<double>? quickCpis,
  })  : customLegs = customLegs ?? <CustomLeg>[],
        quickCpis = quickCpis ?? <double>[];

  /// 每日目标，统一用厘米存，避免单位换算引入误差
  double goalCm;
  String activeProfileId;
  bool autostart;

  /// 托盘常驻：关掉窗口后继续在后台记录。默认开启。
  bool trayEnabled;

  /// 按键统计：只统计每个键的次数，不记顺序和内容。默认关闭。
  bool keyStatsEnabled;

  /// 是否已完成首次引导
  bool onboarded;

  /// 无障碍最后一次「确认正常」的时间（ISO8601，手机专属）。
  ///
  /// 用途（P3-1）：ColorOS 等 ROM 会在**应用升级/重装后撤销无障碍授权**
  /// （见坑 58），此时里程静默停止增长。光显示"已关闭"不够——用户不知道
  /// 停了多久。有了这个时间戳就能算出停用时长，横幅据此分档提示
  /// （当天精确到分钟、超过一天改为醒目提醒）。
  ///
  /// 写入时机：采样循环里检测到无障碍**正常**时持续刷新（相当于"最后心跳"）；
  /// 检测到断开时**不动它**，让它自然变旧——旧值就是停用起点。
  /// 空串 = 从没正常过（多半是首次安装还没授权），此时不显示时长。
  String a11yLastOkAt;

  /// 「云端有历史」的恢复提示是否已展示过（P3-2，2026-10-16）。
  ///
  /// 场景：卸载重装/换机后本地数据全空、教程重走，但登录云账号后，
  /// 云端的历史会被自动拉进只读镜像（cloud_mirror）——数据其实没丢，
  /// 只是用户不知道。这条提示就是为了在**登录后的首次概览**里告诉他：
  /// 「云端有 N 天历史，已在旅程页合并显示」。
  ///
  /// 只提示一次（置 true 后不再弹），因为镜像会持续自动同步，
  /// 不需要每次都讲。
  bool cloudRestoreNoticeShown;

  /// 「本周小结」周日提示：记录**上一次提示的周日日期**（YYYY-MM-DD）。
  /// 判定：今天是周日 且 该字段 ≠ 今天 → 显示横幅并写入今天。
  /// 这样保证每个周日只提示一次，其他天不弹，下周日又会被提醒。
  String weeklyNoticeSunday;

  /// 已同意的《隐私政策》版本号。空 = 从未同意 —— 启动时拦在知情同意页，
  /// 采集引擎不启动、定时器不跑、不发任何网络请求（用户拍板 2026-10-11）。
  /// 与 kPrivacyPolicyVersion 不等（政策改版）时，下次启动重新征求同意。
  String privacyAgreedVersion;

  /// 同意时间（ISO8601）。留痕与自查用，不参与任何业务判定。
  String privacyAgreedAt;

  /// 常驻通知速览（手机专属）：状态栏常驻显示今日距离/视频条数/点击次数。
  /// 兼作前台服务保活——降低无障碍服务被系统回收的概率。默认关闭，
  /// 用户主动开启（通知是侵入性展示，交用户决定）。
  bool statusNotification;

  // 注：M3 精确模式字段 precisionMode 已于 2026-10-09 随 Shizuku 通道整体删除
  // （决策 21，ColorOS 16 系统层拦第三方 Shizuku 授权，门槛不可接受）。旧
  // profiles.json 残留的 precision_mode 键被 fromJson 静默忽略，无需迁移。

  /// 自动判定板块（手机专属）：前台命中刷视频白名单（抖音/快手等）时
  /// 自动按刷视频口径计价，离开自动切回。手动板块切换仍是保底。默认开启。
  bool autoBoard;

  /// 'light' / 'dark' / 'system'
  String themeMode;

  /// 配色方案：'classic'（经典橙）/ 'green'（护眼绿）
  String themePalette;

  /// Mica 云母背景（Windows 11 22H2+）。默认关闭：它是换皮肤级效果，
  /// 留给用户主动开启，不喜欢或老系统上可以一键退回。
  bool micaEnabled;

  /// 图表默认显示多少天
  int rangeDays;

  /// AI 相关。**这里绝不存 API 密钥**，密钥进系统凭据库。
  bool aiEnabled;
  String aiProvider;
  String aiEndpoint;
  String aiModel;

  /// 允许联网查询目的地距离（Nominatim / OpenStreetMap）。默认关闭：
  /// 这是应用唯一的一处网络请求，首次点「搜索距离」时向用户说明、
  /// 征得同意后打开；设置页可关。只发送用户输入的地名文本。
  bool geocodeEnabled;

  /// 用户自定义的旅途目的地
  List<CustomLeg> customLegs;

  /// 「快捷切换」自定义的鼠标精度（CPI/DPI 数值，升序去重）。
  ///
  /// 用途：一个人可能有多只鼠标或多套参数（家里 800、公司 1600），
  /// 设置页的预设芯片只有六个固定值，覆盖不到 1200 之外的常见值。
  /// 这里存用户自己加的，跟预设一起出现在「鼠标精度」那一排里。
  ///
  /// ⚠️ 只存数值，不存名字：名字交给界面统一渲染（就是数字本身）。
  /// 存重复值没有意义（同一数值的芯片点了效果完全一样），写入前必须去重。
  /// 去重口径唯一：lib/data/quick_cpi.dart 的 sanitizeQuickCpis()。
  List<double> quickCpis;

  /// 桌面悬浮窗：常驻前台角落的迷你胶囊（今日里程 + 目标进度）。
  /// 默认关闭：悬浮窗有侵入性，交给用户主动开启。
  bool overlayEnabled;

  /// 悬浮窗鼠标穿透：开启后悬浮窗对鼠标完全透明（纯装饰），
  /// 只能从设置页或托盘菜单再关。默认关闭：先让用户能拖动它。
  bool overlayClickThrough;

  // —— 云端账号（排行榜/同步）。登录态的核心是 token：非空即已登录 ——

  /// 云功能总开关（默认关闭）：参与排行榜、云端同步、好友私信的总闸。
  /// 关闭时客户端不做任何云活动（令牌保留，重新打开即恢复，无需重新登录）。
  /// 首次引导时询问；进入排行榜未开启时也会提醒（拒绝过则只留页内入口）。
  bool cloudEnabled;

  /// 排行榜的“参与云端？”提醒是否被用户拒绝过：拒绝后不再弹窗，
  /// 只在榜单页留一条非阻断提示条。登录/退出登录时复位。
  bool cloudPromptDismissed;

  /// 登录账号：用户自取，仅用于登录，永不公开展示（公开的是 cloudId）
  String cloudAccount;

  /// 会话令牌：登录成功后服务端发放，之后所有写操作出示它代替密码。
  /// 空 = 未登录。客户端只存令牌不存密码，可随时在服务端作废。
  String cloudToken;

  /// 公开短码 ID（如 M8K2-Q9X7），用于加好友和榜单展示，永不公开账号
  String cloudId;

  /// 用户名（展示用，可修改）
  String nickname;

  /// 上报序号（P0-4 / P1-3，2026-10-14）：每次上报自增 1，服务端据此识别
  /// "重放旧数据"与"序号倒退"。同一天内单调递增；跨天归零重新计数。
  /// 服务端对不带 seq 的旧客户端走兼容路径，所以这个字段是渐进升级的。
  int reportSeq;

  /// [reportSeq] 所属的日期（YYYY-MM-DD）。用来判断"是否换天了"——
  /// 换天则序号归零。服务端按 (user, date, device) 存游标，与这里一致。
  String reportSeqDate;

  /// 我的头像当前公开版本（服务端审核制：0 = 无公开头像）。
  /// 仅作展示判断与缓存失效，真实状态以服务端 me 接口为准。
  int avatarVersion;

  /// 最近一次上传是否还在待审核（上传成功置位，审核结果由通知/me 回填）
  bool avatarPending;

  /// 个性签名当前公开版（服务端审核制：审核通过才前移；榜单/资料卡只展示它）
  String bio;

  /// 最近一次提交的待审核签名（提交成功写入，审核结果由通知/me 回填）。
  /// 编辑框里编辑的是它：审核中时用户看到自己刚提交的内容。
  String bioPendingText;

  /// 待审签名状态：'none' / 'pending' / 'approved' / 'rejected'（与云端 me 一致）
  String bioStatus;

  /// 简介（可修改）
  String intro;

  /// 在线状态展示档位：0 = 隐藏 / 1 = 仅在线（默认）/ 2 = 详细（展示 statusText）。
  /// 与服务端 users.status_mode 一致；本地是缓存，以 me/profile 接口为准。
  int statusMode;

  /// 详细状态文字（如「游戏中」，最多 20 字）。
  /// 仅档位 2 且在线时才对好友可见（隐私分档在服务端判）。
  String statusText;

  /// 当前佩戴的头像框 id（如 'xiaomao'，'' = 未佩戴）。
  /// 以服务端为准（persona 接口），本地仅缓存用于侧栏/资料页回显。
  String frame;

  /// 绑定的 QQ 号：仅用于忘记密码时人工找回，私有字段，任何榜单不显示
  String qqBound;

  /// 登录框记住账号（下次预填账号名）
  bool rememberAccount;

  /// 下次自动登录（保存令牌，启动时静默恢复会话）
  bool autoLogin;

  /// 本设备标识：本地随机 UUID，首次启动生成后固定不变。
  /// 云端按 (账号， 日期， 设备) 分行存储，它决定“这一行是谁报的”。
  /// 不含任何硬件信息，不参与哈希，纯随机。
  String deviceId;

  /// **本机数据（days/账本）归属的账号**（cloudId，空 = 匿名 / 从未认领）。
  ///
  /// 解决 MT-04「换账号的数据归属」：store.days 是**设备级**数据，账号是
  /// **身份级**身份。退出登录不能删本机数据（用户的记录不该因为换号消失），
  /// 但也不能让下一个登录的账号"继承"这些数据的上传资格——那会把 A 的
  /// 里程以 B 的名义推进云端（服务端 SUM 后就是两份真人数据的混合物）。
  ///
  /// 判定口径（只有一处：lib/data/owner.dart 的 uploadableDays）：
  ///   · dataOwnerId 为空  → 匿名数据，首次登录时**由用户显式认领**才归属
  ///   · dataOwnerId == 当前账号 → 正常上报
  ///   · dataOwnerId != 当前账号 → **不上报**（本机记录仍可见，但不属于这个账号）
  String dataOwnerId;

  /// 云端镜像增量拉取游标（毫秒时间戳）。0 = 从未拉过，下次全量。
  int syncSince;

  /// 已确认上传到云端的最新完整天（YYYY-MM-DD，空 = 从未上传）。
  ///
  /// ⚠️ **旧版水位线，只作兼容兜底**（MT-03，2026-10-18）。它只有"到哪天"
  /// 一个信息，规则是 `k > 它` ⇒ **它左边漏传的天永远补不回来**：离线几天、
  /// 联网那天传成功、水位线跳过去，中间那几天本地有云端没有却再也不传。
  ///
  /// 现在真正的账本是 [uploadedDatesJson]；这一项仍在写（给旧版本/备份
  /// 反读），也仍在迁移期当兜底。
  String reportedUpTo;

  /// **已确认上传过的天的集合**（JSON 数组字符串，如 `["2026-10-07","2026-10-08"]`；
  /// 空 = 从未建立账本，此时退回 [reportedUpTo] 的老规则）。
  ///
  /// 为什么要有它：欠账应当等于「本地有的天 − 已上传的天」，与时间顺序无关。
  /// 水位线做不到这件事——它是一条单向的线，线左边漏掉的就永远补不回来。
  /// 集合还能顺手吃掉两种边角：系统时间倒退 / 换时区后出现"比水位线还旧"的
  /// 新天；以及补报失败后需要重试的天（集合不前进，下次还会被选中）。
  ///
  /// 解析与合并只在 `lib/data/owner.dart` 一处（`parseUploadedDates` /
  /// `mergeUploadedDates`），别在别处各写一遍。
  String uploadedDatesJson;

  Map<String, dynamic> toJson() => {
        'schema': kSchemaVersion,
        'goal_cm': goalCm,
        'active_profile_id': activeProfileId,
        'autostart': autostart,
        'tray_enabled': trayEnabled,
        'key_stats_enabled': keyStatsEnabled,
        'onboarded': onboarded,
        if (privacyAgreedVersion.isNotEmpty)
          'privacy_agreed_version': privacyAgreedVersion,
        if (privacyAgreedAt.isNotEmpty) 'privacy_agreed_at': privacyAgreedAt,
        if (a11yLastOkAt.isNotEmpty) 'a11y_last_ok_at': a11yLastOkAt,
        // 只在 true 时写，保持旧文件干净（false 是默认）
        if (cloudRestoreNoticeShown) 'cloud_restore_notice_shown': true,
        if (weeklyNoticeSunday.isNotEmpty) 'weekly_notice_sunday': weeklyNoticeSunday,
        // 非默认值才写，保持旧数据文件干净
        if (statusNotification) 'status_notification': true,
        if (!autoBoard) 'auto_board': false,
        'theme_mode': themeMode,
        'theme_palette': themePalette,
        'mica_enabled': micaEnabled,
        'range_days': rangeDays,
        // 非默认值才写，保持旧数据文件干净
        'ai': {
          'enabled': aiEnabled,
          'provider': aiProvider,
          'endpoint': aiEndpoint,
          'model': aiModel,
        },
        // 为零时不写，保持旧数据文件干净
        if (geocodeEnabled) 'geocode_enabled': geocodeEnabled,
        if (overlayEnabled) 'overlay_enabled': overlayEnabled,
        if (overlayClickThrough) 'overlay_click_through': overlayClickThrough,
        if (cloudEnabled) 'cloud_enabled': true,
        if (cloudPromptDismissed) 'cloud_prompt_dismissed': true,
        if (cloudAccount.isNotEmpty) 'cloud_account': cloudAccount,
        // ⚠️ cloud_token **不写这里**（P1-2，2026-10-14）：
        // 令牌由 SecureStore 加密后单独存 credential.enc（见 store.dart）。
        // 明文写进 config.json 等于把登录凭据和普通数据混在一起，
        // 复制数据目录/传网盘都会连凭据一起带走。
        if (cloudId.isNotEmpty) 'cloud_id': cloudId,
        if (nickname.isNotEmpty) 'nickname': nickname,
        if (reportSeq > 0) 'report_seq': reportSeq,
        if (reportSeqDate.isNotEmpty) 'report_seq_date': reportSeqDate,
        if (avatarVersion > 0) 'avatar_version': avatarVersion,
        if (avatarPending) 'avatar_pending': true,
        if (bio.isNotEmpty) 'bio': bio,
        if (bioPendingText.isNotEmpty) 'bio_pending_text': bioPendingText,
        if (bioStatus != 'none') 'bio_status': bioStatus,
        if (intro.isNotEmpty) 'intro': intro,
        if (statusMode != 1) 'status_mode': statusMode,
        if (statusText.isNotEmpty) 'status_text': statusText,
        if (frame.isNotEmpty) 'frame': frame,
        if (qqBound.isNotEmpty) 'qq_bound': qqBound,
        if (rememberAccount) 'remember_account': rememberAccount,
        if (autoLogin) 'auto_login': autoLogin,
        if (deviceId.isNotEmpty) 'device_id': deviceId,
        if (syncSince != 0) 'sync_since': syncSince,
        if (reportedUpTo.isNotEmpty) 'reported_up_to': reportedUpTo,
        if (uploadedDatesJson.isNotEmpty)
          'uploaded_dates': uploadedDatesJson,
        if (dataOwnerId.isNotEmpty) 'data_owner_id': dataOwnerId,
        if (customLegs.isNotEmpty)
          'custom_legs': customLegs.map((l) => l.toJson()).toList(),
        if (quickCpis.isNotEmpty) 'quick_cpis': quickCpis,
      };

  factory AppConfig.fromJson(Map<String, dynamic> j) {
    final ai = (j['ai'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AppConfig(
      goalCm: (j['goal_cm'] as num?)?.toDouble() ?? 100000,
      activeProfileId: (j['active_profile_id'] as String?) ?? 'p_default',
      autostart: (j['autostart'] as bool?) ?? false,
      trayEnabled: (j['tray_enabled'] as bool?) ?? true,
      keyStatsEnabled: (j['key_stats_enabled'] as bool?) ?? false,
      onboarded: (j['onboarded'] as bool?) ?? false,
      privacyAgreedVersion: (j['privacy_agreed_version'] as String?) ?? '',
      privacyAgreedAt: (j['privacy_agreed_at'] as String?) ?? '',
      a11yLastOkAt: (j['a11y_last_ok_at'] as String?) ?? '',
      cloudRestoreNoticeShown: (j['cloud_restore_notice_shown'] as bool?) ?? false,
      weeklyNoticeSunday: (j['weekly_notice_sunday'] as String?) ?? '',
      statusNotification: (j['status_notification'] as bool?) ?? false,
      autoBoard: (j['auto_board'] as bool?) ?? true,
      themeMode: (j['theme_mode'] as String?) ?? 'light',
      themePalette: (j['theme_palette'] as String?) ?? 'classic',
      micaEnabled: (j['mica_enabled'] as bool?) ?? false,
      rangeDays: (j['range_days'] as num?)?.toInt() ?? 7,
      aiEnabled: (ai['enabled'] as bool?) ?? false,
      aiProvider: (ai['provider'] as String?) ?? '',
      aiEndpoint: (ai['endpoint'] as String?) ?? '',
      aiModel: (ai['model'] as String?) ?? '',
      geocodeEnabled: (j['geocode_enabled'] as bool?) ?? false,
      overlayEnabled: (j['overlay_enabled'] as bool?) ?? false,
      overlayClickThrough: (j['overlay_click_through'] as bool?) ?? false,
      // 旧版本没有这个键：已在用云的老用户（有令牌）自动视为开启，避免升级后云功能失联
      cloudEnabled: (j['cloud_enabled'] as bool?) ??
          ((j['cloud_token'] as String?)?.isNotEmpty ?? false),
      cloudPromptDismissed:
          (j['cloud_prompt_dismissed'] as bool?) ?? false,
      cloudAccount: (j['cloud_account'] as String?) ?? '',
      // 兼容旧版配置：老文件里有明文 cloud_token，store.dart 加载后会
      // 把它迁移进加密存储并清除。新版配置里不存在这个键，恒为空串。
      cloudToken: (j['cloud_token'] as String?) ?? '',
      cloudId: (j['cloud_id'] as String?) ?? '',
      nickname: (j['nickname'] as String?) ?? '',
      reportSeq: (j['report_seq'] as num?)?.toInt() ?? 0,
      reportSeqDate: (j['report_seq_date'] as String?) ?? '',
      avatarVersion: (j['avatar_version'] as num?)?.toInt() ?? 0,
      avatarPending: (j['avatar_pending'] as bool?) ?? false,
      bio: (j['bio'] as String?) ?? '',
      bioPendingText: (j['bio_pending_text'] as String?) ?? '',
      bioStatus: (j['bio_status'] as String?) ?? 'none',
      intro: (j['intro'] as String?) ?? '',
      statusMode: (j['status_mode'] as num?)?.toInt() ?? 1,
      statusText: (j['status_text'] as String?) ?? '',
      frame: (j['frame'] as String?) ?? '',
      qqBound: (j['qq_bound'] as String?) ?? '',
      rememberAccount: (j['remember_account'] as bool?) ?? false,
      autoLogin: (j['auto_login'] as bool?) ?? false,
      deviceId: (j['device_id'] as String?) ?? '',
      syncSince: (j['sync_since'] as num?)?.toInt() ?? 0,
      reportedUpTo: (j['reported_up_to'] as String?) ?? '',
      uploadedDatesJson: (j['uploaded_dates'] as String?) ?? '',
      // 老配置没有这个字段：留空 = 匿名未认领。**不能**拿 cloudId 兜底——
      // 那等于把"从没认领过的匿名历史"直接判给当前登录账号（正是 MT-04 要防的）。
      dataOwnerId: (j['data_owner_id'] as String?) ?? '',
      customLegs: ((j['custom_legs'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CustomLeg.fromJson)
          .toList(),
      // 老配置没有这个键 ⇒ 空列表（界面上就是没有额外芯片）。
      // 读入时同样过去重，防止手改 config.json 塞进重复值。
      quickCpis: sanitizeQuickCpis(
          ((j['quick_cpis'] as List?) ?? const []).whereType<num>().map((n) => n.toDouble())),
    );
  }
}

/// 统一的 JSON 编码器：带缩进，方便用户直接打开文件查看。
/// 这是"数据属于用户"的具体体现，不是可读性洁癖。
const jsonOut = JsonEncoder.withIndent('  ');
