// -*- coding: utf-8 -*-
// 触控里程 · 鼠标精度测量的计算逻辑
//
// 单独成文件是因为这些是纯计算、有明确对错、必须测：
// 算错了整个应用的距离数字全是错的，而且错得很隐蔽（数量级看着还挺合理）。
//
// 原理：
//   鼠标传感器每移动一英寸报告固定数量的"计数"，这个数量就是 CPI。
//   系统读不到它（HID 协议不要求设备上报），所以靠实测：
//   让用户沿直线移动一段量好的距离，数一下设备报了多少计数。
//
//   CPI = 计数 ÷ (实际厘米 ÷ 2.54)

import 'data/models.dart';

const double kInchToCm = 2.54;

/// 由一次测量算出 CPI。距离非法时返回 null，由调用方决定怎么提示。
double? cpiFromMeasurement({required double counts, required double cm}) {
  if (cm <= 0) return null;
  if (counts <= 0) return null;
  return counts / (cm / kInchToCm);
}

/// 一次测量至少要有多少计数才算有效。
///
/// 低于这个值几乎肯定是没记录到（比如用户忘了真的移动鼠标），
/// 这时候算出来的 CPI 会离谱到没法用，不如直接判为无效。
const double kMinValidCounts = 50;

/// 多次测量的平均 CPI。
double averageCpi(List<CalibrationSample> samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s.cpi;
  }
  return sum / samples.length;
}

/// 离散度：(最大 - 最小) / 平均，用百分比表示。
///
/// 这个指标比平均值更能说明"这次测量可信吗"——
/// 三次结果 800/805/803 说明手稳，800/1200/650 说明中途歪了或没走完全程。
double spreadPercent(List<CalibrationSample> samples) {
  if (samples.length < 2) return 0;
  var min = samples.first.cpi;
  var max = samples.first.cpi;
  for (final s in samples) {
    if (s.cpi < min) min = s.cpi;
    if (s.cpi > max) max = s.cpi;
  }
  final avg = averageCpi(samples);
  if (avg <= 0) return 0;
  return (max - min) / avg * 100;
}

/// 测量质量的评价。
enum MeasureQuality { needMore, good, fair, poor }

MeasureQuality qualityOf(List<CalibrationSample> samples) {
  if (samples.length < 2) return MeasureQuality.needMore;
  final spread = spreadPercent(samples);
  if (spread < 3) return MeasureQuality.good;
  if (spread < 8) return MeasureQuality.fair;
  return MeasureQuality.poor;
}

String qualityText(MeasureQuality q) => switch (q) {
      MeasureQuality.needMore => '建议再测几次以便交叉验证',
      MeasureQuality.good => '几次结果高度一致，测量可信',
      MeasureQuality.fair => '几次结果基本一致，可以接受',
      MeasureQuality.poor => '几次结果差异较大，建议重测——'
          '确认鼠标是沿直线走完了全程',
    };

/// 常见的标称 CPI。实测值贴近其中某个，说明测量靠谱。
const commonCpiValues = <double>[
  400, 800, 1000, 1200, 1600, 2000, 2400, 3200, 4000, 6400
];

/// 找出最接近实测值的标称值，以及偏差百分比。
///
/// 传感器实际值和标称值差几个百分点是正常的；
/// 如果偏差很大（比如实测 1150 而最近的标称是 1200，差 4%），
/// 那也只是提示信息，不修正用户的实测结果。
(double nominal, double deviationPercent)? nearestCommonCpi(double measured) {
  if (measured <= 0) return null;
  double? best;
  var bestDiff = double.infinity;
  for (final v in commonCpiValues) {
    final diff = (v - measured).abs();
    if (diff < bestDiff) {
      bestDiff = diff;
      best = v;
    }
  }
  if (best == null) return null;
  return (best, (measured - best) / best * 100);
}

/// 按轴向分别求平均。某轴没测过就沿用另一轴的结果
/// （多数鼠标两轴 CPI 相同，只有少数型号不一致）。
(double cpiX, double cpiY) axisAverages(List<CalibrationSample> samples) {
  final xs = samples.where((s) => s.axis == 'X').toList();
  final ys = samples.where((s) => s.axis == 'Y').toList();
  final overall = averageCpi(samples);
  final cpiX = xs.isEmpty ? overall : averageCpi(xs);
  final cpiY = ys.isEmpty ? overall : averageCpi(ys);
  return (cpiX, cpiY);
}
