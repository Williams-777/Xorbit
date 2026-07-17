import 'dart:io';
import 'package:flutter/material.dart';

class MyDeviceCard extends StatelessWidget {
  final bool editingName;
  final TextEditingController nameCtrl;
  final String myName;
  final void Function(String) onSave;
  final VoidCallback onEditToggle;

  const MyDeviceCard({
    super.key,
    required this.editingName,
    required this.nameCtrl,
    required this.myName,
    required this.onSave,
    required this.onEditToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.primary.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Platform.isAndroid || Platform.isIOS
                  ? Icons.smartphone
                  : Icons.computer,
              color: scheme.primary,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: editingName
                ? TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                    ),
                    onSubmitted: onSave,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'This device',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.primary.withOpacity(0.7),
                        ),
                      ),
                      Text(
                        myName,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
          ),
          IconButton(
            icon: Icon(
              editingName ? Icons.check_rounded : Icons.edit_rounded,
              size: 18,
              color: scheme.primary,
            ),
            onPressed: () {
              if (editingName) {
                onSave(nameCtrl.text.trim());
              } else {
                onEditToggle();
              }
            },
          ),
        ],
      ),
    );
  }
}
