
# FlexHttp

A lightweight, flexible, and user-friendly HTTP client for Dart and Flutter, developed by Rudradeep. Built with simplicity and extensibility in mind, the `flex_http` package supports all major platforms (including Web and WASM) and offers powerful features like retries, caching, streaming, file uploads, and custom interceptors.

## Features

- **Cross-Platform**: Works on iOS, Android, Windows, macOS, Linux.
- **HTTP Methods**: Supports GET, POST, PUT, DELETE, PATCH, and file uploads.
- **Automatic Retries**: Configurable retry logic for handling network failures.
- **In-Memory Caching**: Cache GET responses to reduce redundant requests.
- **Streaming**: Efficiently handle large responses with streamed data.
- **Interceptors**: Customize request and response handling with flexible interceptors.
- **Timeouts**: Set per-request timeouts for reliable network operations.
- **Logging**: Optional built-in logging for debugging.

---

## Installation

Add the `flex_http` package to your project by including it in your `pubspec.yaml`:

```yaml
dependencies:
  flex_http: ^0.1.2
```

Then, run:

```bash
dart pub get
```

Or, if you're using Flutter:

```bash
flutter pub get
```

---

## Usage

### Basic Request

Make a simple GET request with `flex_http`:

```dart
import 'package:flex_http/flex_http.dart';

void main() async {
  final client = FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com').build();
  final response = await client.get<Map<String, dynamic>>('/posts/1');
  print('Post Title: ${response.decodedBody()['title']}');
  client.close();
}
```

### POST with Body

Send a POST request with a JSON body:

```dart
import 'dart:convert';
import 'package:flex_http/flex_http.dart';

void main() async {
final client = FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com').build();
final response = await client.post<Map<String, dynamic>>(
  '/posts',
  body: {'title': 'New Post', 'body': 'Hello World', 'userId': 1},
);
print('Created Post ID: ${response.decodedBody()['id']}');
client.close();
}
```

### File Upload

Upload a file (as bytes):

```dart
import 'dart:convert';
import 'package:flex_http/flex_http.dart';

void main() async {
  final client = FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com').build();
  final fileBytes = utf8.encode('Test content'); // Simulate file content
  final response = await client.upload<String>(
    '/posts',
    fileBytes: fileBytes,
    fileName: 'test.txt',
    decoder: (body) => body.toString(),
  );
  print('Upload Response: ${response.body}');
  client.close();
}
```

### Streaming Response

Stream a response for large data:

```dart
import 'dart:convert';
import 'package:flex_http/flex_http.dart';

void main() async {
  final client = FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com').build();
  final stream = client.stream<String>('/posts/1');
  await for (final chunk in stream) {
    print('Chunk: ${chunk.data}');
    break; // Stop after first chunk for this example
  }
  client.close();
}
```

### Custom Configuration

Use `FlexHttpBuilder` to configure `flex_http` with retries, logging, and interceptors:

```dart
import 'dart:convert';
import 'package:flex_http/flex_http.dart';

void main() async {
  final client = FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com')
      .withMaxRetries(3) // Retry failed requests up to 3 times
      .withTimeout(Duration(seconds: 5)) // 5-second timeout
      .withLogging(true) // Enable request/response logging
      .withInterceptor(LoggingInterceptor()) // Add custom interceptor
      .build();

  final response = await client.get<Map<String, dynamic>>('/posts/1');
  print(response.decodedBody()['title']);
  client.close();
}
```

### Caching

Enable caching for GET requests:

```dart
import 'dart:convert';
import 'package:flex_http/flex_http.dart';

void main() async {
  final client = FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com').build();
  final response1 = await client.get<Map<String, dynamic>>('/posts/1', useCache: true);
  print('First call: ${response1.decodedBody()['title']}');
  final response2 = await client.get<Map<String, dynamic>>('/posts/1', useCache: true);
  print('Cached call: ${response2.decodedBody()['title']}');
  client.close();
}
```

---

## Configuration Options

`FlexHttpBuilder` provides a fluent API to customize your `flex_http` client:

- `withBaseUrl(String url)`: Sets the base URL for all requests.
- `withHeader(String key, String value)`: Adds a default header.
- `withTimeout(Duration duration)`: Sets a timeout for requests.
- `withMaxRetries(int retries)`: Configures the number of retry attempts.
- `withLogging(bool enable)`: Enables/disables logging.
- `withInterceptor(FlexInterceptor interceptor)`: Adds a custom interceptor.

---

## Custom Interceptors

Create custom interceptors by extending `FlexInterceptor`:

```dart
class AuthInterceptor extends FlexInterceptor {
  @override
  Future<void> onRequest(FlexHttpRequest request) async {
    request.request.headers['Authorization'] = 'Bearer your-token';
  }

  @override
  Future<void> onResponse(FlexResponse response) async {
    if (response.statusCode == 401) {
      print('Unauthorized - refreshing token...');
    }
  }
}

final client = FlexHttpBuilder(baseUrl: 'https://api.example.com')
    .withInterceptor(AuthInterceptor())
    .build();
```

---

## Platform Support

The `flex_http` package is fully compatible with:

- iOS
- Android
- Web
- Windows
- macOS
- Linux
- WASM (WebAssembly)

Thanks to the `http` package dependency, `flex_http` works seamlessly across all Dart platforms.

---

## Contributing

Contributions to `flex_http` are welcome! To get started:

1. Fork the repository: [https://github.com/Deep3way/Flex_http](https://github.com/Deep3way/Flex_http)
2. Clone your fork:

   ```bash
   git clone https://github.com/<your-username>/Flex_http.git
   ```

3. Create a branch:

   ```bash
   git checkout -b feature/your-feature-name
   ```

4. Make your changes and commit:

   ```bash
   git commit -m "Add your feature"
   ```

5. Push to your fork:

   ```bash
   git push origin feature/your-feature-name
   ```

6. Open a pull request on the main repository.

Please ensure your code is formatted with `dart format` and includes tests where applicable.

---

## License

`flex_http` is released under the BSD 3-Clause License by Rudradeep. See the [LICENSE](LICENSE) file for details.

---

## Contact

For questions, suggestions, or support, feel free to reach out to Rudradeep via the issue tracker on GitHub.

---

Happy coding with `flex_http`! 🚀

Made With ❤️ By `Rudradeep`!
