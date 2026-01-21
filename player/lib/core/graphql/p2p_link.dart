import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gql/language.dart' show printNode;
import 'package:graphql_flutter/graphql_flutter.dart';

import '../p2p/p2p_service.dart';

/// A GraphQL Link that sends operations over P2P.
///
/// This link is used when the app is connected via P2P mode instead of
/// direct HTTP connections. It routes GraphQL queries and mutations through
/// the P2P layer to the Mydia server.
class P2pGraphQLLink extends Link {
  final P2pService _p2pService;
  final String _serverNodeId;
  final Future<String?> Function() _getAuthToken;

  P2pGraphQLLink({
    required P2pService p2pService,
    required String serverNodeId,
    required Future<String?> Function() getAuthToken,
  })  : _p2pService = p2pService,
        _serverNodeId = serverNodeId,
        _getAuthToken = getAuthToken;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    try {
      // Get the current auth token
      final authToken = await _getAuthToken();

      // Convert the request document to a query string using gql's built-in printer
      final query = printNode(request.operation.document);
      final operationName = request.operation.operationName;
      final variables = request.variables;

      debugPrint('[P2pGraphQLLink] Sending request: $operationName');

      // Send the GraphQL request over P2P
      final responseData = await _p2pService.sendGraphQLRequest(
        peer: _serverNodeId,
        query: query,
        variables: variables.isNotEmpty ? variables : null,
        operationName: operationName,
        authToken: authToken,
      );

      debugPrint('[P2pGraphQLLink] Received response');

      // Create the response
      yield Response(
        data: responseData,
        context: request.context,
        response: const {},
      );
    } catch (e, stackTrace) {
      debugPrint('[P2pGraphQLLink] Error: $e');
      debugPrint('[P2pGraphQLLink] Stack: $stackTrace');

      // Yield an error response
      yield Response(
        errors: [
          GraphQLError(
            message: e.toString(),
          ),
        ],
        context: request.context,
        response: const {},
      );
    }
  }
}

/// Creates a GraphQL client configured for P2P mode.
///
/// [p2pService] - The P2P service instance for sending requests
/// [serverNodeId] - The node ID of the Mydia server to connect to
/// [getAuthToken] - A function that returns the current auth token
GraphQLClient createP2pGraphQLClient({
  required P2pService p2pService,
  required String serverNodeId,
  required Future<String?> Function() getAuthToken,
}) {
  final link = P2pGraphQLLink(
    p2pService: p2pService,
    serverNodeId: serverNodeId,
    getAuthToken: getAuthToken,
  );

  return GraphQLClient(
    link: link,
    cache: GraphQLCache(store: HiveStore()),
  );
}
