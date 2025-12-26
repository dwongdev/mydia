# Seek Preview Implementation

## Overview

This document describes the implementation of seek preview thumbnail functionality for the Flutter video player.

## Components Implemented

### 1. ThumbnailService (`lib/core/player/thumbnail_service.dart`)

A service that fetches and parses WebVTT files containing thumbnail sprite sheet mappings.

**Features:**
- Fetches VTT files from `/api/v1/media/{file_id}/thumbnails.vtt`
- Parses WebVTT format to extract timestamp-to-sprite mappings
- Supports sprite sheet coordinates in `#xywh=x,y,width,height` format
- Caches parsed thumbnail data to avoid repeated requests
- Graceful fallback when thumbnails are unavailable

**Usage:**
```dart
final thumbnailService = ThumbnailService(
  serverUrl: serverUrl,
  authToken: authToken,
);

// Fetch thumbnails for a file
final cues = await thumbnailService.fetchThumbnails(fileId);

// Get thumbnail for specific timestamp
final cue = thumbnailService.getThumbnailForTime(cues, seekPosition);

// Build sprite URL
final spriteUrl = thumbnailService.getSpriteUrl(cue.spriteFilename);
```

### 2. SeekPreview Widget (`lib/presentation/widgets/seek_preview.dart`)

A widget that displays thumbnail previews during video scrubbing.

**Features:**
- Displays cropped section of sprite sheet based on VTT coordinates
- Shows timestamp label with thumbnail
- Smooth fade in/out animations
- Handles loading and error states gracefully
- Authenticated image loading with bearer tokens

**Components:**
- `SeekPreview`: Core widget that renders a single thumbnail preview
- `SeekPreviewOverlay`: Wrapper that manages state and positioning

### 3. Backend API (`lib/mydia_web/controllers/api/thumbnail_controller.ex`)

Controller for serving thumbnail assets.

**Endpoints:**
- `GET /api/v1/media/:id/thumbnails.vtt` - Serves WebVTT file
- `GET /api/v1/media/:id/thumbnails.jpg` - Serves sprite sheet image

**Features:**
- Serves files from GeneratedMedia storage
- Long cache headers (1 year) for performance
- 404 responses when thumbnails unavailable
- Graceful handling of missing files on disk

### 4. Static File Serving

The endpoint configuration already supports serving generated media files:

```elixir
plug Plug.Static,
  at: "/generated",
  from: Application.compile_env(:mydia, :generated_media_path) ||
        Path.join(Application.app_dir(:mydia, "priv"), "generated"),
  gzip: false,
  cache_control_for_etags: "public, max-age=31536000"
```

Sprite sheets are accessible at `/generated/sprites/{tier1}/{tier2}/{checksum}.jpg`.

## Current Limitation

### Chewie Integration Challenge

The current implementation uses the Chewie video player package, which does not expose seek bar drag events or scrubbing state to the parent widget. This means we cannot directly detect when the user is dragging the seek bar to show thumbnail previews at the exact moment of interaction.

**Why This Matters:**
- Seek previews are most useful when shown during active seeking/scrubbing
- Chewie abstracts its controls and doesn't provide hooks for drag events
- The `VideoPlayerController` only reports discrete position changes, not continuous drag state

### Possible Solutions

#### Option 1: Custom Video Controls (Recommended)
Replace Chewie with custom-built video controls that expose seek drag events:

```dart
// Example of custom seek bar with drag detection
Positioned(
  bottom: 0,
  left: 0,
  right: 0,
  child: GestureDetector(
    onHorizontalDragStart: (details) {
      // Show seek preview
      setState(() => _isSeeking = true);
    },
    onHorizontalDragUpdate: (details) {
      // Update seek preview position
      final seekPosition = _calculateSeekPosition(details);
      setState(() => _seekPosition = seekPosition);
    },
    onHorizontalDragEnd: (details) {
      // Hide seek preview and seek video
      setState(() => _isSeeking = false);
      _videoController.seekTo(Duration(seconds: _seekPosition!.toInt()));
    },
    child: CustomSeekBar(...),
  ),
)
```

#### Option 2: Fork/Extend Chewie
Modify Chewie to expose seek drag callbacks:

```dart
ChewieController(
  ...
  onSeekStart: () => setState(() => _showPreview = true),
  onSeekUpdate: (position) => setState(() => _seekPosition = position),
  onSeekEnd: () => setState(() => _showPreview = false),
)
```

#### Option 3: Hover-Based Previews (Web/Desktop)
For web and desktop platforms, show previews on hover over the seek bar instead of during drag:

```dart
MouseRegion(
  onHover: (event) {
    final position = _calculatePositionFromHover(event);
    setState(() {
      _hoverPosition = position;
      _showPreview = true;
    });
  },
  onExit: (_) => setState(() => _showPreview = false),
  child: SeekBar(...),
)
```

## Integration Steps (When Controls Are Updated)

Once custom controls or an extended Chewie are available:

1. **Add thumbnail state to PlayerScreen:**
```dart
// Add to _PlayerScreenState
ThumbnailService? _thumbnailService;
List<ThumbnailCue> _thumbnailCues = [];
double? _seekPosition;
bool _isSeeking = false;
```

2. **Load thumbnails during initialization:**
```dart
Future<void> _loadThumbnails(String serverUrl, String token) async {
  _thumbnailService = ThumbnailService(
    serverUrl: serverUrl,
    authToken: token,
  );

  try {
    final cues = await _thumbnailService!.fetchThumbnails(widget.fileId);
    setState(() {
      _thumbnailCues = cues;
    });
    debugPrint('Loaded ${cues.length} thumbnail cues');
  } catch (e) {
    debugPrint('Failed to load thumbnails: $e');
  }
}

// Call after player initialization
_loadThumbnails(serverUrl, token);
```

3. **Add seek preview overlay to UI:**
```dart
Stack(
  children: [
    // Video player
    Chewie(controller: _chewieController!),

    // Seek preview overlay
    if (_thumbnailService != null && _isSeeking)
      SeekPreviewOverlay(
        thumbnailCues: _thumbnailCues,
        seekPosition: _seekPosition,
        duration: _videoController!.value.duration.inSeconds.toDouble(),
        serverUrl: serverUrl,
        authToken: token,
        thumbnailService: _thumbnailService!,
      ),

    // Other overlays...
  ],
)
```

4. **Wire up seek events:**
```dart
// When seek drag starts
onSeekStart: () {
  setState(() => _isSeeking = true);
},

// When seek position updates
onSeekUpdate: (double position) {
  setState(() => _seekPosition = position);
},

// When seek drag ends
onSeekEnd: () {
  setState(() {
    _isSeeking = false;
    _seekPosition = null;
  });
},
```

## Backend Data Flow

1. **Thumbnail Generation** (background job):
   - `ThumbnailGenerator.generate(media_file)` creates sprite sheet and VTT
   - Files stored in `GeneratedMedia` with checksums
   - `media_file.sprite_blob` and `media_file.vtt_blob` updated

2. **Client Request Flow**:
   ```
   Flutter Client
     |
     ├─> GET /api/v1/media/:id/thumbnails.vtt
     |     └─> ThumbnailController.show_vtt
     |           └─> Serves file from GeneratedMedia storage
     |
     ├─> Parse VTT to extract sprite coordinates
     |
     └─> GET /generated/sprites/{tier1}/{tier2}/{checksum}.jpg
           └─> Plug.Static serves sprite sheet
   ```

3. **Sprite Cropping**:
   - Flutter loads full sprite sheet via `CachedNetworkImage`
   - Uses `Transform.translate` and `ClipRect` to crop region
   - Coordinates from VTT: `#xywh=x,y,width,height`

## Testing

### Backend Testing

Test VTT endpoint:
```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:4000/api/v1/media/$FILE_ID/thumbnails.vtt
```

Test sprite endpoint:
```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:4000/api/v1/media/$FILE_ID/thumbnails.jpg \
  --output sprite.jpg
```

### Flutter Testing

```dart
// Test thumbnail service
final service = ThumbnailService(
  serverUrl: 'http://localhost:4000',
  authToken: testToken,
);

final cues = await service.fetchThumbnails(testFileId);
expect(cues.isNotEmpty, true);

final cue = service.getThumbnailForTime(cues, 30.0);
expect(cue, isNotNull);
expect(cue!.contains(30.0), true);
```

## Performance Considerations

1. **Caching:**
   - VTT files cached in `ThumbnailService._cache`
   - Sprite sheets cached by `CachedNetworkImage`
   - Backend serves with 1-year cache headers

2. **Network Efficiency:**
   - VTT file only fetched once per file
   - Single sprite sheet contains all thumbnails
   - Authenticated requests use existing session token

3. **Memory:**
   - Sprite sheets ~500KB-2MB typical
   - VTT files ~5-20KB typical
   - Flutter's image cache handles memory management

## Future Enhancements

1. **Progress Indicator:** Show loading state while VTT is being fetched
2. **Prefetching:** Preload sprites for likely-to-play content
3. **Multiple Quality Levels:** Generate multiple sprite resolutions
4. **Live Thumbnails:** Generate on-demand for live content
5. **Touch Feedback:** Haptic feedback when dragging seek bar

## Conclusion

The core infrastructure for seek preview thumbnails is complete and ready to use. The only remaining step is integrating with video player controls that expose seek drag events. Once custom controls are implemented (or Chewie is extended), the preview overlay can be added to the player screen with minimal code changes.

All backend endpoints, services, and widgets are fully functional and tested. The implementation follows Flutter best practices and includes proper error handling, caching, and graceful degradation when thumbnails are unavailable.
