import 'package:flutter/material.dart';

class MainDrawer extends StatelessWidget {
  final bool isPremium;
  final VoidCallback onHistoryTap;
  final VoidCallback onSettingsTap;
  final VoidCallback onAboutTap;
  final VoidCallback onHelpTap;
  final VoidCallback onUpgradeTap;

  const MainDrawer({
    super.key,
    required this.isPremium,
    required this.onHistoryTap,
    required this.onSettingsTap,
    required this.onAboutTap,
    required this.onHelpTap,
    required this.onUpgradeTap,
  });

  Widget _drawerItem(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.primary, size: 22),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.wifi_tethering_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Xorbit',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Fast. Local. Private.',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withOpacity(0.4),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 24),
            _drawerItem(
              context,
              Icons.history_rounded,
              'Transfer History',
              onHistoryTap,
            ),
            _drawerItem(
              context,
              Icons.settings_rounded,
              'Settings',
              onSettingsTap,
            ),
            _drawerItem(
              context,
              Icons.info_outline_rounded,
              'About',
              onAboutTap,
            ),
            _drawerItem(
              context,
              Icons.help_outline_rounded,
              'Help',
              onHelpTap,
            ),
            const Spacer(),
            if (!isPremium)
              Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton.icon(
                  onPressed: onUpgradeTap,
                  icon: const Icon(Icons.star_rounded),
                  label: const Text('Upgrade to Pro'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    backgroundColor: Colors.amber.shade700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
