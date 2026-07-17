import 'package:flutter/material.dart';
import 'package:xorbit/models/app_state.dart';

class SettingsPage extends StatefulWidget {
  final Function(String) onNameChanged;
  const SettingsPage({super.key, required this.onNameChanged});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: appState.myName);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    await appState.saveDeviceName(name);
    widget.onNameChanged(name);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device name saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Device Name',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: const InputDecoration(
                    hintText: 'Enter device name',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
          const SizedBox(height: 28),
          const Text(
            'Appearance',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: themeNotifier,
            builder: (_, __) => SwitchListTile(
              title: const Text('Dark Mode'),
              value: themeNotifier.isDark,
              onChanged: (_) {
                themeNotifier.toggle();
                themeNotifier.save();
              },
              secondary: Icon(
                themeNotifier.isDark
                    ? Icons.nightlight_round
                    : Icons.wb_sunny_rounded,
              ),
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'Device ID',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            appState.myId,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
