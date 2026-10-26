/// سيرفر سيبر مكة: العنوان والمفتاح العام (scripts/install.sh بيطبعهم بعد التركيب).
/// المفتاح ده عام بطبيعته — مفتاح الخدمة (SERVICE_ROLE_KEY) عمره ما يتحط في التطبيق.
///
/// للتجربة المحلية:
///   flutter run --dart-define=API_URL=http://localhost:8089 --dart-define=ANON_KEY=...
const String kApiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://api.makka.io');
const String kAnonKey = String.fromEnvironment('ANON_KEY', defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzkyODQ5MDI5LCJleHAiOjIxMDgyMDkwMjl9.PqCIzwtERESs6NnUAB7pQISY9x2yW4elfgIWqpbZ2to');
