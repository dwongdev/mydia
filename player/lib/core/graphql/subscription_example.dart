import 'package:flutter/material.dart';

/// Example of how to use GraphQL subscriptions for real-time progress updates.
///
/// This demonstrates subscribing to progress updates for a specific content item (movie or episode).
/// When playback progress is updated on another device, this subscription receives the update
/// and can update the UI in real-time.
///
/// Usage in a widget:
/// ```dart
/// class VideoPlayerWidget extends ConsumerWidget {
///   final String nodeId; // The movie or episode ID
///
///   const VideoPlayerWidget({super.key, required this.nodeId});
///
///   @override
///   Widget build(BuildContext context, WidgetRef ref) {
///     final client = ref.watch(graphqlClientWithSubscriptionsProvider);
///
///     if (client == null) {
///       return const Text('Not connected');
///     }
///
///     return Subscription(
///       options: SubscriptionOptions(
///         document: documentNodeSubscriptionProgressUpdated,
///         variables: Variables$Subscription$ProgressUpdated(nodeId: nodeId).toJson(),
///       ),
///       builder: (result) {
///         if (result.hasException) {
///           debugPrint('Subscription error: ${result.exception}');
///           return const SizedBox.shrink();
///         }
///
///         if (result.isLoading) {
///           debugPrint('Subscription loading...');
///           return const SizedBox.shrink();
///         }
///
///         if (result.data != null) {
///           final subscription = Subscription$ProgressUpdated.fromJson(result.data!);
///           final progress = subscription.progressUpdated;
///
///           if (progress != null) {
///             debugPrint('Progress updated: ${progress.positionSeconds}s');
///             // Update your video player position here
///           }
///         }
///
///         return const SizedBox.shrink();
///       },
///     );
///   }
/// }
/// ```
///
/// Important notes:
/// - Use `graphqlClientWithSubscriptionsProvider` instead of `graphqlClientProvider`
/// - The subscription will reconnect automatically on network interruption
/// - Clean up subscriptions when the widget is disposed (handled by graphql_flutter)
/// - Only subscribe when actively playing content to reduce server load
class SubscriptionExample extends StatelessWidget {
  const SubscriptionExample({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('See source code for subscription usage example'),
    );
  }
}
