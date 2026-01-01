/// Binary content encoding/decoding for control plane messages.
///
/// This library provides encoding and decoding of message bodies with automatic
/// detection of binary vs UTF-8 content. Enables transmission of binary data
/// (thumbnails, encrypted blobs) through the relay control plane.
///
/// ## Encoding Format
///
/// Messages include a `body_encoding` field:
/// - `"raw"` - Body is UTF-8 text (default, most common)
/// - `"base64"` - Body is base64-encoded binary data
///
/// ## Usage
///
/// ```dart
/// // Decoding (handles both formats)
/// final text = MessageDecoder.decodeBody({'body': 'Hello', 'body_encoding': 'raw'});
/// // => 'Hello' (as String)
///
/// final binary = MessageDecoder.decodeBody({'body': 'AAEC/w==', 'body_encoding': 'base64'});
/// // => Uint8List [0, 1, 2, 255]
///
/// // Backwards compatible - assumes raw if no encoding specified
/// final legacy = MessageDecoder.decodeBody({'body': 'Legacy message'});
/// // => 'Legacy message' (as String)
///
/// // Encoding
/// final encoded = MessageDecoder.encodeBody('Hello');
/// // => {'body': 'Hello', 'body_encoding': 'raw'}
///
/// final binaryEncoded = MessageDecoder.encodeBody(Uint8List.fromList([0, 255]));
/// // => {'body': 'AP8=', 'body_encoding': 'base64'}
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

/// Encoding type for message bodies.
enum BodyEncoding {
  /// UTF-8 text content (default)
  raw,

  /// Base64-encoded binary content
  base64,
}

/// Decoder/encoder for control plane message bodies.
///
/// Handles automatic detection and conversion between UTF-8 text
/// and binary data using the `body_encoding` field.
abstract class MessageDecoder {
  /// Decodes a message body based on the encoding field.
  ///
  /// Returns:
  /// - A [String] for "raw" encoding
  /// - A [Uint8List] for "base64" encoding
  /// - `null` if the body is null
  ///
  /// If no `body_encoding` field is present, assumes "raw" for
  /// backwards compatibility with legacy messages.
  ///
  /// ## Parameters
  ///
  /// - [message] - A map with "body" and optionally "body_encoding" fields
  ///
  /// ## Returns
  ///
  /// The decoded body as either [String] or [Uint8List], or `null`.
  static dynamic decodeBody(Map<String, dynamic> message) {
    final body = message['body'];
    if (body == null) return null;

    final encoding = message['body_encoding'] ?? 'raw';

    if (encoding == 'base64' && body is String) {
      return base64Decode(body);
    }

    return body;
  }

  /// Decodes a message body as a [String].
  ///
  /// If the body is base64-encoded, decodes it and converts to UTF-8 string.
  /// Returns `null` if the body is null.
  ///
  /// ## Parameters
  ///
  /// - [message] - A map with "body" and optionally "body_encoding" fields
  ///
  /// ## Returns
  ///
  /// The decoded body as a [String], or `null`.
  static String? decodeBodyAsString(Map<String, dynamic> message) {
    final decoded = decodeBody(message);
    if (decoded == null) return null;
    if (decoded is String) return decoded;
    if (decoded is Uint8List) return utf8.decode(decoded);
    return decoded.toString();
  }

  /// Decodes a message body as binary [Uint8List].
  ///
  /// If the body is a raw string, converts it to UTF-8 bytes.
  /// Returns `null` if the body is null.
  ///
  /// ## Parameters
  ///
  /// - [message] - A map with "body" and optionally "body_encoding" fields
  ///
  /// ## Returns
  ///
  /// The decoded body as [Uint8List], or `null`.
  static Uint8List? decodeBodyAsBytes(Map<String, dynamic> message) {
    final decoded = decodeBody(message);
    if (decoded == null) return null;
    if (decoded is Uint8List) return decoded;
    if (decoded is String) return Uint8List.fromList(utf8.encode(decoded));
    return null;
  }

  /// Encodes a body value with automatic type detection.
  ///
  /// Strings are encoded as "raw", binary data as "base64".
  ///
  /// ## Parameters
  ///
  /// - [body] - The body content (String, Uint8List, List<int>, or null)
  ///
  /// ## Returns
  ///
  /// A map with `body` and `body_encoding` fields.
  static Map<String, dynamic> encodeBody(dynamic body) {
    if (body == null) {
      return {'body': null, 'body_encoding': 'raw'};
    }

    if (body is String) {
      return {'body': body, 'body_encoding': 'raw'};
    }

    if (body is Uint8List) {
      return {'body': base64Encode(body), 'body_encoding': 'base64'};
    }

    if (body is List<int>) {
      return {
        'body': base64Encode(Uint8List.fromList(body)),
        'body_encoding': 'base64',
      };
    }

    // Fallback: convert to string
    return {'body': body.toString(), 'body_encoding': 'raw'};
  }

  /// Checks if a message body is binary (base64 encoded).
  ///
  /// ## Parameters
  ///
  /// - [message] - A map with optionally "body_encoding" field
  ///
  /// ## Returns
  ///
  /// `true` if the body is base64-encoded, `false` otherwise.
  static bool isBinaryBody(Map<String, dynamic> message) {
    return message['body_encoding'] == 'base64';
  }

  /// Gets the body encoding from a message.
  ///
  /// ## Parameters
  ///
  /// - [message] - A map with optionally "body_encoding" field
  ///
  /// ## Returns
  ///
  /// The [BodyEncoding] value, defaulting to [BodyEncoding.raw].
  static BodyEncoding getBodyEncoding(Map<String, dynamic> message) {
    final encoding = message['body_encoding'];
    if (encoding == 'base64') return BodyEncoding.base64;
    return BodyEncoding.raw;
  }
}
