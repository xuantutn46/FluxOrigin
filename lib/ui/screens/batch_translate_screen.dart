import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import '../theme/app_theme.dart';
import '../theme/config_provider.dart';
import '../widgets/language_selector.dart';
import '../../controllers/batch_translation_controller.dart';
import '../../utils/app_strings.dart';
import '../../services/dev_logger.dart';

/// Screen that translates every matching file in a chosen folder.
///
/// This is the UI for the "Batch Translate" feature (GitHub issue #5).
class BatchTranslateScreen extends StatefulWidget {
  final bool isDark;

  const BatchTranslateScreen({super.key, required this.isDark});

  @override
  State<BatchTranslateScreen> createState() => _BatchTranslateScreenState();
}

class _BatchTranslateScreenState extends State<BatchTranslateScreen> {
  final BatchTranslationController _controller = BatchTranslationController();

  // Configuration
  String? _folderPath;
  String? _dictionaryPath;
  bool _recursive = false;
  bool _skipExisting = true;
  String _sourceLang = 'Tiếng Anh';
  String _targetLang = 'Tiếng Việt';

  // State
  List<String> _discoveredFiles = const [];
  BatchResult? _result;
  BatchProgress? _progress;
  bool _isRunning = false;
  String _statusMessage = '';

  final List<String> _allLanguages = ['Tiếng Anh', 'Tiếng Trung', 'Tiếng Việt'];

  Future<void> _pickFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: AppStrings.get(
          context.read<ConfigProvider>().appLanguage, 'batch_pick_folder'),
    );
    if (result == null) return;
    setState(() => _folderPath = result);
    await _refreshDiscoveredFiles();
  }

  Future<void> _pickDictionary() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result == null || result.files.single.path == null) return;
    setState(() => _dictionaryPath = result.files.single.path);
  }

  Future<void> _refreshDiscoveredFiles() async {
    if (_folderPath == null) {
      setState(() => _discoveredFiles = const []);
      return;
    }
    final files = await BatchTranslationController.scanFolder(
      _folderPath!,
      recursive: _recursive,
      extensions: const ['.txt'],
    );
    setState(() => _discoveredFiles = files);
  }

  Future<void> _start() async {
    if (_folderPath == null || _discoveredFiles.isEmpty) return;

    final configProvider = context.read<ConfigProvider>();
    final lang = configProvider.appLanguage;

    if (!configProvider.isConfigured) {
      _snack(AppStrings.get(lang, 'please_configure_project'), isError: true);
      return;
    }

    setState(() {
      _isRunning = true;
      _result = null;
      _progress = BatchProgress(
        total: _discoveredFiles.length,
        completed: 0,
        failed: 0,
        skipped: 0,
      );
      _statusMessage = AppStrings.get(lang, 'status_batch_progress')
          .replaceAll('{current}', '0')
          .replaceAll('{total}', _discoveredFiles.length.toString());
    });

    try {
      final result = await _controller.translateFolder(
        folderPath: _folderPath!,
        dictionaryDir: configProvider.dictionaryDir,
        modelName: configProvider.selectedModel,
        sourceLanguage: _sourceLang,
        targetLanguage: _targetLang,
        allowInternet: false,
        userGlossaryPath: _dictionaryPath,
        recursive: _recursive,
        skipExisting: _skipExisting,
        onUpdate: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _statusMessage = AppStrings.get(lang, 'status_batch_progress')
                .replaceAll('{current}',
                    (p.completed + p.failed + p.skipped).toString())
                .replaceAll('{total}', p.total.toString());
          });
        },
        appLanguage: lang,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _statusMessage = AppStrings.get(lang, 'status_batch_done')
            .replaceAll('{success}', result.succeeded.toString())
            .replaceAll('{failed}', result.failed.toString());
      });
    } catch (e) {
      if (!mounted) return;
      DevLogger()
          .error('BatchScreen', 'Batch failed', details: e.toString());
      _snack(
          '${AppStrings.get(lang, 'status_error')}: $e',
          isError: true);
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  void _requestPause() {
    _controller.requestPause();
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : null,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<ConfigProvider>().appLanguage;
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(lang),
          const SizedBox(height: 16),
          _buildConfig(lang),
          const SizedBox(height: 16),
          Expanded(child: _buildBody(lang)),
        ],
      ),
    );
  }

  Widget _buildHeader(String lang) {
    return Row(
      children: [
        FaIcon(
          FontAwesomeIcons.folderTree,
          color: widget.isDark ? Colors.white : AppColors.lightPrimary,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.get(lang, 'batch_title'),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Merriweather',
                  color: widget.isDark
                      ? Colors.white
                      : AppColors.lightPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                AppStrings.get(lang, 'batch_subtitle'),
                style: TextStyle(
                  fontSize: 13,
                  color:
                      widget.isDark ? Colors.grey[400] : Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConfig(String lang) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isDark
              ? const Color(0xFF444444)
              : Colors.grey[300]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Folder row
          Row(
            children: [
              FaIcon(
                FontAwesomeIcons.folderOpen,
                size: 18,
                color: widget.isDark
                    ? Colors.white
                    : AppColors.lightPrimary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _folderPath ?? AppStrings.get(lang, 'batch_no_folder'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: _folderPath == null
                        ? (widget.isDark
                            ? Colors.grey[500]
                            : Colors.grey[500])
                        : (widget.isDark
                            ? Colors.white
                            : Colors.black87),
                  ),
                ),
              ),
              OutlinedButton(
                onPressed: _isRunning ? null : _pickFolder,
                child: Text(AppStrings.get(lang, 'batch_pick_folder')),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Dictionary row (optional)
          Row(
            children: [
              FaIcon(
                FontAwesomeIcons.book,
                size: 18,
                color: widget.isDark
                    ? Colors.white
                    : AppColors.lightPrimary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _dictionaryPath != null
                      ? path.basename(_dictionaryPath!)
                      : AppStrings.get(lang, 'batch_pick_dictionary'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: _dictionaryPath == null
                        ? (widget.isDark
                            ? Colors.grey[500]
                            : Colors.grey[500])
                        : (widget.isDark
                            ? Colors.white
                            : Colors.black87),
                  ),
                ),
              ),
              if (_dictionaryPath != null)
                IconButton(
                  onPressed: _isRunning
                      ? null
                      : () => setState(() => _dictionaryPath = null),
                  icon: const FaIcon(FontAwesomeIcons.xmark, size: 12),
                ),
              OutlinedButton(
                onPressed: _isRunning ? null : _pickDictionary,
                child: Text(AppStrings.get(lang, 'choose_file')),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Toggles + language selectors
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Switch(
                      value: _recursive,
                      onChanged: _isRunning
                          ? null
                          : (v) {
                              setState(() => _recursive = v);
                              _refreshDiscoveredFiles();
                            },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppStrings.get(lang, 'batch_recursive'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Switch(
                      value: _skipExisting,
                      onChanged: _isRunning
                          ? null
                          : (v) => setState(() => _skipExisting = v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppStrings.get(lang, 'batch_skip_existing'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Languages
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: LanguageSelector(
                    value: _sourceLang,
                    isDark: widget.isDark,
                    availableLanguages: _allLanguages,
                    disabledLanguage: _targetLang,
                    onChange: _isRunning
                        ? (_) {}
                        : (v) => setState(() {
                              if (v == _targetLang) {
                                _targetLang = _sourceLang;
                              }
                              _sourceLang = v;
                            }),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: LanguageSelector(
                    value: _targetLang,
                    isDark: widget.isDark,
                    availableLanguages: _allLanguages,
                    disabledLanguage: _sourceLang,
                    onChange: _isRunning
                        ? (_) {}
                        : (v) => setState(() => _targetLang = v),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // File count + Start
          Row(
            children: [
              Expanded(
                child: Text(
                  AppStrings.get(lang, 'batch_files_found')
                      .replaceAll('{count}', _discoveredFiles.length.toString()),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _discoveredFiles.isEmpty
                        ? Colors.orange
                        : (widget.isDark
                            ? Colors.green[300]
                            : Colors.green[700]),
                  ),
                ),
              ),
              if (_isRunning)
                OutlinedButton.icon(
                  onPressed: _requestPause,
                  icon: const FaIcon(FontAwesomeIcons.pause, size: 12),
                  label: Text(AppStrings.get(lang, 'batch_pause')),
                )
              else
                ElevatedButton.icon(
                  onPressed: (_folderPath == null ||
                          _discoveredFiles.isEmpty)
                      ? null
                      : _start,
                  icon: const FaIcon(FontAwesomeIcons.play, size: 12),
                  label: Text(AppStrings.get(lang, 'batch_start')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.isDark
                        ? Colors.white
                        : AppColors.lightPrimary,
                    foregroundColor:
                        widget.isDark ? Colors.black : Colors.white,
                    elevation: 0,
                  ),
                ),
            ],
          ),

          if (_progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _progress!.total > 0 ? _progress!.fraction : null,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
              backgroundColor: widget.isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.grey[200],
              color: widget.isDark
                  ? Colors.white
                  : AppColors.lightPrimary,
            ),
            const SizedBox(height: 4),
            Text(
              _statusMessage,
              style: TextStyle(
                fontSize: 12,
                color:
                    widget.isDark ? Colors.grey[400] : Colors.grey[600],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(String lang) {
    final items = _result?.files ??
        _discoveredFiles
            .map((f) => BatchFileResult(
                filePath: f, fileName: path.basename(f)))
            .toList();

    if (items.isEmpty) {
      return Center(
        child: Text(
          _folderPath == null
              ? AppStrings.get(lang, 'batch_no_folder')
              : '—',
          style: TextStyle(
            color: widget.isDark ? Colors.grey[500] : Colors.grey[500],
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: widget.isDark ? AppColors.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isDark
              ? const Color(0xFF444444)
              : Colors.grey[300]!,
        ),
      ),
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          color: widget.isDark
              ? const Color(0xFF333333)
              : Colors.grey[200],
        ),
        itemBuilder: (ctx, i) {
          final item = items[i];
          return _BatchFileRow(
            result: item,
            isDark: widget.isDark,
            lang: lang,
          );
        },
      ),
    );
  }
}

class _BatchFileRow extends StatelessWidget {
  final BatchFileResult result;
  final bool isDark;
  final String lang;

  const _BatchFileRow({
    required this.result,
    required this.isDark,
    required this.lang,
  });

  @override
  Widget build(BuildContext context) {
    final (labelKey, color) = _statusPresentation(result.status);
    return ListTile(
      leading: FaIcon(
        FontAwesomeIcons.fileLines,
        size: 16,
        color: color,
      ),
      title: Text(
        result.fileName,
        style: const TextStyle(fontSize: 13),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: result.errorMessage != null
          ? Text(
              result.errorMessage!,
              style: TextStyle(
                fontSize: 11,
                color: Colors.red[300],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          AppStrings.get(lang, labelKey),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }

  (String, Color) _statusPresentation(BatchFileStatus s) {
    switch (s) {
      case BatchFileStatus.pending:
        return ('batch_status_pending', Colors.grey);
      case BatchFileStatus.running:
        return ('batch_status_running', Colors.blue);
      case BatchFileStatus.done:
        return ('batch_status_done', Colors.green);
      case BatchFileStatus.failed:
        return ('batch_status_failed', Colors.red);
      case BatchFileStatus.skipped:
        return ('batch_status_skipped', Colors.orange);
    }
  }
}
