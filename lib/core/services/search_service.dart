import 'package:llamadart/llamadart.dart';
import 'duckduckgo_search_provider.dart';
import 'search_provider.dart';

/// Facade for web search backed by a pluggable [WebSearchProvider].
///
/// Defaults to the zero-config DuckDuckGo scraper (free, no key).
/// A self-hosted SearXNG instance can be used instead.
class SearchService {
  static final SearchService _instance = SearchService._internal();
  factory SearchService() => _instance;
  SearchService._internal();

  WebSearchProvider _provider = const DuckDuckGoProvider();

  /// The currently active search backend.
  WebSearchProvider get provider => _provider;

  /// Swap the search backend at runtime (e.g. DuckDuckGo -> SearXNG).
  void configure(WebSearchProvider provider) {
    _provider = provider;
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
