import 'package:flutter/material.dart';

import '../../../data/db/db.dart';
import '../../../data/repositories/program_repo.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';
import 'day_editor_screen.dart';

class ProgramEditorScreen extends StatefulWidget {
  const ProgramEditorScreen({super.key, required this.programId});

  final int programId;

  @override
  State<ProgramEditorScreen> createState() => _ProgramEditorScreenState();
}

class _ProgramEditorScreenState extends State<ProgramEditorScreen> {
  late final ProgramRepo _programRepo;
  late final TextEditingController _nameController;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _programRepo = ProgramRepo(AppDatabase.instance);
    _nameController = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final programs = await _programRepo.getPrograms();
    final program = programs.firstWhere((p) => p['id'] == widget.programId, orElse: () => {});
    if (program.isNotEmpty) {
      _nameController.text = program['name'] as String? ?? '';
    }
    setState(() {
      _loaded = true;
    });
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    await _programRepo.updateProgram(id: widget.programId, name: name);
  }

  Future<void> _addDay() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New Day'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Day name'),
            autofocus: true,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    final dayName = result ?? '';
    if (dayName.isEmpty) return;
    final days = await _programRepo.getProgramDays(widget.programId);
    await _programRepo.addProgramDay(
      programId: widget.programId,
      dayIndex: days.length,
      dayName: dayName,
    );
    setState(() {});
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Program'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () async {
              await _saveName();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Program saved.')),
              );
            },
          ),
          const SizedBox(width: 72),
        ],
      ),
      body: Stack(
        children: [
          const GlassBackground(),
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Program name'),
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Map<String, Object?>>>(
                  future: _programRepo.getProgramDays(widget.programId),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final days = snapshot.data ?? [];
                    if (days.isEmpty) {
                      return const Center(child: Text('Add your first day.'));
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: days.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final day = days[index];
                        final dayId = day['id'] as int;
                        return GlassCard(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            title: Text(day['day_name'] as String),
                            subtitle: Text("Day ${(day['day_index'] as int) + 1}"),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => DayEditorScreen(
                                    programDayId: dayId,
                                    programId: widget.programId,
                                  ),
                                ),
                              );
                              setState(() {});
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: GlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.add_circle_outline),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('Add Day')),
                      TextButton(onPressed: _addDay, child: const Text('Add')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
