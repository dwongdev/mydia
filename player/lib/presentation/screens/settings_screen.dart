import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/connection/connection_diagnostics_provider.dart';
import '../../core/connection/connection_provider.dart';
import '../../core/graphql/graphql_provider.dart';
import 'settings/settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _handleLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      // Use the auth state provider's logout method
      await ref.read(authStateProvider.notifier).logout();

      // Clear settings
      final settingsService = ref.read(settingsServiceProvider);
      await settingsService.clearSettings();

      if (context.mounted) {
        context.go('/login');
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Failed to load settings',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  error.toString(),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        data: (settings) => ListView(
          children: [
            // Account section
            const _SectionHeader(title: 'Account'),
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(settings.username),
              subtitle: Text(settings.serverUrl),
            ),
            ListTile(
              leading: const Icon(Icons.devices),
              title: const Text('Devices'),
              subtitle: const Text('Manage paired devices'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/devices'),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Logout'),
              onTap: () => _handleLogout(context, ref),
            ),
            const Divider(),

            // Connection section
            const _SectionHeader(title: 'Connection'),
            const _ConnectionDiagnosticsTile(),
            const Divider(),

            // About section
            const _SectionHeader(title: 'About'),
            const ListTile(
              leading: Icon(Icons.copyright),
              title: Text('Mydia Player'),
              subtitle: Text('Media streaming client'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

/// Expandable tile showing connection status and diagnostics.
class _ConnectionDiagnosticsTile extends ConsumerStatefulWidget {
  const _ConnectionDiagnosticsTile();

  @override
  ConsumerState<_ConnectionDiagnosticsTile> createState() =>
      _ConnectionDiagnosticsTileState();
}

class _ConnectionDiagnosticsTileState
    extends ConsumerState<_ConnectionDiagnosticsTile> {

  @override
  Widget build(BuildContext context) {
    // Watch connection provider directly for live status
    final connectionState = ref.watch(connectionProvider);

    // Determine status display from live connection state
    final isP2P = connectionState.isP2PMode;

    IconData icon;
    Color statusColor;
    String statusText;
    String subtitle;

    if (isP2P) {
      icon = Icons.hub_outlined;
      statusColor = Colors.blue;
      statusText = 'P2P';
      subtitle = 'Connected via P2P mesh';
    } else {
      icon = Icons.wifi;
      statusColor = Colors.green;
      statusText = 'Direct';
      subtitle = 'Direct connection to server';
    }

    return Column(
      children: [
        ListTile(
          leading: Icon(icon, color: statusColor),
          title: Row(
            children: [
              const Text('Status'),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Text(subtitle),
        ),
      ],
    );
  }
}
