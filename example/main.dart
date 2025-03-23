import 'package:flex_http/flex_http.dart';

void main() async {
  final client = FlexHttpBuilder(baseUrl: 'https://jsonplaceholder.typicode.com')
      .withLogging(true)
      .build();
  final response = await client.get<Map<String, dynamic>>('/posts/1');
  print('Post Title: ${response.decodedBody()['title']}');
  client.close();
}