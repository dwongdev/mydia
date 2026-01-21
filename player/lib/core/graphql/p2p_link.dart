import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gql/ast.dart';
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

      // Convert the request document to a query string
      final query = _documentToString(request.operation.document);
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

  /// Convert a GraphQL DocumentNode to a query string.
  String _documentToString(DocumentNode document) {
    final buffer = StringBuffer();

    for (final definition in document.definitions) {
      if (definition is OperationDefinitionNode) {
        _writeOperation(buffer, definition);
      } else if (definition is FragmentDefinitionNode) {
        _writeFragment(buffer, definition);
      }
    }

    return buffer.toString();
  }

  void _writeOperation(StringBuffer buffer, OperationDefinitionNode op) {
    // Operation type
    switch (op.type) {
      case OperationType.query:
        buffer.write('query ');
        break;
      case OperationType.mutation:
        buffer.write('mutation ');
        break;
      case OperationType.subscription:
        buffer.write('subscription ');
        break;
    }

    // Operation name
    if (op.name != null) {
      buffer.write(op.name!.value);
    }

    // Variables
    if (op.variableDefinitions.isNotEmpty) {
      buffer.write('(');
      for (var i = 0; i < op.variableDefinitions.length; i++) {
        if (i > 0) buffer.write(', ');
        _writeVariableDefinition(buffer, op.variableDefinitions[i]);
      }
      buffer.write(')');
    }

    // Selection set
    buffer.write(' ');
    _writeSelectionSet(buffer, op.selectionSet);
  }

  void _writeVariableDefinition(StringBuffer buffer, VariableDefinitionNode varDef) {
    buffer.write('\$${varDef.variable.name.value}: ');
    _writeType(buffer, varDef.type);
    final defaultValue = varDef.defaultValue?.value;
    if (defaultValue != null) {
      buffer.write(' = ');
      _writeValue(buffer, defaultValue);
    }
  }

  void _writeType(StringBuffer buffer, TypeNode type) {
    if (type is NamedTypeNode) {
      buffer.write(type.name.value);
      if (!type.isNonNull) return;
    } else if (type is ListTypeNode) {
      buffer.write('[');
      _writeType(buffer, type.type);
      buffer.write(']');
    }
  }

  void _writeSelectionSet(StringBuffer buffer, SelectionSetNode selectionSet) {
    buffer.write('{ ');
    for (final selection in selectionSet.selections) {
      _writeSelection(buffer, selection);
      buffer.write(' ');
    }
    buffer.write('}');
  }

  void _writeSelection(StringBuffer buffer, SelectionNode selection) {
    if (selection is FieldNode) {
      _writeField(buffer, selection);
    } else if (selection is FragmentSpreadNode) {
      buffer.write('...${selection.name.value}');
    } else if (selection is InlineFragmentNode) {
      buffer.write('...');
      if (selection.typeCondition != null) {
        buffer.write(' on ${selection.typeCondition!.on.name.value}');
      }
      buffer.write(' ');
      _writeSelectionSet(buffer, selection.selectionSet);
    }
  }

  void _writeField(StringBuffer buffer, FieldNode field) {
    // Alias
    if (field.alias != null) {
      buffer.write('${field.alias!.value}: ');
    }

    // Name
    buffer.write(field.name.value);

    // Arguments
    if (field.arguments.isNotEmpty) {
      buffer.write('(');
      for (var i = 0; i < field.arguments.length; i++) {
        if (i > 0) buffer.write(', ');
        final arg = field.arguments[i];
        buffer.write('${arg.name.value}: ');
        _writeValue(buffer, arg.value);
      }
      buffer.write(')');
    }

    // Selection set
    if (field.selectionSet != null) {
      buffer.write(' ');
      _writeSelectionSet(buffer, field.selectionSet!);
    }
  }

  void _writeFragment(StringBuffer buffer, FragmentDefinitionNode fragment) {
    buffer.write('fragment ${fragment.name.value} on ${fragment.typeCondition.on.name.value} ');
    _writeSelectionSet(buffer, fragment.selectionSet);
    buffer.write(' ');
  }

  void _writeValue(StringBuffer buffer, ValueNode value) {
    if (value is VariableNode) {
      buffer.write('\$${value.name.value}');
    } else if (value is IntValueNode) {
      buffer.write(value.value);
    } else if (value is FloatValueNode) {
      buffer.write(value.value);
    } else if (value is StringValueNode) {
      buffer.write('"${_escapeString(value.value)}"');
    } else if (value is BooleanValueNode) {
      buffer.write(value.value ? 'true' : 'false');
    } else if (value is NullValueNode) {
      buffer.write('null');
    } else if (value is EnumValueNode) {
      buffer.write(value.name.value);
    } else if (value is ListValueNode) {
      buffer.write('[');
      for (var i = 0; i < value.values.length; i++) {
        if (i > 0) buffer.write(', ');
        _writeValue(buffer, value.values[i]);
      }
      buffer.write(']');
    } else if (value is ObjectValueNode) {
      buffer.write('{');
      for (var i = 0; i < value.fields.length; i++) {
        if (i > 0) buffer.write(', ');
        final field = value.fields[i];
        buffer.write('${field.name.value}: ');
        _writeValue(buffer, field.value);
      }
      buffer.write('}');
    }
  }

  String _escapeString(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
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
