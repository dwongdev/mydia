// Web implementation for lifecycle events using dart:html.
// ignore: avoid_web_libraries_in_flutter
// ignore: deprecated_member_use
import 'dart:html' as html;

typedef BeforeUnloadCallback = void Function();

BeforeUnloadCallback? _currentCallback;

void _onBeforeUnload(html.Event event) {
  _currentCallback?.call();
}

/// Register a callback to be called before the page unloads.
/// On web, this listens to the 'beforeunload' event.
void registerBeforeUnload(BeforeUnloadCallback callback) {
  _currentCallback = callback;
  html.window.addEventListener('beforeunload', _onBeforeUnload);
}

/// Unregister the beforeunload callback.
void unregisterBeforeUnload() {
  html.window.removeEventListener('beforeunload', _onBeforeUnload);
  _currentCallback = null;
}
