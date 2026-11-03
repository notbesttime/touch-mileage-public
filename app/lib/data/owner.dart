// -*- coding: utf-8 -*-
// 触控里程 · 本机数据归属判定（MT-04）+ 已上传账本（MT-03），2026-10-18
//
// 这个文件管两件事，它们是同一类问题的两面：
//   · **归属**：这份数据归哪个账号（MT-04，坑 79）
//   · **账本**：这份数据里哪些天已经传上去了（MT-03，坑 81）
//
// 共同点：两者都是"跨账号/跨时间"的状态，都必须显式记录、不能靠推断。

import 'dart:convert';

import 'models.dart';

/// 本机数据是否归属于 [cloudId] 这个账号（决定能不能上报）。
bool dataBelongsTo(String dataOwnerId, String cloudId) {
  if (cloudId.isEmpty) return false;
  return dataOwnerId.isNotEmpty && dataOwnerId == cloudId;
}

/// 本机是否存在"不属于当前账号"的历史（界面上应该提示而不是静默）。
bool hasForeignData(String dataOwnerId, String cloudId) {
  if (dataOwnerId.isEmpty) return false;   // 匿名，不是"别人的"
  return dataOwnerId != cloudId;
}

/// 欠账上限：一次补报最多带多少天。
/// 与服务端单次批量上限（500 条）留出余量；也避免"一年没上线"时拼出巨大请求体。
const int kBackfillMaxDays = 400;

/// 本次启动/登录**允许上报**的天。
///
/// [localKeys] 本机全部有记录的天；[today] 今天；
/// [reportedUpTo] 旧版**水位线**（仅在 [uploadedDatesJson] 为空时兜底）；
/// [uploadedDatesJson] 已确认上传过的天的集合（JSON 数组字符串，空 = 未知）；
/// [dataOwnerId]/[cloudId] 见文件头。
///
/// ⚠️ 归属判定的顺序很关键：**先判归属，再算欠账**。
/// 反过来（先算欠账再过滤）也能得到同样结果，但一旦将来有人只改了欠账
/// 那一段、忘了归属，就会重新打通这条串号路径。这里用一个返回值把
/// "不许传"表达出来，调用方没有机会绕过去。
///
/// —— 为什么不再只用 reportedUpTo（MT-03，2026-10-18）——
///
/// 水位线只有一个日期，规则是 `k > 水位线`。于是**水位线左边漏传的天永远
/// 补不回来**：离线几天 → 联网那天传成功 → 水位线跳到今天 → 中间那几天
/// 本地有、云端没有，却再也不会被选中（`mt03_backfill_gap_test.dart` 固化了
/// 这条）。改成"已上传的天集合"后，欠账 = 本地有的天 − 已上传的天，与时间
/// 顺序无关，也就顺手解决了系统时间倒退/换时区的问题。
/// [dayOwners] 逐天的归属（date -> ownerId）。**这是按天判归属的唯一依据**
/// （坑 90，2026-10-19）。老调用方不传时退回「整机归属」的旧行为。
List<String> uploadableDays({
  required Iterable<String> localKeys,
  required String today,
  required String dataOwnerId,
  required String cloudId,
  String reportedUpTo = '',
  String uploadedDatesJson = '',
  Map<String, String> dayOwners = const {},
}) {
  if (!dataBelongsTo(dataOwnerId, cloudId)) return const <String>[];

  final uploaded = parseUploadedDates(uploadedDatesJson);
  // 有账本就按账本算（`[]` = 确认一天都没传过，等价于"全部待传"）；
  // 没账本时退回旧版水位线规则，让迁移期的老配置行为不变。
  final useSet = uploadedDatesJson.isNotEmpty;

  // today 是否并入，取决于 [dayOwners] **明确说了什么**（坑 91）：
  //
  //   · dayOwners 里有 today 且归别人/匿名 ⇒ 不并入（这是本次修正的目标：
  //     换号当天，今天归 A 时 B 不能把它发上去）
  //   · dayOwners 里没有 today（不知道）⇒ **照旧并入**。今天的数据还在涨，
  //     「今天必须每轮覆盖上传」是既有语义，不能因为不知道就丢掉。
  //     调用方若确实没有今天的记录，由它自己按「有没有这条记录」过滤。
  //
  // 曾经试过用 `localKeys.contains(today)` 判断，那是错的：localKeys 是
  // 「本机有记录的天」，有些调用方根本不传今天（它确实还没有记录），
  // 于是「今天」被误判成不存在——MT-03 的补报用例当场红了 10 条。
  final todayOwner = dayOwners[today];
  final skipToday = todayOwner != null && todayOwner != cloudId;
  final pending = [
    for (final k in ({...localKeys, if (!skipToday) today}))
      if (_dayBelongsTo(k, dayOwners, cloudId, today) &&
          !_alreadyUploaded(
            k,
            uploaded: uploaded,
            useSet: useSet,
            reportedUpTo: reportedUpTo,
            today: today,
          ))
        k,
  ]..sort();

  if (pending.length <= kBackfillMaxDays) return pending;
  // 超量时**保留最新的那些**：旧的补不回来更可惜的是"今天还在涨"，
  // 而更早的天等下一轮还会再出现在集合里（集合语义不会把它们丢掉）。
  return pending.sublist(pending.length - kBackfillMaxDays);
}

/// 从本机某一天的多个账号记录里，挑出**归 [cloudId] 的那一份**（坑 91）。
///
/// 为什么必须是独立函数：上传时如果直接拿「合计视图」，同一天 A 记 500、
/// B 记 300 就会把 800 全报给当前账号（服务端是覆盖写，A 的份额直接变成
/// B 的）。这条判定既要被真实代码用，也要能被测试直接打到——写在
/// `main.dart` 的 StatefulWidget 里就两样都做不到（坑 90 的第二次反向
/// 验证失败就是这个原因：测试里复刻了一份逻辑，改坏真实代码它不会红）。
///
/// 返回 null 表示这天没有该账号的记录（不该发）。
DayRecord? recordOwnedBy(Iterable<DayRecord> records, String cloudId) {
  if (cloudId.isEmpty) return null; // 未登录：什么都不发
  for (final r in records) {
    if (r.ownerId == cloudId) return r;
  }
  return null;
}

/// 取「当前账号该发的那一份」：date -> 记录。只含该账号真有记录的天。
///
/// 与 [recordOwnedBy] 同一个口径，只是批量版本（上传入口用它）。
Map<String, DayRecord> recordsOwnedBy(
  Map<String, List<DayRecord>> byDate,
  String cloudId,
) {
  final out = <String, DayRecord>{};
  if (cloudId.isEmpty) return out;
  for (final entry in byDate.entries) {
    final mine = recordOwnedBy(entry.value, cloudId);
    if (mine != null) out[entry.key] = mine;
  }
  return out;
}

/// 登录完成后，整机归属（`AppConfig.dataOwnerId`）应该变成什么（坑 90）。
///
/// 返回 `null` = 保持不变。这是**唯一的一处判定**，`account.dart` 只负责
/// 按结论赋值——判定逻辑放这里，测试才碰得到（UI 里的 if 没法单测，
/// 而它恰恰是坑 90 的所在）。
///
/// 四条规则：
///   ① **换了账号** ⇒ 一定跟着新账号走。
///      原来这里写的是「非空就不动」，后果是本机数据永远挂在第一个账号名下：
///      新账号一天也传不上去，换回原账号又把中间的记录一起带走。
///   ② 同一个账号重新登录 ⇒ 不动（数据本来就归它）。
///   ③ 本机没有历史 ⇒ 直接归属（没什么可争的）。
///   ④ 本机有匿名历史 ⇒ **问一次**（[claimLocal]）。不默认并入：
///      这台机器的历史可能是别人留下的，默认并入就是把 A 的里程算到 B 头上。
///      选「暂不」返回 `null`（保持匿名），数据仍在本地可见，只是不上传。
String? resolveDataOwner({
  required String currentOwnerId,
  required String newCloudId,
  required bool switched,
  required int localDayCount,
  bool? claimLocal,
}) {
  if (newCloudId.isEmpty) return null;
  if (switched) return newCloudId;
  if (currentOwnerId.isNotEmpty) return null;
  if (localDayCount == 0) return newCloudId;
  return claimLocal == true ? newCloudId : null;
}

/// 这次登录要不要弹「本机有 N 天记录，要并入吗」（坑 90）。
///
/// 只在「本机是匿名 + 有历史」时问一次；换号不问（换号跟着新账号走，
/// 逐天归属已经把各天分好了，不需要用户再做决定）。
bool needsClaimPrompt({
  required String currentOwnerId,
  required bool switched,
  required int localDayCount,
}) {
  if (switched) return false;
  return currentOwnerId.isEmpty && localDayCount > 0;
}

/// 这一天归不归当前账号（坑 90）。
///
/// 三条规则，顺序不能换：
///   ① 有逐天归属 ⇒ **只看那一天的归属**，与整机归属无关。
///      这是换号后新账号能正常上传、旧账号的天不被带走的关键。
///   ② 没有逐天归属（老数据 / 调用方没传） ⇒ 退回整机归属判定
///      （调用方已经过了 `dataBelongsTo`，所以这一层只处理「天」）。
///   ③ **今天不搞特例**（2026-10-19 修正，见下）。
///
/// —— 为什么去掉「今天永远用整机归属」这个特例 ——
///
/// 最初加它是想解决「换号当天，新账号记的量传不上去」。但那个特例的
/// 实际后果是：A 上午记了 500，下午换 B —— 今天这条记录的归属是 A，
/// 特例却让 B 把它传上去 ⇒ **A 的量以 B 的名义进了云端**。
/// 这正是本题要消灭的串号，不能为了「新账号当天有数据」把它放回来。
///
/// 两种取舍都有「混」的一面，区别在哪一侧：
///   · 保留特例 ⇒ 旧账号的量被**主动**送给新账号（更糟，不可接受）
///   · 去掉特例 ⇒ 新账号当天的量要等切回原账号才上传（保守，数据不丢）
/// 选后者：**宁可不传，不可送错**。同一天内换号的精确切分需要把粒度
/// 改成「(账号, 日期)」，那是另一个量级的改动（归 MT-06 一起考虑）。
bool _dayBelongsTo(
  String day,
  Map<String, String> dayOwners,
  String cloudId,
  String today,
) {
  final owner = dayOwners[day];
  if (owner == null) return true; // ② 没有逐天归属 ⇒ 信任整机归属（已判过）
  if (owner.isEmpty) return false; // 匿名天的数据不传，等显式认领
  return owner == cloudId; // ① 只看这一天的归属
}

/// 某一天是否**已经确认上传过**（决定它要不要进欠账集合）。
///
/// 两条规则并存，按账本是否存在切换：
///   · 有账本（[useSet]）：只看集合。与时间顺序无关。
///   · 没账本：旧版水位线规则 `k > reportedUpTo`，外加"今天永远要传"。
bool _alreadyUploaded(
  String day, {
  required Set<String> uploaded,
  required bool useSet,
  required String reportedUpTo,
  required String today,
}) {
  if (useSet) {
    // 今天例外：今天的数据还在涨，必须每轮覆盖上传（集合里有它也要再传）。
    if (day == today) return false;
    return uploaded.contains(day);
  }
  // 旧版：水位线之后的天 + 今天。水位线为空 = 一天都没传过。
  if (day == today) return false;
  if (reportedUpTo.isEmpty) return false;
  return day.compareTo(reportedUpTo) <= 0;
}

/// 解析"已上传的天集合"。坏数据一律当空集合（宁可多重传一次，不能永远不传）。
Set<String> parseUploadedDates(String json) {
  if (json.isEmpty) return <String>{};
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return <String>{};
    return {
      for (final e in decoded)
        if (e is String && e.length == 10) e,
    };
  } catch (_) {
    return <String>{};
  }
}

/// 把"这次成功上传的天"并入集合，返回新的 JSON（日期升序）。
///
/// **不做折叠、不设上限**，理由：折叠（"这天及以前全部传过"）会把"漏了
/// 其中某天"这种真实情况掩盖掉——而那正是本次要修的缺陷本身；条数上限
/// 则会让更早的漏天再次变成"永远补不回来"。日期串 10 字节 × 一年 365 天
/// ≈ 3.6 KB，cfg 只在批量补报成功时写一次，这个体量不值得为它引一个
/// 会丢信息的优化。实测见 `mt03_backfill_gap_test.dart` 的"集合不丢天"。
String mergeUploadedDates(String json, Iterable<String> uploaded) {
  final set = parseUploadedDates(json)..addAll(uploaded);
  if (set.isEmpty) return '';
  final sorted = set.toList()..sort();
  return jsonEncode(sorted);
}

/// 纠错：把**指定的一些天**重新排进欠账，返回新的账本。
///
/// 用途（MT-03 剩余项）：迁移是保守的——水位线左边**已经漏掉**的天它救不回来
/// （见 [migrateUploadedDates]）。这个函数就是那个出口：用户点「重新上传本机
/// 记录」时，把选定天的账本记录抹掉，它们就重新出现在 [uploadableDays] 里。
///
/// [days] 传 `null` 表示**本机全部**（"整个重传一遍"）。
///
/// 与 [migrateUploadedDates] 的区别：迁移是"猜"（按水位线推断），这里是
/// "用户说了算"——所以它不需要保守，也不需要合并，直接做减法。
String forgetUploadedDates({
  required String uploadedDatesJson,
  required Iterable<String> localKeys,
  Iterable<String>? days,
}) {
  final target = days == null ? localKeys.toSet() : days.toSet();
  if (target.isEmpty) return uploadedDatesJson;
  final kept = parseUploadedDates(uploadedDatesJson)..removeAll(target);
  // ⚠️ 必须返回 `'[]'` 而不是空串：空串在 uploadableDays 里表示"账本从未建立"
  // （退回旧水位线规则），而我们要表达的是"确认这些天还没传过"。这两个
  // 语义一旦混掉，纠错就会静默失效——正是坑 81 记下的那个坑。
  final sorted = kept.toList()..sort();
  return jsonEncode(sorted);
}

/// 对账结果（MT-03，2026-10-18）。
///
/// 为什么需要它：修好记账只保证「以后不漏」，**没法知道已经漏了什么**。
/// 迁移是保守的、纠错要用户自己想起来点，中间没有任何机制告诉用户
/// "你的本地和云端不一样了"。对账就是把这件事变成可见的。
class ReconcileReport {
  const ReconcileReport({
    required this.localOnly,
    required this.cloudOnly,
    required this.both,
  });

  /// 本地有、云端没有 —— **要补报的天**（补报沉底 / 纠错对象）。
  final List<String> localOnly;

  /// 云端有、本地没有 —— 换了设备或镜像没拉到；**不是错误，但要能看见**
  /// （很可能是另一台设备的天，本机不该去补它，否则会把别人的记录当自己的传）。
  final List<String> cloudOnly;

  /// 两边都有 —— 正常。
  final List<String> both;

  bool get isConsistent => localOnly.isEmpty && cloudOnly.isEmpty;
  int get localOnlyCount => localOnly.length;
  int get cloudOnlyCount => cloudOnly.length;
  int get bothCount => both.length;
}

/// 纯函数对账：[localKeys] 本机有的天，[cloudDates] 云端有的天。
///
/// 不做任何网络与落盘——判定与副作用分开，测试与调用方都省事。
ReconcileReport reconcileDays({
  required Iterable<String> localKeys,
  required Iterable<String> cloudDates,
}) {
  final local = localKeys.toSet();
  final cloud = cloudDates.toSet();
  final localOnly = [...local.difference(cloud)]..sort();
  final cloudOnly = [...cloud.difference(local)]..sort();
  final both = [...local.intersection(cloud)]..sort();
  return ReconcileReport(
    localOnly: localOnly,
    cloudOnly: cloudOnly,
    both: both,
  );
}

/// 老配置迁移：把"水位线"翻译成"已上传的天集合"。
///
/// **保守原则**：水位线之前的本地天一律视为已上传（那是旧版本的语义），
/// 于是迁移后的第一次同步不会突然把几年的历史全量重传一遍。代价是：
/// 水位线左边**已经漏掉**的天，这次迁移救不回来——那批数据要等用户下一次
/// 触发补报（MT-03 的人工纠错入口）才补，或者接受它已经丢了。
///
/// 想激进一点（宁可重传也把漏的补上）就反过来：返回 `'[]'`，让全部本地天
/// 都进欠账集合。**不做这个选择的原因**：一次重传几百天会打满服务端单次
/// 批量上限、也需要分多轮；而且老用户根本分不清"这几天是重传"还是"数据变了"。
/// 保守迁移只影响"以后不再漏"，不影响"以前已经漏的"。
String migrateUploadedDates({
  required Iterable<String> localKeys,
  required String reportedUpTo,
}) {
  if (reportedUpTo.isEmpty) return '[]';   // 从没传过 ⇒ 空账本，一切待传
  final known = <String>{
    for (final k in localKeys)
      if (k.compareTo(reportedUpTo) <= 0) k,
  };
  // 水位线那天本身也算已传（旧语义是 `k > 水位线` 才补，即水位线当天已传）
  known.add(reportedUpTo);
  final sorted = known.toList()..sort();
  return jsonEncode(sorted);
}
