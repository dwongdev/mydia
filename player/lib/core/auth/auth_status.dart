/// Authentication status for the app.
///
/// Used to distinguish between different authentication states,
/// particularly for handling offline mode where credentials exist
/// but the server is unreachable.
enum AuthStatus {
  /// No stored credentials - user needs to login
  unauthenticated,

  /// Connected to server with valid credentials
  authenticated,

  /// Has credentials but can't reach server - downloads only mode
  offlineMode,
}
