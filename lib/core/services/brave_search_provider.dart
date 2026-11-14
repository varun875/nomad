import 'dart:convert';

import 'package:http/http.dart' as http;
import 'search_provider.dart';

/// Brave Search API backend (https://brave.com/search/api/).
///
/// Bring Your Own Key: the caller supplies a key from their own Brave account;
/// it is stored in the platform keychain and no key is ever bundled in the APK.
class BraveSearchProvider implements WebSearchProvider {
  BraveSearchProvider({required this.apiKey});

  final String apiKey;

  static const _endpoint = 'https://api.search.brave.com/res/v1/web/search';

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || apiKey.isEmpty) return [];
    try {
      final uri = Uri.parse(_endpoint).replace(queryParameters: {
        'q': trimmed,
        'count': maxResults.clamp(1, 20).toString(),
      });

      final response = await http.get(uri, headers: {
        'Accept': 'application/json',
        'X-Subscription-Token': apiKey,
      }).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        print('Brave Search HTTP ${response.statusCode}');
        return [];
      }

      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final web = data['web'] as Map<String, dynamic>?;
      final items = (web?['results'] as List?) ?? const [];

      final results = <SearchResult>[];
      for (final item in items) {
        if (results.length >= maxResults) break;
        final m = item as Map<String, dynamic>;
        final title = (m['title'] as String?)?.trim() ?? '';
        if (title.isEmpty) continue;
        results.add(SearchResult(
          title: title,
          url: (m['url'] as String?) ?? '',
          snippet: ((m['description'] as String?) ?? '').trim(),
        ));
      }

      print('Brave Search: returning ${results.length} results');
      return results;
    } catch (e) {
      print('Brave Search error: $e');
      return [];
    }
  }
}
