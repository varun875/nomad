import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/duckduckgo_search_provider.dart';
import 'package:nomad/core/services/search_service.dart';

void main() {
  test('SearchService defaults to DuckDuckGo before a key is loaded', () {
    expect(SearchService().provider, isA<DuckDuckGoProvider>());
  });

  test('configure swaps the active provider', () {
    final service = SearchService();
    service.configure(const DuckDuckGoProvider());
    expect(service.provider, isA<DuckDuckGoProvider>());
  });
}
