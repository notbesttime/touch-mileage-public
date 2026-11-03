// -*- coding: utf-8 -*-
// 触控里程 · 凭据安全存储（P1-2，2026-10-14）
//
// 为什么需要它：《设计文档》从第一天就写着"AI 密钥进系统凭据库，绝不落在
// 明文 JSON 里"，但云令牌一直是明文写在 config.json 的 cloud_token 字段。
// 本次把它挪出来，两端各自用系统能力保护：
//
//   · Windows：DPAPI（CryptProtectData，走既有 C++ 引擎 FFI，不引插件依赖）
//   · Android：Keystore（AES-GCM 密钥存在硬件级密钥库，走 MethodChannel）
//
// ⚠️ **能力边界务必如实理解，别当成"绝对安全"**：
//   · Windows 的 DPAPI 密钥绑定当前**用户账户** ⇒ 防住「数据目录被复制
//     /传网盘/换账户」，但**不防同账户下运行的恶意程序**（它能调同一个
//     解密 API）。这是 DPAPI 的固有限制。
//   · Android 的 Keystore 更强（密钥不出安全硬件，root 之外拿不到），
//     但同样不防"设备已被完全控制"的极端情况。
//   · 真正的兜底是「登录设备」页（P1-1）——用户能看见并踢掉陌生设备。
//
// 设计：**失败一律不落明文**。加密失败就当作"没有令牌"，让用户重新登录，
// 而不是退回明文存盘——那样等于什么都没做。

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// FFI 函数签名：`int f(const char* in, char* buf, int cap)`
/// 返回写入字节数；buf 为空或 cap 不足时返回所需长度；失败返回 -1。
///
/// 与项目中 mileage_ffi 的 mileage_device_name / mileage_last_error 同一写法：
/// 缓冲区用 Utf8 指针 + Int32 容量，先传空指针问长度再分配。
typedef _SecureNative = ffi.Int32 Function(
    ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Int32);
typedef _SecureDart = int Function(
    ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int);

class SecureStore {
  SecureStore._();

  static const _channel = MethodChannel('touch_mileage/secure');

  static ffi.DynamicLibrary? _lib;
  static _SecureDart? _protect;
  static _SecureDart? _unprotect;

  /// 是否真的**能加密**。不可用时调用方应不保存令牌（而不是退回明文）。
  ///
  /// ⚠️ 这里必须判断"能力是否真的就绪"，不能只判断平台——
  /// 单元测试环境跑在 Windows 上，但既没有引擎 DLL 也没有 Keystore，
  /// 只判 `Platform.isWindows` 会返回 true，给出"已加密"的假象。
  /// （这个错误是被 secure_store_test 抓出来的。）
  static bool get available {
    if (Platform.isWindows) return _initWindows();
    // Android 的能力要真正调一次才知道（Keystore 可能被系统禁用/降级）；
    // 这里按平台假定可用，实际失败由 protect() 返回 null 兜住 —— 结果一样：
    // 加密不成功就不落盘。
    return Platform.isAndroid;
  }

  /// Windows：延迟加载引擎 DLL 并取符号。加载失败返回 false（不抛）。
  static bool _initWindows() {
    if (_protect != null && _unprotect != null) return true;
    try {
      // 与 mileage_ffi.dart 用同一个库；这里独立打开一次句柄即可，
      // 动态库本身是进程内共享的，不会重复加载。
      _lib ??= ffi.DynamicLibrary.open('mileage_engine.dll');
      _protect ??= _lib!.lookupFunction<_SecureNative, _SecureDart>(
          'mileage_secure_protect');
      _unprotect ??= _lib!.lookupFunction<_SecureNative, _SecureDart>(
          'mileage_secure_unprotect');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 加密。返回 base64 密文；失败返回 null（调用方据此不落盘）。
  static Future<String?> protect(String plain) async {
    if (plain.isEmpty) return null;
    if (Platform.isWindows) {
      if (!_initWindows()) return null;
      return _callFfi(_protect!, plain);
    }
    if (Platform.isAndroid) {
      try {
        final out = await _channel
            .invokeMethod<String>('protect', {'plain': plain});
        return (out == null || out.isEmpty) ? null : out;
      } catch (_) {
        return null;
      }
    }
    return null; // 其他平台：不落明文
  }

  /// 解密。任何失败（换账户、换设备、密文损坏）一律返回 null ——
  /// 调用方当作"没有登录态"，引导重新登录即可，不报错、不崩。
  static Future<String?> unprotect(String cipherB64) async {
    if (cipherB64.isEmpty) return null;
    if (Platform.isWindows) {
      if (!_initWindows()) return null;
      return _callFfi(_unprotect!, cipherB64);
    }
    if (Platform.isAndroid) {
      try {
        return await _channel
            .invokeMethod<String>('unprotect', {'cipher': cipherB64});
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 调用 C 侧函数：先问长度、再分配缓冲区（与 mileage_ffi 的字符串约定一致）。
  static String? _callFfi(_SecureDart fn, String input) {
    final inPtr = input.toNativeUtf8();
    try {
      // 先问长度：buf 传空指针、cap 传 0（与 mileage_ffi 的 _deviceName 同一约定）
      final need = fn(inPtr, ffi.nullptr, 0);
      if (need <= 0) return null;
      final buf = malloc<ffi.Uint8>(need);
      try {
        final got = fn(inPtr, buf.cast<Utf8>(), need);
        if (got <= 0) return null;
        // 密文是二进制，不能按 C 串截断 —— 用实际返回长度切片。
        final bytes = buf.asTypedList(got);
        return base64Encode(bytes);
      } finally {
        malloc.free(buf);
      }
    } finally {
      malloc.free(inPtr);
    }
  }
}
