// Web-specific URL handling using dart:html and dart:js
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

/// Gets the initial route from the browser's URL hash.
/// Returns the hash without the leading '#', or '/' if no hash is present.
///
/// Phoenix injects `window.mydiaInitialHash` before Flutter loads to capture
/// the hash before any potential timing issues with dart:html's window.location.
String getInitialRoute() {
  // First, try to read the hash that Phoenix captured before Flutter loaded
  final phoenixHash = js.context['mydiaInitialHash'] as String?;

  // Also try direct access as fallback
  final hash = html.window.location.hash;
  final href = html.window.location.href;

  // Use Phoenix-captured hash first, then fallback to direct access
  String effectiveHash = '';

  if (phoenixHash != null && phoenixHash.isNotEmpty) {
    effectiveHash = phoenixHash;
  } else if (hash.isNotEmpty) {
    effectiveHash = hash;
  } else if (href.contains('#')) {
    final hashIndex = href.indexOf('#');
    effectiveHash = href.substring(hashIndex);
  }

  if (effectiveHash.isNotEmpty && effectiveHash.length > 1) {
    // Remove the leading '#' from the hash
    return effectiveHash.substring(1);
  }
  return '/';
}
