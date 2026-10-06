class AppConstants {
  static const String baseURL = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: "http://localhost:8080/api/v1",
  );
}
