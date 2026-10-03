import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/logger.dart';
import 'duckduckgo_search_provider.dart';
import 'search_provider.dart';

/// TinyFish live web search provider powered by Monid (100% free, no credit card).
///
/// Executes headless-browser rendered searches over the live web without
/// getting blocked by anti-bot or CAPTCHA challenges.
///
/// The Monid API key is supplied per user (Settings -> Web Search) and stored
/// in the platform keychain - it is never hardcoded or bundled into the app.
/// When no key is configured, [search] skips the network entirely and uses the
/// fallback provider.
class TinyFishSearchProvider implements WebSearchProvider {
  final String apiKey;
  final bool enableFallback;

  const TinyFishSearchProvider({
    this.apiKey = '',
    this.enableFallback = true,
  });

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return [];

    if (apiKey.trim().isEmpty) {
      // No per-user key configured: never call Monid with an empty/invalid
      // bearer token, just use the keyless fallback.
      Log.w('Search', 'No TinyFish/Monid API key configured; using fallback');
    } else {
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
    }

    if (enableFallback) {
      Log.d('Search', 'Falling back to DuckDuckGo');
      return const DuckDuckGoProvider().search(trimmedQuery, maxResults: maxResults);
    }

    return [];
  }
}
