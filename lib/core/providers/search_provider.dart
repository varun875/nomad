import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/brave_search_provider.dart';
import '../services/duckduckgo_search_provider.dart';
import '../services/searxng_search_provider.dart';
import '../services/search_provider.dart';
import '../services/search_service.dart';

/// The active web-search backend.
///
/// Defaults to the zero-config DuckDuckGo scraper. Precedence when configured:
/// 1. Brave Search API, when a key is stored in prefs (`brave_api_key`);
/// 2. a SearXNG instance, when a URL is stored in prefs (`searxng_url`).
///
/// Settings UI can call `ref.read(webSearchProvider.notifier).setBraveApiKey(...)`
/// or `...setSearxngInstance(...)` to reconfigure at runtime.
final webSearchProvider = StateNotifierProvider<WebSearchConfigNotifier, WebSearchProvider>(
  (ref) => WebSearchConfigNotifier(),
);

class WebSearchConfigNotifier extends StateNotifier<WebSearchProvider> {
  WebSearchConfigNotifier() : super(const DuckDuckGoProvider()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final braveKey = prefs.getString('brave_api_key');
    if (braveKey != null && braveKey.trim().isNotEmpty) {
      _apply(BraveSearchProvider(apiKey: braveKey.trim()));
      return;
    }
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

  /// Store (or clear, when empty) a Brave Search API key. When set, Brave
  /// becomes the active backend.
  Future<void> setBraveApiKey(String key) async {
    final trimmed = key.trim();
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove('brave_api_key');
      await _load();
    } else {
      await prefs.setString('brave_api_key', trimmed);
      _apply(BraveSearchProvider(apiKey: trimmed));
    }
  }

  /// Point search at a SearXNG instance (or restore the default when empty).
  /// Has no effect while a Brave API key is configured.
  Future<void> setSearxngInstance(String url) async {
    final trimmed = url.trim();
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove('searxng_url');
    } else {
      await prefs.setString('searxng_url', trimmed);
    }
    final braveKey = prefs.getString('brave_api_key');
    if (braveKey == null || braveKey.trim().isEmpty) {
      await _load();
    }
  }
}
