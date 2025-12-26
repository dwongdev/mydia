# Mydia Player

A cross-platform media player client for Mydia, built with Flutter.

## Features

- Cross-platform support (iOS, Android, Web, macOS, Windows, Linux)
- Clean architecture with separation of concerns
- Dark theme optimized for media consumption
- GraphQL integration with Mydia backend
- Secure credential storage
- Offline media caching

## Getting Started

### Prerequisites

- Flutter SDK 3.2.0 or higher
- Dart SDK 3.2.0 or higher

### Installation

1. Install dependencies:
   ```bash
   flutter pub get
   ```

2. Generate code (for Riverpod providers and other generated code):
   ```bash
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

### Running

Development mode:
```bash
flutter run
```

Specific platform:
```bash
flutter run -d chrome      # Web
flutter run -d macos       # macOS
flutter run -d android     # Android
flutter run -d ios         # iOS
```

### Building

Web:
```bash
flutter build web
```

Android:
```bash
flutter build apk          # APK
flutter build appbundle    # App Bundle
```

iOS:
```bash
flutter build ios
```

Desktop:
```bash
flutter build macos
flutter build windows
flutter build linux
```

## Project Structure

```
lib/
├── main.dart                 # Application entry point
├── app.dart                  # App configuration
├── core/                     # Core utilities and configuration
│   ├── theme/               # App theming
│   ├── router/              # Navigation configuration
│   └── providers/           # Global providers
├── data/                     # Data layer (repositories, data sources)
├── domain/                   # Domain layer (entities, use cases)
└── presentation/            # Presentation layer (screens, widgets)
    ├── screens/
    └── widgets/
```

## Code Generation

This project uses code generation for:
- Riverpod providers (`riverpod_generator`)
- Router configuration (go_router with code generation)

Run code generation:
```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

Watch mode for development:
```bash
flutter pub run build_runner watch --delete-conflicting-outputs
```

## Architecture

The project follows Clean Architecture principles:

- **Presentation Layer**: Flutter widgets, screens, and UI state management
- **Domain Layer**: Business logic and entities (coming soon)
- **Data Layer**: API clients, repositories, and local storage (coming soon)

State management is handled by Riverpod 2.x with code generation.

## Configuration

The app connects to a Mydia server instance. Configure the server URL in the login screen or through app settings.

## Development

### Adding Dependencies

Add to `pubspec.yaml` and run:
```bash
flutter pub get
```

### Linting

The project uses `flutter_lints` for code quality. Run analysis:
```bash
flutter analyze
```

### Testing

Run tests:
```bash
flutter test
```

## License

This project is part of the Mydia ecosystem.
