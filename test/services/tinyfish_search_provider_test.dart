import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/tinyfish_search_provider.dart';

void main() {
  test('TinyFishSearchProvider basic properties', () {
    const provider = TinyFishSearchProvider();
    expect(provider.apiKey, equals(kDefaultTinyFishApiKey));
    expect(provider.enableFallback, isTrue);
  });

  test('TinyFishSearchProvider empty query returns empty list', () async {
    const provider = TinyFishSearchProvider();
    final results = await provider.search('   ');
    expect(results, isEmpty);
  });
}
