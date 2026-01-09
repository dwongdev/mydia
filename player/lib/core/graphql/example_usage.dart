/// Example usage of the GraphQL client with Riverpod
///
/// This file demonstrates how to use the GraphQL client and providers
/// in your Flutter widgets. This file is for documentation purposes only
/// and should not be imported in production code.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../auth/auth_status.dart';
import 'graphql_provider.dart';

// Example 1: Check authentication status
class AuthStatusWidget extends ConsumerWidget {
  const AuthStatusWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authStatus = ref.watch(authStateProvider);

    return authStatus.when(
      data: (status) => Text(
        status == AuthStatus.authenticated ? 'Logged in' : 'Not logged in',
      ),
      loading: () => const CircularProgressIndicator(),
      error: (error, _) => Text('Error: $error'),
    );
  }
}

// Example 2: Login flow
class LoginExample extends ConsumerWidget {
  const LoginExample({super.key});

  Future<void> _handleLogin(WidgetRef ref) async {
    try {
      await ref.read(authStateProvider.notifier).login(
            serverUrl: 'https://mydia.example.com',
            token: 'your-jwt-token',
            userId: 'user-123',
            username: 'john_doe',
          );
      // Navigate to home screen after successful login
    } catch (e) {
      // Handle login error
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ElevatedButton(
      onPressed: () => _handleLogin(ref),
      child: const Text('Login'),
    );
  }
}

// Example 3: Execute a GraphQL query
class GraphQLQueryExample extends ConsumerWidget {
  const GraphQLQueryExample({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(graphqlClientProvider);

    if (client == null) {
      return const Text('GraphQL client not initialized');
    }

    // Define your query
    const String queryString = '''
      query HomeScreen {
        continueWatching(first: 10) {
          id
          title
          type
        }
      }
    ''';

    return GraphQLProvider(
      client: ValueNotifier(client),
      child: Query(
        options: QueryOptions(
          document: gql(queryString),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
        builder: (QueryResult result, {refetch, fetchMore}) {
          if (result.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (result.hasException) {
            return Text('Error: ${result.exception.toString()}');
          }

          if (result.data == null) {
            return const Text('No data');
          }

          final items = result.data!['continueWatching'] as List;

          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return ListTile(
                title: Text(item['title']),
                subtitle: Text(item['type']),
              );
            },
          );
        },
      ),
    );
  }
}

// Example 4: Execute a GraphQL mutation
class GraphQLMutationExample extends ConsumerWidget {
  const GraphQLMutationExample({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(graphqlClientProvider);

    if (client == null) {
      return const Text('GraphQL client not initialized');
    }

    const String mutationString = '''
      mutation UpdateMovieProgress(\$movieId: ID!, \$positionSeconds: Int!) {
        updateMovieProgress(movieId: \$movieId, positionSeconds: \$positionSeconds) {
          positionSeconds
          percentage
        }
      }
    ''';

    return GraphQLProvider(
      client: ValueNotifier(client),
      child: Mutation(
        options: MutationOptions(
          document: gql(mutationString),
          onCompleted: (dynamic resultData) {
            // Handle successful mutation
            print('Progress updated: $resultData');
          },
          onError: (error) {
            // Handle mutation error
            print('Error updating progress: $error');
          },
        ),
        builder: (RunMutation runMutation, QueryResult? result) {
          return ElevatedButton(
            onPressed: () {
              runMutation({
                'movieId': 'movie-123',
                'positionSeconds': 3600,
              });
            },
            child: const Text('Update Progress'),
          );
        },
      ),
    );
  }
}

// Example 5: Logout
class LogoutExample extends ConsumerWidget {
  const LogoutExample({super.key});

  Future<void> _handleLogout(WidgetRef ref) async {
    await ref.read(authStateProvider.notifier).logout();
    // Navigate to login screen
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ElevatedButton(
      onPressed: () => _handleLogout(ref),
      child: const Text('Logout'),
    );
  }
}

// Example 6: Using with FutureProvider for data fetching
final homeDataProvider = FutureProvider.autoDispose((ref) async {
  final client = ref.watch(graphqlClientProvider);

  if (client == null) {
    throw Exception('GraphQL client not available');
  }

  const String query = '''
    query HomeScreen {
      continueWatching(first: 10) {
        id
        title
      }
    }
  ''';

  final result = await client.query(
    QueryOptions(
      document: gql(query),
      fetchPolicy: FetchPolicy.networkOnly,
    ),
  );

  if (result.hasException) {
    throw result.exception!;
  }

  return result.data!['continueWatching'];
});

class FutureProviderExample extends ConsumerWidget {
  const FutureProviderExample({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final homeData = ref.watch(homeDataProvider);

    return homeData.when(
      data: (items) => ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return ListTile(title: Text(item['title']));
        },
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Text('Error: $error'),
    );
  }
}
