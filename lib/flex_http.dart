/// A lightweight, flexible HTTP client for Dart and Flutter.
///
/// Provides an extensible HTTP client with support for retries, caching, streaming,
/// file uploads, and custom interceptors. Ideal for simple and complex network requests.
///
/// Example:
/// ```dart
/// final client = FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com')
///     .withLogging(true)
///     .build();
/// final response = await client.get<Map<String, dynamic>>('/posts/1');
/// print(response.decodedBody()['title']);
/// client.close();
/// ```
library flex_http;

import 'dart:convert';
import 'dart:io';
import 'dart:async';

/// The core HTTP client class for making network requests.
///
/// Configurable via [FlexHttpBuilder], it supports common HTTP methods (GET, POST, etc.),
/// retries, caching, streaming, and interceptors.
class FlexHttp {
  HttpClient? _client;

  /// The base URL prepended to all request paths.
  final String? baseUrl;

  /// Default headers applied to all requests.
  final Map<String, String> defaultHeaders;

  /// Timeout duration for requests.
  final Duration timeout;

  /// List of interceptors for customizing requests and responses.
  final List<FlexInterceptor> interceptors;

  /// Maximum number of retry attempts for failed requests.
  final int maxRetries;

  /// Enables logging of requests and responses.
  final bool enableLogging;
  final Map<String, FlexResponse> _cache = {};

  /// Maximum connections per host for the underlying HTTP client.
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

  /// Creates a pre-configured [FlexHttp] instance with a [baseUrl].
  factory FlexHttp.config({String? baseUrl}) =>
      FlexHttpBuilder(baseUrl: baseUrl).build();

  /// The underlying HTTP client, lazily initialized with configuration.
  HttpClient get client {
    if (_client == null) {
      _client = HttpClient()
        ..maxConnectionsPerHost = maxConnectionsPerHost
        ..idleTimeout = const Duration(seconds: 10);
    }
    return _client!;
  }

  /// Sends a GET request to [path].
  ///
  /// [headers]: Optional custom headers.
  /// [useCache]: If true, returns cached response if available.
  /// [decoder]: Custom function to decode the response body.
  /// Returns a [FlexResponse] with the decoded body of type [T].
  Future<FlexResponse<T>> get<T>(
    String path, {
    Map<String, String>? headers,
    bool useCache = false,
    T Function(dynamic)? decoder,
  }) =>
      _request<T>('GET', path,
          headers: headers, useCache: useCache, decoder: decoder);

  /// Sends a POST request to [path] with an optional [body].
  Future<FlexResponse<T>> post<T>(
    String path, {
    Map<String, String>? headers,
    dynamic body,
    T Function(dynamic)? decoder,
  }) =>
      _request<T>('POST', path, headers: headers, body: body, decoder: decoder);

  /// Sends a PUT request to [path] with an optional [body].
  Future<FlexResponse<T>> put<T>(
    String path, {
    Map<String, String>? headers,
    dynamic body,
    T Function(dynamic)? decoder,
  }) =>
      _request<T>('PUT', path, headers: headers, body: body, decoder: decoder);

  /// Sends a DELETE request to [path].
  Future<FlexResponse<T>> delete<T>(
    String path, {
    Map<String, String>? headers,
    T Function(dynamic)? decoder,
  }) =>
      _request<T>('DELETE', path, headers: headers, decoder: decoder);

  /// Sends a PATCH request to [path] with an optional [body].
  Future<FlexResponse<T>> patch<T>(
    String path, {
    Map<String, String>? headers,
    dynamic body,
    T Function(dynamic)? decoder,
  }) =>
      _request<T>('PATCH', path,
          headers: headers, body: body, decoder: decoder);

  /// Uploads a [file] to [path] as a multipart/form-data request.
  ///
  /// [fieldName]: Name of the form field (default: 'file').
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
    request.headers.contentType = ContentType('multipart', 'form-data',
        parameters: {'boundary': boundary});

    request.write('--$boundary\r\n');
    request.write(
        'Content-Disposition: form-data; name="$fieldName"; filename="${file.path.split('/').last}"\r\n');
    request.write('Content-Type: ${await _guessMimeType(file)}\r\n\r\n');
    request.add(await file.readAsBytes());
    request.write('\r\n--$boundary--\r\n');

    return await _executeRequest<T>(request, method: 'POST', decoder: decoder);
  }

  /// Streams the response from [path] as chunks of data.
  ///
  /// [lineDecoder]: Optional function to decode each chunk.
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
        final response =
            await _executeRequest<T>(request, method: method, decoder: decoder);
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

  /// Closes the HTTP client and clears the cache.
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

/// Builder class for configuring a [FlexHttp] instance.
///
/// Example:
/// ```dart
/// final client = FlexHttpBuilder(baseUrl: 'https://api.example.com')
///     .withMaxRetries(3)
///     .withLogging(true)
///     .build();
/// ```
class FlexHttpBuilder {
  String? baseUrl;
  Map<String, String> defaultHeaders = {};
  Duration? timeout;
  List<FlexInterceptor> interceptors = [];
  int maxRetries = 0;
  bool enableLogging = false;
  int maxConnectionsPerHost = 6;

  FlexHttpBuilder({this.baseUrl});

  /// Sets the base URL for all requests.
  FlexHttpBuilder withBaseUrl(String url) {
    baseUrl = url;
    return this;
  }

  /// Adds a default header to all requests.
  FlexHttpBuilder withHeader(String key, String value) {
    defaultHeaders[key] = value;
    return this;
  }

  /// Sets the timeout duration for requests.
  FlexHttpBuilder withTimeout(Duration duration) {
    timeout = duration;
    return this;
  }

  /// Adds an interceptor to the request pipeline.
  FlexHttpBuilder withInterceptor(FlexInterceptor interceptor) {
    interceptors.add(interceptor);
    return this;
  }

  /// Sets the maximum number of retries for failed requests.
  FlexHttpBuilder withMaxRetries(int retries) {
    maxRetries = retries;
    return this;
  }

  /// Enables or disables logging of requests and responses.
  FlexHttpBuilder withLogging(bool enable) {
    enableLogging = enable;
    return this;
  }

  /// Sets the maximum number of connections per host.
  FlexHttpBuilder withMaxConnections(int max) {
    maxConnectionsPerHost = max;
    return this;
  }

  /// Builds and returns a configured [FlexHttp] instance.
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

/// Represents an HTTP request with cancellation support.
class FlexHttpRequest {
  final HttpClientRequest request;
  bool _isCancelled = false;

  FlexHttpRequest(this.request);

  /// Cancels the request.
  void cancel() => _isCancelled = true;

  /// Whether the request has been cancelled.
  bool get isCancelled => _isCancelled;
}

/// Represents an HTTP response with decoded body support.
///
/// [T] is the type of the decoded body.
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

  /// Decodes the response body into type [T].
  T decodedBody() {
    final decoded = jsonDecode(body);
    return _decoder != null ? _decoder!(decoded) : decoded as T;
  }

  @override
  String toString() => 'FlexResponse[$method] $statusCode: $body';
}

/// Represents a streamed HTTP response chunk.
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

/// Exception thrown when an HTTP request fails.
class FlexHttpException implements Exception {
  final String message;
  final int? statusCode;

  FlexHttpException(this.message, {this.statusCode});

  factory FlexHttpException.fromError(dynamic error) {
    if (error is SocketException) {
      return FlexHttpException('Network error: ${error.message}');
    }
    if (error is TimeoutException) {
      return FlexHttpException('Request timed out');
    }
    if (error is FlexHttpException) {
      return error;
    }

    // Preserve the original structure for testing while ensuring safety
    return FlexHttpException('Unknown error: ${error.toString()}');
  }

  @override
  String toString() => 'FlexHttpException: $message (Status: $statusCode)';
}

/// Abstract base class for intercepting HTTP requests and responses.
///
/// Extend this to add custom behavior like logging or authentication.
abstract class FlexInterceptor {
  /// Called before a request is sent.
  Future<void> onRequest(FlexHttpRequest request) async {}

  /// Called after a response is received.
  Future<void> onResponse(FlexResponse response) async {}

  /// Called for each chunk of a streamed response.
  Future<void> onStreamResponse(FlexStreamResponse response) async {}
}

/// A sample interceptor that logs requests and responses.
class LoggingInterceptor extends FlexInterceptor {
  @override
  Future<void> onRequest(FlexHttpRequest request) async {
    print('Request: ${request.request.method} ${request.request.uri}');
  }

  @override
  Future<void> onResponse(FlexResponse response) async {
    print(
        'Response: ${response.method} ${response.statusCode} - ${response.body}');
  }

  @override
  Future<void> onStreamResponse(FlexStreamResponse response) async {
    print('Stream: ${response.statusCode} - ${response.data}');
  }
}
