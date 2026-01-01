/// Custom GraphQL Link that routes requests through a relay tunnel.
///
/// This link is used when the player is connected via relay mode (when direct
/// connection to the Mydia instance is not possible). Instead of making HTTP
/// requests directly, it sends them through the WebSocket tunnel to the
/// metadata-relay service, which forwards them to the Mydia instance.
///
/// ## Usage
///
/// ```dart
/// final tunnel = await tunnelService.connectViaRelay(instanceId);
/// final link = RelayLink(tunnel);
/// final client = GraphQLClient(link: link, cache: cache);
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';

import '../relay/relay_tunnel_service.dart';

/// A GraphQL Link that sends requests through a relay tunnel.
///
/// This link wraps a [RelayTunnel] and routes all GraphQL queries and mutations
/// through it using the tunnel's HTTP request proxying capability.
class RelayLink extends Link {
  /// Creates a new [RelayLink] with the given tunnel.
  ///
  /// The [tunnel] must be active (connected) before creating the link.
  /// The optional [authToken] is added to request headers for authentication.
  RelayLink(this._tunnel, {this.authToken});

  final RelayTunnel _tunnel;

  /// Optional auth token to include in requests.
  final String? authToken;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    if (!_tunnel.isActive) {
      yield Response(
        response: const <String, dynamic>{},
        data: null,
        errors: [
          const GraphQLError(message: 'Relay tunnel is not active'),
        ],
        context: request.context,
      );
      return;
    }

    try {
      // Build the GraphQL request body
      final body = json.encode({
        'query': request.operation.document.definitions
            .map((d) => d.toString())
            .join('\n'),
        'operationName': request.operation.operationName,
        'variables': request.variables,
      });

      // Build headers
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

      // Add auth token if available
      if (authToken != null) {
        headers['Authorization'] = 'Bearer $authToken';
      }

      debugPrint('[RelayLink] Sending GraphQL request through tunnel');
      debugPrint('[RelayLink] Operation: ${request.operation.operationName}');

      // Send request through tunnel
      final tunnelResponse = await _tunnel.request(
        method: 'POST',
        path: '/api/graphql',
        headers: headers,
        body: body,
      );

      debugPrint('[RelayLink] Tunnel response status: ${tunnelResponse.status}');

      if (!tunnelResponse.isSuccess) {
        yield Response(
          response: <String, dynamic>{'statusCode': tunnelResponse.status},
          data: null,
          errors: [
            GraphQLError(
              message:
                  'Tunnel request failed with status ${tunnelResponse.status}',
            ),
          ],
          context: request.context,
        );
        return;
      }

      // Parse the response body
      final responseBody = tunnelResponse.bodyAsString;
      if (responseBody == null) {
        yield Response(
          response: const <String, dynamic>{},
          data: null,
          errors: [
            const GraphQLError(message: 'Empty response from tunnel'),
          ],
          context: request.context,
        );
        return;
      }

      debugPrint('[RelayLink] Response body length: ${responseBody.length}');

      final Map<String, dynamic> jsonResponse;
      try {
        jsonResponse = json.decode(responseBody) as Map<String, dynamic>;
      } catch (e) {
        yield Response(
          response: const <String, dynamic>{},
          data: null,
          errors: [
            GraphQLError(message: 'Failed to parse response: $e'),
          ],
          context: request.context,
        );
        return;
      }

      // Extract data and errors from GraphQL response
      final data = jsonResponse['data'] as Map<String, dynamic>?;
      final errorsJson = jsonResponse['errors'] as List<dynamic>?;

      List<GraphQLError>? errors;
      if (errorsJson != null) {
        errors = errorsJson.map((e) {
          final errorMap = e as Map<String, dynamic>;
          return GraphQLError(
            message: errorMap['message'] as String? ?? 'Unknown error',
            locations: (errorMap['locations'] as List<dynamic>?)
                ?.map((l) {
                  final loc = l as Map<String, dynamic>;
                  return ErrorLocation(
                    line: loc['line'] as int? ?? 0,
                    column: loc['column'] as int? ?? 0,
                  );
                })
                .toList(),
            path: (errorMap['path'] as List<dynamic>?)
                ?.map((p) => p.toString())
                .toList(),
            extensions: errorMap['extensions'] as Map<String, dynamic>?,
          );
        }).toList();
      }

      yield Response(
        response: jsonResponse,
        data: data,
        errors: errors,
        context: request.context,
      );
    } catch (e, stack) {
      debugPrint('[RelayLink] Error: $e');
      debugPrint('[RelayLink] Stack: $stack');
      yield Response(
        response: const <String, dynamic>{},
        data: null,
        errors: [
          GraphQLError(message: 'Relay request failed: $e'),
        ],
        context: request.context,
      );
    }
  }
}
