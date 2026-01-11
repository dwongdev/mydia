library webrtc_link;

import 'dart:async';
import 'dart:convert';

import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:flutter/foundation.dart';

import 'package:gql/language.dart';

import '../webrtc/webrtc_connection_manager.dart';

/// A GraphQL Link that routes requests through a WebRTC Data Channel.
class WebRTCLink extends Link {
  final WebRTCConnectionManager _manager;
  final String? _authToken;

  WebRTCLink(this._manager, {String? authToken}) : _authToken = authToken;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    final operation = request.operation;
    final variables = request.variables;
    
    // Determine operation type (query, mutation, subscription)
    // For now we treat everything as a simple request-response
    // Subscriptions would need a different handling over WebRTC (e.g. keeping the stream open)
    
    final operationName = operation.operationName;
    final document = printNode(operation.document);
    
    debugPrint('[WebRTCLink] Sending request: operationName=$operationName');
    
    // Serialize request
    final body = {
      'operationName': operationName,
      'query': document,
      'variables': variables,
    };
    
    final headers = <String, String>{
      'content-type': 'application/json',
    };
    
    if (_authToken != null) {
      headers['authorization'] = 'Bearer $_authToken';
    }
    
    debugPrint('[WebRTCLink] Headers: $headers');
    debugPrint('[WebRTCLink] Calling _manager.request...');
    
    try {
      final response = await _manager.request(
        method: 'POST',
        path: '/api/graphql', // Or whatever endpoint the server expects for tunneled requests
        headers: headers,
        body: jsonEncode(body),
      );
      
      debugPrint('[WebRTCLink] Got response: status=${response.status}');
      
      if (response.status >= 200 && response.status < 300) {
        final Map<String, dynamic> jsonResponse;
        if (response.body is String) {
          jsonResponse = jsonDecode(response.body as String);
        } else if (response.body is Map) {
          jsonResponse = response.body as Map<String, dynamic>;
        } else {
          throw Exception('Invalid response body type: ${response.body.runtimeType}');
        }
        
        yield Response(
          data: jsonResponse['data'],
          errors: (jsonResponse['errors'] as List?)
              ?.map((e) => GraphQLError(message: e.toString()))
              .toList(),
          response: {'headers': response.headers},
        );
      } else {
        throw ServerException(
          originalException: Exception('HTTP ${response.status}: ${response.body}'),
          parsedResponse: Response(response: {'status': response.status, 'body': response.body}),
        );
      }
    } catch (e) {
      throw ServerException(
        originalException: e,
        parsedResponse: Response(response: {'error': e.toString()}),
      );
    }
  }
}
