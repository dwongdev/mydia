/// Connection status indicator widget.
///
/// Displays the current connection mode (P2P/direct) with a subtle
/// indicator that updates in real-time when the connection mode changes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_provider.dart';
import '../../core/p2p/p2p_service.dart';

/// A compact badge showing the current connection status.
class ConnectionStatusBadge extends ConsumerWidget {
  const ConnectionStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);
    final isP2P = connectionState.isP2PMode;

    debugPrint('[ConnectionStatusBadge] build: isP2P=$isP2P, peerConnectionType=${p2pStatus.peerConnectionType}');

    // Get color and label based on connection type
    final (Color statusColor, String label) = isP2P
        ? _getP2PStatusInfo(p2pStatus.peerConnectionType)
        : (Colors.green, 'Direct');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isP2P ? Icons.hub_outlined : Icons.wifi,
            size: 14,
            color: statusColor,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: statusColor,
            ),
          ),
        ],
      ),
    );
  }

  /// Get the color and label for P2P connection based on type
  (Color, String) _getP2PStatusInfo(P2pConnectionType connectionType) {
    return switch (connectionType) {
      P2pConnectionType.direct => (Colors.green, 'P2P (Direct)'),
      P2pConnectionType.relay => (Colors.orange, 'P2P (Relay)'),
      P2pConnectionType.mixed => (Colors.blue, 'P2P (Mixed)'),
      P2pConnectionType.none => (Colors.blue, 'P2P'),
    };
  }
}

/// A list tile showing connection status with more details.
class ConnectionStatusTile extends ConsumerWidget {
  const ConnectionStatusTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);
    final isP2P = connectionState.isP2PMode;

    String subtitle;
    IconData icon;
    Color statusColor;

    if (isP2P) {
      final (color, transportDetail) =
          _getP2PTransportInfo(p2pStatus.peerConnectionType);
      subtitle = transportDetail;
      icon = Icons.hub_outlined;
      statusColor = color;
    } else {
      subtitle = 'Direct HTTP connection to server';
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

  /// Get the color and transport details for P2P connection type
  (Color, String) _getP2PTransportInfo(P2pConnectionType connectionType) {
    return switch (connectionType) {
      P2pConnectionType.direct => (
          Colors.green,
          'Direct peer-to-peer connection'
        ),
      P2pConnectionType.relay => (
          Colors.orange,
          'Connected via relay server'
        ),
      P2pConnectionType.mixed => (
          Colors.blue,
          'Using both relay and direct paths'
        ),
      P2pConnectionType.none => (Colors.blue, 'Connecting via P2P mesh...'),
    };
  }
}
