/// Simple web-search results model.
class SearchResult {
  final String title;
  final String url;
  final String snippet;

  SearchResult({required this.title, required this.url, required this.snippet});
}

/// Contract for pluggable web-search backends.
///
/// Nomad currently ships with the Brave Search API backend; new backends
/// implement this interface and register through SearchService.configure or
/// the webSearchProvider Riverpod provider.
abstract class WebSearchProvider {
  /// Search the web and return the top [maxResults] results for [query].
  Future<List<SearchResult>> search(String query, {int maxResults = 5});
}
