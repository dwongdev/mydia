# GraphQL Subscriptions Implementation

This document describes the GraphQL subscriptions implementation for real-time progress sync across devices.

## Backend Implementation (Elixir/Phoenix)

### 1. Dependencies

Added `absinthe_phoenix` to `mix.exs`:

```elixir
{:absinthe_phoenix, "~> 2.0"}
```

### 2. Subscription Types

Created `/lib/mydia_web/schema/subscription_types.ex`:

```elixir
object :playback_subscriptions do
  field :progress_updated, :progress do
    arg(:node_id, non_null(:id))

    config(fn args, _info ->
      {:ok, topic: args.node_id}
    end)
  end
end
```

### 3. Schema Updates

Updated `/lib/mydia_web/schema.ex` to include subscriptions:

```elixir
import_types(MydiaWeb.Schema.SubscriptionTypes)

subscription do
  import_fields(:playback_subscriptions)
end
```

### 4. Phoenix Endpoint Configuration

Added WebSocket socket for GraphQL subscriptions in `/lib/mydia_web/endpoint.ex`:

```elixir
socket "/api/graphql/socket", Absinthe.Phoenix.Socket,
  websocket: true,
  longpoll: false
```

### 5. Application Supervision Tree

Added Absinthe.Subscription to `/lib/mydia/application.ex`:

```elixir
{Absinthe.Subscription, MydiaWeb.Endpoint}
```

### 6. Subscription Triggers

Updated `/lib/mydia_web/schema/resolvers/playback_resolver.ex` to publish events:

```elixir
# In update_movie_progress/3
Absinthe.Subscription.publish(
  MydiaWeb.Endpoint,
  formatted_progress,
  progress_updated: movie_id
)

# In update_episode_progress/3
Absinthe.Subscription.publish(
  MydiaWeb.Endpoint,
  formatted_progress,
  progress_updated: episode_id
)
```

## Frontend Implementation (Flutter)

### 1. GraphQL Schema

Updated `/clients/player/lib/graphql/schema.graphql`:

```graphql
schema {
  mutation: RootMutationType
  query: RootQueryType
  subscription: RootSubscriptionType
}

type RootSubscriptionType {
  "Subscribe to playback progress updates for a specific content item"
  progressUpdated(nodeId: ID!): Progress
}
```

### 2. Subscription Query

Created `/clients/player/lib/graphql/subscriptions/progress_updated.graphql`:

```graphql
subscription ProgressUpdated($nodeId: ID!) {
  progressUpdated(nodeId: $nodeId) {
    ...ProgressFragment
  }
}
```

### 3. Code Generation

Generated Dart types using:

```bash
./dev flutter pub run build_runner build --delete-conflicting-outputs
```

This creates `/clients/player/lib/graphql/subscriptions/progress_updated.graphql.dart` with type-safe subscription classes.

### 4. GraphQL Client

The existing `graphqlClientWithSubscriptionsProvider` already supports WebSocket subscriptions via the `createGraphQLClientWithSubscriptions` function in `/clients/player/lib/core/graphql/client.dart`.

### 5. Usage Example

See `/clients/player/lib/core/graphql/subscription_example.dart` for detailed usage patterns.

Basic usage:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/graphql/subscriptions/progress_updated.graphql.dart';
import 'package:player/core/graphql/graphql_provider.dart';

class VideoPlayerWidget extends ConsumerWidget {
  final String nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(graphqlClientWithSubscriptionsProvider);

    return Subscription(
      options: SubscriptionOptions(
        document: documentNodeSubscriptionProgressUpdated,
        variables: Variables$Subscription$ProgressUpdated(nodeId: nodeId).toJson(),
      ),
      builder: (result) {
        if (result.data != null) {
          final subscription = Subscription$ProgressUpdated.fromJson(result.data!);
          final progress = subscription.progressUpdated;
          // Update UI with new progress
        }
        return YourWidget();
      },
    );
  }
}
```

## How It Works

1. **Client subscribes**: When a video player starts, it subscribes to progress updates using the content's node ID (movie or episode ID).

2. **Progress update triggered**: When playback progress is updated via the `updateMovieProgress` or `updateEpisodeProgress` mutation (from any device), the resolver publishes an event.

3. **Event broadcast**: Phoenix PubSub broadcasts the event to all connected clients subscribed to that node ID.

4. **Real-time update**: Subscribed clients receive the update via WebSocket and can update their UI (e.g., progress bar, timestamp).

## Network Resilience

- WebSocket automatically reconnects on network interruption (configured in `createWebSocketLink`)
- Inactivity timeout: 30 seconds
- Auto-reconnect enabled by default
- Authentication token included in initial WebSocket payload

## Testing

To test subscriptions:

1. Open the app on two devices (or browser tabs)
2. Start playing the same content on device A
3. Subscribe to progress updates on device B
4. Update progress on device A (seek or play)
5. Device B should receive the update in real-time

## Performance Considerations

- Only subscribe when actively viewing content details or during playback
- Unsubscribe when navigating away to reduce server load
- The subscription is scoped to a single node ID, so each subscription is lightweight
- Phoenix PubSub handles broadcast efficiently across distributed nodes

## Future Enhancements

Potential improvements:

1. Add subscriptions for:
   - Watched status changes
   - Favorite status changes
   - New episodes added to shows
   - Download progress updates

2. Implement subscription batching for multiple items

3. Add offline queueing for subscription events
