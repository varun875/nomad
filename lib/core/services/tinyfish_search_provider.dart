import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/logger.dart';
import 'duckduckgo_search_provider.dart';
import 'search_provider.dart';

/// Default Monid API key for TinyFish live search.
const String kDefaultTinyFishApiKey = 'monid_live_rFkjItGuHsqO4GxFE8k3SNpU';

/// TinyFish live web search provider powered by Monid (100% free, no credit card).
///
/// Executes headless-browser rendered searches over the live web without
/// getting blocked by anti-bot or CAPTCHA challenges.
class TinyFishSearchProvider implements WebSearchProvider {
  final String apiKey;
  final bool enableFallback;

  const TinyFishSearchProvider({
    this.apiKey = kDefaultTinyFishApiKey,
    this.enableFallback = true,
  });

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return [];

    try {
      Log.d('Search', 'Running TinyFish search for "$trimmedQuery"');
      final uri = Uri.parse('https://api.monid.ai/v1/run');
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
              'X-Monid-Client': 'nomad',
            },
            body: jsonEncode({
              'provider': 'tinyfish',
              'endpoint': '/search',
              'input': {
                'queryParams': {
                  'query': trimmedQuery,
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final output = data['output'] as Map<String, dynamic>?;
        final items = (output?['results'] as List?) ?? const [];

        final results = <SearchResult>[];
        for (final item in items) {
          if (results.length >= maxResults) break;
          final m = item as Map<String, dynamic>;
          final title = (m['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) continue;

          results.add(
            SearchResult(
              title: title,
              url: (m['url'] as String?) ?? '',
              snippet: (m['snippet'] as String?)?.trim() ?? '',
            ),
          );
        }

        Log.d('Search', 'TinyFish returned ${results.length} results');
        if (results.isNotEmpty) return results;
      } else {
        Log.w('Search', 'TinyFish HTTP error: ${response.statusCode}');
      }
    } catch (e, st) {
      Log.e('Search', 'TinyFish search error: $e', e, st);
    }

    if (enableFallback) {
      Log.d('Search', 'Falling back to DuckDuckGo');
      return const DuckDuckGoProvider().search(trimmedQuery, maxResults: maxResults);
    }

    return [];
  }
}
