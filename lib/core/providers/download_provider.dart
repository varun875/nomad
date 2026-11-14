import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/hf_model.dart';
import '../models/download_status.dart';
import '../services/model_service.dart';
import '../services/inference_service.dart';
import '../services/download_notification_service.dart';

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, List<HFModel>>((ref) {
  return DownloadNotifier();
});

class DownloadNotifier extends StateNotifier<List<HFModel>> {
  StreamSubscription? _downloadSubscription;

  DownloadNotifier() : super([]) {
    _loadInstalledModels();
    _setupDownloader();
  }

  @override
  void dispose() {
    _downloadSubscription?.cancel();
    super.dispose();
  }

  void _loadInstalledModels() {
    final box = Hive.box('models');
    final hived = <HFModel>[];
    for (final key in box.keys.toList()) {
      try {
        final v = box.get(key);
        if (v == null) continue;
        hived.add(HFModel.fromJson(Map<String, dynamic>.from(v as Map)));
      } catch (e) {
        // Corrupt entry (schema change / interrupted write) would crash startup.
        // Remove it so the app can launch and the user can re-download.
        try {
          box.delete(key);
        } catch (_) {}
      }
    }
    final hivedIds = hived.map((m) => m.id).toSet();
    // Update existing state entries with Hive data, add any new ones
    state = [
      for (final m in state)
        if (hivedIds.contains(m.id))
          hived.firstWhere((h) => h.id == m.id)
        else
          m,
      ...hived.where((h) => !state.any((m) => m.id == h.id)),
    ];
  }



  Future<void> _setupDownloader() async {
    try {
      // Ensure the temporary cache directory exists on macOS
      // (background_downloader uses getTemporaryDirectory() which does not
      // auto-create the directory on macOS sandbox)
      try {
        final cacheDir = await getApplicationCacheDirectory();
        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
      } catch (_) {}
      
      final configured = await FileDownloader().configure(
        globalConfig: [('requestTimeout', const Duration(hours: 2))],
      );
      print('Downloader configured: $configured');
      _downloadSubscription = FileDownloader().updates.listen((update) {
        if (update is TaskProgressUpdate) {
          _updateProgress(
              update.task.taskId, update.progress, update.networkSpeed);
        } else if (update is TaskStatusUpdate) {
          print('Download status: ${update.status} for ${update.task.taskId}');
          if (update.status == TaskStatus.complete) {
            _markAsCompleted(update.task.taskId);
          } else if (update.status == TaskStatus.failed ||
              update.status == TaskStatus.canceled) {
            _markAsFailed(update.task.taskId, update.exception?.toString());
          }
        }
      });
      // Re-emit the current status/progress of tasks that were running while
      // the app was suspended, so the UI resumes where it left off.
      await FileDownloader().resumeFromBackground();
      await _reconcileStaleDownloads();
    } catch (e, stack) {
      print('ERROR: Failed to configure downloader: $e\n$stack');
    }
  }

  /// After an app restart, restore any downloads that finished while the app
  /// was away. background_downloader removes completed tasks from its task
  /// table, so a model left in "downloading" state with no live task has
  /// either finished or failed — verify the file and settle it.
  Future<void> _reconcileStaleDownloads() async {
    final stale =
        state.where((m) => m.downloadStatus == DownloadStatus.downloading).toList();
    for (final model in stale) {
      final task = await FileDownloader().taskForId(model.id);
      if (task != null) continue; // Still alive; resumeFromBackground handles it.

      final modelsDir = await ModelService.getModelDirectory();
      final modelPath = '${modelsDir.path}/${model.id.replaceAll('/', '_')}.gguf';
      if (await File(modelPath).exists()) {
        // _markAsCompleted re-verifies the file size and deletes it if bogus.
        _markAsCompleted(model.id);
      } else {
        _markAsFailed(model.id, 'Download interrupted. Tap to retry.');
      }
    }
  }



  Future<void> startDownloadWithUrl(HFModel model, String url) async {
    if (url.isEmpty) {
      print('Could not find download URL for ${model.id}');
      return;
    }

    // Free-storage preflight: the model file, its vision projector, and a 1 GB
    // buffer must fit before a download is started.
    final mmprojUrl = ModelService.getMmprojUrl(model.id);
    final neededBytes = (model.totalBytes ?? (model.sizeMB * 1024 * 1024)) +
        (mmprojUrl != null ? (model.mmprojBytes ?? 0) : 0) +
        (1024 * 1024 * 1024);
    final storage = await ModelService.getStorageSpace();
    final freeBytes = storage['free'] ?? 0;
    if (freeBytes > 0 && freeBytes < neededBytes) {
      final missingMB = ((neededBytes - freeBytes) / (1024 * 1024)).ceil();
      print('Not enough storage for ${model.id}: '
          'needs $neededBytes bytes, $freeBytes free');
      final failed = model.copyWith(
        downloadStatus: DownloadStatus.error,
        progress: 0,
        errorMessage:
            'Not enough storage. Free up about $missingMB MB and try again.',
      );
      if (state.any((m) => m.id == model.id)) {
        state =
            state.map((m) => m.id == model.id ? failed : m).toList();
      } else {
        state = [...state, failed];
      }
      unawaited(Hive.box('models').put(model.id, failed.toJson()));
      return;
    }

    print('Starting download for ${model.id}: $url');

    // Ensure models directory exists
    // Desktop Nomad Code runs as a separate process, so desktop model files
    // live in a predictable user-visible folder shared with that server.
    // Mobile keeps using the private app documents directory.
    final sharedDesktopModels = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final modelsDir = await ModelService.getModelDirectory();
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }

    final filename = '${model.id.replaceAll('/', '_')}.gguf';

    // Flux-style: direct public HF CDN URL, no Authorization header.
    // All Nomad models are on public Unsloth/Finn repos (resolve/main),
    // so anonymous CloudFront is fastest - no token throttle or extra hop.
    final task = DownloadTask(
      url: url,
      filename: filename,
      directory: sharedDesktopModels ? 'Nomad/models' : 'models',
      baseDirectory: BaseDirectory.applicationDocuments,
      updates: Updates.statusAndProgress,
      retries: 3,
      allowPause: true,
      taskId: model.id,
      displayName: model.name,
      priority: 10, // High priority for faster downloading
      requiresWiFi: await _downloadsRequireWifi(),
    );

    // Preserve existing progress if resuming, otherwise start at 0
    final currentProgress = model.progress;
    final updatedModel = model.copyWith(
      downloadStatus: DownloadStatus.downloading,
      progress: currentProgress,
    );

    if (state.any((m) => m.id == model.id)) {
      state = state.map((m) => m.id == model.id ? updatedModel : m).toList();
    } else {
      state = [...state, updatedModel];
    }

    // Persist the in-progress record so a restart (which re-reads Hive) can
    // restore the download and its progress instead of forgetting it.
    final box = Hive.box('models');
    await box.put(model.id, updatedModel.toJson());

    final enqueued = await FileDownloader().enqueue(task);
    print('Download task enqueued for ${model.id}: $enqueued (file: $filename)');
    if (enqueued) {
      DownloadNotificationService.onDownloadStart(
        model.id,
        model.name,
        model.totalBytes ?? (model.sizeMB * 1024 * 1024).toInt(),
      );
    }
    if (!enqueued) {
      state = state.map((m) {
        if (m.id == model.id) {
          return m.copyWith(
            downloadStatus: DownloadStatus.error,
            progress: 0,
            errorMessage: 'Failed to start download. Check network connection.',
          );
        }
        return m;
      }).toList();
    }
  }

  void _updateProgress(String id, double progress, double speed) {
    // The mmproj task streams under its own id; fold its progress into the
    // owning model's combined (model + projector) progress so the card shows
    // one download with the projector's bytes included.
    final isMmproj = id.endsWith('_mmproj');
    final modelId =
        isMmproj ? id.substring(0, id.length - '_mmproj'.length) : id;
    // Clamp progress between 0 and 1 to avoid negative or >100% values
    final clampedProgress = progress.clamp(0.0, 1.0);
    final box = Hive.box('models');
    state = state.map((m) {
      if (m.id == modelId) {
        final modelBytes = m.totalBytes ?? (m.sizeMB * 1024 * 1024);
        final mmprojBytes =
            ModelService.getMmprojUrl(m.id) != null ? (m.mmprojBytes ?? 0) : 0;
        final totalBytes = modelBytes + mmprojBytes;
        // Once the mmproj phase starts the model file is fully on disk, so
        // combined progress never regresses between the two tasks.
        final downloadedBytes = isMmproj
            ? modelBytes + (mmprojBytes * clampedProgress).toInt()
            : (modelBytes * clampedProgress).toInt();
        final combinedProgress =
            totalBytes == 0 ? 0.0 : downloadedBytes / totalBytes;
        final newPercent = (combinedProgress * 100).round();

        DownloadNotificationService.onProgressUpdate(
          modelId,
          combinedProgress,
          speed >= 0 ? speed : (m.downloadSpeed ?? 0),
          downloadedBytes,
          totalBytes,
        );

        final updated = m.copyWith(
          downloadStatus: DownloadStatus.downloading,
          progress: newPercent,
          downloadSpeed: speed >= 0 ? speed : (m.downloadSpeed ?? 0),
          downloadedBytes: downloadedBytes,
          totalBytes: modelBytes.toInt(),
        );

        // Persist every 5% so progress survives an app restart without
        // excessive flash I/O on mobile (was every 1% = ~100 writes).
        if (m.progress != newPercent && newPercent % 5 == 0) {
          unawaited(box.put(modelId, updated.toJson()));
        }
        return updated;
      }
      return m;
    }).toList();
  }

  Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Verifies a downloaded mmproj file against its pinned SHA-256, deleting the
  /// file on mismatch or when the hash cannot be read, so a corrupted
  /// projector is never kept around for the backend to load. Returns whether
  /// the file passed verification.
  Future<bool> _verifyMmproj(String modelId) async {
    final expected = ModelService.pinnedMmprojSha256For(modelId);
    if (expected == null || expected.isEmpty) return true;
    final modelsDir = await ModelService.getModelDirectory();
    final file =
        File('${modelsDir.path}/${modelId.replaceAll('/', '_')}.mmproj');
    if (!await file.exists()) return true;
    try {
      final actual = await _sha256OfFile(file);
      if (actual.toLowerCase() != expected.toLowerCase()) {
        print('ERROR: mmproj SHA256 mismatch for $modelId');
        try {
          await file.delete();
        } catch (_) {}
        return false;
      }
      print('mmproj SHA256 verified for $modelId');
      return true;
    } catch (e) {
      // A hash-read failure means the file may be truncated or corrupted:
      // delete it instead of keeping a potentially bad projector.
      print('ERROR: mmproj SHA256 check failed for $modelId: $e (deleting file)');
      try {
        await file.delete();
      } catch (_) {}
      return false;
    }
  }

  Future<void> _markAsCompleted(String id) async {
    // The multimodal projector shares this completion pipeline but has no
    // state entry of its own, so verify it here against its pinned hash and
    // surface any failure on the owning model.
    if (id.endsWith('_mmproj')) {
      final modelId = id.substring(0, id.length - '_mmproj'.length);
      final verified = await _verifyMmproj(modelId);
      if (!verified) {
        await _markAsFailed(
            modelId, 'Vision projector download failed (checksum). Tap to retry.');
        return;
      }
      await _completeModel(modelId);
      return;
    }
    final matches = state.where((m) => m.id == id);
    if (matches.isEmpty) return;
    final model = matches.first;
    final modelsDir = await ModelService.getModelDirectory();
    final modelPath = '${modelsDir.path}/${id.replaceAll('/', '_')}.gguf';

    // Verify file exists
    final file = File(modelPath);
    if (!await file.exists()) {
      print('ERROR: Download completed but file not found at $modelPath');
      _markAsFailed(id, 'Download file not found. Please try again.');
      return;
    }

    final fileSize = await file.length();

    // Verify the file actually matches the expected size. background_downloader
    // reports "complete" even when a server error page is saved under the .gguf
    // name, so a partial or bogus file would otherwise be marked as installed.
    final expectedBytes = model.totalBytes ?? (model.sizeMB * 1024 * 1024);
    if (expectedBytes > 0 && fileSize < expectedBytes * 0.9) {
      print('ERROR: File size mismatch for $id: '
          '${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB downloaded, '
          'expected ~${(expectedBytes / 1024 / 1024).toStringAsFixed(0)} MB');
      try {
        await file.delete();
      } catch (_) {}
      _markAsFailed(
        id,
        'Downloaded file is incomplete '
        '(${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB, expected '
        '~${(expectedBytes / 1024 / 1024).toStringAsFixed(0)} MB). '
        'Please try again.',
      );
      return;
    }

    final expectedSha = ModelService.pinnedSha256For(id);
    if (expectedSha != null && expectedSha.isNotEmpty) {
      try {
        final actualSha = await _sha256OfFile(file);
        if (actualSha.toLowerCase() != expectedSha.toLowerCase()) {
          print('ERROR: SHA256 mismatch for $id: expected $expectedSha got $actualSha');
          try {
            await file.delete();
          } catch (_) {}
          _markAsFailed(
            id,
            'Download corrupted (checksum mismatch). Please try again.',
          );
          return;
        }
        print('SHA256 verified for $id');
      } catch (e) {
        print('ERROR: SHA256 check failed for $id: $e');
        try {
          await file.delete();
        } catch (_) {}
        _markAsFailed(
          id,
          'Download corrupted (checksum check failed). Please try again.',
        );
        return;
      }
    } else {
      print('ERROR: No pinned SHA256 for $id — refusing to mark as completed');
      try {
        await file.delete();
      } catch (_) {}
      _markAsFailed(
        id,
        'Missing checksum for model. Please update the app.',
      );
      return;
    }

    print(
        'Download completed: $modelPath (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');

    // Download multimodal projector (mmproj) for vision models. The model is
    // only marked installed once the projector has arrived and verified, so a
    // vision download failure surfaces in the UI instead of being silent.
    final mmprojUrl = ModelService.getMmprojUrl(id);
    if (mmprojUrl != null) {
      final mmprojPath =
          '${modelsDir.path}/${id.replaceAll('/', '_')}.mmproj';
      if (!await File(mmprojPath).exists()) {
        final pendingModel = model.copyWith(
          downloaded: false,
          downloadStatus: DownloadStatus.downloading,
          localPath: modelPath,
        );
        state = state.map((m) => m.id == id ? pendingModel : m).toList();
        await Hive.box('models').put(id, pendingModel.toJson());
        await _enqueueMmproj(id, mmprojUrl);
        return;
      }
      // Projector already on disk (e.g. restored after a restart): enforce its
      // integrity before declaring the download complete.
      if (!await _verifyMmproj(id)) {
        await _markAsFailed(
            id, 'Vision projector download failed (checksum). Tap to retry.');
        return;
      }
    }

    await _completeModel(id);
  }

  /// Marks a fully verified model (and its mmproj, when present) as installed.
  Future<void> _completeModel(String id) async {
    final matches = state.where((m) => m.id == id);
    if (matches.isEmpty) return;
    final model = matches.first;
    var modelPath = model.localPath;
    if (modelPath == null) {
      final modelsDir = await ModelService.getModelDirectory();
      modelPath = '${modelsDir.path}/${id.replaceAll('/', '_')}.gguf';
    }

    DownloadNotificationService.onDownloadComplete(id);

    final completedModel = model.copyWith(
      downloaded: true,
      progress: 100,
      downloadStatus: DownloadStatus.completed,
      localPath: modelPath,
    );

    state = state.map((m) => m.id == id ? completedModel : m).toList();

    final box = Hive.box('models');
    await box.put(id, completedModel.toJson());
  }

  /// Whether downloads should pause until Wi-Fi is available (Settings).
  Future<bool> _downloadsRequireWifi() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('downloadsRequireWifi') ?? false;
  }

  Future<void> _enqueueMmproj(String id, String url) async {
    final sharedDesktopModels =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final mmprojTask = DownloadTask(
      url: url,
      filename: '${id.replaceAll('/', '_')}.mmproj',
      directory: sharedDesktopModels ? 'Nomad/models' : 'models',
      baseDirectory: BaseDirectory.applicationDocuments,
      // The projector is a full download (up to ~200 MB): show its progress.
      updates: Updates.statusAndProgress,
      retries: 3,
      allowPause: true,
      taskId: '${id}_mmproj',
      requiresWiFi: await _downloadsRequireWifi(),
    );
    try {
      final enqueued = await FileDownloader().enqueue(mmprojTask);
      if (!enqueued) {
        await _markAsFailed(
            id, 'Vision projector download failed to start. Tap to retry.');
      }
    } catch (e) {
      print('Mmproj download error for $id: $e');
      await _markAsFailed(
          id, 'Vision projector download failed. Tap to retry.');
    }
  }

  Future<void> _markAsFailed(String id, [String? error]) async {
    // The mmproj task has no state entry of its own: strip the suffix so its
    // failure surfaces on the owning model's card instead of disappearing.
    final modelId = id.endsWith('_mmproj')
        ? id.substring(0, id.length - '_mmproj'.length)
        : id;
    print('Download failed for $modelId: ${error ?? 'unknown error'}');
    DownloadNotificationService.onDownloadError(modelId);
    final box = Hive.box('models');
    state = state.map((m) {
      if (m.id == modelId) {
        final failed = m.copyWith(
          downloadStatus: DownloadStatus.error,
          progress: 0,
          errorMessage: error ?? 'Download failed. Tap to retry.',
        );
        unawaited(box.put(modelId, failed.toJson()));
        return failed;
      }
      return m;
    }).toList();
  }

  Future<void> deleteModel(String id) async {
    final modelIndex = state.indexWhere((m) => m.id == id);
    if (modelIndex == -1) return;

    // Cancel any live download first - otherwise its later complete event
    // will re-mark the just-deleted model as installed.
    try {
      await FileDownloader().cancelTaskWithId(id);
      await FileDownloader().cancelTaskWithId('${id}_mmproj');
    } catch (_) {}

    final model = state[modelIndex];

    // Unload the model from the inference engine first. Otherwise the engine
    // keeps a stale handle to a now-deleted file, and the next message either
    // errors or silently re-loads a path that no longer exists. On Windows
    // this also prevents the file delete from failing while it is open.
    if (InferenceService().isLoaded &&
        InferenceService().modelPath == model.localPath) {
      await InferenceService().unloadModel();
      print('Unloaded active model: ${model.localPath}');
    }

    if (model.localPath != null) {
      final file = File(model.localPath!);
      if (await file.exists()) {
        await file.delete();
        print('Deleted model file: ${model.localPath}');
      }
      // Also delete the mmproj if it exists
      final mmprojFile = File(model.localPath!.replaceAll('.gguf', '.mmproj'));
      if (await mmprojFile.exists()) {
        await mmprojFile.delete();
        print('Deleted mmproj file: ${mmprojFile.path}');
      }
    }

    final box = Hive.box('models');
    await box.delete(id);

    // Update state by resetting download info instead of just removing (so it stays in library)
    state = state
        .map((m) => m.id == id
            ? m.copyWith(
                downloadStatus: DownloadStatus.none,
                downloaded: false,
                localPath: null,
                progress: 0,
              )
            : m)
        .toList();
  }

  /// Clear error state before retrying download
  void clearError(String id) {
    state = state.map((m) {
      if (m.id == id) {
        return m.copyWith(
          downloadStatus: DownloadStatus.none,
          errorMessage: null,
          progress: 0,
          clearError: true,
        );
      }
      return m;
    }).toList();
  }

  /// Cancel a downloading model
  Future<void> cancelDownload(String id) async {
    DownloadNotificationService.onDownloadCancelled(id);
    // Cancel the download tasks (model file and vision projector)
    await FileDownloader().cancelTaskWithId(id);
    await FileDownloader().cancelTaskWithId('${id}_mmproj');

    // Reset state
    final box = Hive.box('models');
    state = state.map((m) {
      if (m.id == id) {
        final cancelled = m.copyWith(
          downloadStatus: DownloadStatus.none,
          progress: 0,
          downloadSpeed: 0,
        );
        unawaited(box.put(id, cancelled.toJson()));
        return cancelled;
      }
      return m;
    }).toList();

    // Clean up any partial files
    final modelsDir = await ModelService.getModelDirectory();
    final partialFile = File('${modelsDir.path}/${id.replaceAll('/', '_')}.gguf');
    if (await partialFile.exists()) {
      await partialFile.delete();
    }
    final partialMmproj =
        File('${modelsDir.path}/${id.replaceAll('/', '_')}.mmproj');
    if (await partialMmproj.exists()) {
      await partialMmproj.delete();
    }
  }
}
