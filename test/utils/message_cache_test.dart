import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/widgets/rich_message_renderer.dart';

void main() {
  const renderer = RichMessageRenderer(text: '', isUser: false);
  setUp(RichMessageRenderer.clearCache);
  tearDown(RichMessageRenderer.clearCache);

  test('parsed-reply cache evicts by retained characters, not only entry count',
      () {
    for (var i = 0; i < 40; i++) {
      renderer.getOrParseSegments('$i ${'x' * 40000}');
      expect(RichMessageRenderer.cachedSourceCharacters,
          lessThanOrEqualTo(1024 * 1024));
    }
    expect(RichMessageRenderer.cachedSourceCharacters, greaterThan(0));
    final retained = RichMessageRenderer.cachedSourceCharacters;
    renderer.getOrParseSegments('x' * (1024 * 1024 + 1));
    expect(RichMessageRenderer.cachedSourceCharacters, retained);
  });

  test(
      'cache hits do not double-count and pressure clearing releases all entries',
      () {
    renderer.getOrParseSegments('Hello');
    renderer.getOrParseSegments('Hello');
    expect(RichMessageRenderer.cachedSourceCharacters, 5);
    RichMessageRenderer.clearCache();
    expect(RichMessageRenderer.cachedSourceCharacters, 0);
    renderer.getOrParseSegments('Hello');
    expect(RichMessageRenderer.cachedSourceCharacters, 5);
  });
}
