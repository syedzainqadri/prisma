import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart';
import 'package:retry/retry.dart';

import '../../../version.dart';
import '../../configure/environment.dart';
import '../../runtime/datasource.dart';
import '../../runtime/prisma_log.dart';
import '../common/engine.dart';
import '../common/errors/prisma_client_unknown_request_error.dart';
import '../common/get_config_result.dart';
import '../common/types/query_engine.dart';
import '../common/types/transaction.dart';
import '../intenal_utils/header_getter.dart';
import '../intenal_utils/is_schema_missing.dart';
import '../intenal_utils/runtime_http_headers_builder.dart';
import '../intenal_utils/throw_graphql_error.dart';
import '_internal/data_proxy_tx_info.dart';

/// Prisma data proxy engine.
class DataProxyEngine extends Engine {
  DataProxyEngine({
    required super.logEmitter,
    required super.schema,
    required super.dmmf,
    required super.datasources,
    required super.environment,
    required this.intenalDatasources,
  });

  /// Internal datasources.
  final Iterable<Datasource> intenalDatasources;

  @override
  Future<void> commitTransaction(
      {required TransactionHeaders headers,
      required TransactionInfo info}) async {
    final Uri url = (info as DataProxyTxInfo).endpoint;
    final Uri endppoint = url.replace(
      pathSegments: [
        ...url.pathSegments,
        'commit',
      ],
    );
    final Response response = await post(
      endppoint,
      headers: runtimeHttpHeadersBuilder(headers.toJson()),
    );

    if (response.statusCode > 400) {
      final e = PrismaClientUnknownRequestError('Bad request',
          clientVersion: binaryVersion);
      logEmitter.emit(PrismaLogLevel.error, e);
      throw e;
    }

    final Map<String, dynamic> json = jsonDecode(response.body);
    try {
      throwGraphQLError(json['errors']);
    } on Exception catch (e) {
      logEmitter.emit(PrismaLogLevel.error, e);
      rethrow;
    }
  }

  @override
  Future<void> rollbackTransaction(
      {required TransactionHeaders headers,
      required TransactionInfo info}) async {
    final Uri url = (info as DataProxyTxInfo).endpoint;
    final Uri endppoint = url.replace(
      pathSegments: [
        ...url.pathSegments,
        'rollback',
      ],
    );
    final Response response = await post(
      endppoint,
      headers: runtimeHttpHeadersBuilder(headers.toJson()),
    );

    if (response.statusCode > 400) {
      final e = PrismaClientUnknownRequestError('Bad request',
          clientVersion: binaryVersion);
      logEmitter.emit(PrismaLogLevel.error, e);
      throw e;
    }

    final Map<String, dynamic> json = jsonDecode(response.body);
    try {
      throwGraphQLError(json['errors']);
    } on Exception catch (e) {
      logEmitter.emit(PrismaLogLevel.error, e);
      rethrow;
    }
  }

  @override
  Future<TransactionInfo> startTransaction(
      {required TransactionHeaders headers,
      TransactionOptions options = const TransactionOptions()}) async {
    final Uri baseUrl = await url;
    final Uri endpoint = baseUrl.replace(
      pathSegments: [...baseUrl.pathSegments, 'transaction', 'start'],
    );
    final String body = jsonEncode({
      'max_wait': options.maxWait,
      'timeout': options.timeout,
      'isolation_level': options.isolationLevel?.name,
    });
    final Response response = await post(
      endpoint,
      headers: {
        ...runtimeHttpHeadersBuilder(headers.toJson()),
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (response.statusCode > 400) {
      final e = PrismaClientUnknownRequestError('Bad request',
          clientVersion: binaryVersion);
      logEmitter.emit(PrismaLogLevel.error, e);
      throw e;
    }

    final Map<String, dynamic> json = jsonDecode(response.body);
    try {
      throwGraphQLError(json['errors']);
    } on Exception catch (e) {
      logEmitter.emit(PrismaLogLevel.error, e);
      rethrow;
    }

    return DataProxyTxInfo(json['id'],
        endpoint: json['data-proxy']['endpoint']);
  }

  @override
  Future<void> start() async {
    // Ignore: Data proxy don't need to start
  }

  @override
  Future<void> stop() async {
    // Ignore: Data proxy don't need to stop
  }

  @override
  FutureOr<GetConfigResult> getConfig() {
    throw UnimplementedError('Interactive getConfig are not yet supported');
  }

  @override
  Future<QueryEngineResult> request(
      {required String query, QueryEngineRequestHeaders? headers}) async {
    logEmitter.emit(
      PrismaLogLevel.query,
      PrismaQueryEvent(
        target: '',
        timestamp: DateTime.now(),
        query: query,
        params: "{}",
        duration: 0,
      ),
    );

    final Exception retryException = Exception('retry');
    return retry<QueryEngineResult>(
      () async {
        final Uri url = (await this.url).replace(
          path: '${(await this.url).path}/graphql',
        );
        logEmitter.emit(PrismaLogLevel.info, Exception('Calling $url'));

        final Response response = await post(
          url.replace(
            path: '${url.path}/graphql',
          ),
          body: json.encode({
            'query': query,
            'variables': {},
          }),
          headers: runtimeHttpHeadersBuilder({
            ...?headers?.toJson().cast(),
            'Authorization': 'Bearer $_apiKey',
          }),
          encoding: utf8,
        );

        final Map<String, dynamic> result = json.decode(response.body);

        if (isSchemaMissing(result)) {
          await _updateSchema();
          throw retryException;
        } else if (response.statusCode > 400) {
          final e = PrismaClientUnknownRequestError('Bad request',
              clientVersion: binaryVersion);
          logEmitter.emit(PrismaLogLevel.error, e);
          throw e;
        }

        try {
          throwGraphQLError(result['errors']);
        } on Exception catch (e) {
          logEmitter.emit(PrismaLogLevel.error, e);
          rethrow;
        }

        // Rust engine returns time in microseconds and we want it in miliseconds
        final int elapsed =
            int.parse(headerGetter(response.headers, 'x-elapsed')!) ~/ 1000;

        return QueryEngineResult(result['data'], elapsed);
      },
      maxDelay: const Duration(milliseconds: 200),
      maxAttempts: 10,
      retryIf: (e) =>
          e is ClientException || e is TimeoutException || e == retryException,
    );
  }

  /// Update schema.
  Future<void> _updateSchema() async {
    final Response response = await put(
      (await url).replace(
        path: '${(await url).path}/schema',
      ),
      headers: runtimeHttpHeadersBuilder({
        'Authorization': 'Bearer $_apiKey',
      }),
      encoding: utf8,
      body: schema,
    );

    if (response.statusCode > 400) {
      final e = PrismaClientUnknownRequestError('Update schema failed',
          clientVersion: binaryVersion);
      logEmitter.emit(PrismaLogLevel.error, e);
      throw e;
    }

    logEmitter.emit(PrismaLogLevel.info,
        Exception('Schema (re)uploaded (hash: $schemaHash)'));
  }

  /// Returns base64 encoded string of the schema.
  ///
  /// See https://github.com/prisma/prisma/blob/a7b02ca3f1d13467cdd3cc545249840d67c60791/packages/client/src/generation/utils/buildInlineSchema.ts#L15
  @override
  String get schema => base64.encode(utf8.encode(super.schema));

  /// Returns schame sha256 hash.
  ///
  /// See https://github.com/prisma/prisma/blob/a7b02ca3f1d13467cdd3cc545249840d67c60791/packages/client/src/generation/utils/buildInlineSchema.ts#L16
  String get schemaHash => sha256.convert(utf8.encode(schema)).toString();

  /// Returns connection url.
  Future<Uri> get connectionAddress async {
    // If datasources is not empty, use the first one.
    final Iterable<String> urls = datasources.entries
        .map((e) => e.value.url)
        .where((e) => e?.isNotEmpty == true)
        .cast<String>();
    if (urls.isNotEmpty) {
      return parseConnectionAddress(urls.first);
    }

    // Find in internal datasources.
    final Iterable<String> envNames = intenalDatasources
        .map((e) => e.url)
        .where((e) => e?.isNotEmpty == true)
        .cast<String>();
    final PrismaEnvironment environment = await this.environment;

    for (final name in envNames) {
      final value = environment[name];
      if (value?.isNotEmpty == true) {
        return parseConnectionAddress(value!);
      }
    }

    throw StateError('Not found Data Proxy connection address');
  }

  /// Return request url.
  Future<Uri> get url async => (await connectionAddress).replace(
        scheme: 'https',
        path: '/$remoteClientVersion/$schemaHash',
        queryParameters: {},
      );

  /// Return Prisma data proxy api key.
  Future<String> get _apiKey async =>
      (await connectionAddress).queryParameters['api_key']!;

  /// Paser connection address.
  Uri parseConnectionAddress(String url) {
    final Uri uri = Uri.parse(url);

    if (!uri.isScheme('prisma')) {
      throw StateError(
          'Datasource URL must use prisma:// protocol when --data-proxy is used');
    }

    if (!uri.queryParameters.containsKey('api_key')) {
      throw StateError('No valid API key found in the datasource URL');
    }

    return uri;
  }

  /// Return data proxy remote client version.
  Future<String> get remoteClientVersion async =>
      (await environment).clientDataProxyClientVersion;
}
