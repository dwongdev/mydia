/// Connection status indicator widget.
///
/// Displays the current connection mode (P2P/direct) with a subtle
/// indicator that updates in real-time when the connection mode changes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_provider.dart';

/// A compact badge showing the current connection status.
class ConnectionStatusBadge extends ConsumerWidget {
  const ConnectionStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final isP2P = connectionState.isP2PMode;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isP2P
            ? Colors.blue.withValues(alpha: 0.15)
            : Colors.green.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isP2P
              ? Colors.blue.withValues(alpha: 0.3)
              : Colors.green.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isP2P ? Icons.hub_outlined : Icons.wifi,
            size: 14,
            color: isP2P ? Colors.blue : Colors.green,
          ),
          const SizedBox(width: 4),
          Text(
            isP2P ? 'P2P' : 'Direct',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isP2P ? Colors.blue : Colors.green,
            ),
          ),
        ],
      ),
    );
  }
}

/// A list tile showing connection status with more details.
class ConnectionStatusTile extends ConsumerWidget {
  const ConnectionStatusTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final isP2P = connectionState.isP2PMode;

    String subtitle;
    IconData icon;
    Color statusColor;

    if (isP2P) {
      subtitle = 'Connected via P2P mesh';
      icon = Icons.hub_outlined;
      statusColor = Colors.blue;
    } else {
      subtitle = 'Direct connection to server';
      icon = Icons.wifi;
      statusColor = Colors.green;
    }

    return ListTile(
      leading: Icon(icon, color: statusColor),
      title: const Row(
        children: [
          Text('Connection'),
          SizedBox(width: 8),
          ConnectionStatusBadge(),
        ],
      ),
      subtitle: Text(subtitle),
    );
  }
}
