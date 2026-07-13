import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NoPoiApp());
  unawaited(
    NotificationService.instance.init().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'nopoi notifications',
          context: ErrorDescription('while initializing local notifications'),
        ),
      );
    }),
  );
}

class NoPoiApp extends StatelessWidget {
  const NoPoiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoPoi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff75b98b)),
        useMaterial3: true,
        fontFamily: 'sans',
      ),
      home: const NoPoiHome(),
    );
  }
}

enum AppPage { choice, task, expense, expenseHistory, subscription, home, poi }

class NoPoiHome extends StatefulWidget {
  const NoPoiHome({super.key});

  @override
  State<NoPoiHome> createState() => _NoPoiHomeState();
}

class _NoPoiHomeState extends State<NoPoiHome> with TickerProviderStateMixin {
  static const _storageKey = 'nopoi_flutter_state_v1';
  final _taskController = TextEditingController();
  final _amountController = TextEditingController();
  final _otherExpenseController = TextEditingController();
  final _paperKey = GlobalKey();
  final _trashKey = GlobalKey();

  AppPage _page = AppPage.choice;
  DateTime? _notifyAt;
  String _expenseKind = '食費';
  List<NopoiTask> _tasks = [];
  List<NopoiTask> _poiTasks = [];
  List<NopoiTask> _doneTasks = [];
  List<ExpenseItem> _expenses = [];
  List<Subscription> _subscriptions = [];
  final Set<String> _checkedTaskIds = {};
  Offset? _paperStart;
  Offset? _paperEnd;
  late AnimationController _paperController;

  @override
  void initState() {
    super.initState();
    _paperController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _load();
  }

  @override
  void dispose() {
    _taskController.dispose();
    _amountController.dispose();
    _otherExpenseController.dispose();
    _paperController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null) return;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    setState(() {
      _tasks = (data['tasks'] as List? ?? [])
          .map((e) => NopoiTask.fromJson(e))
          .toList();
      _poiTasks = (data['poiTasks'] as List? ?? [])
          .map((e) => NopoiTask.fromJson(e))
          .toList();
      _doneTasks = (data['doneTasks'] as List? ?? [])
          .map((e) => NopoiTask.fromJson(e))
          .toList();
      _expenses = (data['expenses'] as List? ?? [])
          .map((e) => ExpenseItem.fromJson(e))
          .toList();
      _subscriptions = (data['subscriptions'] as List? ?? [])
          .map((e) => Subscription.fromJson(e))
          .toList();
    });
    await _recordDueSubscriptions();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode({
        'tasks': _tasks.map((e) => e.toJson()).toList(),
        'poiTasks': _poiTasks.map((e) => e.toJson()).toList(),
        'doneTasks': _doneTasks.map((e) => e.toJson()).toList(),
        'expenses': _expenses.map((e) => e.toJson()).toList(),
        'subscriptions': _subscriptions.map((e) => e.toJson()).toList(),
      }),
    );
  }

  // タスク入力欄にこの文字列を入力して追加すると、保存データの初期化を確認する。
  static const _resetCommand = 'asdfghjkl;:]';

  Future<void> _addTask() async {
    final text = _taskController.text.trim();
    if (text.isEmpty) return;
    if (text == _resetCommand) {
      _taskController.clear();
      await _confirmAndResetAllData();
      return;
    }
    final task = NopoiTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      text: text,
      notifyAt: _notifyAt,
      createdAt: DateTime.now(),
    );
    setState(() {
      _tasks.insert(0, task);
      _taskController.clear();
      _notifyAt = null;
    });
    await _save();
    if (task.notifyAt != null && task.notifyAt!.isAfter(DateTime.now())) {
      await NotificationService.instance.scheduleTask(task);
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タスクを追加しました')));
    }
  }

  Future<void> _confirmAndResetAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('データを初期化しますか？'),
        content: const Text(
          'タスク・Poiリスト・完了済みタスク・収支の記録をすべて削除します。\nこの操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffc4565d),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('初期化する'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _resetAllData();
    }
  }

  Future<void> _resetAllData() async {
    // 通知が残らないよう、タスクに紐づく予定済み通知をすべてキャンセルする。
    for (final task in _tasks) {
      await NotificationService.instance.cancelTask(task);
    }
    setState(() {
      _tasks = [];
      _poiTasks = [];
      _doneTasks = [];
      _expenses = [];
      _subscriptions = [];
      _checkedTaskIds.clear();
      _notifyAt = null;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('データを初期化しました')));
    }
  }

  Future<void> _selectNotifyAt() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _notifyAt ?? now,
      firstDate: now,
      lastDate: DateTime(now.year + 3),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _notifyAt ?? now.add(const Duration(minutes: 5)),
      ),
    );
    if (time == null) return;
    setState(() {
      _notifyAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _addExpense() async {
    final rawAmount = int.tryParse(_amountController.text.trim());
    if (rawAmount == null || rawAmount == 0) return;
    // 金額は常に絶対値で保存する。収入/支出の区別は kind（内容）で判定する。
    final amount = rawAmount.abs();
    final kind =
        _expenseKind == 'その他' && _otherExpenseController.text.trim().isNotEmpty
        ? _otherExpenseController.text.trim()
        : _expenseKind;
    setState(() {
      _expenses.insert(
        0,
        ExpenseItem(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          amount: amount,
          kind: kind,
          createdAt: DateTime.now(),
        ),
      );
      _amountController.clear();
      _otherExpenseController.clear();
    });
    await _save();
  }

  Future<void> _recordDueSubscriptions() async {
    final now = DateTime.now();
    var changed = false;
    final added = <Subscription>[];
    setState(() {
      for (var i = 0; i < _subscriptions.length; i++) {
        final subscription = _subscriptions[i];
        if (!subscription.isActive) continue;
        var month = DateTime(
          subscription.startMonth.year,
          subscription.startMonth.month,
        );
        final currentMonth = DateTime(now.year, now.month);
        var lastRecorded = subscription.lastRecordedYearMonth;
        while (!month.isAfter(currentMonth)) {
          final dueDate = subscription.billingDateFor(month.year, month.month);
          final yearMonth = Subscription.yearMonth(month);
          final alreadyRecorded = _expenses.any(
            (item) =>
                item.subscriptionId == subscription.id &&
                Subscription.yearMonth(item.createdAt) == yearMonth,
          );
          if (!dueDate.isAfter(now) && !alreadyRecorded) {
            _expenses.insert(
              0,
              ExpenseItem(
                id: 'subscription_${subscription.id}_$yearMonth',
                amount: subscription.amount,
                kind: subscription.category,
                title: subscription.name,
                sourceType: 'subscription',
                subscriptionId: subscription.id,
                createdAt: dueDate,
              ),
            );
            lastRecorded = yearMonth;
            changed = true;
            added.add(subscription);
          }
          month = DateTime(month.year, month.month + 1);
        }
        if (lastRecorded != subscription.lastRecordedYearMonth) {
          _subscriptions[i] = subscription.copyWith(
            lastRecordedYearMonth: lastRecorded,
          );
          changed = true;
        }
      }
    });
    if (changed) await _save();
    for (final subscription in added.where(
      (item) => item.notificationEnabled,
    )) {
      await NotificationService.instance.showSubscriptionRecorded(subscription);
    }
  }

  Future<void> _saveSubscription(Subscription subscription) async {
    setState(() {
      final index = _subscriptions.indexWhere(
        (item) => item.id == subscription.id,
      );
      if (index == -1) {
        _subscriptions.insert(0, subscription);
      } else {
        _subscriptions[index] = subscription;
      }
    });
    await _save();
    await _recordDueSubscriptions();
  }

  Future<void> _toggleSubscription(Subscription subscription) async {
    await _saveSubscription(
      subscription.copyWith(isActive: !subscription.isActive),
    );
  }

  Future<void> _deleteSubscription(Subscription subscription) async {
    setState(
      () => _subscriptions.removeWhere((item) => item.id == subscription.id),
    );
    await _save();
  }

  Future<void> _showSubscriptionEditor([Subscription? existing]) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final amount = TextEditingController(
      text: existing?.amount.toString() ?? '',
    );
    final memo = TextEditingController(text: existing?.memo ?? '');
    var billingDay = existing?.billingDay ?? DateTime.now().day;
    var category = existing?.category ?? '娯楽';
    var notificationEnabled = existing?.notificationEnabled ?? false;
    var startMonth =
        existing?.startMonth ??
        DateTime(DateTime.now().year, DateTime.now().month);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'サブスクを追加' : 'サブスクを編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'サービス名'),
                ),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '月額料金（円）'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  initialValue: billingDay,
                  decoration: const InputDecoration(labelText: '引き落とし日'),
                  items: List.generate(
                    31,
                    (i) => DropdownMenuItem(
                      value: i + 1,
                      child: Text('毎月${i + 1}日'),
                    ),
                  ),
                  onChanged: (value) =>
                      setDialogState(() => billingDay = value!),
                ),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'カテゴリ'),
                  items:
                      const ['食費', '交通費', '勉強', '遊び', '日用品', '娯楽', '生活費', 'その他']
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(),
                  onChanged: (value) => setDialogState(() => category = value!),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('開始月: ${startMonth.year}年${startMonth.month}月'),
                  trailing: const Icon(Icons.calendar_month),
                  onTap: () async {
                    final selected = await showDatePicker(
                      context: context,
                      initialDate: startMonth,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (selected != null)
                      setDialogState(
                        () => startMonth = DateTime(
                          selected.year,
                          selected.month,
                        ),
                      );
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自動登録時に通知'),
                  value: notificationEnabled,
                  onChanged: (value) =>
                      setDialogState(() => notificationEnabled = value),
                ),
                TextField(
                  controller: memo,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'メモ（任意）'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty ||
                    (int.tryParse(amount.text.trim()) ?? 0) < 1)
                  return;
                Navigator.pop(context, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _saveSubscription(
        Subscription(
          id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
          name: name.text.trim(),
          amount: int.parse(amount.text.trim()),
          billingDay: billingDay,
          category: category,
          memo: memo.text.trim(),
          notificationEnabled: notificationEnabled,
          startMonth: startMonth,
          isActive: existing?.isActive ?? true,
          lastRecordedYearMonth: existing?.lastRecordedYearMonth,
          createdAt: existing?.createdAt ?? DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    }
    name.dispose();
    amount.dispose();
    memo.dispose();
  }

  Future<void> _poiTask(NopoiTask task) async {
    _setPaperFlight();
    await _paperController.forward(from: 0);
    if (!mounted) return;
    setState(() {
      _paperStart = null;
      _paperEnd = null;
      _tasks.removeWhere((item) => item.id == task.id);
      _poiTasks.insert(0, task.copyWith(movedAt: DateTime.now()));
    });
    await NotificationService.instance.cancelTask(task);
    await _save();
  }

  Future<void> _doneTask(NopoiTask task) async {
    setState(() => _checkedTaskIds.add(task.id));
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() {
      _tasks.removeWhere((item) => item.id == task.id);
      _checkedTaskIds.remove(task.id);
      _doneTasks.insert(0, task.copyWith(movedAt: DateTime.now()));
    });
    await NotificationService.instance.cancelTask(task);
    await _save();
  }

  void _setPaperFlight() {
    final paperBox = _paperKey.currentContext?.findRenderObject() as RenderBox?;
    final trashBox = _trashKey.currentContext?.findRenderObject() as RenderBox?;
    if (paperBox == null || trashBox == null) return;
    final start = paperBox.localToGlobal(paperBox.size.center(Offset.zero));
    final end = trashBox.localToGlobal(trashBox.size.center(Offset.zero));
    setState(() {
      _paperStart = start;
      _paperEnd = end;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff5faf6),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _Header(onChoice: () => setState(() => _page = AppPage.choice)),
                Expanded(child: _buildPage()),
              ],
            ),
            if (_paperStart != null && _paperEnd != null)
              AnimatedBuilder(
                animation: _paperController,
                builder: (context, child) {
                  final t = Curves.easeInOutCubic.transform(
                    _paperController.value,
                  );
                  final arc = sin(t * pi) * -90;
                  final pos =
                      Offset.lerp(_paperStart, _paperEnd, t)! + Offset(0, arc);
                  return Positioned(
                    left: pos.dx - 18,
                    top: pos.dy - 18,
                    child: Transform.rotate(
                      angle: t * pi * 4,
                      child: Opacity(
                        opacity: 1 - (t * .7),
                        child: const CrumpledPaper(size: 42),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage() {
    switch (_page) {
      case AppPage.choice:
        return _ChoicePage(onGo: (page) => setState(() => _page = page));
      case AppPage.task:
        return _TaskPage(
          controller: _taskController,
          notifyAt: _notifyAt,
          riskText: _riskText(),
          onPickDate: _selectNotifyAt,
          onAdd: _addTask,
          onHome: () => setState(() => _page = AppPage.home),
        );
      case AppPage.expense:
        return _ExpensePage(
          amountController: _amountController,
          otherController: _otherExpenseController,
          expenseKind: _expenseKind,
          onKindChanged: (value) => setState(() => _expenseKind = value),
          onAdd: _addExpense,
          onHome: () => setState(() => _page = AppPage.home),
        );
      case AppPage.expenseHistory:
        return _ExpenseHistoryPage(
          expenses: _expenses,
          onHome: () => setState(() => _page = AppPage.home),
          onExpense: () => setState(() => _page = AppPage.expense),
        );
      case AppPage.subscription:
        return _SubscriptionPage(
          subscriptions: _subscriptions,
          onHome: () => setState(() => _page = AppPage.home),
          onAdd: () => _showSubscriptionEditor(),
          onEdit: _showSubscriptionEditor,
          onToggle: _toggleSubscription,
          onDelete: _deleteSubscription,
        );
      case AppPage.home:
        return _MainPage(
          tasks: _tasks,
          expenses: _expenses,
          poiCount: _poiTasks.length,
          checkedIds: _checkedTaskIds,
          onExpense: () => setState(() => _page = AppPage.expense),
          onExpenseHistory: () =>
              setState(() => _page = AppPage.expenseHistory),
          onSubscription: () => setState(() => _page = AppPage.subscription),
          onTask: () => setState(() => _page = AppPage.task),
          onPoiList: () => setState(() => _page = AppPage.poi),
          onPoi: _poiTask,
          onDone: _doneTask,
          trashKey: _trashKey,
          paperKey: _paperKey,
        );
      case AppPage.poi:
        return _PoiPage(
          poiTasks: _poiTasks,
          doneTasks: _doneTasks,
          onHome: () => setState(() => _page = AppPage.home),
          onTask: () => setState(() => _page = AppPage.task),
        );
    }
  }

  String _riskText() {
    final text = _taskController.text.trim();
    final similar = text.isEmpty
        ? 0
        : _poiTasks
              .where(
                (task) => task.text.contains(text) || text.contains(task.text),
              )
              .length;
    if (similar >= 2 || _poiTasks.length >= 10) {
      return '危険度: 高 - 似たタスクがPoiされがちです。小さく分けると成功しやすいかも。';
    }
    if (similar == 1 || _poiTasks.length >= 5) {
      return '危険度: 中 - Poiが少し増えています。通知日時を近めにすると安心です。';
    }
    if (_poiTasks.isNotEmpty) {
      return '危険度: 低 - Poi履歴はありますが、このタスクはまだ大丈夫そうです。';
    }
    return '危険度: 低 - まだPoi傾向はありません。';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onChoice});
  final VoidCallback onChoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xfffffdf8).withValues(alpha: .92),
        border: const Border(bottom: BorderSide(color: Color(0xffd8e1e5))),
      ),
      child: Row(
        children: [
          const Text(
            'NoPoi',
            style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '投げ出さないための\nちいさな管理部屋',
              style: TextStyle(color: Color(0xff6b7880), height: 1.25),
            ),
          ),
          OutlinedButton(onPressed: onChoice, child: const Text('選択画面')),
        ],
      ),
    );
  }
}

class _ChoicePage extends StatelessWidget {
  const _ChoicePage({required this.onGo});
  final ValueChanged<AppPage> onGo;

  @override
  Widget build(BuildContext context) {
    // 4枚のカードを横並びにするには十分な幅が必要。
    final wide = MediaQuery.of(context).size.width > 1000;
    final cards = [
      _ChoiceCard(
        'タスク管理',
        'やることと通知日時を決めて追加します。',
        Icons.checklist,
        () => onGo(AppPage.task),
        const Color(0xffe9f7ef),
      ),
      _ChoiceCard(
        '支出管理',
        '支出や収入を正負の金額で記録します。',
        Icons.payments_outlined,
        () => onGo(AppPage.expense),
        const Color(0xfffff0d0),
      ),
      _ChoiceCard(
        'メイン画面',
        'ウサギの部屋、Task、Poiリストを確認します。',
        Icons.home_outlined,
        () => onGo(AppPage.home),
        const Color(0xffe8f2ff),
      ),
      _ChoiceCard(
        'サブスク管理',
        '月額料金を毎月の支出に自動で記録します。',
        Icons.autorenew,
        () => onGo(AppPage.subscription),
        const Color(0xffffe8f0),
      ),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: wide
              ? Row(
                  children: cards
                      .map(
                        (card) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: card,
                          ),
                        ),
                      )
                      .toList(),
                )
              : SingleChildScrollView(
                  child: Column(
                    children: cards
                        .map(
                          (card) => Padding(
                            padding: const EdgeInsets.all(8),
                            child: card,
                          ),
                        )
                        .toList(),
                  ),
                ),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard(this.title, this.body, this.icon, this.onTap, this.color);
  final String title;
  final String body;
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Ink(
        height: 210,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xffd8e1e5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 36),
            const Spacer(),
            Text(
              title,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: const TextStyle(color: Color(0xff6b7880), height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskPage extends StatelessWidget {
  const _TaskPage({
    required this.controller,
    required this.notifyAt,
    required this.riskText,
    required this.onPickDate,
    required this.onAdd,
    required this.onHome,
  });

  final TextEditingController controller;
  final DateTime? notifyAt;
  final String riskText;
  final VoidCallback onPickDate;
  final VoidCallback onAdd;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    return _FormShell(
      title: 'タスク管理',
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xfffff6da),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xffedd386)),
          ),
          child: Text(riskText),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'タスク内容',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: onPickDate,
          icon: const Icon(Icons.notifications_active_outlined),
          label: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              notifyAt == null ? '通知日時を決める' : '通知: ${formatDate(notifyAt!)}',
            ),
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton(onPressed: onAdd, child: const Text('追加する')),
            OutlinedButton(onPressed: onHome, child: const Text('メイン画面')),
          ],
        ),
      ],
    );
  }
}

class _ExpensePage extends StatelessWidget {
  const _ExpensePage({
    required this.amountController,
    required this.otherController,
    required this.expenseKind,
    required this.onKindChanged,
    required this.onAdd,
    required this.onHome,
  });

  final TextEditingController amountController;
  final TextEditingController otherController;
  final String expenseKind;
  final ValueChanged<String> onKindChanged;
  final VoidCallback onAdd;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    const kinds = ['食費', '交通費', '勉強', '遊び', '日用品', '収入', 'その他'];
    return _FormShell(
      title: '収支管理',
      children: [
        TextField(
          controller: amountController,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          decoration: const InputDecoration(
            labelText: '金額',
            helperText: '金額は正の数で入力してください',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: expenseKind,
          decoration: const InputDecoration(
            labelText: '内容',
            border: OutlineInputBorder(),
          ),
          items: kinds
              .map((kind) => DropdownMenuItem(value: kind, child: Text(kind)))
              .toList(),
          onChanged: (value) {
            if (value != null) onKindChanged(value);
          },
        ),
        if (expenseKind == 'その他') ...[
          const SizedBox(height: 14),
          TextField(
            controller: otherController,
            decoration: const InputDecoration(
              labelText: 'その他の内容',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton(onPressed: onAdd, child: const Text('記録する')),
            OutlinedButton(onPressed: onHome, child: const Text('メイン画面')),
          ],
        ),
      ],
    );
  }
}

class _FormShell extends StatelessWidget {
  const _FormShell({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xfffffdf8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xffd8e1e5)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 18),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MainPage extends StatelessWidget {
  const _MainPage({
    required this.tasks,
    required this.expenses,
    required this.poiCount,
    required this.checkedIds,
    required this.onExpense,
    required this.onExpenseHistory,
    required this.onSubscription,
    required this.onTask,
    required this.onPoiList,
    required this.onPoi,
    required this.onDone,
    required this.trashKey,
    required this.paperKey,
  });

  final List<NopoiTask> tasks;
  final List<ExpenseItem> expenses;
  final int poiCount;
  final Set<String> checkedIds;
  final VoidCallback onExpense;
  final VoidCallback onExpenseHistory;
  final VoidCallback onSubscription;
  final VoidCallback onTask;
  final VoidCallback onPoiList;
  final ValueChanged<NopoiTask> onPoi;
  final ValueChanged<NopoiTask> onDone;
  final GlobalKey trashKey;
  final GlobalKey paperKey;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 900;
    final content = [
      _TaskPanel(
        tasks: tasks,
        checkedIds: checkedIds,
        onPoi: onPoi,
        onDone: onDone,
        paperKey: paperKey,
      ),
      _RoomPanel(poiCount: poiCount, onPoiList: onPoiList, trashKey: trashKey),
      _MoneyPanel(
        expenses: expenses,
        poiCount: poiCount,
        onExpense: onExpense,
        onExpenseHistory: onExpenseHistory,
        onSubscription: onSubscription,
        onTask: onTask,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.all(14),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 330, child: content[0]),
                const SizedBox(width: 14),
                Expanded(child: content[1]),
                const SizedBox(width: 14),
                SizedBox(width: 270, child: content[2]),
              ],
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: SizedBox(height: 320, child: content[0]),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: SizedBox(height: 470, child: content[1]),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: SizedBox(height: 420, child: content[2]),
                ),
              ],
            ),
    );
  }
}

class _TaskPanel extends StatelessWidget {
  const _TaskPanel({
    required this.tasks,
    required this.checkedIds,
    required this.onPoi,
    required this.onDone,
    required this.paperKey,
  });
  final List<NopoiTask> tasks;
  final Set<String> checkedIds;
  final ValueChanged<NopoiTask> onPoi;
  final ValueChanged<NopoiTask> onDone;
  final GlobalKey paperKey;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Task',
      child: tasks.isEmpty
          ? const Text(
              'まだタスクがありません。',
              style: TextStyle(color: Color(0xff6b7880)),
            )
          : ListView.separated(
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final task = tasks[index];
                final checked = checkedIds.contains(task.id);
                return Container(
                  key: index == 0 ? paperKey : null,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xffd8e1e5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: checked
                                ? const Icon(
                                    Icons.check_box,
                                    key: ValueKey('checked'),
                                    color: Color(0xff278554),
                                  )
                                : const Icon(
                                    Icons.check_box_outline_blank,
                                    key: ValueKey('blank'),
                                    color: Color(0xffb7c3c7),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              task.text,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        task.notifyAt == null
                            ? '通知: 未設定'
                            : '通知: ${formatDate(task.notifyAt!)}',
                        style: const TextStyle(
                          color: Color(0xff6b7880),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => onPoi(task),
                              child: const Text('Poi'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => onDone(task),
                              child: const Text('Done'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _RoomPanel extends StatelessWidget {
  const _RoomPanel({
    required this.poiCount,
    required this.onPoiList,
    required this.trashKey,
  });
  final int poiCount;
  final VoidCallback onPoiList;
  final GlobalKey trashKey;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: RoomPainter(poiCount))),
          Align(
            alignment: const Alignment(.05, .55),
            child: CustomPaint(
              size: const Size(170, 210),
              painter: RabbitPainter(),
            ),
          ),
          Positioned(
            right: 34,
            bottom: 52,
            child: GestureDetector(
              key: trashKey,
              onTap: onPoiList,
              child: CustomPaint(
                size: const Size(138, 132),
                painter: TrashCanPainter(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoneyPanel extends StatelessWidget {
  const _MoneyPanel({
    required this.expenses,
    required this.poiCount,
    required this.onExpense,
    required this.onExpenseHistory,
    required this.onSubscription,
    required this.onTask,
  });
  final List<ExpenseItem> expenses;
  final int poiCount;
  final VoidCallback onExpense;
  final VoidCallback onExpenseHistory;
  final VoidCallback onSubscription;
  final VoidCallback onTask;

  @override
  Widget build(BuildContext context) {
    final incomeTotal = expenses
        .where((item) => item.isIncome)
        .fold<int>(0, (sum, item) => sum + item.amount.abs());
    final expenseTotal = expenses
        .where((item) => !item.isIncome)
        .fold<int>(0, (sum, item) => sum + item.amount.abs());
    final balance = incomeTotal - expenseTotal;
    final balanceColor = balance > 0
        ? const Color(0xff278554)
        : balance < 0
        ? const Color(0xffc4565d)
        : const Color(0xff6b7880);
    return _Panel(
      title: '',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 0, 2, 0),
        children: [
          FilledButton(onPressed: onExpense, child: const Text('収支管理')),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onSubscription,
            icon: const Icon(Icons.autorenew),
            label: const Text('サブスク管理'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onTask, child: const Text('タスク追加')),
          const SizedBox(height: 12),
          _StatBox(
            label: '残高（収支）',
            value: formatSignedAmount(balance),
            valueColor: balanceColor,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatBox(
                  label: '収入合計',
                  value: '$incomeTotal円',
                  valueColor: const Color(0xff278554),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatBox(
                  label: '支出合計',
                  value: '$expenseTotal円',
                  valueColor: const Color(0xffc4565d),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _StatBox(label: 'Poiされた数', value: '$poiCount'),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '最近の収支',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'Roboto',
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed: onExpenseHistory,
                  child: const Text('収支履歴'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (expenses.isEmpty)
            const Text(
              '収支管理から記録できます。',
              style: TextStyle(color: Color(0xff6b7880)),
            )
          else
            ...expenses
                .take(5)
                .map(
                  (item) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xffd8e1e5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item.isIncome ? '+' : '-'}${item.amount.abs()}円',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: item.isIncome
                                ? const Color(0xff278554)
                                : const Color(0xffc4565d),
                          ),
                        ),
                        Text(
                          '${item.title ?? item.kind} / ${formatDate(item.createdAt)}${item.sourceType == 'subscription' ? ' / サブスク' : ''}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff6b7880),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _SubscriptionPage extends StatelessWidget {
  const _SubscriptionPage({
    required this.subscriptions,
    required this.onHome,
    required this.onAdd,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });
  final List<Subscription> subscriptions;
  final VoidCallback onHome;
  final VoidCallback onAdd;
  final ValueChanged<Subscription> onEdit;
  final ValueChanged<Subscription> onToggle;
  final ValueChanged<Subscription> onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Expanded(
            child: _Panel(
              title: 'サブスク管理',
              child: subscriptions.isEmpty
                  ? const Text(
                      'サブスクを追加すると、指定日に支出へ自動記録します。',
                      style: TextStyle(color: Color(0xff6b7880)),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: subscriptions.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final item = subscriptions[index];
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xffd8e1e5)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.name,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                  Chip(
                                    label: Text(item.isActive ? '有効' : '停止中'),
                                  ),
                                ],
                              ),
                              Text('${item.amount}円 / 月　・　${item.category}'),
                              const SizedBox(height: 4),
                              Text(
                                '次回: ${formatDate(item.nextBillingDate(DateTime.now()))}　通知: ${item.notificationEnabled ? 'ON' : 'OFF'}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff6b7880),
                                ),
                              ),
                              if (item.memo.isNotEmpty)
                                Text(
                                  item.memo,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xff6b7880),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: () => onEdit(item),
                                    child: const Text('編集'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () => onToggle(item),
                                    child: Text(item.isActive ? '停止' : '再開'),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      final ok = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('サブスクを削除しますか？'),
                                          content: const Text(
                                            '過去に記録された支出履歴は削除されません。',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('キャンセル'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(context, true),
                                              child: const Text('削除'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok == true) onDelete(item);
                                    },
                                    child: const Text('削除'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton(onPressed: onHome, child: const Text('メイン画面')),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('サブスクを追加'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExpenseHistoryPage extends StatelessWidget {
  const _ExpenseHistoryPage({
    required this.expenses,
    required this.onHome,
    required this.onExpense,
  });

  final List<ExpenseItem> expenses;
  final VoidCallback onHome;
  final VoidCallback onExpense;

  @override
  Widget build(BuildContext context) {
    final summaries = buildMonthlyExpenseSummaries(expenses);
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Expanded(
            child: _Panel(
              title: '収支履歴',
              child: _ExpenseHistoryList(expenses: expenses),
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _Panel(
              title: '月別分析',
              child: _ExpenseAnalysisPanel(summaries: summaries),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton(onPressed: onHome, child: const Text('メイン画面')),
              FilledButton(onPressed: onExpense, child: const Text('収支管理')),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExpenseHistoryList extends StatelessWidget {
  const _ExpenseHistoryList({required this.expenses});
  final List<ExpenseItem> expenses;

  @override
  Widget build(BuildContext context) {
    if (expenses.isEmpty) {
      return const Text(
        'まだ収支履歴がありません。',
        style: TextStyle(color: Color(0xff6b7880)),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: expenses.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = expenses[index];
        final isIncome = item.kind == '収入';
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xffd8e1e5)),
          ),
          child: Row(
            children: [
              Icon(
                isIncome ? Icons.trending_up : Icons.payments_outlined,
                color: isIncome
                    ? const Color(0xff278554)
                    : const Color(0xffc4565d),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title == null
                          ? '${item.amount}円'
                          : '${item.title}　${item.amount}円',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: isIncome
                            ? const Color(0xff278554)
                            : const Color(0xffc4565d),
                      ),
                    ),
                    Text(
                      '${item.kind} / ${formatDate(item.createdAt)}${item.sourceType == 'subscription' ? ' / サブスク' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff6b7880),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ExpenseAnalysisPanel extends StatelessWidget {
  const _ExpenseAnalysisPanel({required this.summaries});
  final List<MonthlyExpenseSummary> summaries;

  @override
  Widget build(BuildContext context) {
    if (summaries.isEmpty) {
      return const Text(
        '収支を記録すると月別の集計が表示されます。',
        style: TextStyle(color: Color(0xff6b7880)),
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ...summaries.map((summary) => _MonthlySummaryCard(summary: summary)),
        const SizedBox(height: 14),
        const Text(
          '月別収支グラフ',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const _TrendLegend(),
        const SizedBox(height: 8),
        SizedBox(
          height: 150,
          child: CustomPaint(
            painter: ExpenseTrendPainter(summaries.take(6).toList()),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class _MonthlySummaryCard extends StatelessWidget {
  const _MonthlySummaryCard({required this.summary});
  final MonthlyExpenseSummary summary;

  @override
  Widget build(BuildContext context) {
    final balanceColor = summary.balance > 0
        ? const Color(0xff278554)
        : summary.balance < 0
        ? const Color(0xffc4565d)
        : const Color(0xff6b7880);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd8e1e5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  summary.label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '収支 ${formatSignedAmount(summary.balance)}',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: balanceColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SummaryRow(
            label: '収入',
            total: summary.incomeTotal,
            delta: summary.incomeDelta,
            percentChange: summary.incomePercentChange,
            color: const Color(0xff278554),
          ),
          const SizedBox(height: 6),
          _SummaryRow(
            label: '支出',
            total: summary.expenseTotal,
            delta: summary.expenseDelta,
            percentChange: summary.expensePercentChange,
            color: const Color(0xffc4565d),
            invertDeltaColor: true,
          ),
          const SizedBox(height: 6),
          _SummaryRow(
            label: '収支',
            total: summary.balance,
            delta: summary.balanceDelta,
            percentChange: summary.balancePercentChange,
            color: balanceColor,
          ),
          if (summary.categoryTotals.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: summary.categoryTotals.entries
                  .map(
                    (entry) =>
                        _CategoryChip(label: entry.key, amount: entry.value),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.total,
    required this.delta,
    required this.percentChange,
    required this.color,
    this.invertDeltaColor = false,
  });

  final String label;
  final int total;
  final int delta;
  final double? percentChange;
  final Color color;
  final bool invertDeltaColor;

  @override
  Widget build(BuildContext context) {
    final rawUp = delta > 0;
    final rawDown = delta < 0;
    final deltaColor = delta == 0
        ? const Color(0xff6b7880)
        : (invertDeltaColor ? rawDown : rawUp)
        ? const Color(0xff278554)
        : const Color(0xffc4565d);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 42,
          child: Text(
            label,
            style: TextStyle(fontWeight: FontWeight.w700, color: color),
          ),
        ),
        Expanded(
          child: Text(
            '$total円',
            style: TextStyle(fontWeight: FontWeight.w800, color: color),
          ),
        ),
        Text(
          '前月比 ${formatSignedAmount(delta)} / ${formatPercent(percentChange)}',
          style: TextStyle(fontSize: 12, color: deltaColor),
        ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.amount});
  final String label;
  final int amount;

  @override
  Widget build(BuildContext context) {
    return const SizedBox();
  }
}

class MonthlyExpenseSummary {
  MonthlyExpenseSummary({
    required this.month,
    required this.incomeTotal,
    required this.expenseTotal,
    required this.balance,
    required this.incomeDelta,
    required this.expenseDelta,
    required this.balanceDelta,
    required this.incomePercentChange,
    required this.expensePercentChange,
    required this.balancePercentChange,
    required this.categoryTotals,
  });

  final DateTime month;

  /// その月の収入合計。
  final int incomeTotal;

  /// その月の支出合計。
  final int expenseTotal;

  /// その月の収支（収入 - 支出）。
  final int balance;

  final int incomeDelta;
  final int expenseDelta;
  final int balanceDelta;

  final double? incomePercentChange;
  final double? expensePercentChange;
  final double? balancePercentChange;

  final Map<String, int> categoryTotals;

  String get label => '${month.year}/${month.month.toString().padLeft(2, '0')}';
}

class ExpenseTrendPainter extends CustomPainter {
  ExpenseTrendPainter(List<MonthlyExpenseSummary> summaries)
    : summaries = summaries.reversed.toList();

  final List<MonthlyExpenseSummary> summaries;

  static const incomeColor = Color(0xff278554);
  static const expenseColor = Color(0xffc4565d);
  static const balanceColor = Color(0xff3d6fb4);

  @override
  void paint(Canvas canvas, Size size) {
    if (summaries.isEmpty) return;
    final axis = Paint()
      ..color = const Color(0xffd8e1e5)
      ..strokeWidth = 1.5;
    final incomeBar = Paint()..color = incomeColor;
    final expenseBar = Paint()..color = expenseColor;
    final balanceLine = Paint()
      ..color = balanceColor
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final balanceDot = Paint()..color = balanceColor;
    final textPainter = TextPainter(
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    const bottom = 18.0;
    const top = 8.0;
    final chartHeight = size.height - bottom - top;

    // 収入は上向き、支出は下向きに伸ばすため、中央をゼロラインとして
    // 上半分に収入、下半分に支出を描画する。
    final maxTotal = summaries
        .expand((s) => [s.incomeTotal, s.expenseTotal])
        .fold<int>(0, max)
        .clamp(1, 1 << 31);

    final zeroY = top + chartHeight * 0.5;
    final halfHeight = chartHeight * 0.5;

    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), axis);

    final slot = size.width / summaries.length;
    final balancePoints = <Offset>[];

    for (var i = 0; i < summaries.length; i++) {
      final summary = summaries[i];
      final groupLeft = slot * i + slot * .12;
      final groupWidth = slot * .76;
      final barWidth = groupWidth * .44;

      // 収入バー：ゼロラインから上向きに伸びる。
      final incomeHeight = halfHeight * (summary.incomeTotal / maxTotal);
      final incomeRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(groupLeft, zeroY - incomeHeight, barWidth, incomeHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(incomeRect, incomeBar);

      // 支出バー：ゼロラインから下向きに伸びる。
      final expenseHeight = halfHeight * (summary.expenseTotal / maxTotal);
      final expenseRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          groupLeft + barWidth + groupWidth * .06,
          zeroY,
          barWidth,
          expenseHeight,
        ),
        const Radius.circular(4),
      );
      canvas.drawRRect(expenseRect, expenseBar);

      // 収支の折れ線は、プラスなら上向き、マイナスなら下向きに合わせて表示する。
      final balanceHeight = halfHeight * (summary.balance / maxTotal);
      final balanceX = slot * i + slot * .5;
      final balanceY = zeroY - balanceHeight;
      balancePoints.add(Offset(balanceX, balanceY));

      textPainter.text = TextSpan(
        text: '${summary.month.month}月',
        style: const TextStyle(fontSize: 10, color: Color(0xff6b7880)),
      );
      textPainter.layout(maxWidth: slot);
      textPainter.paint(
        canvas,
        Offset(slot * i + (slot - textPainter.width) / 2, size.height - 14),
      );
    }

    for (var i = 0; i < balancePoints.length - 1; i++) {
      canvas.drawLine(balancePoints[i], balancePoints[i + 1], balanceLine);
    }
    for (final point in balancePoints) {
      canvas.drawCircle(point, 3, balanceDot);
    }
  }

  @override
  bool shouldRepaint(ExpenseTrendPainter oldDelegate) =>
      oldDelegate.summaries != summaries;
}

class _TrendLegend extends StatelessWidget {
  const _TrendLegend();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        _LegendItem(color: ExpenseTrendPainter.incomeColor, label: '収入'),
        _LegendItem(color: ExpenseTrendPainter.expenseColor, label: '支出'),
        _LegendItem(color: ExpenseTrendPainter.balanceColor, label: '収支'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xff6b7880)),
        ),
      ],
    );
  }
}

class _PoiPage extends StatelessWidget {
  const _PoiPage({
    required this.poiTasks,
    required this.doneTasks,
    required this.onHome,
    required this.onTask,
  });
  final List<NopoiTask> poiTasks;
  final List<NopoiTask> doneTasks;
  final VoidCallback onHome;
  final VoidCallback onTask;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 760;
    final lists = [
      _HistoryList(
        title: '達成リスト',
        tasks: doneTasks,
        empty: 'まだ達成したタスクはありません。',
        icon: Icons.check_circle_outline,
      ),
      _HistoryList(
        title: 'Poiリスト',
        tasks: poiTasks,
        empty: 'まだPoiされたタスクはありません。',
        icon: Icons.delete_outline,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Expanded(
            child: wide
                ? Row(
                    children: lists
                        .map(
                          (w) => Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: w,
                            ),
                          ),
                        )
                        .toList(),
                  )
                : ListView(
                    children: lists
                        .map(
                          (w) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SizedBox(height: 320, child: w),
                          ),
                        )
                        .toList(),
                  ),
          ),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton(onPressed: onHome, child: const Text('メイン画面')),
              OutlinedButton(onPressed: onTask, child: const Text('タスク追加')),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.title,
    required this.tasks,
    required this.empty,
    required this.icon,
  });
  final String title;
  final List<NopoiTask> tasks;
  final String empty;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: title,
      child: tasks.isEmpty
          ? Text(empty, style: const TextStyle(color: Color(0xff6b7880)))
          : ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final task = tasks[index];
                return ListTile(
                  tileColor: Colors.transparent,
                  shape: const RoundedRectangleBorder(),
                  leading: Icon(icon),
                  title: Text(task.text),
                  subtitle: Text(
                    task.movedAt == null ? '' : formatDate(task.movedAt!),
                  ),
                );
              },
            ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfffffdf8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd8e1e5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
          ],
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({required this.label, required this.value, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd8e1e5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Color(0xff6b7880))),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class CrumpledPaper extends StatelessWidget {
  const CrumpledPaper({super.key, required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size * .82),
      painter: CrumpledPaperPainter(),
    );
  }
}

class RoomPainter extends CustomPainter {
  RoomPainter(this.poiCount);
  final int poiCount;

  @override
  void paint(Canvas canvas, Size size) {
    final wall = Paint()..color = const Color(0xffb9dbef);
    final floor = Paint()..color = const Color(0xffe9d7bd);
    canvas.drawRect(Offset.zero & Size(size.width, size.height * .55), wall);
    canvas.drawRect(
      Offset(0, size.height * .55) & Size(size.width, size.height * .45),
      floor,
    );
    _drawRug(canvas, size);
  }

  void _drawRug(Canvas canvas, Size size) {
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .5, size.height - 62),
        width: min(440, size.width * .72),
        height: 88,
      ),
      Paint()..color = const Color(0xfff3cfd0),
    );
  }

  @override
  bool shouldRepaint(RoomPainter oldDelegate) =>
      oldDelegate.poiCount != poiCount;
}

class RabbitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final fur = Paint()..color = const Color(0xfffffefe);
    final furShade = Paint()..color = const Color(0xffeef4f2);
    final line = Paint()
      ..color = const Color(0xffcfdbd8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final blush = Paint()..color = const Color(0xffffd7dc);
    final eye = Paint()..color = const Color(0xff253238);
    final nose = Paint()..color = const Color(0xfff29dad);
    final shadow = Paint()..color = const Color(0x33253139);

    canvas.drawOval(Rect.fromLTWH(36, 186, 98, 20), shadow);

    final leftEar = Path()
      ..moveTo(57, 102)
      ..cubicTo(41, 65, 43, 13, 70, 3)
      ..cubicTo(92, 16, 91, 72, 76, 108)
      ..close();
    final rightEar = Path()
      ..moveTo(96, 108)
      ..cubicTo(83, 70, 87, 15, 114, 4)
      ..cubicTo(138, 18, 134, 72, 111, 103)
      ..close();
    canvas.drawPath(leftEar, fur);
    canvas.drawPath(rightEar, fur);
    canvas.drawPath(leftEar, line);
    canvas.drawPath(rightEar, line);

    final leftInner = Path()
      ..moveTo(64, 90)
      ..cubicTo(54, 60, 56, 26, 70, 17)
      ..cubicTo(82, 30, 80, 66, 71, 93)
      ..close();
    final rightInner = Path()
      ..moveTo(103, 93)
      ..cubicTo(96, 62, 100, 28, 114, 17)
      ..cubicTo(126, 32, 122, 68, 109, 94)
      ..close();
    canvas.drawPath(leftInner, blush);
    canvas.drawPath(rightInner, blush);

    canvas.drawOval(Rect.fromLTWH(38, 88, 96, 76), fur);
    canvas.drawOval(Rect.fromLTWH(38, 88, 96, 76), line);
    canvas.drawOval(Rect.fromLTWH(29, 136, 112, 72), fur);
    canvas.drawOval(Rect.fromLTWH(29, 136, 112, 72), line);
    canvas.drawOval(Rect.fromLTWH(52, 156, 66, 48), furShade);

    canvas.drawCircle(const Offset(73, 123), 5, eye);
    canvas.drawCircle(const Offset(99, 123), 5, eye);
    canvas.drawOval(Rect.fromLTWH(82, 136, 12, 8), nose);

    final mouth = Paint()
      ..color = const Color(0xff94a4a0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawArc(Rect.fromLTWH(74, 142, 12, 10), 0, pi, false, mouth);
    canvas.drawArc(Rect.fromLTWH(90, 142, 12, 10), 0, pi, false, mouth);

    canvas.drawOval(Rect.fromLTWH(22, 174, 42, 30), fur);
    canvas.drawOval(Rect.fromLTWH(106, 174, 42, 30), fur);
    canvas.drawOval(Rect.fromLTWH(22, 174, 42, 30), line);
    canvas.drawOval(Rect.fromLTWH(106, 174, 42, 30), line);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class TrashCanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final lid = Paint()..color = const Color(0xff7f9298);
    final can = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xff95a8ad), Color(0xffc1d0d2)],
      ).createShader(Offset.zero & size);
    final w = size.width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .12, 0, w * .76, 20),
        const Radius.circular(6),
      ),
      lid,
    );
    final path = Path()
      ..moveTo(w * .2, 20)
      ..lineTo(w * .88, 20)
      ..lineTo(w * .74, size.height)
      ..lineTo(w * .28, size.height)
      ..close();
    canvas.drawPath(path, can);
    final line = Paint()
      ..color = const Color(0xff73858b)
      ..strokeWidth = 4;
    canvas.drawLine(
      Offset(w * .4, 34),
      Offset(w * .36, size.height - 16),
      line,
    );
    canvas.drawLine(
      Offset(w * .6, 34),
      Offset(w * .64, size.height - 16),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class CrumpledPaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * .18, size.height * .28)
      ..quadraticBezierTo(
        size.width * .36,
        -4,
        size.width * .58,
        size.height * .16,
      )
      ..quadraticBezierTo(
        size.width * .95,
        size.height * .04,
        size.width * .86,
        size.height * .42,
      )
      ..quadraticBezierTo(
        size.width * 1.04,
        size.height * .78,
        size.width * .62,
        size.height * .84,
      )
      ..quadraticBezierTo(
        size.width * .34,
        size.height * 1.05,
        size.width * .16,
        size.height * .72,
      )
      ..quadraticBezierTo(
        -4,
        size.height * .52,
        size.width * .18,
        size.height * .28,
      );
    canvas.drawPath(path, Paint()..color = const Color(0xfffffaf0));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xffd4cab7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final crease = Paint()
      ..color = const Color(0xffd9cfbd)
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(size.width * .24, size.height * .33),
      Offset(size.width * .56, size.height * .22),
      crease,
    );
    canvas.drawLine(
      Offset(size.width * .38, size.height * .28),
      Offset(size.width * .74, size.height * .58),
      crease,
    );
    canvas.drawLine(
      Offset(size.width * .22, size.height * .66),
      Offset(size.width * .56, size.height * .50),
      crease,
    );
    canvas.drawLine(
      Offset(size.width * .52, size.height * .78),
      Offset(size.width * .80, size.height * .42),
      crease,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class NopoiTask {
  NopoiTask({
    required this.id,
    required this.text,
    required this.createdAt,
    this.notifyAt,
    this.movedAt,
  });
  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime? notifyAt;
  final DateTime? movedAt;

  NopoiTask copyWith({DateTime? movedAt}) => NopoiTask(
    id: id,
    text: text,
    createdAt: createdAt,
    notifyAt: notifyAt,
    movedAt: movedAt ?? this.movedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'notifyAt': notifyAt?.toIso8601String(),
    'movedAt': movedAt?.toIso8601String(),
  };

  factory NopoiTask.fromJson(dynamic json) {
    final data = json as Map<String, dynamic>;
    return NopoiTask(
      id: data['id'] as String,
      text: data['text'] as String,
      createdAt: DateTime.parse(data['createdAt'] as String),
      notifyAt: data['notifyAt'] == null
          ? null
          : DateTime.parse(data['notifyAt'] as String),
      movedAt: data['movedAt'] == null
          ? null
          : DateTime.parse(data['movedAt'] as String),
    );
  }
}

class Subscription {
  Subscription({
    required this.id,
    required this.name,
    required this.amount,
    required this.billingDay,
    required this.category,
    required this.memo,
    required this.notificationEnabled,
    required this.startMonth,
    required this.isActive,
    this.lastRecordedYearMonth,
    required this.createdAt,
    required this.updatedAt,
  });
  final String id;
  final String name;
  final int amount;
  final int billingDay;
  final String category;
  final String memo;
  final bool notificationEnabled;
  final DateTime startMonth;
  final bool isActive;
  final String? lastRecordedYearMonth;
  final DateTime createdAt;
  final DateTime updatedAt;

  static String yearMonth(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';
  DateTime billingDateFor(int year, int month) {
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, min(billingDay, lastDay));
  }

  DateTime nextBillingDate(DateTime now) {
    final thisMonth = billingDateFor(now.year, now.month);
    return thisMonth.isAfter(now)
        ? thisMonth
        : billingDateFor(now.year, now.month + 1);
  }

  Subscription copyWith({bool? isActive, String? lastRecordedYearMonth}) =>
      Subscription(
        id: id,
        name: name,
        amount: amount,
        billingDay: billingDay,
        category: category,
        memo: memo,
        notificationEnabled: notificationEnabled,
        startMonth: startMonth,
        isActive: isActive ?? this.isActive,
        lastRecordedYearMonth:
            lastRecordedYearMonth ?? this.lastRecordedYearMonth,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'amount': amount,
    'billingDay': billingDay,
    'category': category,
    'memo': memo,
    'notificationEnabled': notificationEnabled,
    'startMonth': startMonth.toIso8601String(),
    'isActive': isActive,
    'lastRecordedYearMonth': lastRecordedYearMonth,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory Subscription.fromJson(dynamic json) {
    final data = json as Map<String, dynamic>;
    return Subscription(
      id: data['id'] as String,
      name: data['name'] as String,
      amount: data['amount'] as int,
      billingDay: data['billingDay'] as int,
      category: data['category'] as String,
      memo: data['memo'] as String? ?? '',
      notificationEnabled: data['notificationEnabled'] as bool? ?? false,
      startMonth: DateTime.parse(data['startMonth'] as String),
      isActive: data['isActive'] as bool? ?? true,
      lastRecordedYearMonth: data['lastRecordedYearMonth'] as String?,
      createdAt: DateTime.parse(data['createdAt'] as String),
      updatedAt: DateTime.parse(data['updatedAt'] as String),
    );
  }
}

class ExpenseItem {
  ExpenseItem({
    required this.id,
    required this.amount,
    required this.kind,
    required this.createdAt,
    this.title,
    this.sourceType = 'manual',
    this.subscriptionId,
  });
  final String id;
  final int amount;
  final String kind;
  final DateTime createdAt;
  final String? title;
  final String sourceType;
  final String? subscriptionId;

  bool get isIncome => kind == '収入';

  /// 収入なら正の値、支出なら負の値として扱った金額（収支計算用）。
  int get signedAmount => isIncome ? amount.abs() : -amount.abs();

  Map<String, dynamic> toJson() => {
    'id': id,
    'amount': amount,
    'kind': kind,
    'createdAt': createdAt.toIso8601String(),
    'title': title,
    'sourceType': sourceType,
    'subscriptionId': subscriptionId,
  };

  factory ExpenseItem.fromJson(dynamic json) {
    final data = json as Map<String, dynamic>;
    return ExpenseItem(
      id: data['id'] as String,
      amount: data['amount'] as int,
      kind: data['kind'] as String,
      createdAt: DateTime.parse(data['createdAt'] as String),
      title: data['title'] as String?,
      sourceType: data['sourceType'] as String? ?? 'manual',
      subscriptionId: data['subscriptionId'] as String?,
    );
  }
}

List<MonthlyExpenseSummary> buildMonthlyExpenseSummaries(
  List<ExpenseItem> expenses,
) {
  final groupedExpenseCategories = <DateTime, Map<String, int>>{};
  final groupedIncomeTotal = <DateTime, int>{};
  final groupedExpenseTotal = <DateTime, int>{};

  for (final item in expenses) {
    final month = DateTime(item.createdAt.year, item.createdAt.month);
    if (item.isIncome) {
      final amount = item.amount.abs();
      if (amount == 0) continue;
      groupedIncomeTotal[month] = (groupedIncomeTotal[month] ?? 0) + amount;
    } else {
      final amount = spendingAmount(item);
      if (amount == 0) continue;
      groupedExpenseTotal[month] = (groupedExpenseTotal[month] ?? 0) + amount;
      final categories = groupedExpenseCategories.putIfAbsent(
        month,
        () => <String, int>{},
      );
      categories[item.kind] = (categories[item.kind] ?? 0) + amount;
    }
  }

  final months = <DateTime>{
    ...groupedIncomeTotal.keys,
    ...groupedExpenseTotal.keys,
  }.toList()..sort();

  final summaries = <MonthlyExpenseSummary>[];
  var previousIncome = 0;
  var previousExpense = 0;
  var previousBalance = 0;
  for (final month in months) {
    final incomeTotal = groupedIncomeTotal[month] ?? 0;
    final expenseTotal = groupedExpenseTotal[month] ?? 0;
    final balance = incomeTotal - expenseTotal;
    final categoryTotals =
        groupedExpenseCategories[month] ?? const <String, int>{};
    final sortedCategories = Map.fromEntries(
      categoryTotals.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)),
    );

    final isFirst = summaries.isEmpty;
    final incomeDelta = isFirst ? 0 : incomeTotal - previousIncome;
    final expenseDelta = isFirst ? 0 : expenseTotal - previousExpense;
    final balanceDelta = isFirst ? 0 : balance - previousBalance;

    double? percentOf(int delta, int previous) {
      if (isFirst || previous == 0) return null;
      return (delta / previous) * 100;
    }

    summaries.add(
      MonthlyExpenseSummary(
        month: month,
        incomeTotal: incomeTotal,
        expenseTotal: expenseTotal,
        balance: balance,
        incomeDelta: incomeDelta,
        expenseDelta: expenseDelta,
        balanceDelta: balanceDelta,
        incomePercentChange: percentOf(incomeDelta, previousIncome),
        expensePercentChange: percentOf(expenseDelta, previousExpense),
        balancePercentChange: percentOf(balanceDelta, previousBalance),
        categoryTotals: sortedCategories,
      ),
    );
    previousIncome = incomeTotal;
    previousExpense = expenseTotal;
    previousBalance = balance;
  }
  return summaries.reversed.toList();
}

int spendingAmount(ExpenseItem item) {
  if (item.isIncome) return 0;
  return item.amount.abs();
}

String formatSignedAmount(int value) {
  if (value > 0) return '+$value円';
  if (value < 0) return '$value円';
  return '0円';
}

String formatPercent(double? value) {
  if (value == null) return '前月データなし';
  final sign = value > 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(1)}%';
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();
  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  Future<void> scheduleTask(NopoiTask task) async {
    final when = task.notifyAt;
    if (when == null) return;
    await _plugin.zonedSchedule(
      task.id.hashCode & 0x7fffffff,
      'NoPoi タスク通知',
      task.text,
      tz.TZDateTime.from(when, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'nopoi_tasks',
          'NoPoi Tasks',
          channelDescription: 'NoPoi task reminder notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  Future<void> cancelTask(NopoiTask task) async {
    await _plugin.cancel(task.id.hashCode & 0x7fffffff);
  }

  Future<void> showSubscriptionRecorded(Subscription subscription) async {
    await _plugin.show(
      subscription.id.hashCode & 0x7fffffff,
      'NoPoi サブスクを記録しました',
      '${subscription.name} ${subscription.amount}円を支出に追加しました。',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'nopoi_subscriptions',
          'NoPoi Subscriptions',
          channelDescription: 'NoPoi subscription record notifications',
          importance: Importance.defaultImportance,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}

String formatDate(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.month)}/${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}
