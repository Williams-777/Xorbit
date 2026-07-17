import 'package:flutter/material.dart';
import 'package:xorbit/models/app_state.dart';

class DeviceCard extends StatelessWidget {
  final XorbitDevice device;
  final bool connectedToUs;
  final VoidCallback onConnectPressed;

  const DeviceCard({
    super.key,
    required this.device,
    required this.connectedToUs,
    required this.onConnectPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: connectedToUs
                ? Colors.green.withOpacity(0.4)
                : scheme.onSurface.withOpacity(0.07),
          ),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (connectedToUs ? Colors.green : scheme.primary)
                  .withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.devices_rounded,
              color: connectedToUs ? Colors.green : scheme.primary,
              size: 20,
            ),
          ),
          title: Text(
            device.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            connectedToUs ? '✅ Connected' : device.ip,
            style: TextStyle(
              fontSize: 11,
              color: connectedToUs
                  ? Colors.green
                  : scheme.onSurface.withOpacity(0.4),
            ),
          ),
          trailing: connectedToUs
              ? null
              : ElevatedButton(
                  onPressed: onConnectPressed,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Connect'),
                ),
        ),
      ),
    );
  }
}
