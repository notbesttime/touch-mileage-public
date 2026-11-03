// -*- coding: utf-8 -*-
// 触控里程 · 数值与文案格式化
//
// 单独成文件的原因：这部分是纯函数、最容易写错边界、也最需要单元测试，
// 不该和界面代码混在一起。

/// 完整的距离描述，如「12.34 米」。
String formatDistance(double cm) {
  if (cm < 100) return '${cm.toStringAsFixed(1)} 厘米';
  if (cm < 100000) return '${(cm / 100).toStringAsFixed(2)} 米';
  return '${(cm / 100000).toStringAsFixed(2)} 公里';
}

/// 返回 (数值, 单位)，供大字号分开显示。
(String, String) splitDistance(double cm) {
  if (cm < 100) return (cm.toStringAsFixed(1), '厘米');
  if (cm < 100000) return ((cm / 100).toStringAsFixed(1), '米');
  return ((cm / 100000).toStringAsFixed(2), '公里');
}

/// 紧凑写法，用于柱状图坐标轴这类空间局促的地方。
String formatCompact(double cm) {
  if (cm <= 0) return '0';
  if (cm < 100) return '${cm.toStringAsFixed(0)}厘米';
  if (cm < 100000) return '${(cm / 100).toStringAsFixed(0)}米';
  return '${(cm / 100000).toStringAsFixed(1)}公里';
}

/// 趣味参照表。按"不超过当前距离的最大参照物"来挑选，
/// 所以必须按长度升序排列。
const references = <(String, double)>[
  ('张 A4 纸', 29.7),
  ('个键盘', 45),
  ('张书桌', 120),
  ('个人的身高', 170),
  ('辆汽车', 450),
  ('个篮球场', 2800),
  ('个标准泳池', 5000),
  ('座埃菲尔铁塔', 33000),
  ('圈操场跑道', 40000),
];

String funComparison(double cm) {
  if (cm < 5) return '刚开始记录';
  for (final ref in references.reversed) {
    if (cm >= ref.$2) {
      final n = cm / ref.$2;
      // 倍数很大时不显示小数，否则会出现「123.4 个篮球场」这种噪音
      final txt = n >= 10 ? n.toStringAsFixed(0) : n.toStringAsFixed(1);
      return '≈ $txt ${ref.$1}';
    }
  }
  return '≈ ${(cm / 29.7).toStringAsFixed(1)} 张 A4 纸';
}

/// 滚轮圈数（常见滚轮一圈 24 格）
String formatRevolutions(double notches) =>
    (notches.abs() / 24.0).toStringAsFixed(0);

/// 滚轮滚动的物理距离。常见滚轮周长约 2.6 毫米/格。
double scrollMetersFromWheel(double notches) => notches.abs() * 0.0026;

String formatScroll(double meters) {
  if (meters < 1) return '${(meters * 100).toStringAsFixed(0)} 厘米';
  return '${meters.toStringAsFixed(1)} 米';
}

/// 把 Windows 虚拟键码映射成可读的键名。
///
/// 只映射字母、数字和少数常见键；其余归入"其他"。
/// 因为我们只统计次数，键名只是给人看的标签，不需要穷举。
String keyLabel(int vkey) {
  // A-Z: 0x41-0x5A
  if (vkey >= 0x41 && vkey <= 0x5A) {
    return String.fromCharCode(vkey); // 'A'..'Z'
  }
  // 0-9 主键盘: 0x30-0x39
  if (vkey >= 0x30 && vkey <= 0x39) {
    return String.fromCharCode(vkey);
  }
  // 小数字键盘: VK_NUMPAD0-9 = 0x60-0x69
  if (vkey >= 0x60 && vkey <= 0x69) {
    return '${vkey - 0x60}';
  }
  switch (vkey) {
    case 0x20:
      return '空格';
    case 0x0D:
      return '回车';
    case 0x08:
      return '退格';
    case 0x09:
      return 'Tab';
    case 0x10:
      return 'Shift';
    case 0x11:
      return 'Ctrl';
    case 0x12:
      return 'Alt';
    case 0x25:
      return '←';
    case 0x26:
      return '↑';
    case 0x27:
      return '→';
    case 0x28:
      return '↓';
    default:
      return '其他';
  }
}
