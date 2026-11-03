# 触控里程 · Touch Mileage

把鼠标和手指的**真实位移**换算成"里程"的小工具：滚了多少厘米、点了多少下、刷了多久。
Windows 端用 Raw Input 读鼠标移动，Android 端通过无障碍服务统计滚动与点击手势，
两端数据可以同步到自己的账号里，看历史、看排行。

<p align="center">
  <img src="assets/site.png" alt="官方网站" width="440">
</p>

## 主要功能

- **位移即里程**：按 CPI 把鼠标移动计数折算成厘米，滚轮、点击、按键分别统计
- **10 厘米校准**：拿尺子量 10 厘米推一次，反推出你这只鼠标的真实 CPI
- **手机端翻页统计**：用无障碍服务数滚动手势与点击次数，折算成屏幕里程
- **刷视频单独分账**：视频类应用里的滑动单独记账，能看出"刷视频走了多远、刷了多久"
- **本地优先**：所有记录先写在本机，未登录也能用；登录后才同步
- **周报与排行**：按周汇总、时段分布、好友榜

## 为什么这个仓库只有一部分代码

Android 端的里程统计依赖**无障碍服务**（AccessibilityService）。这类权限在系统设置里
"看起来"能读到屏幕上的全部内容，所以每次安装都值得犹豫一下——这是合理的怀疑。

我们把这项服务**实际做了什么**完整放出来，你可以自己核对，不需要相信任何文字说明：

| 你想确认的 | 怎么确认 |
|---|---|
| 它有没有申请"读取窗口内容"的能力 | 跑 `node tools/verify_a11y.mjs 你的.apk`，工具直接从 APK 二进制里读 |
| 它到底接收哪几类事件 | 同上，工具会把事件掩码的每一位解出来（本项目是 4 种） |
| 拿到事件之后它碰了哪些字段 | 看 `MileageAccessibilityService.kt` 的 `onAccessibilityEvent` |
| 它把什么传了出去 | 看 [EVIDENCE.md](EVIDENCE.md) 的字段表，逐项对照 `models.dart` |

实测结果与完整说明见 **[EVIDENCE.md](EVIDENCE.md)**。

### 自己验证（不需要装 Android SDK）

```bash
node tools/verify_a11y.mjs app-release.apk
```

Windows 上也可以直接双击 `tools/verify_a11y.ps1`。工具只读你指定的 APK 文件，
**不联网、不上传、不写任何东西**；它自带 Android 二进制 XML 解析器，只用 Node 内置模块。

想确认这个工具不是"永远输出通过"，跑一次自检：

```bash
node tools/verify_a11y.mjs app-release.apk --selftest
```

它会在内存里把 `canRetrieveWindowContent` 从 `false` 改成 `true`，然后看自己会不会报警。

## 本仓库包含什么

| 目录 | 内容 |
|---|---|
| `app/android/app/src/main/kotlin/` | 无障碍服务、事件记账、常驻通知、凭据存储 |
| `app/android/app/src/main/res/xml/accessibility_service_config.xml` | 能力声明（最该看的就是这个文件） |
| `app/android/app/src/main/AndroidManifest.xml` | 权限与组件清单 |
| `app/lib/engine/` | 事件 → 里程的换算（手机端与 FFI 接口） |
| `app/lib/data/models.dart` | 数据模型，含上传字段的定义 |
| `app/lib/data/owner.dart` | 本机数据归属判定（谁能上传哪一天） |
| `app/lib/data/privacy_policy.dart` | App 内置的隐私政策全文 |
| `app/lib/data/secure_store.dart` | 令牌的本地加密存储 |
| `tools/verify_a11y.mjs`、`verify_a11y.ps1` | 上面那个自证工具 |

## 本仓库不包含什么，为什么

| 不包含 | 原因 |
|---|---|
| 服务端代码与部署配置 | 与"无障碍权限用来做什么"无关，且涉及部署拓扑与运维细节 |
| Windows 端 C++ 引擎 | 与 Android 无障碍无关 |
| 界面层代码 | 与权限无关，且体量大、可读性差 |
| 客户端网络层（`cloud.dart`） | 含接口地址与鉴权流程，属于服务端相关设计 |
| 内部设计与运维文档 | 面向开发者本人，含服务器与流程信息 |

所以这个仓库**不是可独立构建的完整工程**，是一份**可核对的摘录**：每个文件都与
正式发版所用代码**逐字节一致**，没有为了公开而改写任何一行（包括注释里提到的内部文档名，
那些文档不随本仓公开）。

## 版本

对应 **触控里程 Android 0.5.3**（versionCode 14）的采集层与计量层。

## 许可

[GNU AGPL-3.0](LICENSE)。个人使用、审计、二次开发都不受限制；
如果你要把修改后的版本作为网络服务提供给他人，需要同样开放源码。
