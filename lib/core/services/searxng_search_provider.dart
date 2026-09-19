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

  static bool isAllowedSearxngUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return false;
    if (uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (host == 'localhost' || host == '::1' || host == '0.0.0.0') return false;
    final ipv4 = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$');
    if (ipv4.hasMatch(host)) {
      final parts = host.split('.').map(int.parse).toList();
      if (parts.any((p) => p < 0 || p > 255)) return false;
      // RFC1918 + loopback + link-local + CGNAT + multicast + 0/8 + broadcast
      if (parts[0] == 10) return false;
      if (parts[0] == 127) return false;
      if (parts[0] == 0) return false;
      if (parts[0] == 169 && parts[1] == 254) return false;
      if (parts[0] == 192 && parts[1] == 168) return false;
      if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return false;
      if (parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127) return false;
      if (parts[0] >= 224) return false;
      if (parts[0] == 255 && parts[1] == 255) return false;
    }
    // IPv6 literals (Uri.host strips brackets): block loopback/link-local/ULA/private
    if (host.contains(':')) {
      final h = host.toLowerCase();
      if (h == '::1' || h == '::' ) return false;
      if (h.startsWith('fe80:') || h.startsWith('fec0:') || h.startsWith('fc00:') || h.startsWith('fd00:')) return false;
      if (h.startsWith('::ffff:')) return false;
    }
    // Metadata / cloud endpoints and onion
    if (host == '169.254.169.254' || host.endsWith('.169.254.169.254')) return false;
    if (host == 'metadata.google.internal' || host.endsWith('.metadata.google.internal')) return false;
    if (host.endsWith('.onion') || host.endsWith('.local')) return false;
    return true;
  }

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    if (query.trim().isEmpty) return [];
    if (!isAllowedSearxngUrl(baseUrl)) {
      print('SearXNG blocked: disallowed baseUrl $baseUrl');
      return [];
    }

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
