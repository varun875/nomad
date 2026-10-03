import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:llamadart/llamadart.dart';
import '../utils/logger.dart';
import 'duckduckgo_search_provider.dart';
import 'search_provider.dart';
import 'tinyfish_search_provider.dart';

/// Facade for web search backed by a pluggable [WebSearchProvider].
///
/// Uses TinyFish via Monid when the user has supplied their own API key
/// (Settings -> Web Search), otherwise falls back to the keyless DuckDuckGo
/// provider. The key is stored in the platform keychain, never in the repo.
class SearchService {
  static final SearchService _instance = SearchService._internal();
  factory SearchService() => _instance;
  SearchService._internal();

  static const _tinyFishKeyStorage = 'monid_api_key';
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
    final trimmed = key.trim();
    try {
      if (trimmed.isEmpty) {
        await _secureStorage.delete(key: _tinyFishKeyStorage);
      } else {
        await _secureStorage.write(key: _tinyFishKeyStorage, value: trimmed);
      }
    } catch (e) {
      Log.w('Search', 'Could not save Monid API key: $e');
    }
    await loadFromStorage();
  }

  /// Reads the stored key and selects the matching backend. Falls back to
  /// DuckDuckGo when no key is stored or the keychain is unavailable, so search
  /// never hard-fails.
  Future<void> loadFromStorage() async {
    final key = await readTinyFishApiKey();
    configure(key.isEmpty
        ? const DuckDuckGoProvider()
        : TinyFishSearchProvider(apiKey: key));
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
