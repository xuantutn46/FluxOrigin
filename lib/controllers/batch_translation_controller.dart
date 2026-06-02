import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as path;
import 'translation_controller.dart';
import '../services/dev_logger.dart';

/// Status of a single file within a batch run.
enum BatchFileStatus {
  pending,
  running,
  done,
  failed,
  skipped,
}

/// Result of a single file within a batch run.
class BatchFileResult {
  final String filePath;
  final String fileName;
  BatchFileStatus status;
  String? errorMessage;
  String? outputPath;

  BatchFileResult({
    required this.filePath,
    required this.fileName,
    this.status = BatchFileStatus.pending,
    this.errorMessage,
    this.outputPath,
  });
}

/// Aggregated progress info for a batch run.
class BatchProgress {
  final int total;
  final int completed;
  final int failed;
  final int skipped;
  final String? currentFile;

  const BatchProgress({
    required this.total,
    required this.completed,
    required this.failed,
    required this.skipped,
    this.currentFile,
  });

  /// 0.0..1.0 — overall progress (counts done + failed + skipped as finished).
  double get fraction {
    if (total <= 0) return 0.0;
    return (completed + failed + skipped) / total;
  }
}

/// Final aggregated result of a batch run.
class BatchResult {
  final List<BatchFileResult> files;
  final int succeeded;
  final int failed;
  final int skipped;

  const BatchResult({
    required this.files,
    required this.succeeded,
    required this.failed,
    required this.skipped,
  });

  int get total => files.length;
}

/// Translates every matching file in a folder sequentially.
///
/// This is the controller behind the "Batch Translate" feature
/// (GitHub issue #5). It reuses [TranslationController.processFile] for the
/// per-file work, so all the recent fixes (issue #6 user-glossary handling,
/// pause/resume, progress throttling) automatically apply to batch runs too.
class BatchTranslationController {
  final TranslationController _translationController = TranslationController();
  final DevLogger _logger = DevLogger();

  bool _isPaused = false;
  bool _isRunning = false;

  /// Whether a batch run is currently in progress.
  bool get isRunning => _isRunning;

  /// Request a graceful pause. The currently-translating chunk finishes,
  /// then the loop exits before starting the next file.
  void requestPause() {
    _isPaused = true;
  }

  /// Reset pause state — call before starting/resuming.
  void resetPause() {
    _isPaused = false;
  }

  /// Scan a folder for files matching the given extensions.
  ///
  /// Returns an empty list (and logs a warning) if the folder does not exist
  /// or is not a directory. Hidden files (names starting with `.`) are
  /// skipped to avoid surprising the user with `.DS_Store`, `Thumbs.db`, etc.
  static Future<List<String>> scanFolder(
    String folderPath, {
    bool recursive = false,
    List<String> extensions = const ['.txt'],
  }) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      return const [];
    }

    final results = <String>[];
    final lowerExts = extensions.map((e) => e.toLowerCase()).toList();

    Future<void> walk(Directory d) async {
      await for (final entity in d.list(followLinks: false)) {
        final name = path.basename(entity.path);
        if (name.startsWith('.')) continue; // skip hidden
        if (entity is Directory) {
          if (recursive) {
            await walk(entity);
          }
        } else if (entity is File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (lowerExts.contains(ext)) {
            results.add(entity.path);
          }
        }
      }
    }

    await walk(dir);
    results.sort();
    return results;
  }

  /// Run a batch translation over every file in [folderPath] matching the
  /// given extensions. The call is **sequential** (one file at a time) to
  /// avoid overloading the local LLM and to keep the UI simple.
  ///
  /// Per-file results are streamed via [onUpdate] with a [BatchProgress]
  /// snapshot. The final [BatchResult] is returned when the run finishes
  /// (or is paused).
  Future<BatchResult> translateFolder({
    required String folderPath,
    required String dictionaryDir,
    required String modelName,
    required String sourceLanguage,
    required String targetLanguage,
    required bool allowInternet,
    String? userGlossaryPath,
    bool recursive = false,
    bool skipExisting = false,
    List<String> extensions = const ['.txt'],
    required Function(BatchProgress progress) onUpdate,
    String appLanguage = 'vi',
  }) async {
    if (_isRunning) {
      throw StateError(
          'BatchTranslationController is already running. Wait for the current batch to finish or pause it.');
    }
    _isRunning = true;
    _isPaused = false;
    _translationController.resetPause();

    _logger.info('Batch', 'Starting batch translation', details: '''
Folder: $folderPath
Recursive: $recursive
Skip existing: $skipExisting
Extensions: $extensions
Shared glossary: ${userGlossaryPath ?? "<none>"}
''');

    try {
      final files = await scanFolder(folderPath,
          recursive: recursive, extensions: extensions);
      final results = files
          .map((f) => BatchFileResult(
                filePath: f,
                fileName: path.basename(f),
              ))
          .toList();

      _logger.info('Batch', 'Found ${results.length} file(s) to translate');

      if (results.isEmpty) {
        onUpdate(const BatchProgress(
          total: 0,
          completed: 0,
          failed: 0,
          skipped: 0,
        ));
        return const BatchResult(
            files: [], succeeded: 0, failed: 0, skipped: 0);
      }

      int completed = 0;
      int failed = 0;
      int skipped = 0;

      for (int i = 0; i < results.length; i++) {
        if (_isPaused) {
          _logger.info('Batch',
              'Paused at file ${i + 1}/${results.length} (${results[i].fileName})');
          // Mark remaining as pending; the user can resume
          for (int j = i; j < results.length; j++) {
            results[j].status = BatchFileStatus.pending;
          }
          break;
        }

        final result = results[i];
        result.status = BatchFileStatus.running;
        onUpdate(BatchProgress(
          total: results.length,
          completed: completed,
          failed: failed,
          skipped: skipped,
          currentFile: result.fileName,
        ));

        // Skip if output already exists and user opted into skipExisting.
        // The convention is: <originalName>_translated.txt in the same folder.
        final outputPath = _deriveOutputPath(result.filePath);
        final outputFile = File(outputPath);
        if (skipExisting && await outputFile.exists()) {
          result.status = BatchFileStatus.skipped;
          result.outputPath = outputPath;
          skipped++;
          _logger.info('Batch',
              'Skipped (output exists): ${result.fileName}');
          continue;
        }

        try {
          final translated = await _translationController.processFile(
            filePath: result.filePath,
            dictionaryDir: dictionaryDir,
            modelName: modelName,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            allowInternet: allowInternet,
            userGlossaryPath: userGlossaryPath,
            appLanguage: appLanguage,
            // Pause is propagated via TranslationController; we still
            // surface it through our own _isPaused flag below.
            onUpdate: (_, __) {/* per-file progress not surfaced at batch level */},
            onChunkUpdate: (_, __, ___, ____) {},
          );

          if (translated == null) {
            // Inner controller paused — treat as pause for the batch.
            result.status = BatchFileStatus.pending;
            result.errorMessage = 'paused';
            _isPaused = true;
            break;
          }

          // Save the translated content next to the source file.
          await outputFile.writeAsString(translated);
          result.status = BatchFileStatus.done;
          result.outputPath = outputPath;
          completed++;
          _logger.info('Batch',
              'Done: ${result.fileName} → $outputPath (${translated.length} chars)');
        } catch (e) {
          result.status = BatchFileStatus.failed;
          result.errorMessage = e.toString();
          failed++;
          _logger.error('Batch', 'Failed: ${result.fileName}', details: e.toString());
          // Continue with the next file rather than aborting the whole batch.
        }
      }

      final finalProgress = BatchProgress(
        total: results.length,
        completed: completed,
        failed: failed,
        skipped: skipped,
      );
      onUpdate(finalProgress);

      _logger.info('Batch',
          'Batch finished: $completed succeeded, $failed failed, $skipped skipped');

      return BatchResult(
        files: results,
        succeeded: completed,
        failed: failed,
        skipped: skipped,
      );
    } finally {
      _isRunning = false;
    }
  }

  /// Build the default output path for a translated file.
  ///
  /// Convention: `<originalName>_translated.txt` written in the same folder
  /// as the source. This is intentionally simple — the user can move/rename
  /// the output later, and a later enhancement could expose a configurable
  /// naming pattern.
  static String _deriveOutputPath(String sourcePath) {
    final dir = path.dirname(sourcePath);
    final name = path.basenameWithoutExtension(sourcePath);
    return path.join(dir, '${name}_translated.txt');
  }

  /// Exposed for tests — see deriveOutputPath.
  @visibleForTesting
  static String debugDeriveOutputPath(String sourcePath) =>
      _deriveOutputPath(sourcePath);
}
