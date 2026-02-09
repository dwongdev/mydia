import 'package:flutter_test/flutter_test.dart';
import 'package:player/app.dart';
import 'package:player/native/frb_generated.dart'
    if (dart.library.js_interop) 'package:player/native/frb_stub.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('Can call rust function', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.textContaining('Result: `Hello, Tom!`'), findsOneWidget);
  });
}
