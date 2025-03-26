import 'dart:io';
import 'package:flex_http/flex_http.dart';
import 'package:test/test.dart';

void main() {
  late FlexHttp client;

  setUp(() {
    final builder =
        FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com')
            .withLogging(true)
            .withMaxRetries(1);
    client = builder.build();
  });

  tearDown(() {
    client.close();
  });

  group('FlexHttp Tests', () {
    test('GET request returns 200 and valid JSON', () async {
      final response = await client.get<Map<String, dynamic>>('/posts/1');
      expect(response.statusCode, 200);
      expect(response.decodedBody(), isMap);
      expect(response.decodedBody()['id'], 1);
      expect(response.decodedBody()['title'], isNotEmpty);
      expect(
          response.headers.value('content-type'), contains('application/json'));
    });

    test('POST request creates a resource with 201 status', () async {
      final response = await client.post<Map<String, dynamic>>(
        '/posts',
        body: {'title': 'Test Post', 'body': 'This is a test', 'userId': 1},
      );
      expect(response.statusCode, 201);
      expect(response.decodedBody()['id'], isNotNull);
      expect(response.decodedBody()['title'], 'Test Post');
      expect(response.decodedBody()['body'], 'This is a test');
      expect(response.decodedBody()['userId'], 1);
    });

    test('PUT request updates a resource', () async {
      final response = await client.put<Map<String, dynamic>>(
        '/posts/1',
        body: {
          'id': 1,
          'title': 'Updated Post',
          'body': 'Updated',
          'userId': 1
        },
      );
      expect(response.statusCode, 200);
      expect(response.decodedBody()['title'], 'Updated Post');
      expect(response.decodedBody()['body'], 'Updated');
      expect(response.decodedBody()['id'], 1);
    });

    test('DELETE request returns 200', () async {
      final response = await client.delete('/posts/1');
      expect(response.statusCode, 200);
      expect(response.body, '{}');
    });

    test('PATCH request partially updates a resource', () async {
      final response = await client.patch<Map<String, dynamic>>(
        '/posts/1',
        body: {'title': 'Patched Post'},
      );
      expect(response.statusCode, 200);
      expect(response.decodedBody()['title'], 'Patched Post');
      expect(response.decodedBody()['id'], 1);
    });

    test('Upload file simulation returns 201 (mocked)', () async {
      final tempFile = File('test.txt')..writeAsStringSync('Test content');
      final response = await client.upload<String>(
        '/posts',
        file: tempFile,
        decoder: (dynamic body) => body.toString(),
      );
      expect(response.statusCode, 201);
      expect(response.body, isNotEmpty);
      tempFile.deleteSync();
    });

    test('Stream response delivers data', () async {
      final stream = client.stream<String>('/posts/1');
      int chunkCount = 0;
      await for (final chunk in stream) {
        expect(chunk.statusCode, 200);
        expect(chunk.data, isNotEmpty);
        expect(chunk.data, contains('"id": 1'));
        chunkCount++;
        if (chunkCount > 0) break;
      }
      expect(chunkCount, greaterThan(0));
    });

    test('Retries on network failure exhausts attempts', () async {
      final builder = FlexHttpBuilder(baseUrl: 'http://nonexistent.domain')
          .withMaxRetries(2)
          .withLogging(true);
      final failingClient = builder.build();
      expect(
        () async => await failingClient.get('/test'),
        throwsA(isA<FlexHttpException>()
            .having((e) => e.message, 'message', contains('Network error'))),
      );
      failingClient.close();
    });

    test('Request cancellation works with interceptor', () async {
      final builder =
          FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com')
              .withInterceptor(_CancelInterceptor())
              .withLogging(true);
      final requestClient = builder.build();
      expect(
        () async => await requestClient.get('/posts/1'),
        throwsA(isA<FlexHttpException>()
            .having((e) => e.message, 'message', 'Request cancelled')),
      );
      requestClient.close();
    });

    test('GET with invalid endpoint returns 404', () async {
      final response =
          await client.get<Map<String, dynamic>>('/invalid-endpoint');
      expect(response.statusCode, 404);
      expect(response.body, '{}');
    });

    test('POST with malformed JSON throws exception', () async {
      expect(
        () async => await client.post<Map<String, dynamic>>(
          '/posts',
          body: () => 'not json', // Unencodable object (a function)
        ),
        throwsA(isA<FlexHttpException>().having(
          (e) => e.message,
          'message',
          contains('Converting object to an encodable object failed'),
        )),
      );
    });

    test('Timeout triggers with short duration', () async {
      final builder =
          FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com')
              .withTimeout(Duration(milliseconds: 1))
              .withMaxRetries(0);
      final slowClient = builder.build();
      expect(
        () async => await slowClient.get('/posts/1'),
        throwsA(isA<FlexHttpException>()
            .having((e) => e.message, 'message', 'Request timed out')),
      );
      slowClient.close();
    });

    test('Caching works with GET requests', () async {
      final response1 =
          await client.get<Map<String, dynamic>>('/posts/1', useCache: true);
      expect(response1.statusCode, 200);
      final response2 =
          await client.get<Map<String, dynamic>>('/posts/1', useCache: true);
      expect(response2.statusCode, 200);
      expect(response2.body, response1.body);
      expect(response2.decodedBody()['id'], 1);
    });

    test('Multiple interceptors execute in order', () async {
      final log = <String>[];
      final builder =
          FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com')
              .withInterceptor(_LoggingInterceptor('First', log))
              .withInterceptor(_LoggingInterceptor('Second', log));
      final multiClient = builder.build();
      final response = await multiClient.get('/posts/1');
      expect(response.statusCode, 200);
      expect(log, [
        'First Request',
        'Second Request',
        'First Response',
        'Second Response'
      ]);
      multiClient.close();
    });
  });
}

class _CancelInterceptor extends FlexInterceptor {
  @override
  Future<void> onRequest(FlexHttpRequest request) async {
    request.cancel();
  }
}

class _LoggingInterceptor extends FlexInterceptor {
  final String name;
  final List<String> log;

  _LoggingInterceptor(this.name, this.log);

  @override
  Future<void> onRequest(FlexHttpRequest request) async {
    log.add('$name Request');
  }

  @override
  Future<void> onResponse(FlexResponse response) async {
    log.add('$name Response');
  }
}
