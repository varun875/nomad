/// Strongly-typed download state, replacing the old stringly-typed
/// `downloadStatus` field that was prone to typos.
enum DownloadStatus {
  none,
  downloading,
  paused,
  completed,
  error;

  /// Deserialise from the JSON string stored in Hive.
  static DownloadStatus fromString(String? value) {
    switch (value) {
      case 'downloading':
        return DownloadStatus.downloading;
      case 'paused':
        return DownloadStatus.paused;
      case 'completed':
        return DownloadStatus.completed;
      case 'error':
        return DownloadStatus.error;
      default:
        return DownloadStatus.none;
    }
  }

  /// Serialise to a plain string for Hive / JSON storage.
  String toJsonString() => name;
}
