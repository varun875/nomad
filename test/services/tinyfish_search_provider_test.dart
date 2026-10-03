import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/tinyfish_search_provider.dart';

void main() {
  test('TinyFishSearchProvider has no hardcoded default key', () {
    const provider = TinyFishSearchProvider();
    expect(provider.apiKey, isEmpty);
    expect(provider.enableFallback, isTrue);
  });

  test('TinyFishSearchProvider keeps a user-supplied key', () {
    const provider = TinyFishSearchProvider(apiKey: 'user-supplied-key');
    expect(provider.apiKey, equals('user-supplied-key'));
  });

  test('TinyFishSearchProvider empty query returns empty list', () async {
    const provider = TinyFishSearchProvider(apiKey: 'user-supplied-key');
    final results = await provider.search('   ');
    expect(results, isEmpty);
  });
}
