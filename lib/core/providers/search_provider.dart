import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/duckduckgo_search_provider.dart';
import '../services/searxng_search_provider.dart';
import '../services/search_provider.dart';
import '../services/search_service.dart';

/// The active web-search backend - DuckDuckGo only (free, no key).
///
/// Defaults to the zero-config DuckDuckGo scraper. An optional self-hosted
/// SearXNG instance can be used instead when `searxng_url` is stored.
final webSearchProvider = StateNotifierProvider<WebSearchConfigNotifier, WebSearchProvider>(
  (ref) => WebSearchConfigNotifier(),
);

class WebSearchConfigNotifier extends StateNotifier<WebSearchProvider> {
  WebSearchConfigNotifier() : super(const DuckDuckGoProvider()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final instance = prefs.getString('searxng_url');
    if (instance != null && instance.trim().isNotEmpty) {
      _apply(SearxngProvider(baseUrl: instance.trim()));
      return;
    }
    _apply(const DuckDuckGoProvider());
  }

  void _apply(WebSearchProvider provider) {
    state = provider;
    SearchService().configure(provider);
  }

  /// Switch backends at runtime (e.g. from the settings screen).
  void setProvider(WebSearchProvider provider) => _apply(provider);

  /// Point search at a SearXNG instance (or restore the default when empty).
  Future<void> setSearxngInstance(String url) async {
    final trimmed = url.trim();
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove('searxng_url');
    } else {
      await prefs.setString('searxng_url', trimmed);
    }
    await _load();
  }
}
