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
  unawaited(NotificationService.instance.init().catchError((Object error, StackTrace stackTrace) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'nopoi notifications',
      context: ErrorDescription('while initializing local notifications'),
    ));
  }));
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

enum AppPage { choice, task, expense, home, poi }

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
      _tasks = (data['tasks'] as List? ?? []).map((e) => NopoiTask.fromJson(e)).toList();
      _poiTasks = (data['poiTasks'] as List? ?? []).map((e) => NopoiTask.fromJson(e)).toList();
      _doneTasks = (data['doneTasks'] as List? ?? []).map((e) => NopoiTask.fromJson(e)).toList();
      _expenses = (data['expenses'] as List? ?? []).map((e) => ExpenseItem.fromJson(e)).toList();
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode({
      'tasks': _tasks.map((e) => e.toJson()).toList(),
      'poiTasks': _poiTasks.map((e) => e.toJson()).toList(),
      'doneTasks': _doneTasks.map((e) => e.toJson()).toList(),
      'expenses': _expenses.map((e) => e.toJson()).toList(),
    }));
  }

  Future<void> _addTask() async {
    final text = _taskController.text.trim();
    if (text.isEmpty) return;
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('タスクを追加しました')),
      );
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
      initialTime: TimeOfDay.fromDateTime(_notifyAt ?? now.add(const Duration(minutes: 5))),
    );
    if (time == null) return;
    setState(() {
      _notifyAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _addExpense() async {
    final amount = int.tryParse(_amountController.text.trim());
    if (amount == null || amount == 0) return;
    final kind = _expenseKind == 'その他' && _otherExpenseController.text.trim().isNotEmpty
        ? _otherExpenseController.text.trim()
        : _expenseKind;
    setState(() {
      _expenses.insert(0, ExpenseItem(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        amount: amount,
        kind: kind,
        createdAt: DateTime.now(),
      ));
      _amountController.clear();
      _otherExpenseController.clear();
    });
    await _save();
  }

  Future<void> _poiTask(NopoiTask task) async {
    _setPaperFlight();
    await _paperController.forward(from: 0);
    setState(() {
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
                  final t = Curves.easeInOutCubic.transform(_paperController.value);
                  final arc = sin(t * pi) * -90;
                  final pos = Offset.lerp(_paperStart, _paperEnd, t)! + Offset(0, arc);
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
      case AppPage.home:
        return _MainPage(
          tasks: _tasks,
          expenses: _expenses,
          poiCount: _poiTasks.length,
          checkedIds: _checkedTaskIds,
          onExpense: () => setState(() => _page = AppPage.expense),
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
        : _poiTasks.where((task) => task.text.contains(text) || text.contains(task.text)).length;
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
          const Text('NoPoi', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('投げ出さないための、ちいさな管理部屋', style: TextStyle(color: Color(0xff6b7880))),
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
    final wide = MediaQuery.of(context).size.width > 760;
    final cards = [
      _ChoiceCard('タスク管理', 'やることと通知日時を決めて追加します。', Icons.checklist, () => onGo(AppPage.task), const Color(0xffe9f7ef)),
      _ChoiceCard('支出管理', '支出や収入を正負の金額で記録します。', Icons.payments_outlined, () => onGo(AppPage.expense), const Color(0xfffff0d0)),
      _ChoiceCard('メイン画面', 'ウサギの部屋、Task、Poiリストを確認します。', Icons.home_outlined, () => onGo(AppPage.home), const Color(0xffe8f2ff)),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: wide
              ? Row(children: cards.map((card) => Expanded(child: Padding(padding: const EdgeInsets.all(8), child: card))).toList())
              : ListView(children: cards.map((card) => Padding(padding: const EdgeInsets.all(8), child: card)).toList()),
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
            Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(color: Color(0xff6b7880), height: 1.5)),
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
          decoration: const InputDecoration(labelText: 'タスク内容', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: onPickDate,
          icon: const Icon(Icons.notifications_active_outlined),
          label: Align(
            alignment: Alignment.centerLeft,
            child: Text(notifyAt == null ? '通知日時を決める' : '通知: ${formatDate(notifyAt!)}'),
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton(onPressed: onAdd, child: const Text('追加する')),
            OutlinedButton(onPressed: onHome, child: const Text('メイン画面へ')),
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
      title: '支出管理',
      children: [
        TextField(
          controller: amountController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '金額', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: expenseKind,
          decoration: const InputDecoration(labelText: '内容', border: OutlineInputBorder()),
          items: kinds.map((kind) => DropdownMenuItem(value: kind, child: Text(kind))).toList(),
          onChanged: (value) {
            if (value != null) onKindChanged(value);
          },
        ),
        if (expenseKind == 'その他') ...[
          const SizedBox(height: 14),
          TextField(
            controller: otherController,
            decoration: const InputDecoration(labelText: 'その他の内容', border: OutlineInputBorder()),
          ),
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton(onPressed: onAdd, child: const Text('記録する')),
            OutlinedButton(onPressed: onHome, child: const Text('メイン画面へ')),
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
                  Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
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
      _TaskPanel(tasks: tasks, checkedIds: checkedIds, onPoi: onPoi, onDone: onDone, paperKey: paperKey),
      _RoomPanel(poiCount: poiCount, onPoiList: onPoiList, trashKey: trashKey),
      _MoneyPanel(expenses: expenses, poiCount: poiCount, onExpense: onExpense, onTask: onTask),
    ];
    return Padding(
      padding: const EdgeInsets.all(14),
      child: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 330, child: content[0]),
              const SizedBox(width: 14),
              Expanded(child: content[1]),
              const SizedBox(width: 14),
              SizedBox(width: 270, child: content[2]),
            ])
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
                  child: SizedBox(height: 390, child: content[2]),
                ),
              ],
            ),
    );
  }
}

class _TaskPanel extends StatelessWidget {
  const _TaskPanel({required this.tasks, required this.checkedIds, required this.onPoi, required this.onDone, required this.paperKey});
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
          ? const Text('まだタスクがありません。', style: TextStyle(color: Color(0xff6b7880)))
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
                                ? const Icon(Icons.check_box, key: ValueKey('checked'), color: Color(0xff278554))
                                : const Icon(Icons.check_box_outline_blank, key: ValueKey('blank'), color: Color(0xffb7c3c7)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(task.text, style: const TextStyle(fontWeight: FontWeight.w700))),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(task.notifyAt == null ? '通知: 未設定' : '通知: ${formatDate(task.notifyAt!)}', style: const TextStyle(color: Color(0xff6b7880), fontSize: 12)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: OutlinedButton(onPressed: () => onPoi(task), child: const Text('Poi'))),
                          const SizedBox(width: 8),
                          Expanded(child: FilledButton(onPressed: () => onDone(task), child: const Text('Done'))),
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
  const _RoomPanel({required this.poiCount, required this.onPoiList, required this.trashKey});
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
            child: CustomPaint(size: const Size(170, 210), painter: RabbitPainter()),
          ),
          Positioned(
            right: 34,
            bottom: 52,
            child: GestureDetector(
              key: trashKey,
              onTap: onPoiList,
              child: CustomPaint(size: const Size(138, 132), painter: TrashCanPainter()),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoneyPanel extends StatelessWidget {
  const _MoneyPanel({required this.expenses, required this.poiCount, required this.onExpense, required this.onTask});
  final List<ExpenseItem> expenses;
  final int poiCount;
  final VoidCallback onExpense;
  final VoidCallback onTask;

  @override
  Widget build(BuildContext context) {
    final total = expenses.fold<int>(0, (sum, item) => sum + item.amount);
    return _Panel(
      title: '',
      child: ListView(
        children: [
          FilledButton(onPressed: onExpense, child: const Text('支出管理へ')),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onTask, child: const Text('タスク追加へ')),
          const SizedBox(height: 12),
          _StatBox(label: '支出合計', value: '${total.toString()}円'),
          const SizedBox(height: 10),
          _StatBox(label: 'Poiされた数', value: '$poiCount'),
          const SizedBox(height: 16),
          const Text('直近の支出', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          if (expenses.isEmpty)
            const Text('支出管理から記録できます。', style: TextStyle(color: Color(0xff6b7880)))
          else
            ...expenses.take(5).map((item) => Container(
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
                      Text('${item.amount}円', style: TextStyle(fontWeight: FontWeight.w900, color: item.amount >= 0 ? const Color(0xff278554) : const Color(0xffc4565d))),
                      Text('${item.kind} / ${formatDate(item.createdAt)}', style: const TextStyle(fontSize: 12, color: Color(0xff6b7880))),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}

class _PoiPage extends StatelessWidget {
  const _PoiPage({required this.poiTasks, required this.doneTasks, required this.onHome, required this.onTask});
  final List<NopoiTask> poiTasks;
  final List<NopoiTask> doneTasks;
  final VoidCallback onHome;
  final VoidCallback onTask;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 760;
    final lists = [
      _HistoryList(title: '達成リスト', tasks: doneTasks, empty: 'まだ達成したタスクはありません。', icon: Icons.check_circle_outline),
      _HistoryList(title: 'Poiリスト', tasks: poiTasks, empty: 'まだPoiされたタスクはありません。', icon: Icons.delete_outline),
    ];
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Expanded(
            child: wide
                ? Row(children: lists.map((w) => Expanded(child: Padding(padding: const EdgeInsets.all(8), child: w))).toList())
                : ListView(children: lists.map((w) => Padding(padding: const EdgeInsets.only(bottom: 12), child: SizedBox(height: 320, child: w))).toList()),
          ),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton(onPressed: onHome, child: const Text('メイン画面へ')),
              OutlinedButton(onPressed: onTask, child: const Text('タスク追加へ')),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.title, required this.tasks, required this.empty, required this.icon});
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
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final task = tasks[index];
                return ListTile(
                  tileColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Color(0xffd8e1e5))),
                  leading: Icon(icon),
                  title: Text(task.text),
                  subtitle: Text(task.movedAt == null ? '' : formatDate(task.movedAt!)),
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
            Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
          ],
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xffd8e1e5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Color(0xff6b7880))),
        Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
      ]),
    );
  }
}

class CrumpledPaper extends StatelessWidget {
  const CrumpledPaper({super.key, required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size * .82), painter: CrumpledPaperPainter());
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
    canvas.drawRect(Offset(0, size.height * .55) & Size(size.width, size.height * .45), floor);
    _drawWindow(canvas, size);
    _drawRug(canvas, size);
    _drawFurniture(canvas, size);
    _drawTrashPapers(canvas, size);
  }

  void _drawWindow(Canvas canvas, Size size) {
    final frame = Paint()..color = const Color(0xfffff7e8);
    final sky = Paint()..color = const Color(0xffdff5ff);
    final rect = RRect.fromRectAndRadius(Rect.fromLTWH(size.width - 160, 35, 118, 92), const Radius.circular(8));
    canvas.drawRRect(rect, sky);
    canvas.drawRRect(rect, Paint()..color = Colors.transparent..style = PaintingStyle.stroke..strokeWidth = 8..strokeCap = StrokeCap.round);
    canvas.drawRect(Rect.fromLTWH(size.width - 105, 39, 8, 84), frame);
    canvas.drawRect(Rect.fromLTWH(size.width - 156, 78, 110, 8), frame);
  }

  void _drawRug(Canvas canvas, Size size) {
    canvas.drawOval(Rect.fromCenter(center: Offset(size.width * .5, size.height - 62), width: min(440, size.width * .72), height: 88), Paint()..color = const Color(0xfff3cfd0));
  }

  void _drawFurniture(Canvas canvas, Size size) {
    final wood = Paint()..color = const Color(0xffc89863);
    final darkWood = Paint()..color = const Color(0xff9f7248);
    final plant = Paint()..color = const Color(0xff5fa573);
    final shade = Paint()..color = const Color(0xfff4cf76);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(28, size.height * .47, 116, 86), const Radius.circular(6)), wood);
    canvas.drawRect(Rect.fromLTWH(43, size.height * .51, 26, 26), darkWood);
    canvas.drawRect(Rect.fromLTWH(89, size.height * .51, 26, 26), darkWood);
    canvas.drawRect(Rect.fromLTWH(42, size.height * .47 - 80, 15, 80), darkWood);
    canvas.drawCircle(Offset(49, size.height * .47 - 88), 32, shade);
    canvas.drawRect(Rect.fromLTWH(size.width - 210, size.height * .52, 84, 18), darkWood);
    canvas.drawRect(Rect.fromLTWH(size.width - 199, size.height * .52 + 18, 10, 64), darkWood);
    canvas.drawRect(Rect.fromLTWH(size.width - 147, size.height * .52 + 18, 10, 64), darkWood);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(size.width - 92, size.height * .44, 44, 88), const Radius.circular(8)), Paint()..color = const Color(0xffdfc6a6));
    canvas.drawOval(Rect.fromCenter(center: Offset(size.width - 70, size.height * .42), width: 70, height: 38), plant);
    canvas.drawOval(Rect.fromCenter(center: Offset(size.width - 100, size.height * .43), width: 56, height: 32), plant);
    canvas.drawOval(Rect.fromCenter(center: Offset(size.width - 42, size.height * .43), width: 56, height: 32), plant);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(size.width * .35, size.height * .50, 104, 58), const Radius.circular(8)), Paint()..color = const Color(0xfff7e8be));
    canvas.drawRect(Rect.fromLTWH(size.width * .35 + 18, size.height * .50 + 58, 10, 42), darkWood);
    canvas.drawRect(Rect.fromLTWH(size.width * .35 + 76, size.height * .50 + 58, 10, 42), darkWood);
  }

  void _drawTrashPapers(Canvas canvas, Size size) {
    final count = min(14, poiCount ~/ 2);
    for (var i = 0; i < count; i++) {
      final x = 24 + ((i * 53) % max(1, (size.width - 190).toInt()));
      final y = size.height - 45 - ((i % 4) * 22);
      canvas.save();
      canvas.translate(x.toDouble(), y.toDouble());
      canvas.rotate((-20 + (i * 31) % 48) * pi / 180);
      CrumpledPaperPainter().paint(canvas, const Size(38, 31));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(RoomPainter oldDelegate) => oldDelegate.poiCount != poiCount;
}

class RabbitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final white = Paint()..color = Colors.white;
    final outline = Paint()..color = const Color(0xffdfe7e7)..style = PaintingStyle.stroke..strokeWidth = 2;
    final pink = Paint()..color = const Color(0xffffd7dc);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(42, 0, 42, 108), const Radius.circular(24)), white);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(86, 0, 42, 108), const Radius.circular(24)), white);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(53, 16, 20, 76), const Radius.circular(16)), pink);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(97, 16, 20, 76), const Radius.circular(16)), pink);
    canvas.drawOval(Rect.fromLTWH(43, 88, 84, 82), white);
    canvas.drawOval(Rect.fromLTWH(43, 88, 84, 82), outline);
    canvas.drawOval(Rect.fromLTWH(33, 126, 104, 82), white);
    canvas.drawOval(Rect.fromLTWH(33, 126, 104, 82), outline);
    canvas.drawCircle(const Offset(72, 124), 5, Paint()..color = const Color(0xff233139));
    canvas.drawCircle(const Offset(99, 124), 5, Paint()..color = const Color(0xff233139));
    canvas.drawOval(Rect.fromLTWH(80, 139, 12, 8), Paint()..color = const Color(0xfff2a7b0));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class TrashCanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final lid = Paint()..color = const Color(0xff7f9298);
    final can = Paint()..shader = const LinearGradient(colors: [Color(0xff95a8ad), Color(0xffc1d0d2)]).createShader(Offset.zero & size);
    final w = size.width;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * .12, 0, w * .76, 20), const Radius.circular(6)), lid);
    final path = Path()
      ..moveTo(w * .2, 20)
      ..lineTo(w * .88, 20)
      ..lineTo(w * .74, size.height)
      ..lineTo(w * .28, size.height)
      ..close();
    canvas.drawPath(path, can);
    final line = Paint()..color = const Color(0xff73858b)..strokeWidth = 4;
    canvas.drawLine(Offset(w * .4, 34), Offset(w * .36, size.height - 16), line);
    canvas.drawLine(Offset(w * .6, 34), Offset(w * .64, size.height - 16), line);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class CrumpledPaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * .18, size.height * .28)
      ..quadraticBezierTo(size.width * .36, -4, size.width * .58, size.height * .16)
      ..quadraticBezierTo(size.width * .95, size.height * .04, size.width * .86, size.height * .42)
      ..quadraticBezierTo(size.width * 1.04, size.height * .78, size.width * .62, size.height * .84)
      ..quadraticBezierTo(size.width * .34, size.height * 1.05, size.width * .16, size.height * .72)
      ..quadraticBezierTo(-4, size.height * .52, size.width * .18, size.height * .28);
    canvas.drawPath(path, Paint()..color = const Color(0xfffffaf0));
    canvas.drawPath(path, Paint()..color = const Color(0xffd4cab7)..style = PaintingStyle.stroke..strokeWidth = 1.5);
    final crease = Paint()..color = const Color(0xffd9cfbd)..strokeWidth = 1.2;
    canvas.drawLine(Offset(size.width * .24, size.height * .33), Offset(size.width * .56, size.height * .22), crease);
    canvas.drawLine(Offset(size.width * .38, size.height * .28), Offset(size.width * .74, size.height * .58), crease);
    canvas.drawLine(Offset(size.width * .22, size.height * .66), Offset(size.width * .56, size.height * .50), crease);
    canvas.drawLine(Offset(size.width * .52, size.height * .78), Offset(size.width * .80, size.height * .42), crease);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class NopoiTask {
  NopoiTask({required this.id, required this.text, required this.createdAt, this.notifyAt, this.movedAt});
  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime? notifyAt;
  final DateTime? movedAt;

  NopoiTask copyWith({DateTime? movedAt}) => NopoiTask(id: id, text: text, createdAt: createdAt, notifyAt: notifyAt, movedAt: movedAt ?? this.movedAt);

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
      notifyAt: data['notifyAt'] == null ? null : DateTime.parse(data['notifyAt'] as String),
      movedAt: data['movedAt'] == null ? null : DateTime.parse(data['movedAt'] as String),
    );
  }
}

class ExpenseItem {
  ExpenseItem({required this.id, required this.amount, required this.kind, required this.createdAt});
  final String id;
  final int amount;
  final String kind;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'amount': amount,
        'kind': kind,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ExpenseItem.fromJson(dynamic json) {
    final data = json as Map<String, dynamic>;
    return ExpenseItem(
      id: data['id'] as String,
      amount: data['amount'] as int,
      kind: data['kind'] as String,
      createdAt: DateTime.parse(data['createdAt'] as String),
    );
  }
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();
  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(requestAlertPermission: true, requestBadgePermission: true, requestSoundPermission: true);
    await _plugin.initialize(const InitializationSettings(android: android, iOS: ios));
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true);
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
}

String formatDate(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.month)}/${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}
