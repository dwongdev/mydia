import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/remote_device.dart';
import '../../../graphql/queries/devices_list.graphql.dart';
import '../../../graphql/mutations/revoke_device.graphql.dart';

part 'devices_controller.g.dart';

/// Controller for managing devices list and operations.
@riverpod
class DevicesController extends _$DevicesController {
  @override
  Future<List<RemoteDevice>> build() async {
    return _loadDevices();
  }

  /// Load all devices for the current user.
  Future<List<RemoteDevice>> _loadDevices() async {
    final client = ref.read(graphqlClientProvider);

    if (client == null) {
      throw Exception('GraphQL client not available');
    }

    final result = await client.query(
      QueryOptions(
        document: documentNodeQueryDevicesList,
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );

    if (result.hasException) {
      throw Exception(result.exception.toString());
    }

    final query = Query$DevicesList.fromJson(result.data!);
    final devices = query.devices ?? [];

    return devices
        .where((d) => d != null)
        .map((d) => _mapToDevice(d!))
        .toList();
  }

  /// Refresh the devices list.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _loadDevices());
  }

  /// Revoke a device by ID.
  Future<bool> revokeDevice(String deviceId) async {
    final client = ref.read(graphqlClientProvider);

    if (client == null) {
      throw Exception('GraphQL client not available');
    }

    final result = await client.mutate(
      MutationOptions(
        document: documentNodeMutationRevokeDevice,
        variables: {'id': deviceId},
      ),
    );

    if (result.hasException) {
      throw Exception(result.exception.toString());
    }

    final mutation = Mutation$RevokeDevice.fromJson(result.data!);
    final success = mutation.revokeDevice?.success ?? false;

    if (success) {
      // Refresh the list after revoking
      await refresh();
    }

    return success;
  }

  /// Map GraphQL device to domain model.
  RemoteDevice _mapToDevice(Query$DevicesList$devices device) {
    return RemoteDevice(
      id: device.id,
      deviceName: device.deviceName,
      platform: device.platform,
      lastSeenAt: device.lastSeenAt != null
          ? DateTime.tryParse(device.lastSeenAt!)
          : null,
      isRevoked: device.isRevoked,
      createdAt: DateTime.parse(device.createdAt),
    );
  }
}
