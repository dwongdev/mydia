import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class EpisodeDetailScreen extends StatelessWidget {
  final String id;

  const EpisodeDetailScreen({
    super.key,
    required this.id,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Episode Details'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.play_circle_outline,
              size: 100,
              color: Colors.grey,
            ),
            const SizedBox(height: 24),
            Text(
              'Episode Detail Screen',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            Text(
              'Episode ID: $id',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey[400],
                  ),
            ),
            const SizedBox(height: 24),
            const Text(
              'This screen will display episode details and playback',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
