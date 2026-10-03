import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/search_provider.dart';
import '../services/search_service.dart';

/// The active web-search backend — TinyFish when a Monid key is configured,
/// otherwise the keyless DuckDuckGo provider.
final webSearchProvider = Provider<WebSearchProvider>((ref) {
  return SearchService().provider;
});
