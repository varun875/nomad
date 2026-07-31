import 'dart:convert';
import 'package:http/http.dart' as http;
import 'search_provider.dart';

/// Default public SearXNG instance used when no custom one is configured.
const String kDefaultSearxngInstance = 'https://searx.be';

/// SearXNG (https://github.com/searxng/searxng) JSON API backend.
///
/// No API key or account required. [baseUrl] defaults to a public instance but
/// can point at any SearXNG server (e.g. self-hosted), as long as JSON output
/// is enabled (`format=json`).
class SearxngProvider implements WebSearchProvider {
  const SearxngProvider({this.baseUrl = kDefaultSearxngInstance});

  /// Base URL of the SearXNG instance, e.g. `https://searx.be`.
  final String baseUrl;

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    if (query.trim().isEmpty) return [];

    try {
      final uri = Uri.parse('$baseUrl/search').replace(
        queryParameters: {
          'q': query.trim(),
          'format': 'json',
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        print('SearXNG HTTP ${response.statusCode}');
        return [];
      }

      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final items = (data['results'] as List?) ?? const [];

      final results = <SearchResult>[];
      for (final item in items) {
        if (results.length >= maxResults) break;
        final m = item as Map<String, dynamic>;
        final title = (m['title'] as String?)?.trim() ?? '';
        if (title.isEmpty) continue;

        results.add(SearchResult(
          title: title,
          url: (m['url'] as String?) ?? '',
          snippet: (m['content'] as String?)?.trim() ?? '',
        ));
      }

      print('SearXNG: returning ${results.length} results');
      return results;
    } catch (e, st) {
      print('SearXNG error: $e');
      print(st);
      return [];
    }
  }
}
