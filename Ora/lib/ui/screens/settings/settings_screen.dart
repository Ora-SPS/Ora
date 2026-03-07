import 'package:flutter/material.dart';

import '../../../data/db/db.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../domain/services/fitbit_service.dart';
import '../../../diagnostics/diagnostics_page.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';
import 'account_screen.dart';
import '../shell/app_shell_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: const [SizedBox(width: 72)],
      ),
      body: const SettingsContent(showBackground: true),
    );
  }
}

class SettingsContent extends StatefulWidget {
  const SettingsContent({super.key, required this.showBackground});

  final bool showBackground;

  @override
  State<SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<SettingsContent> {
  late final SettingsRepo _settingsRepo;
  late final FitbitService _fitbitService;
  bool _loading = true;

  String _unit = 'lb';
  bool _voiceEnabled = true;
  bool _wakeWordEnabled = false;
  String _cloudProvider = 'gemini';
  bool _orbHidden = false;
  bool _snackbarHighContrast = true;

  final _incrementController = TextEditingController();
  final _restController = TextEditingController();
  final _cloudKeyController = TextEditingController();
  final _fitbitClientIdController = TextEditingController();

  final Map<CloudModelTask, String> _taskModels = {};

  bool _showCloudKey = false;

  @override
  void initState() {
    super.initState();
    _settingsRepo = SettingsRepo(AppDatabase.instance);
    _fitbitService = FitbitService();
    _load();
  }

  @override
  void dispose() {
    _incrementController.dispose();
    _restController.dispose();
    _cloudKeyController.dispose();
    _fitbitClientIdController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final unit = await _settingsRepo.getUnit();
    final increment = await _settingsRepo.getIncrement();
    final rest = await _settingsRepo.getRestDefault();
    final voiceEnabled = await _settingsRepo.getVoiceEnabled();
    final wakeWordEnabled = await _settingsRepo.getWakeWordEnabled();
    final cloudKey = await _settingsRepo.getCloudApiKey();
    final cloudProvider = await _settingsRepo.getCloudProvider();
    final orbHidden = await _settingsRepo.getOrbHidden();
    final snackbarHighContrast = await _settingsRepo.getSnackbarHighContrast();
    final fitbitClientId = await _fitbitService.getConfiguredClientId();

    final taskModels = <CloudModelTask, String>{};
    for (final task in SettingsRepo.configurableCloudModelTasks) {
      taskModels[task] = await _settingsRepo.getCloudModelForTask(task);
    }
    AppShellController.instance.setHighContrastSnackbars(snackbarHighContrast);

    if (!mounted) return;
    setState(() {
      _unit = unit;
      _voiceEnabled = voiceEnabled;
      _wakeWordEnabled = wakeWordEnabled;
      _incrementController.text = increment.toStringAsFixed(2);
      _restController.text = rest.toString();
      _cloudKeyController.text = cloudKey ?? '';
      _cloudProvider = cloudProvider;
      _orbHidden = orbHidden;
      _snackbarHighContrast = snackbarHighContrast;
      _fitbitClientIdController.text = fitbitClientId ?? '';
      _taskModels
        ..clear()
        ..addAll(taskModels);
      _normalizeTaskModelsForProvider(forceDefaults: false);
      _loading = false;
    });
  }

  Future<void> _saveIncrement() async {
    final value = double.tryParse(_incrementController.text.trim());
    if (value == null) return;
    await _settingsRepo.setIncrement(value);
  }

  Future<void> _saveRest() async {
    final value = int.tryParse(_restController.text.trim());
    if (value == null) return;
    await _settingsRepo.setRestDefault(value);
  }

  void _normalizeTaskModelsForProvider({required bool forceDefaults}) {
    for (final task in SettingsRepo.configurableCloudModelTasks) {
      final options = SettingsRepo.cloudModelOptionsForTask(
        provider: _cloudProvider,
        task: task,
      );
      final current = _taskModels[task]?.trim() ?? '';
      final fallback = SettingsRepo.defaultCloudModelForTask(
        provider: _cloudProvider,
        task: task,
      );
      if (forceDefaults || current.isEmpty || !options.contains(current)) {
        _taskModels[task] =
            options.contains(fallback) ? fallback : options.first;
      }
    }
  }

  Future<void> _saveCloudSettings() async {
    await _settingsRepo.setCloudApiKey(_cloudKeyController.text);
    await _settingsRepo.setCloudProvider(_cloudProvider);
    for (final task in SettingsRepo.configurableCloudModelTasks) {
      final fallback = SettingsRepo.defaultCloudModelForTask(
        provider: _cloudProvider,
        task: task,
      );
      await _settingsRepo.setCloudModelForTask(
          task, _taskModels[task] ?? fallback);
    }
    final compatibilityModel =
        _taskModels[CloudModelTask.documentImageAnalysis] ??
            SettingsRepo.defaultCloudModelForTask(
              provider: _cloudProvider,
              task: CloudModelTask.documentImageAnalysis,
            );
    await _settingsRepo.setCloudModel(compatibilityModel);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cloud settings saved.')),
    );
  }

  Future<void> _clearCloudApiKey() async {
    final messenger = ScaffoldMessenger.of(context);
    _cloudKeyController.clear();
    await _settingsRepo.setCloudApiKey(null);
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('API key cleared.')),
    );
  }

  Future<void> _saveFitbitClientId() async {
    final messenger = ScaffoldMessenger.of(context);
    final trimmed = _fitbitClientIdController.text.trim();
    await _fitbitService.setClientId(trimmed);
    _fitbitClientIdController.value = TextEditingValue(
      text: trimmed,
      selection: TextSelection.collapsed(offset: trimmed.length),
    );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          trimmed.isEmpty
              ? 'Fitbit Client ID cleared.'
              : 'Fitbit Client ID saved.',
        ),
      ),
    );
  }

  Future<void> _clearFitbitClientId() async {
    final messenger = ScaffoldMessenger.of(context);
    await _fitbitService.setClientId(null);
    _fitbitClientIdController.clear();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Fitbit Client ID cleared.')),
    );
  }

  Widget _buildCloudTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Cloud Provider + API Key')),
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    onPressed: _showCloudSetupInfo,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(child: Text('Provider')),
                  DropdownButton<String>(
                    value: _cloudProvider,
                    items: const [
                      DropdownMenuItem(value: 'gemini', child: Text('Gemini')),
                      DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _cloudProvider = value;
                        _normalizeTaskModelsForProvider(forceDefaults: true);
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'API keys are stored securely on-device (Keychain/Keystore) and never uploaded.',
              ),
              const SizedBox(height: 8),
              const Text('Cloud parsing is required for this app.'),
              const SizedBox(height: 8),
              TextField(
                controller: _cloudKeyController,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  suffixIcon: IconButton(
                    icon: Icon(_showCloudKey
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _showCloudKey = !_showCloudKey),
                  ),
                ),
                obscureText: !_showCloudKey,
                onSubmitted: (_) =>
                    _settingsRepo.setCloudApiKey(_cloudKeyController.text),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _clearCloudApiKey,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear API key'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Task Model Routing'),
              const SizedBox(height: 6),
              const Text(
                'Choose which model runs each AI task. Defaults prioritize speed for interpretation and depth for analysis.',
              ),
              const SizedBox(height: 12),
              ...SettingsRepo.configurableCloudModelTasks
                  .map(_buildTaskModelSelector),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: _saveCloudSettings,
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTaskModelSelector(CloudModelTask task) {
    final options = SettingsRepo.cloudModelOptionsForTask(
      provider: _cloudProvider,
      task: task,
    );
    var current = _taskModels[task];
    if (current == null || !options.contains(current)) {
      current = SettingsRepo.defaultCloudModelForTask(
        provider: _cloudProvider,
        task: task,
      );
      if (!options.contains(current)) {
        current = options.first;
      }
      _taskModels[task] = current;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            task.description,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: current,
            items: options
                .map((model) =>
                    DropdownMenuItem(value: model, child: Text(model)))
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _taskModels[task] = value;
              });
            },
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrainingTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Preferences'),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(child: Text('Units')),
                  DropdownButton<String>(
                    value: _unit,
                    items: const [
                      DropdownMenuItem(value: 'lb', child: Text('lb')),
                      DropdownMenuItem(value: 'kg', child: Text('kg')),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      setState(() => _unit = value);
                      await _settingsRepo.setUnit(value);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _incrementController,
                decoration: const InputDecoration(
                  labelText: 'Weight increment',
                ),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _saveIncrement(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _restController,
                decoration: const InputDecoration(
                  labelText: 'Default rest (sec)',
                ),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _saveRest(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Step Tracker (Fitbit)')),
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    onPressed: _showFitbitSetupInfo,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Used by Link Fitbit in Training/Fitness. Enter only the Fitbit Client ID.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _fitbitClientIdController,
                decoration: const InputDecoration(
                  labelText: 'Fitbit Client ID',
                ),
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _saveFitbitClientId(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _clearFitbitClientId,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Clear'),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _saveFitbitClientId,
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Voice'),
              const SizedBox(height: 8),
              SwitchListTile(
                value: _voiceEnabled,
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable voice'),
                subtitle: const Text('On-device only'),
                onChanged: (value) async {
                  setState(() => _voiceEnabled = value);
                  await _settingsRepo.setVoiceEnabled(value);
                },
              ),
              SwitchListTile(
                value: _wakeWordEnabled,
                contentPadding: EdgeInsets.zero,
                title: const Text('Wake word: "Hey Ora"'),
                subtitle: const Text('Session-only, foreground-only'),
                onChanged: (value) async {
                  setState(() => _wakeWordEnabled = value);
                  await _settingsRepo.setWakeWordEnabled(value);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAppTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Account'),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sign in'),
                subtitle: const Text('Apple, Google, Microsoft, Email'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AccountScreen()),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ora Orb'),
              const SizedBox(height: 8),
              SwitchListTile(
                value: !_orbHidden,
                contentPadding: EdgeInsets.zero,
                title: const Text('Show floating input'),
                subtitle: const Text('Always-on input hub across tabs'),
                onChanged: (value) async {
                  setState(() => _orbHidden = !value);
                  await _settingsRepo.setOrbHidden(!value);
                  AppShellController.instance.setOrbHidden(!value);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Feedback UI'),
              const SizedBox(height: 8),
              SwitchListTile(
                value: _snackbarHighContrast,
                contentPadding: EdgeInsets.zero,
                title: const Text('High-contrast snackbars'),
                subtitle: const Text('Brighter background + darker text'),
                onChanged: (value) async {
                  setState(() => _snackbarHighContrast = value);
                  await _settingsRepo.setSnackbarHighContrast(value);
                  AppShellController.instance.setHighContrastSnackbars(value);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('About'),
              SizedBox(height: 8),
              Text('Local-first. Accounts optional for cloud features.'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Diagnostics'),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('View crash logs'),
                subtitle: const Text(
                  'Inspect recent startup errors and share the local log file.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const DiagnosticsPage(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showCloudSetupInfo() {
    final title =
        _cloudProvider == 'openai' ? 'OpenAI API setup' : 'Gemini API setup';
    final body = _cloudProvider == 'openai'
        ? 'To use OpenAI, follow these steps:\n'
            '1) Go to platform.openai.com\n'
            '2) Sign in or create an account.\n'
            '3) Open the "API Keys" page.\n'
            '4) Click "Create new secret key".\n'
            "5) Copy the key immediately (you won't see it again).\n"
            '6) Paste it into the "API Key" field and press Save.\n'
            'Text, documents, and images may be sent for classification and analysis.'
        : 'To use Gemini, follow these steps:\n'
            '1) Go to aistudio.google.com\n'
            '2) Sign in with your Google account.\n'
            '3) Open "Get API key".\n'
            '4) Create a new key.\n'
            '5) Copy the key and paste it into the "API Key" field, then press Save.\n'
            'Note: the student Gemini plan for the consumer app does not automatically '
            'include API access. Text, documents, and images may be sent for classification and analysis.';
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _showFitbitSetupInfo() {
    const body = 'How to set up Fitbit linking:\n'
        '1) Open https://dev.fitbit.com/apps in a browser and sign in.\n'
        '2) Click "Register an App" (or open your existing app).\n'
        '3) App type: choose "Personal".\n'
        '4) OAuth 2.0 settings: add Redirect URL exactly as:\n'
        '   orafitbit://auth\n'
        '5) Save the app.\n'
        '6) Copy the "Client ID" from the app details.\n'
        '7) Paste it in this field and tap Save.\n\n'
        'Important:\n'
        '- Do not paste your profile/user ID.\n'
        '- Do not paste the Client Secret.\n'
        '- If linking fails, clear this field and re-enter the Client ID.';
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Fitbit setup'),
          content: const SingleChildScrollView(
            child: Text(body),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : DefaultTabController(
            length: 4,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: GlassCard(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: const Center(
                      child: TabBar(
                        isScrollable: true,
                        tabs: [
                          Tab(text: 'Cloud AI'),
                          Tab(text: 'Training'),
                          Tab(text: 'App'),
                          Tab(text: 'Advanced'),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildCloudTab(),
                      _buildTrainingTab(),
                      _buildAppTab(),
                      _buildAdvancedTab(),
                    ],
                  ),
                ),
              ],
            ),
          );

    if (!widget.showBackground) {
      return content;
    }

    return Stack(
      children: [
        const GlassBackground(),
        content,
      ],
    );
  }
}
