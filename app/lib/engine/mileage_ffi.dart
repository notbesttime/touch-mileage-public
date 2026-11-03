// -*- coding: utf-8 -*-
// 触控里程 · 采集引擎的 Dart 绑定层
//
// 通过 Dart FFI 直接调用 mileage_engine.dll，不走 Flutter 插件的方法通道。
// 好处：代码少一半，且以后安卓端调用 C++ 也是同一套写法。
//
// ⚠️ 本文件在 Flutter SDK 安装完成后才能编译验证。目前是按 mileage_api.h
//    的 ABI 写好的绑定，函数名与结构体字段顺序必须与 C 侧严格一致。

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// 与 C 侧 MileageCounters 一一对应。
///
/// 字段顺序不可改动：FFI 按内存偏移读取，顺序错了就会读到错位的数据。
/// 全部字段都是 8 字节（7 个 Double + 2 个 Uint64 = 72 字节），没有填充字节，
/// 这一点已由 test_dll.exe 验证过。
final class MileageCounters extends Struct {
  @Double()
  external double countsPath; // 原始设备计数意义上的路径长度（落盘的真值）

  @Double()
  external double cmPath; // 按当前鼠标精度换算出的厘米

  @Double()
  external double countsX; // 分轴累计，精确测量时用

  @Double()
  external double countsY;

  @Double()
  external double wheel; // 垂直滚轮格数

  @Double()
  external double hwheel; // 水平滚轮格数

  @Double()
  external double absolutePx; // 触屏笔/远程桌面的位移（像素），不计入距离

  @Uint64()
  external int clicks;

  @Uint64()
  external int events;
}

/// 一份不依赖 FFI 内存的快照，方便在界面层传递和比较。
class Counters {
  const Counters({
    this.countsPath = 0,
    this.cmPath = 0,
    this.countsX = 0,
    this.countsY = 0,
    this.wheel = 0,
    this.hwheel = 0,
    this.absolutePx = 0,
    this.clicks = 0,
    this.events = 0,
  });

  final double countsPath;
  final double cmPath;
  final double countsX;
  final double countsY;
  final double wheel;
  final double hwheel;
  final double absolutePx;
  final int clicks;
  final int events;

  factory Counters.fromNative(MileageCounters c) => Counters(
        countsPath: c.countsPath,
        cmPath: c.cmPath,
        countsX: c.countsX,
        countsY: c.countsY,
        wheel: c.wheel,
        hwheel: c.hwheel,
        absolutePx: c.absolutePx,
        clicks: c.clicks,
        events: c.events,
      );

  /// 两次快照之差，用于"本次会话新增了多少"。
  Counters operator -(Counters base) => Counters(
        countsPath: countsPath - base.countsPath,
        cmPath: cmPath - base.cmPath,
        countsX: countsX - base.countsX,
        countsY: countsY - base.countsY,
        wheel: wheel - base.wheel,
        hwheel: hwheel - base.hwheel,
        absolutePx: absolutePx - base.absolutePx,
        clicks: clicks - base.clicks,
        events: events - base.events,
      );

  /// 滚轮转了几圈（常见滚轮一圈 24 格）。
  double get wheelRevolutions => wheel.abs() / 24.0;
}

// —— C 函数签名：native 与 dart 两套，FFI 要求分开声明 ——

typedef _StartNative = Int32 Function();
typedef _StartDart = int Function();

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _SetSensNative = Void Function(Double, Double);
typedef _SetSensDart = void Function(double, double);

typedef _CountersNative = Void Function(Pointer<MileageCounters>);
typedef _CountersDart = void Function(Pointer<MileageCounters>);

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

typedef _DevNameNative = Int32 Function(Int32, Pointer<Utf8>, Int32);
typedef _DevNameDart = int Function(int, Pointer<Utf8>, int);

typedef _ErrNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _ErrDart = int Function(Pointer<Utf8>, int);

// —— 托盘 / 窗口 / 自启 ——
typedef _TrayEnableNative = Int32 Function(Pointer<Utf8>);
typedef _TrayEnableDart = int Function(Pointer<Utf8>);

typedef _TraySetTipNative = Void Function(Pointer<Utf8>);
typedef _TraySetTipDart = void Function(Pointer<Utf8>);

typedef _IntArgNative = Void Function(Int32);
typedef _IntArgDart = void Function(int);

/// 一个 int 参数、返回 int 的导出函数（悬浮窗开关：1 成功）
typedef _IntRetIntNative = Int32 Function(Int32);
typedef _IntRetIntDart = int Function(int);

/// 两个 int 参数的导出函数（Mica 的启用 + 明暗）
typedef _Int2ArgNative = Void Function(Int32, Int32);
typedef _Int2ArgDart = void Function(int, int);

/// 悬浮窗数据更新：今日厘米 + 目标厘米 + 深色标志
typedef _OverlayUpdateNative = Void Function(Double, Double, Int32);
typedef _OverlayUpdateDart = void Function(double, double, int);

typedef _KeyAtNative = Void Function(Int32, Pointer<Int32>, Pointer<Uint64>);
typedef _KeyAtDart = void Function(int, Pointer<Int32>, Pointer<Uint64>);

/// 采集引擎。整个应用只应存在一个实例。
class MileageEngine {
  MileageEngine._(this._lib) {
    _start = _lib.lookupFunction<_StartNative, _StartDart>('mileage_start');
    _stop = _lib.lookupFunction<_VoidNative, _VoidDart>('mileage_stop');
    _isRunning =
        _lib.lookupFunction<_IntNative, _IntDart>('mileage_is_running');
    _setSens = _lib.lookupFunction<_SetSensNative, _SetSensDart>(
        'mileage_set_sensitivity');
    _snapshot =
        _lib.lookupFunction<_CountersNative, _CountersDart>('mileage_snapshot');
    _measureStart =
        _lib.lookupFunction<_VoidNative, _VoidDart>('mileage_measure_start');
    _measurePeek = _lib.lookupFunction<_CountersNative, _CountersDart>(
        'mileage_measure_peek');
    _measureStop = _lib.lookupFunction<_CountersNative, _CountersDart>(
        'mileage_measure_stop');
    _deviceCount =
        _lib.lookupFunction<_IntNative, _IntDart>('mileage_device_count');
    _deviceName = _lib.lookupFunction<_DevNameNative, _DevNameDart>(
        'mileage_device_name');
    _lastError =
        _lib.lookupFunction<_ErrNative, _ErrDart>('mileage_last_error');

    _trayEnable =
        _lib.lookupFunction<_TrayEnableNative, _TrayEnableDart>(
            'mileage_tray_enable');
    _trayDisable =
        _lib.lookupFunction<_VoidNative, _VoidDart>('mileage_tray_disable');
    _traySetTip =
        _lib.lookupFunction<_TraySetTipNative, _TraySetTipDart>(
            'mileage_tray_set_tooltip');
    _trayIsEnabled =
        _lib.lookupFunction<_IntNative, _IntDart>('mileage_tray_is_enabled');
    _trayTakeCommand =
        _lib.lookupFunction<_IntNative, _IntDart>('mileage_tray_take_command');
    _windowShow =
        _lib.lookupFunction<_VoidNative, _VoidDart>('mileage_window_show');
    _windowHide =
        _lib.lookupFunction<_VoidNative, _VoidDart>('mileage_window_hide');
    _setCloseToTray =
        _lib.lookupFunction<_IntArgNative, _IntArgDart>(
            'mileage_set_close_to_tray');
    _imeSet =
        _lib.lookupFunction<_IntArgNative, _IntArgDart>(
            'mileage_ime_set_enabled');
    _micaSet =
        _lib.lookupFunction<_Int2ArgNative, _Int2ArgDart>(
            'mileage_mica_set_enabled');
    _overlaySet = _lib.lookupFunction<_IntRetIntNative, _IntRetIntDart>(
        'mileage_overlay_set_enabled');
    _overlayIs = _lib.lookupFunction<_IntNative, _IntDart>(
        'mileage_overlay_is_enabled');
    _overlayUpdate = _lib.lookupFunction<_OverlayUpdateNative, _OverlayUpdateDart>(
        'mileage_overlay_update');
    _overlayClickThrough = _lib.lookupFunction<_IntArgNative, _IntArgDart>(
        'mileage_overlay_set_click_through');
    _overlayTakeCmd = _lib.lookupFunction<_IntNative, _IntDart>(
        'mileage_overlay_take_command');
    _autostartSet =
        _lib.lookupFunction<_IntArgNative, _IntArgDart>(
            'mileage_autostart_set_enabled');
    _autostartIs =
        _lib.lookupFunction<_IntNative, _IntDart>(
            'mileage_autostart_is_enabled');
    _setKeyCapture =
        _lib.lookupFunction<_IntArgNative, _IntArgDart>(
            'mileage_set_key_capture');
    _keyCaptureEnabled =
        _lib.lookupFunction<_IntNative, _IntDart>(
            'mileage_key_capture_enabled');
    _keyEntries =
        _lib.lookupFunction<_IntNative, _IntDart>(
            'mileage_key_count_entries');
    _keyAt =
        _lib.lookupFunction<_KeyAtNative, _KeyAtDart>(
            'mileage_key_count_at');
  }

  /// 加载 DLL。
  ///
  /// 打包后的 Flutter 应用会把 DLL 放在 exe 同目录，直接按文件名加载即可；
  /// 开发时若找不到，可传入绝对路径。
  factory MileageEngine.open({String? path}) {
    if (!Platform.isWindows) {
      throw UnsupportedError('当前采集引擎只实现了 Windows 版');
    }
    final lib = DynamicLibrary.open(path ?? 'mileage_engine.dll');
    return MileageEngine._(lib);
  }

  final DynamicLibrary _lib;

  late final _StartDart _start;
  late final _VoidDart _stop;
  late final _IntDart _isRunning;
  late final _SetSensDart _setSens;
  late final _CountersDart _snapshot;
  late final _VoidDart _measureStart;
  late final _CountersDart _measurePeek;
  late final _CountersDart _measureStop;
  late final _IntDart _deviceCount;
  late final _DevNameDart _deviceName;
  late final _ErrDart _lastError;

  late final _TrayEnableDart _trayEnable;
  late final _VoidDart _trayDisable;
  late final _TraySetTipDart _traySetTip;
  late final _IntDart _trayIsEnabled;
  late final _IntDart _trayTakeCommand;
  late final _VoidDart _windowShow;
  late final _VoidDart _windowHide;
  late final _IntArgDart _setCloseToTray;
  late final _IntArgDart _imeSet;
  late final _Int2ArgDart _micaSet;
  late final _IntRetIntDart _overlaySet;
  late final _IntDart _overlayIs;
  late final _OverlayUpdateDart _overlayUpdate;
  late final _IntArgDart _overlayClickThrough;
  late final _IntDart _overlayTakeCmd;
  late final _IntArgDart _autostartSet;
  late final _IntDart _autostartIs;
  late final _IntArgDart _setKeyCapture;
  late final _IntDart _keyCaptureEnabled;
  late final _IntDart _keyEntries;
  late final _KeyAtDart _keyAt;

  /// 开始采集。返回 false 时用 [lastError] 取原因。
  bool start() => _start() == 1;

  void stop() => _stop();

  bool get isRunning => _isRunning() == 1;

  /// 设置鼠标精度（每英寸计数）。x、y 可以不同——有些鼠标两轴确实不一致。
  void setSensitivity(double cpiX, [double? cpiY]) =>
      _setSens(cpiX, cpiY ?? cpiX);

  Counters snapshot() => _withCounters(_snapshot);

  /// 开始一次独立计量（精确测量向导用），与总累计互不影响。
  void measureStart() => _measureStart();

  Counters measurePeek() => _withCounters(_measurePeek);

  Counters measureStop() => _withCounters(_measureStop);

  int get deviceCount => _deviceCount();

  /// 取第 [index] 个设备名。C 侧约定：先传空指针问长度，再分配缓冲区取内容。
  String deviceName(int index) {
    final need = _deviceName(index, nullptr, 0);
    if (need <= 0) return '';
    final buf = calloc<Uint8>(need + 1);
    try {
      _deviceName(index, buf.cast<Utf8>(), need + 1);
      return buf.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  String get lastError {
    final need = _lastError(nullptr, 0);
    if (need <= 0) return '';
    final buf = calloc<Uint8>(need + 1);
    try {
      _lastError(buf.cast<Utf8>(), need + 1);
      return buf.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  // —— 托盘 ——

  /// 创建托盘图标。[tooltip] 是鼠标悬停时显示的提示文字。
  bool trayEnable(String tooltip) {
    final p = tooltip.toNativeUtf8();
    try {
      return _trayEnable(p) == 1;
    } finally {
      calloc.free(p);
    }
  }

  void trayDisable() => _trayDisable();

  void traySetTooltip(String tooltip) {
    final p = tooltip.toNativeUtf8();
    try {
      _traySetTip(p);
    } finally {
      calloc.free(p);
    }
  }

  bool get trayIsEnabled => _trayIsEnabled() == 1;

  /// 取一条待处理的托盘命令：0 无、1 显示主界面、2 退出。
  int trayTakeCommand() => _trayTakeCommand();

  void windowShow() => _windowShow();

  void windowHide() => _windowHide();

  /// 点窗口关闭按钮时是否隐藏到托盘。
  void setCloseToTray(bool enable) => _setCloseToTray(enable ? 1 : 0);

  /// 启用 / 禁用主窗口的输入法关联。默认应禁用（避免中文输入法弹候选窗），
  /// 仅在需要打中文的对话框临时启用。
  void setImeEnabled(bool enable) => _imeSet(enable ? 1 : 0);

  /// 启用 / 禁用 Mica 云母背景（Windows 11 22H2+）。
  /// [dark] 要与当前生效的主题明暗一致；主题切换后应重新调用。
  void setMicaEnabled(bool enable, {required bool dark}) =>
      _micaSet(enable ? 1 : 0, dark ? 1 : 0);

  // —— 桌面悬浮窗 ——

  /// 显示 / 隐藏悬浮窗。返回 false 表示创建失败。
  bool setOverlayEnabled(bool enable) => _overlaySet(enable ? 1 : 0) == 1;

  bool get overlayIsEnabled => _overlayIs() == 1;

  /// 更新悬浮窗数据（引擎内部只在文本/主题变化时重绘，随采样循环调用）
  void overlayUpdate(double todayCm, double goalCm, {required bool dark}) =>
      _overlayUpdate(todayCm, goalCm, dark ? 1 : 0);

  /// 鼠标穿透：开启后悬浮窗对鼠标完全透明，只能从设置页或托盘菜单关
  void setOverlayClickThrough(bool enable) =>
      _overlayClickThrough(enable ? 1 : 0);

  /// 取走一条悬浮窗用户命令：0 无、1 隐藏悬浮窗
  int overlayTakeCommand() => _overlayTakeCmd();

  // —— 开机自启 ——

  bool autostartSetEnabled(bool enable) {
    _autostartSet(enable ? 1 : 0);
    return _autostartIs() == 1;
  }

  bool get autostartIsEnabled => _autostartIs() == 1;

  // —— 按键统计 ——

  void setKeyCapture(bool enable) => _setKeyCapture(enable ? 1 : 0);

  bool get keyCaptureEnabled => _keyCaptureEnabled() == 1;

  /// 读取当前累计的按键次数，返回 {虚拟键: 次数}，按次数降序。
  Map<int, int> keyCounts() {
    final n = _keyEntries();
    final out = <int, int>{};
    final vk = calloc<Int32>();
    final val = calloc<Uint64>();
    try {
      for (var i = 0; i < n; i++) {
        _keyAt(i, vk, val);
        out[vk.value] = val.value;
      }
    } finally {
      calloc.free(vk);
      calloc.free(val);
    }
    return out;
  }

  /// 统一处理"分配结构体内存 → 调用 → 复制出来 → 释放"这套样板。
  Counters _withCounters(_CountersDart fn) {
    final p = calloc<MileageCounters>();
    try {
      fn(p);
      return Counters.fromNative(p.ref);
    } finally {
      calloc.free(p);
    }
  }
}
