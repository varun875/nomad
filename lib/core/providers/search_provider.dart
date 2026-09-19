import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/search_provider.dart';
import '../services/search_service.dart';

/// The active web-search backend — powered by TinyFish (live, free web search).
final webSearchProvider = Provider<WebSearchProvider>((ref) {
  return SearchService().provider;
});
