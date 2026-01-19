/// Web implementation for device info.
library;

import 'package:device_info_plus/device_info_plus.dart';

Future<String> getDeviceName() async {
  final deviceInfo = DeviceInfoPlugin();
  final webInfo = await deviceInfo.webBrowserInfo;

  // Return browser name and platform
  final browser = webInfo.browserName.name;
  final platform = webInfo.platform ?? 'Unknown';

  return '$browser on $platform';
}

String getPlatform() {
  return 'web';
}
