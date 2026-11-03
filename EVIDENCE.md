# 证据：这个 App 的无障碍服务到底做了什么

本文不是承诺，是**可复现的核对材料**。每一节都给出你自己跑一遍的命令或代码位置。

对应版本：**触控里程 Android 0.5.3**（versionCode 14）
APK SHA-256：`ed06d0c775e0ff0daf566aa9cd811ab29ef43ac3040d0f5ce731b18718f666b7`

---

## 一、它申请了哪些能力（机器可读，来自 APK 二进制）

Android 的无障碍能力写在编译后的二进制清单里，**不是**写在我们给你看的源码里。
所以要看真相，得看 APK 本身：

```bash
node tools/verify_a11y.mjs app-release.apk
```

实测输出（原样粘贴，未删改）：

```
触控里程 · 无障碍能力自证
==========================================================
APK      : app-release.apk
大小     : 55.29 MB
SHA-256  : ed06d0c775e0ff0daf566aa9cd811ab29ef43ac3040d0f5ce731b18718f666b7
包名     : com.example.touch_mileage
版本     : 0.5.3 (14)

申请的系统权限：
  · INTERNET
  · POST_NOTIFICATIONS
  · FOREGROUND_SERVICE
  · FOREGROUND_SERVICE_SPECIAL_USE
  · com.example.touch_mileage.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION

无障碍服务声明（APK 内 res/-N.xml）：
  canRetrieveWindowContent = false   ← 不读取窗口内容
  accessibilityEventTypes  = 0x00101021，共 4 种：
      0x00000001  TYPE_VIEW_CLICKED                          点击
      0x00000020  TYPE_WINDOW_STATE_CHANGED                  窗口状态变化（前台应用切换）
      0x00001000  TYPE_VIEW_SCROLLED                         滚动
      0x00100000  TYPE_TOUCH_INTERACTION_START               手指按下
  notificationTimeout      = 0
  description              = @ref:0x7f0b0000

结论：✅ 该 APK 的无障碍服务没有声明读取屏幕内容的能力，事件类型仅为上述 4 种。

本结论只针对你手上这个 APK 文件的二进制内容，不依赖任何文字说明。
```

关键在于两行：

| 项 | 值 | 含义 |
|---|---|---|
| `canRetrieveWindowContent` | `false` | **没有申请读取窗口内容的权限**。拿不到屏幕上任何一个字、任何一个控件 |
| `accessibilityEventTypes` | `0x00101021` | 只订阅 4 类事件，见下表 |

这 4 类事件的每一位：

| 位 | 常量 | 我们用它做什么 |
|---|---|---|
| `0x00000001` | `TYPE_VIEW_CLICKED` | 数点击次数（ColorOS 不派发"触摸开始"，这是兜底信号） |
| `0x00000020` | `TYPE_WINDOW_STATE_CHANGED` | 判断前台是不是视频类应用，决定这块滑动算"日常"还是"刷视频" |
| `0x00001000` | `TYPE_VIEW_SCROLLED` | 数滚动手势 + 读这次滑动滚过了多少像素（计价主信号） |
| `0x00100000` | `TYPE_TOUCH_INTERACTION_START` | 数手指按下次数（部分机型不派发，靠上面的点击兜底） |

**没有**订阅：`TYPE_VIEW_TEXT_CHANGED`（文字变化）、`TYPE_WINDOW_CONTENT_CHANGED`（窗口内容变化）、
`TYPE_NOTIFICATION_STATE_CHANGED`（通知内容）——这三类才是"能读到内容"的事件。

### 这个工具本身会不会永远说"通过"

```bash
node tools/verify_a11y.mjs app-release.apk --selftest
```

它会在内存里把 `canRetrieveWindowContent` 从 `false` 改成 `true` 再解析一次，断言自己会报警：

```
自检 · 把一个 canRetrieveWindowContent=false 的 APK 改成 true，看工具会不会报警
  改之前 : false
  改之后 : true
  判定   : ⚠ 已报警 → canRetrieveWindowContent 不是 false —— 该服务有能力读取屏幕内容
  结果   : 通过 —— 这个工具确实会红，不是摆设
```

---

## 二、拿到事件之后，代码碰了哪些字段

全部处理逻辑在一个方法里：[`MileageAccessibilityService.kt`](app/android/app/src/main/kotlin/com/example/touch_mileage/MileageAccessibilityService.kt)
的 `onAccessibilityEvent`（第 311 行起）。四类事件分别只读这几个东西：

| 事件 | 读的字段 | 不读的 |
|---|---|---|
| `TYPE_VIEW_SCROLLED` | `event.scrollDeltaX` / `scrollDeltaY`（这次滚了多少像素） | 任何控件、任何文字 |
| `TYPE_TOUCH_INTERACTION_START` | 事件发生时间（只用来去抖） | — |
| `TYPE_VIEW_CLICKED` | 事件发生时间 | 点了哪个控件、控件上写了什么 |
| `TYPE_WINDOW_STATE_CHANGED` | `event.packageName`（判断是不是视频应用） | 窗口内容、界面文字 |

在整个 Kotlin 目录里搜一遍，确认没有任何"读内容"的 API 调用：

```bash
grep -rn "AccessibilityNodeInfo\|getText(\|getContentDescription\|getChild(\|findAccessibilityNode" \
  app/android/app/src/main/kotlin/
```

输出为空。也就是说：**不是"我们保证不读"，是代码里没有能读的调用。**

### 前台包名怎么处理

`packageName` 只在内存里跟一份视频应用名单比对，得到一个 `true/false`，
然后决定这次滑动记到"日常"还是"刷视频"。它**不进数据库、不进上传体、不写日志**（见第四节）。
同一天你用了哪些 App，我们没有记录。

---

## 三、离开手机的字段只有这些

上传体的定义在 [`models.dart`](app/lib/data/models.dart) 的 `DayRecord.toJson()`（第 305 行）。
逐项列出来，包括为什么它不指向你个人：

| 字段 | 内容 | 能不能指向你 |
|---|---|---|
| `date` | 日期，形如 `2026-11-03`（UTC+8 切天） | 否 |
| `device_id` | 本机首次安装时随机生成的串 | 否（随机值，不含机型/IMEI/序列号/手机号） |
| `seq` | 上报序号，防重放 | 否 |
| `platform` | `android` / `windows` | 否 |
| `counts` | 原始设备计数累计 | 否 |
| `cm` | 折算出的厘米 | 否 |
| `wheel` / `clicks` | 滚轮格数 / 点击次数 | 否 |
| `screens` / `taps` / `shorts` | 翻屏手势 / 触摸次数 / 视频翻页次数 | 否 |
| `video_cm` / `video_dwell_s` | 视频板块的距离与前台时长（秒） | 否 |
| `profile_id` | 本机自定义的精度档案 id | 否 |
| `by_hour` | 24 个小时各自的厘米数 | 否（只有小时级汇总，没有时刻序列） |
| `keys` | 按键名 → 次数（仅你手动开启"按键统计"后才有） | 弱：只有键名与次数，没有输入内容与顺序 |
| `owner_id` | 这一天归属的账号 id | 是（仅在你登录后出现） |

**没有**的字段：屏幕内容、界面文字、控件树、触摸坐标、输入内容、剪贴板、通讯录、
已安装应用列表、前台应用名、位置、设备型号。

---

## 四、日志口径：release 包里零输出

逐事件明细（含包名、像素数）只走 `DebugLog`，而它长这样
（[`DebugLog.kt`](app/android/app/src/main/kotlin/com/example/touch_mileage/DebugLog.kt)）：

```kotlin
object DebugLog {
    val enabled = BuildConfig.DEBUG
    fun d(tag: String, msg: () -> String) { if (enabled) Log.d(tag, msg()) }
    ...
}
```

`BuildConfig.DEBUG` 在正式包里是 `false`，所以这些行在 release 里**根本不会执行**——
不是"打了但你没看见"，是插上 USB 用 `logcat` 也读不到。
（例外：服务连接/解绑这类生命周期日志，只含"服务起来没"，不含任何事件内容。）

---

## 五、这份材料没覆盖什么

- **服务端**：这里只说"客户端传了哪些字段"，服务端怎么存、怎么删，见隐私政策。
- **Windows 端**：走的是 Raw Input，不涉及无障碍权限，不在本文范围。
- **界面层**：与权限无关，未包含在本仓库。

如果你在核对时发现任何一处与本文不符，那就是我们错了，请提 issue。
