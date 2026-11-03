package com.example.touch_mileage

import android.util.Log

/**
 * 逐事件明细日志只在 debug 包输出。
 *
 * release 包里触摸坐标与前台应用包名都是内容级/使用级敏感信息，
 * logcat 插上 USB 即可全量读取——设计文档 6.4「不读内容」的口径在
 * release 日志上同样成立。生命周期日志（服务连接/解绑）不走这里，
 * 它们只含设备能力位，且是 release 真机排查「服务到底起来没」的唯一线索。
 */
object DebugLog {
    val enabled = BuildConfig.DEBUG

    fun d(tag: String, msg: () -> String) {
        if (enabled) Log.d(tag, msg())
    }

    fun i(tag: String, msg: () -> String) {
        if (enabled) Log.i(tag, msg())
    }
}
