library flex_http;

import 'dart:convert';
import 'dart:io';
import 'dart:async';

class FlexHttp {
  HttpClient? _client;
  final String? baseUrl;
  final Map<String, String> defaultHeaders;
  final Duration timeout;
  final List<FlexInterceptor> interceptors;
  final int maxRetries;
  final bool enableLogging;
  final Map<String, FlexResponse> _cache = {};
  final int maxConnectionsPerHost;

  FlexHttp._({
    this.baseUrl,
    Map<String, String>? defaultHeaders,
    Duration? timeout,
    List<FlexInterceptor>? interceptors,
    int? maxRetries,
    bool? enableLogging,
    int? maxConnectionsPerHost,
  })  : defaultHeaders = defaultHeaders ?? {},
        timeout = timeout ?? const Duration(seconds: 30),
        interceptors = interceptors ?? [],
        maxRetries = maxRetries ?? 0,
        enableLogging = enableLogging ?? false,
        maxConnectionsPerHost = maxConnectionsPerHost ?? 6;

  factory FlexHttp.config({String? baseUrl}) => FlexHttpBuilder(baseUrl: baseUrl).build();

  HttpClient get client {
    if (_client == null) {
      _client = HttpClient()
        ..maxConnectionsPerHost = maxConnectionsPerHost
        ..idleTimeout = const Duration(seconds: 10);
    }
    return _client!;
  }

  Future<FlexResponse<T>> get<T>(
      String path, {
        Map<String, String>? headers,
        bool useCache = false,
        T Function(dynamic)? decoder,
      }) =>
      _request<T>('GET', path, headers: headers, useCache: useCache, decoder: decoder);

  Future<FlexResponse<T>> post<T>(
      String path, {
        Map<String, String>? headers,
        dynamic body,
        T Function(dynamic)? decoder,
      }) =>
      _request<T>('POST', path, headers: headers, body: body, decoder: decoder);

  Future<FlexResponse<T>> put<T>(
      String path, {
        Map<String, String>? headers,
        dynamic body,
        T Function(dynamic)? decoder,
      }) =>
      _request<T>('PUT', path, headers: headers, body: body, decoder: decoder);

  Future<FlexResponse<T>> delete<T>(
      String path, {
        Map<String, String>? headers,
        T Function(dynamic)? decoder,
      }) =>
      _request<T>('DELETE', path, headers: headers, decoder: decoder);

  Future<FlexResponse<T>> patch<T>(
      String path, {
        Map<String, String>? headers,
        dynamic body,
        T Function(dynamic)? decoder,
      }) =>
      _request<T>('PATCH', path, headers: headers, body: body, decoder: decoder);

  Future<FlexResponse<T>> upload<T>(
      String path, {
        required File file,
        Map<String, String>? headers,
        String fieldName = 'file',
        T Function(dynamic)? decoder,
      }) async {
    final uri = _buildUri(path);
    final request = await client.postUrl(uri);
    _applyHeaders(request, headers);

    final boundary = '----FlexHttp${DateTime.now().millisecondsSinceEpoch}';
    request.headers.contentType =
        ContentType('multipart', 'form-data', parameters: {'boundary': boundary});

    request.write('--$boundary\r\n');
    request.write(
        'Content-Disposition: form-data; name="$fieldName"; filename="${file.path.split('/').last}"\r\n');
    request.write('Content-Type: ${await _guessMimeType(file)}\r\n\r\n');
    request.add(await file.readAsBytes());
    request.write('\r\n--$boundary--\r\n');

    return await _executeRequest<T>(request, method: 'POST', decoder: decoder);
  }

  Stream<FlexStreamResponse<T>> stream<T>(
      String path, {
        Map<String, String>? headers,
        T Function(String)? lineDecoder,
      }) async* {
    final uri = _buildUri(path);
    final request = await client.getUrl(uri);
    _applyHeaders(request, headers);
    final flexRequest = FlexHttpRequest(request);
    await _runRequestInterceptors(flexRequest);
    if (flexRequest.isCancelled) {
      throw FlexHttpException('Stream request cancelled');
    }

    final response = await request.close().timeout(timeout);
    _log('Streaming $path: ${response.statusCode}');
    await for (final chunk in response.transform(utf8.decoder)) {
      final decoded = lineDecoder != null ? lineDecoder(chunk) : chunk as T;
      final streamResponse = FlexStreamResponse<T>(
        statusCode: response.statusCode,
        data: decoded,
        headers: response.headers,
      );
      await _runStreamInterceptors(streamResponse);
      yield streamResponse;
    }
  }

  Future<FlexResponse<T>> _request<T>(
      String method,
      String path, {
        Map<String, String>? headers,
        dynamic body,
        bool useCache = false,
        T Function(dynamic)? decoder,
      }) async {
    final cacheKey = '$method:$path:${headers?.toString() ?? ''}';
    if (useCache && _cache.containsKey(cacheKey)) {
      _log('Cache hit for $cacheKey');
      return _cache[cacheKey] as FlexResponse<T>;
    }

    int attempts = 0;
    while (true) {
      try {
        final uri = _buildUri(path);
        final request = await _createRequest(method, uri);
        _applyHeaders(request, headers);
        if (body != null) {
          request.write(jsonEncode(body));
        }
        final flexRequest = FlexHttpRequest(request);
        await _runRequestInterceptors(flexRequest);
        if (flexRequest.isCancelled) {
          throw FlexHttpException('Request cancelled');
        }
        final response = await _executeRequest<T>(request, method: method, decoder: decoder);
        await _runResponseInterceptors(response);
        if (useCache) _cache[cacheKey] = response;
        return response;
      } catch (e) {
        attempts++;
        if (attempts > maxRetries) {
          throw FlexHttpException.fromError(e);
        }
        _log('Retrying $method $path (Attempt $attempts/$maxRetries)');
        await Future.delayed(Duration(milliseconds: 500 * attempts));
      }
    }
  }

  Future<HttpClientRequest> _createRequest(String method, Uri uri) async {
    switch (method.toUpperCase()) {
      case 'GET':
        return await client.getUrl(uri);
      case 'POST':
        return await client.postUrl(uri);
      case 'PUT':
        return await client.putUrl(uri);
      case 'DELETE':
        return await client.deleteUrl(uri);
      case 'PATCH':
        return await client.patchUrl(uri);
      default:
        throw FlexHttpException('Unsupported HTTP method: $method');
    }
  }

  Uri _buildUri(String path) {
    if (baseUrl != null) {
      return Uri.parse('$baseUrl$path');
    }
    return Uri.parse(path);
  }

  void _applyHeaders(HttpClientRequest request, Map<String, String>? headers) {
    defaultHeaders.forEach((key, value) => request.headers.add(key, value));
    headers?.forEach((key, value) => request.headers.add(key, value));
    if (request.headers.contentType == null) {
      request.headers.contentType = ContentType.json;
    }
  }

  Future<FlexResponse<T>> _executeRequest<T>(
      HttpClientRequest request, {
        required String method,
        T Function(dynamic)? decoder,
      }) async {
    _log('Executing $method ${request.uri}');
    final response = await request.close().timeout(timeout);
    final responseBody = await response.transform(utf8.decoder).join();
    final flexResponse = FlexResponse<T>(
      statusCode: response.statusCode,
      body: responseBody,
      headers: response.headers,
      method: method,
      decoder: decoder,
    );
    _log('Response $method ${request.uri}: ${response.statusCode}');
    return flexResponse;
  }

  Future<void> _runRequestInterceptors(FlexHttpRequest request) async {
    for (var interceptor in interceptors) {
      await interceptor.onRequest(request);
    }
  }

  Future<void> _runResponseInterceptors(FlexResponse response) async {
    for (var interceptor in interceptors) {
      await interceptor.onResponse(response);
    }
  }

  Future<void> _runStreamInterceptors(FlexStreamResponse response) async {
    for (var interceptor in interceptors) {
      await interceptor.onStreamResponse(response);
    }
  }

  void _log(String message) {
    if (enableLogging) print('[FlexHttp] $message');
  }

  void close() {
    _client?.close();
    _client = null;
    _cache.clear();
    _log('Client closed');
  }

  Future<String> _guessMimeType(File file) async {
    final ext = file.path.split('.').last.toLowerCase();
    return {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'pdf': 'application/pdf',
    }[ext] ??
        'application/octet-stream';
  }
}

class FlexHttpBuilder {
  String? baseUrl;
  Map<String, String> defaultHeaders = {};
  Duration? timeout;
  List<FlexInterceptor> interceptors = [];
  int maxRetries = 0;
  bool enableLogging = false;
  int maxConnectionsPerHost = 6;

  FlexHttpBuilder({this.baseUrl});

  FlexHttpBuilder withBaseUrl(String url) {
    baseUrl = url;
    return this;
  }

  FlexHttpBuilder withHeader(String key, String value) {
    defaultHeaders[key] = value;
    return this;
  }

  FlexHttpBuilder withTimeout(Duration duration) {
    timeout = duration;
    return this;
  }

  FlexHttpBuilder withInterceptor(FlexInterceptor interceptor) {
    interceptors.add(interceptor);
    return this;
  }

  FlexHttpBuilder withMaxRetries(int retries) {
    maxRetries = retries;
    return this;
  }

  FlexHttpBuilder withLogging(bool enable) {
    enableLogging = enable;
    return this;
  }

  FlexHttpBuilder withMaxConnections(int max) {
    maxConnectionsPerHost = max;
    return this;
  }

  FlexHttp build() => FlexHttp._(
    baseUrl: baseUrl,
    defaultHeaders: defaultHeaders,
    timeout: timeout,
    interceptors: interceptors,
    maxRetries: maxRetries,
    enableLogging: enableLogging,
    maxConnectionsPerHost: maxConnectionsPerHost,
  );
}

class FlexHttpRequest {
  final HttpClientRequest request;
  bool _isCancelled = false;

  FlexHttpRequest(this.request);

  void cancel() => _isCancelled = true;
  bool get isCancelled => _isCancelled;
}

class FlexResponse<T> {
  final int statusCode;
  final String body;
  final HttpHeaders headers;
  final String method;
  final T Function(dynamic)? _decoder;

  FlexResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.method,
    T Function(dynamic)? decoder,
  }) : _decoder = decoder;

  T decodedBody() {
    final decoded = jsonDecode(body);
    return _decoder != null ? _decoder!(decoded) : decoded as T;
  }

  @override
  String toString() => 'FlexResponse[$method] $statusCode: $body';
}

class FlexStreamResponse<T> {
  final int statusCode;
  final T data;
  final HttpHeaders headers;

  FlexStreamResponse({
    required this.statusCode,
    required this.data,
    required this.headers,
  });

  @override
  String toString() => 'FlexStreamResponse[$statusCode]: $data';
}

class FlexHttpException implements Exception {
  final String message;
  final int? statusCode;

  FlexHttpException(this.message, {this.statusCode});

  factory FlexHttpException.fromError(dynamic error) {
    if (error is SocketException) return FlexHttpException('Network error: ${error.message}');
    if (error is TimeoutException) return FlexHttpException('Request timed out');
    if (error is FlexHttpException) return error;
    return FlexHttpException('Unknown error: $error');
  }

  @override
  String toString() => 'FlexHttpException: $message (Status: $statusCode)';
}

abstract class FlexInterceptor {
  Future<void> onRequest(FlexHttpRequest request) async {}
  Future<void> onResponse(FlexResponse response) async {}
  Future<void> onStreamResponse(FlexStreamResponse response) async {}
}

class LoggingInterceptor extends FlexInterceptor {
  @override
  Future<void> onRequest(FlexHttpRequest request) async {
    print('Request: ${request.request.method} ${request.request.uri}');
  }

  @override
  Future<void> onResponse(FlexResponse response) async {
    print('Response: ${response.method} ${response.statusCode} - ${response.body}');
  }

  @override
  Future<void> onStreamResponse(FlexStreamResponse response) async {
    print('Stream: ${response.statusCode} - ${response.data}');
  }
}