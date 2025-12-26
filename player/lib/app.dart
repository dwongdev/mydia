import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/providers/providers.dart';
import 'presentation/widgets/cast_mini_controller.dart';

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Mydia Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: router,
      builder: (context, child) {
        // Add cast mini controller overlay to all screens
        return Stack(
          children: [
            if (child != null) child,
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: CastMiniController(),
            ),
          ],
        );
      },
    );
  }
}
