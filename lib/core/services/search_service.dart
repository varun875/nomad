import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:llamadart/llamadart.dart';
import '../utils/logger.dart';
import 'brave_search_provider.dart';
import 'duckduckgo_search_provider.dart';
import 'search_provider.dart';
import 'searxng_search_provider.dart';
import 'tinyfish_search_provider.dart';

/// Facade for web search backed by a pluggable [WebSearchProvider].
///
/// Backend selection, highest priority first — every option is opt-in and
/// zero-config DuckDuckGo is always the fallback:
/// 1. Brave Search API (Settings, bring-your-own key)
/// 2. SearXNG (Settings, self-hosted instance URL)
/// 3. TinyFish via Monid (Settings, per-user Monid key)
/// 4. DuckDuckGo (keyless)
/// Keys and URLs are stored in the platform keychain, never in the repo.
class SearchService {
  static final SearchService _instance = SearchService._internal();
  factory SearchService() => _instance;
  SearchService._internal();

  static const _tinyFishKeyStorage = 'monid_api_key';
  static const _braveKeyStorage = 'brave_api_key';
  static const _searxngUrlStorage = 'searxng_url';
  static const _secureStorage = FlutterSecureStorage();

  WebSearchProvider _provider = const DuckDuckGoProvider();

  /// The currently active search backend.
  WebSearchProvider get provider => _provider;

  /// Swap the search backend at runtime (e.g. DuckDuckGo -> TinyFish).
  void configure(WebSearchProvider provider) {
    _provider = provider;
  }

  /// Whether a TinyFish/Monid key is currently stored.
  Future<bool> hasTinyFishKey() async =>
      (await readTinyFishApiKey()).isNotEmpty;

  /// Returns the stored Monid key, or an empty string if none is set.
  Future<String> readTinyFishApiKey() async {
    try {
      return (await _secureStorage.read(key: _tinyFishKeyStorage))?.trim() ?? '';
    } catch (e) {
      Log.w('Search', 'Could not read Monid API key: $e');
      return '';
    }
  }

  /// Stores (or clears, when [key] is empty) the user's Monid key and applies
  /// it to the active provider immediately.
  Future<void> setTinyFishApiKey(String key) async {
    await _writeOrClear(_tinyFishKeyStorage, key);
    await loadFromStorage();
  }

  /// Whether a Brave Search API key is currently stored.
  Future<bool> hasBraveKey() async => (await readBraveApiKey()).isNotEmpty;

  /// Returns the stored Brave Search API key, or an empty string if none set.
  Future<String> readBraveApiKey() async {
    try {
      return (await _secureStorage.read(key: _braveKeyStorage))?.trim() ?? '';
    } catch (e) {
      Log.w('Search', 'Could not read Brave API key: $e');
      return '';
    }
  }

  /// Stores (or clears, when [key] is empty) the user's Brave Search API key
  /// and applies it to the active provider immediately.
  Future<void> setBraveApiKey(String key) async {
    await _writeOrClear(_braveKeyStorage, key);
    await loadFromStorage();
  }

  /// Whether a self-hosted SearXNG URL is currently stored.
  Future<bool> hasSearxngUrl() async => (await readSearxngUrl()).isNotEmpty;

  /// Returns the stored SearXNG instance URL, or an empty string if none set.
  Future<String> readSearxngUrl() async {
    try {
      return (await _secureStorage.read(key: _searxngUrlStorage))?.trim() ?? '';
    } catch (e) {
      Log.w('Search', 'Could not read SearXNG URL: $e');
      return '';
    }
  }

  /// Stores (or clears, when [url] is empty) the user's self-hosted SearXNG
  /// instance URL and applies it to the active provider immediately.
  Future<void> setSearxngUrl(String url) async {
    await _writeOrClear(_searxngUrlStorage, url);
    await loadFromStorage();
  }

  Future<void> _writeOrClear(String storageKey, String value) async {
    final trimmed = value.trim();
    try {
      if (trimmed.isEmpty) {
        await _secureStorage.delete(key: storageKey);
      } else {
        await _secureStorage.write(key: storageKey, value: trimmed);
      }
    } catch (e) {
      Log.w('Search', 'Could not save $storageKey: $e');
    }
  }

  /// Reads the stored keys/URL and selects the matching backend, highest
  /// priority first (Brave > SearXNG > TinyFish). Falls back to DuckDuckGo
  /// when nothing is stored or the keychain is unavailable, so search never
  /// hard-fails.
  Future<void> loadFromStorage() async {
    final braveKey = await readBraveApiKey();
    if (braveKey.isNotEmpty) {
      configure(BraveSearchProvider(apiKey: braveKey));
      return;
    }
    final searxngUrl = await readSearxngUrl();
    if (searxngUrl.isNotEmpty) {
      // The user explicitly chose this instance, so self-hosted LAN addresses
      // (e.g. http://192.168.1.10:8888) are acceptable targets.
      configure(SearxngProvider(baseUrl: searxngUrl, allowPrivate: true));
      return;
    }
    final key = await readTinyFishApiKey();
    configure(key.isEmpty
        ? const DuckDuckGoProvider()
        : TinyFishSearchProvider(apiKey: key));
  }

  /// Human-readable name of the active backend for the Settings tile.
  Future<String> activeBackendLabel() async {
    if (await hasBraveKey()) return 'Brave Search · key set';
    if (await hasSearxngUrl()) return 'SearXNG · self-hosted';
    if (await hasTinyFishKey()) return 'TinyFish · Monid key set';
    return 'DuckDuckGo';
  }

  /// Search the web and return the top [maxResults] snippets.
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) {
    return _provider.search(query, maxResults: maxResults);
  }

  /// Tool definition for web search that the model can invoke via function calling.
  static ToolDefinition get webSearchTool => ToolDefinition(
    name: 'web_search',
    description:
        'Search the web for current information. Use this for questions '
        'about recent events, facts you are unsure about, '
        'or when the user explicitly asks you to search.',
    parameters: [
      ToolParam.string('query',
          description: 'The search query', required: true),
    ],
    handler: (params) async {
      final query = params.getRequiredString('query');
      final results = await SearchService().search(query, maxResults: 5);
      if (results.isEmpty) {
        return 'No results found for "$query".';
      }
      return SearchService().formatResultsForModel(results);
    },
  );

  /// Format search results into a concise context string for the model.
  String formatResultsForModel(List<SearchResult> results) {
    if (results.isEmpty) return '';
    final buffer = StringBuffer()
      ..writeln('=== WEB SEARCH RESULTS ===');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      buffer.writeln('[${i + 1}] ${r.title}');
      if (r.snippet.isNotEmpty) buffer.writeln('    ${r.snippet}');
    }
    buffer.writeln('==========================');
    return buffer.toString();
  }
}
