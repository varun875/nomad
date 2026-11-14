import 'dart:convert';
import 'dart:io';

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
  const SearxngProvider(
      {this.baseUrl = kDefaultSearxngInstance, this.allowPrivate = false});

  /// Base URL of the SearXNG instance, e.g. `https://searx.be`.
  final String baseUrl;

  /// Whether private/loopback LAN addresses and plain HTTP are tolerated.
  /// Only set for an instance URL the user explicitly configured in Settings
  /// (self-hosted hobbyist setups); never for anything else.
  final bool allowPrivate;

  /// True for addresses we must never let the search request reach regardless
  /// of configuration: link-local (incl. cloud metadata 169.254.169.254),
  /// multicast/reserved, 0.0.0.0/8, CGNAT, and IPv4-mapped equivalents.
  static bool _isAlwaysBlocked(InternetAddress addr) {
    if (addr.isLinkLocal || addr.isMulticast) return true;
    final bytes = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4) {
      final first = bytes[0];
      final second = bytes[1];
      if (first == 0) return true; // 0.0.0.0/8
      if (first == 169 && second == 254) return true; // link-local / metadata
      if (first == 100 && second >= 64 && second <= 127) return true; // CGNAT
      if (first >= 224) return true; // multicast / reserved
      return false;
    }
    // IPv6 link-local fe80::/10 and IPv4-mapped ::ffff:a.b.c.d.
    if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true;
    final isV4Mapped = bytes.take(10).every((b) => b == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isV4Mapped) {
      return _isAlwaysBlocked(
          InternetAddress.fromRawAddress(bytes.sublist(12)));
    }
    return false;
  }

  /// Private/loopback ranges: blocked for the default public instance but
  /// allowed when the user explicitly configured a self-hosted LAN server.
  static bool _isPrivateOrLoopback(InternetAddress addr) {
    if (addr.isLoopback) return true;
    final bytes = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4) {
      final first = bytes[0];
      final second = bytes[1];
      if (first == 10) return true; // RFC1918
      if (first == 127) return true; // loopback
      if (first == 192 && second == 168) return true; // RFC1918
      if (first == 172 && second >= 16 && second <= 31) return true; // RFC1918
      return false;
    }
    // IPv6 unique local addresses fc00::/7 and IPv4-mapped equivalents.
    if ((bytes[0] & 0xfe) == 0xfc) return true;
    final isV4Mapped = bytes.take(10).every((b) => b == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isV4Mapped) {
      return _isPrivateOrLoopback(
          InternetAddress.fromRawAddress(bytes.sublist(12)));
    }
    return false;
  }

  /// Whether [raw] is an acceptable SearXNG base URL.
  ///
  /// IP literals are checked directly; arbitrary hostnames are resolved first
  /// and every resolved address is re-checked, so a name like `foo.nip.io` (or
  /// any DNS-rebinding host) that points at loopback or a metadata IP is
  /// rejected instead of silently bypassing the guard. With [allowPrivate]
  /// (user-configured self-hosted instances) RFC1918/loopback targets and
  /// plain HTTP on those targets are permitted; metadata, CGNAT, link-local
  /// and multicast addresses stay blocked everywhere.
  static Future<bool> isAllowedSearxngUrl(String raw,
      {bool allowPrivate = false}) async {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return false;
    final secure = uri.scheme == 'https';
    if (!secure && uri.scheme != 'http') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (host == 'metadata.google.internal' ||
        host.endsWith('.metadata.google.internal')) {
      return false;
    }
    if (host.endsWith('.onion')) return false;
    if (!allowPrivate) {
      if (host == 'localhost' || host.endsWith('.localhost')) return false;
      if (host.endsWith('.local')) return false;
    }

    bool allowed(InternetAddress addr) {
      if (_isAlwaysBlocked(addr)) return false;
      final private = _isPrivateOrLoopback(addr);
      if (private && !allowPrivate) return false;
      // Plain HTTP is only tolerated for a user-chosen private/loopback
      // server; anything crossing a public network must be HTTPS.
      return secure || private;
    }

    final literal = InternetAddress.tryParse(host);
    if (literal != null) return allowed(literal);

    try {
      final addresses = await InternetAddress.lookup(host);
      if (addresses.isEmpty) return false;
      for (final addr in addresses) {
        if (!allowed(addr)) return false;
      }
    } on SocketException {
      return false;
    }
    return true;
  }

  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async {
    if (query.trim().isEmpty) return [];
    if (!await isAllowedSearxngUrl(baseUrl, allowPrivate: allowPrivate)) {
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
