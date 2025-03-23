# FlexHttp

A lightweight, flexible HTTP client for Dart, designed for simplicity and extensibility. Supports retries, caching, streaming, and custom interceptors.

## Features
- **HTTP Methods**: GET, POST, PUT, DELETE, PATCH, and file uploads.
- **Retries**: Automatic retry on network failures.
- **Caching**: In-memory caching for GET requests.
- **Streaming**: Streamed responses for large data.
- **Interceptors**: Custom request/response handling.

## Installation
Add this to your `pubspec.yaml`:
```yaml
dependencies:
  flex_http: ^1.0.0