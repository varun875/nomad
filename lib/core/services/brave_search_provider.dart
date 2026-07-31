import 'dart:convert';
import 'package:http/http.dart' as http;
import 'search_provider.dart';

/// Brave Search API backend. Requires an API key sent as the
/// `X-Subscription-Token` header (see https://brave.com/search/api/).
///
/// Without a configured key, [search] returns no results.
class BraveSearchProvider implements WebSearchProvider {
  const BraveSearchProvider({required this.apiKey});

  final String apiKey;

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    if (query.trim().isEmpty) return [];
    if (apiKey.isEmpty) {
      print('Brave search: no API key configured');
      return [];
    }

    try {
      final uri = Uri.https(
        'api.search.brave.com',
        '/res/v1/web/search',
        {'q': query.trim(), 'count': '$maxResults'},
      );

      final response = await http.get(
        uri,
        headers: {
          'X-Subscription-Token': apiKey,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        print('Brave search HTTP ${response.statusCode}');
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

        final snippets = <String>[
          if (m['description'] is String) m['description'] as String,
          if (m['extra_snippets'] is List)
            ...(m['extra_snippets'] as List).whereType<String>(),
        ];

        results.add(SearchResult(
          title: title,
          url: (m['url'] as String?) ?? '',
          snippet: snippets.join(' ').trim(),
        ));
      }

      print('Brave search: returning ${results.length} results');
      return results;
    } catch (e, st) {
      print('Brave search error: $e');
      print(st);
      return [];
    }
  }
}
