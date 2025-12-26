/// Native implementation using dart:io.
library;

import 'dart:io';

Future<bool> fileExists(String path) async {
  return await File(path).exists();
}
