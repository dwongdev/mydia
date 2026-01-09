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
  bool _isExpanded = false;
  bool _isProbing = false;

  Future<void> _testDirectConnection() async {
    if (_isProbing) return;

    setState(() {
      _isProbing = true;
    });

    try {
      // Trigger the probe
      final result = await ref.read(connectionProvider.notifier).probeDirectUrls();

      if (result != null) {
        // Update diagnostics with the results
        await ref.read(connectionDiagnosticsProvider.notifier).recordBatchAttempts(
          result.urlResults,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProbing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch connection provider directly for live status
    final connectionState = ref.watch(connectionProvider);
    // Watch diagnostics for URL attempt data
    final diagnostics = ref.watch(connectionDiagnosticsProvider);
    final theme = Theme.of(context);

    // Determine status display from live connection state
    final isRelay = connectionState.isRelayMode;
    final isTunnelActive = connectionState.isTunnelActive;
    final hasDirectUrls = diagnostics.directUrls.isNotEmpty;

    IconData icon;
    Color statusColor;
    String statusText;
    String subtitle;

    if (isRelay) {
      if (isTunnelActive) {
        icon = Icons.cloud_done_outlined;
        statusColor = Colors.orange;
        statusText = 'Relay';
        subtitle = 'Connected via relay tunnel';
      } else {
        icon = Icons.cloud_off_outlined;
        statusColor = Colors.red;
        statusText = 'Disconnected';
        subtitle = 'Relay tunnel disconnected';
      }
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
          trailing: hasDirectUrls
              ? Icon(_isExpanded ? Icons.expand_less : Icons.expand_more)
              : null,
          onTap: hasDirectUrls
              ? () {
                  setState(() {
                    _isExpanded = !_isExpanded;
                  });
                }
              : null,
        ),
        if (_isExpanded && hasDirectUrls)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Section header for direct URLs
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Text(
                        'Direct URLs',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (diagnostics.lastDirectAttempt != null)
                        Text(
                          'Last tried ${_formatDateTime(diagnostics.lastDirectAttempt!)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                        ),
                    ],
                  ),
                ),
                // Direct URLs list
                ...diagnostics.directUrls.map((url) {
                  final attempt = diagnostics.getAttempt(url);
                  return _DirectUrlCard(
                    url: url,
                    attempt: attempt,
                  );
                }),
                // Test button
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isProbing ? null : _testDirectConnection,
                    icon: _isProbing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                    label: Text(_isProbing ? 'Testing...' : 'Test Direct Connection'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) {
      return 'just now';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }
}

/// Card showing a single direct URL and its status.
class _DirectUrlCard extends StatelessWidget {
  final String url;
  final DirectUrlAttempt? attempt;

  const _DirectUrlCard({
    required this.url,
    this.attempt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Color statusColor;
    IconData statusIcon;
    String statusText;

    if (attempt == null) {
      statusColor = Colors.grey;
      statusIcon = Icons.help_outline;
      statusText = 'Not tested';
    } else if (attempt!.success) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
      statusText = 'Connected';
    } else {
      statusColor = Colors.red;
      statusIcon = Icons.error;
      statusText = 'Failed';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, size: 18, color: statusColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _formatUrl(url),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          if (attempt?.error != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: Colors.red[700],
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      attempt!.error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.red[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatUrl(String url) {
    // Remove protocol for cleaner display
    return url.replaceFirst(RegExp(r'^https?://'), '');
  }
}
