import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/hls_quality_selector.dart';

void main() {
  group('HlsQualityLevel', () {
    test('auto quality is marked as isAuto', () {
      expect(HlsQualityLevel.auto.isAuto, isTrue);
      expect(HlsQualityLevel.auto.label, equals('Auto'));
    });

    test('standard quality levels have correct properties', () {
      final levels = HlsQualityLevel.standardLevels;

      expect(levels.length, equals(5));
      expect(levels[0].label, equals('Auto'));
      expect(levels[1].label, equals('1080p'));
      expect(levels[1].height, equals(1080));
      expect(levels[2].label, equals('720p'));
      expect(levels[2].height, equals(720));
      expect(levels[3].label, equals('480p'));
      expect(levels[3].height, equals(480));
      expect(levels[4].label, equals('360p'));
      expect(levels[4].height, equals(360));
    });

    test('equality operator works correctly', () {
      const level1 = HlsQualityLevel(label: '720p', height: 720);
      const level2 = HlsQualityLevel(label: '720p', height: 720);
      const level3 = HlsQualityLevel(label: '1080p', height: 1080);

      expect(level1, equals(level2));
      expect(level1, isNot(equals(level3)));
      expect(HlsQualityLevel.auto, equals(HlsQualityLevel.auto));
    });

    test('hashCode is consistent', () {
      const level1 = HlsQualityLevel(label: '720p', height: 720);
      const level2 = HlsQualityLevel(label: '720p', height: 720);

      expect(level1.hashCode, equals(level2.hashCode));
    });
  });

  group('showHlsQualitySelector', () {
    testWidgets('shows all quality levels', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showHlsQualitySelector(context, HlsQualityLevel.auto);
                },
                child: const Text('Show Selector'),
              ),
            ),
          ),
        ),
      );

      // Tap button to show dialog
      await tester.tap(find.text('Show Selector'));
      await tester.pumpAndSettle();

      // Verify dialog is shown
      expect(find.text('Video Quality'), findsOneWidget);

      // Verify all quality levels are shown
      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('720p'), findsOneWidget);
      expect(find.text('480p'), findsOneWidget);
      expect(find.text('360p'), findsOneWidget);

      // Verify auto has subtitle
      expect(find.text('Adapts to your connection'), findsOneWidget);

      // Verify cancel button
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('shows selected quality with check icon', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showHlsQualitySelector(
                    context,
                    const HlsQualityLevel(label: '720p', height: 720),
                  );
                },
                child: const Text('Show Selector'),
              ),
            ),
          ),
        ),
      );

      // Tap button to show dialog
      await tester.tap(find.text('Show Selector'));
      await tester.pumpAndSettle();

      // Verify check_circle icon exists (for selected item)
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      // Verify circle_outlined icons exist (for unselected items)
      expect(find.byIcon(Icons.circle_outlined), findsNWidgets(4));
    });

    testWidgets('returns selected quality when tapped', (tester) async {
      HlsQualityLevel? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showHlsQualitySelector(
                    context,
                    HlsQualityLevel.auto,
                  );
                },
                child: const Text('Show Selector'),
              ),
            ),
          ),
        ),
      );

      // Tap button to show dialog
      await tester.tap(find.text('Show Selector'));
      await tester.pumpAndSettle();

      // Tap 1080p option
      await tester.tap(find.text('1080p'));
      await tester.pumpAndSettle();

      // Verify the result
      expect(result, isNotNull);
      expect(result?.label, equals('1080p'));
      expect(result?.height, equals(1080));
    });

    testWidgets('returns null when cancelled', (tester) async {
      HlsQualityLevel? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showHlsQualitySelector(
                    context,
                    HlsQualityLevel.auto,
                  );
                },
                child: const Text('Show Selector'),
              ),
            ),
          ),
        ),
      );

      // Tap button to show dialog
      await tester.tap(find.text('Show Selector'));
      await tester.pumpAndSettle();

      // Tap cancel button
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Verify the result is null
      expect(result, isNull);
    });
  });
}
