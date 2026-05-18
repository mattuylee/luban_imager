import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const LubanImagerApp());
}

class LubanImagerApp extends StatefulWidget {
  const LubanImagerApp({super.key});

  @override
  State<LubanImagerApp> createState() => _LubanImagerAppState();
}

class _LubanImagerAppState extends State<LubanImagerApp>
    with WidgetsBindingObserver {
  late String _appName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appName = AppName.forLocales(
      WidgetsBinding.instance.platformDispatcher.locales,
    );
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    setState(() {
      _appName = AppName.forLocales(
        locales ?? WidgetsBinding.instance.platformDispatcher.locales,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: _appName,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2F6F73),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8F6),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: Color(0xFFF7F8F6),
          foregroundColor: Color(0xFF172122),
          elevation: 0,
        ),
      ),
      home: ImagerHomePage(appName: _appName),
    );
  }
}

class AppName {
  static const english = 'Luban Imager';
  static const chinese = '鲁班压图';

  static String forLocales(List<Locale> locales) {
    final locale = locales.isNotEmpty
        ? locales.first
        : WidgetsBinding.instance.platformDispatcher.locale;
    return forLocale(locale);
  }

  static String forLocale(Locale locale) {
    return locale.languageCode.toLowerCase() == 'zh' ? chinese : english;
  }
}

class ImagerHomePage extends StatefulWidget {
  const ImagerHomePage({required this.appName, super.key});

  final String appName;

  @override
  State<ImagerHomePage> createState() => _ImagerHomePageState();
}

class _ImagerHomePageState extends State<ImagerHomePage> {
  static const MethodChannel _channel = MethodChannel(
    'luban_imager/native_images',
  );

  ImageJob? _job;
  var _previewMode = PreviewMode.original;
  var _compareFraction = 0.5;
  var _isPicking = false;
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleNativeCall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _takeSharedImages();
    });
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _removeToast();
    super.dispose();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'sharedImages':
        await _handleNativeImages(call.arguments);
        return null;
      default:
        throw MissingPluginException('No handler for ${call.method}');
    }
  }

  Future<void> _takeSharedImages() async {
    try {
      final response = await _channel.invokeMethod<List<dynamic>>(
        'takeSharedImages',
      );
      await _handleNativeImages(response);
    } on MissingPluginException {
      // Widget tests and unsupported platforms do not provide the native bridge.
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '读取分享图片失败');
    }
  }

  Future<void> _handleNativeImages(Object? response) async {
    final images = response is List<dynamic> ? response : const [];
    if (!mounted || images.isEmpty) {
      return;
    }

    final first = images.first;
    if (first is! Map) {
      return;
    }

    await _startImageJob(
      NativeImage.fromMap(Map<dynamic, dynamic>.from(first)),
      message: '已接收分享图片，正在压缩',
    );
  }

  Future<void> _startImageJob(NativeImage image, {String? message}) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _job = ImageJob(image);
      _previewMode = PreviewMode.original;
      _compareFraction = 0.5;
    });
    if (message != null) {
      _showMessage(message);
    }
    await _compressSelected();
  }

  Future<void> _pickImages() async {
    if (_isPicking) {
      return;
    }

    NativeImage? picked;
    setState(() {
      _isPicking = true;
    });

    try {
      final response = await _channel.invokeMethod<List<dynamic>>('pickImages');
      final images = response ?? [];

      if (!mounted || images.isEmpty) {
        return;
      }

      picked = NativeImage.fromMap(
        Map<dynamic, dynamic>.from(images.first as Map),
      );
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '选择图片失败');
    } finally {
      if (mounted) {
        setState(() {
          _isPicking = false;
        });
      }
    }

    if (picked != null && mounted) {
      await _startImageJob(picked);
    }
  }

  Future<void> _compressSelected() async {
    final job = _job;
    if (job == null) {
      return;
    }
    if (job.isCompressing) {
      return;
    }

    setState(() {
      job
        ..isCompressing = true
        ..error = null;
    });

    try {
      final response = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('compressImage', {
            'sourceHandle': job.original.sourceHandle,
            'displayName': job.original.displayName,
            'previewPath': job.original.previewPath,
            'originalSize': job.original.originalSize,
            'originalWidth': job.original.width,
            'originalHeight': job.original.height,
          });
      if (response == null) {
        throw const FormatException('native compressor returned no data');
      }
      final compressed = CompressedImage.fromMap(response);

      if (!mounted) {
        return;
      }
      setState(() {
        job
          ..compressed = compressed
          ..isCompressing = false
          ..overwritten = false;
        _previewMode = PreviewMode.compare;
      });
      _showMessage(
        compressed.passthrough
            ? '压缩后比原图更大，已使用原图'
            : '压缩完成，节省 ${_savingLabel(job)}',
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        job
          ..isCompressing = false
          ..error = _errorText(error);
      });
      _showMessage(job.error ?? '压缩失败');
    }
  }

  Future<void> _saveSelected() async {
    final job = _job;
    final compressed = job?.compressed;
    if (job == null || compressed == null) {
      return;
    }

    try {
      await _channel.invokeMethod<Map<dynamic, dynamic>>('saveToGallery', {
        'compressedPath': compressed.path,
        'suggestedName': _suggestedName(job.original.displayName),
      });
      _showMessage('已保存到相册');
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '保存失败');
    }
  }

  Future<void> _shareSelected() async {
    await _openShareSheet();
  }

  Future<void> _openShareSheet() async {
    final job = _job;
    final compressed = job?.compressed;
    if (job == null || compressed == null) {
      return;
    }

    try {
      await _channel.invokeMethod<Map<dynamic, dynamic>>('shareImage', {
        'compressedPath': compressed.path,
        'suggestedName': _suggestedName(job.original.displayName),
      });
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '分享失败');
    }
  }

  Future<void> _overwriteSelected() async {
    final job = _job;
    final compressed = job?.compressed;
    if (job == null || compressed == null) {
      return;
    }
    if (!job.original.canOverwrite) {
      _showMessage('当前来源不支持原位覆盖，请使用保存');
      return;
    }

    final confirmed = await _confirmOverwrite(job.original.displayName);
    if (!confirmed || !mounted) {
      return;
    }

    try {
      await _channel.invokeMethod<Map<dynamic, dynamic>>('overwriteOriginal', {
        'sourceHandle': job.original.sourceHandle,
        'compressedPath': compressed.path,
      });
      if (!mounted) {
        return;
      }
      setState(() {
        job.overwritten = true;
      });
      _showMessage('已覆盖');
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '覆盖失败');
    }
  }

  Future<bool> _confirmOverwrite(String name) async {
    final first = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('覆盖'),
        content: Text('将用压缩后的图片替换「$name」，此操作无法从 App 内撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (first != true || !mounted) {
      return false;
    }

    final second = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('再次确认'),
        content: const Text('确认覆盖？建议先保存备份。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
    return second == true;
  }

  void _clearImage() {
    setState(() {
      _job = null;
      _previewMode = PreviewMode.original;
      _compareFraction = 0.5;
    });
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    _removeToast();

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      return;
    }

    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: colorScheme.onInverseSurface,
      fontWeight: FontWeight.w700,
    );

    _toastEntry = OverlayEntry(
      builder: (context) {
        final top = MediaQuery.of(context).padding.top + kToolbarHeight + 8;
        return Positioned(
          left: 16,
          right: 16,
          top: top,
          child: IgnorePointer(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Material(
                  color: colorScheme.inverseSurface,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: textStyle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_toastEntry!);
    _toastTimer = Timer(const Duration(seconds: 1), () {
      _toastEntry?.remove();
      _toastEntry = null;
      _toastTimer = null;
    });
  }

  void _removeToast() {
    _toastTimer?.cancel();
    _toastTimer = null;
    _toastEntry?.remove();
    _toastEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appName),
        actions: job == null
            ? null
            : [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TextButton.icon(
                    onPressed: _isPicking ? null : _pickImages,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('重新选择'),
                  ),
                ),
              ],
      ),
      body: SafeArea(
        child: job == null ? _buildEmptyState() : _buildPreviewPanel(job),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.image_search_outlined,
              size: 72,
              color: Color(0xFF5D6F70),
            ),
            const SizedBox(height: 20),
            Text(
              '选择图片开始压缩',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isPicking ? null : _pickImages,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('选择图片'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewPanel(ImageJob job) {
    final compressed = job.compressed;
    final canCompare = compressed != null;
    final mode = canCompare ? _previewMode : PreviewMode.original;

    return LayoutBuilder(
      builder: (context, constraints) {
        final showCompareSlider = mode == PreviewMode.compare && canCompare;
        final showWarning = compressed?.passthrough == true;
        const minPreviewHeight = 200.0;
        const baseChromeHeight = 360.0;
        const compareSliderHeight = 52.0;
        const warningHeight = 58.0;
        // Keep the panel fixed-height while the preview can stay at least 200px.
        final chromeHeight =
            baseChromeHeight +
            (showWarning ? warningHeight : 0.0) -
            (showCompareSlider ? 0.0 : compareSliderHeight);
        final availablePreviewHeight = constraints.maxHeight - chromeHeight;
        final previewHeight = math.max(
          minPreviewHeight,
          availablePreviewHeight,
        );

        List<Widget> buildContent() {
          return [
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      job.original.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '移除',
                    visualDensity: VisualDensity.compact,
                    onPressed: _clearImage,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _MetricBlock(
                    label: '原图',
                    value: _formatSize(job.original.originalSize),
                    detail: '${job.original.width}×${job.original.height}',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MetricBlock(
                    label: '压缩后',
                    value: compressed == null
                        ? '--'
                        : _formatSize(compressed.outputSize),
                    detail: compressed == null
                        ? '--'
                        : '${compressed.width}×${compressed.height}',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MetricBlock(
                    label: '节省',
                    value: compressed == null ? '--' : _savingLabel(job),
                    detail: compressed?.passthrough == true ? '压缩后更大' : '',
                  ),
                ),
              ],
            ),
            if (showWarning) ...[
              const SizedBox(height: 10),
              const _WarningStrip(message: '压缩结果比原图更大，已自动使用原图。'),
            ],
            const SizedBox(height: 14),
            SegmentedButton<PreviewMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: PreviewMode.original,
                  icon: Icon(Icons.image_outlined),
                  label: Text('原图'),
                ),
                ButtonSegment(
                  value: PreviewMode.compressed,
                  icon: Icon(Icons.photo_size_select_large_outlined),
                  label: Text('压缩'),
                ),
                ButtonSegment(
                  value: PreviewMode.compare,
                  icon: Icon(Icons.compare_outlined),
                  label: Text('对比'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: canCompare
                  ? (selection) {
                      setState(() {
                        _previewMode = selection.first;
                      });
                    }
                  : null,
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: previewHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFEDEFEA),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFDADFD8)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: _buildImagePreview(job, mode),
                ),
              ),
            ),
            if (showCompareSlider) ...[
              const SizedBox(height: 4),
              Slider(
                value: _compareFraction,
                min: 0.05,
                max: 0.95,
                onChanged: (value) {
                  setState(() {
                    _compareFraction = value;
                  });
                },
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: compressed == null || job.isCompressing
                      ? null
                      : _saveSelected,
                  icon: const Icon(Icons.save_alt_outlined),
                  label: const Text('保存'),
                ),
                FilledButton.tonalIcon(
                  onPressed: compressed == null || job.isCompressing
                      ? null
                      : _shareSelected,
                  icon: const Icon(Icons.ios_share_outlined),
                  label: const Text('分享'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: compressed == null ? null : _overwriteSelected,
                  icon: const Icon(Icons.warning_amber_rounded),
                  label: const Text('覆盖'),
                ),
              ],
            ),
          ];
        }

        final child = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: buildContent(),
        );
        if (availablePreviewHeight >= minPreviewHeight) {
          return Padding(padding: const EdgeInsets.all(16), child: child);
        }

        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildImagePreview(ImageJob job, PreviewMode mode) {
    final compressedPath = job.compressed?.path;
    if (mode == PreviewMode.compressed && compressedPath != null) {
      return _ZoomablePreview(
        width: job.compressed?.width ?? job.original.width,
        height: job.compressed?.height ?? job.original.height,
        child: _PreviewImage(path: compressedPath),
      );
    }
    if (mode == PreviewMode.compare && compressedPath != null) {
      return _ZoomablePreview(
        width: job.original.width,
        height: job.original.height,
        overlay: const Stack(
          children: [
            Positioned(left: 12, top: 12, child: _PreviewBadge(label: '原图')),
            Positioned(right: 12, top: 12, child: _PreviewBadge(label: '压缩')),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              fit: StackFit.expand,
              children: [
                _PreviewImage(path: compressedPath),
                ClipRect(
                  clipper: _CompareClipper(_compareFraction),
                  child: _PreviewImage(path: job.original.previewPath),
                ),
                Positioned(
                  left: constraints.maxWidth * _compareFraction - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: Colors.white),
                ),
              ],
            );
          },
        ),
      );
    }
    return _ZoomablePreview(
      width: job.original.width,
      height: job.original.height,
      child: _PreviewImage(path: job.original.previewPath),
    );
  }

  String _savingLabel(ImageJob job) {
    final compressed = job.compressed;
    if (compressed == null || job.original.originalSize <= 0) {
      return '--';
    }
    if (compressed.passthrough) {
      return '使用原图';
    }
    final saved = job.original.originalSize - compressed.outputSize;
    if (saved <= 0) {
      return '0%';
    }
    return '${(saved / job.original.originalSize * 100).toStringAsFixed(1)}%';
  }

  String _suggestedName(String originalName) {
    final dot = originalName.lastIndexOf('.');
    if (dot <= 0) {
      return '${originalName}_luban.jpg';
    }
    return '${originalName.substring(0, dot)}_luban${originalName.substring(dot)}';
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  String _errorText(Object error) {
    if (error is PlatformException) {
      return error.message ?? error.code;
    }
    return error.toString();
  }
}

enum PreviewMode { original, compressed, compare }

class NativeImage {
  NativeImage({
    required this.sourceHandle,
    required this.displayName,
    required this.previewPath,
    required this.originalSize,
    required this.width,
    required this.height,
    required this.canOverwrite,
  });

  factory NativeImage.fromMap(Map<dynamic, dynamic> map) {
    return NativeImage(
      sourceHandle: map['sourceHandle'] as String,
      displayName: map['displayName'] as String? ?? 'image',
      previewPath: map['previewPath'] as String,
      originalSize: (map['originalSize'] as num?)?.toInt() ?? 0,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      canOverwrite: map['canOverwrite'] as bool? ?? false,
    );
  }

  final String sourceHandle;
  final String displayName;
  final String previewPath;
  final int originalSize;
  final int width;
  final int height;
  final bool canOverwrite;
}

class CompressedImage {
  CompressedImage({
    required this.path,
    required this.outputSize,
    required this.width,
    required this.height,
    required this.passthrough,
  });

  factory CompressedImage.fromMap(Map<dynamic, dynamic> map) {
    return CompressedImage(
      path: map['path'] as String,
      outputSize: (map['outputSize'] as num?)?.toInt() ?? 0,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      passthrough: map['passthrough'] as bool? ?? false,
    );
  }

  final String path;
  final int outputSize;
  final int width;
  final int height;
  final bool passthrough;
}

class ImageJob {
  ImageJob(this.original);

  final NativeImage original;
  CompressedImage? compressed;
  bool isCompressing = false;
  bool overwritten = false;
  String? error;
}

class _WarningStrip extends StatelessWidget {
  const _WarningStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDADFD8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: const Color(0xFF5D6F70)),
          ),
          const SizedBox(height: 7),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ZoomablePreview extends StatefulWidget {
  const _ZoomablePreview({
    required this.width,
    required this.height,
    required this.child,
    this.overlay,
  });

  final int width;
  final int height;
  final Widget child;
  final Widget? overlay;

  @override
  State<_ZoomablePreview> createState() => _ZoomablePreviewState();
}

class _ZoomablePreviewState extends State<_ZoomablePreview> {
  static const _minScale = 1.0;
  static const _maxScale = 8.0;

  Size _viewportSize = Size.zero;
  Size _canvasSize = Size.zero;
  var _scale = _minScale;
  var _offset = Offset.zero;
  var _gestureStartScale = _minScale;
  var _gestureStartOffset = Offset.zero;
  var _gestureStartScenePoint = Offset.zero;

  @override
  void didUpdateWidget(covariant _ZoomablePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.width != widget.width || oldWidget.height != widget.height) {
      _resetTransform();
    }
  }

  void _resetTransform() {
    _scale = _minScale;
    _offset = Offset.zero;
  }

  double _clampScale(double scale) {
    return scale.clamp(_minScale, _maxScale).toDouble();
  }

  Offset _clampOffset(Offset offset, double scale) {
    final maxX = math.max(
      0.0,
      (_canvasSize.width * scale - _viewportSize.width) / 2,
    );
    final maxY = math.max(
      0.0,
      (_canvasSize.height * scale - _viewportSize.height) / 2,
    );

    return Offset(
      maxX == 0 ? 0 : offset.dx.clamp(-maxX, maxX).toDouble(),
      maxY == 0 ? 0 : offset.dy.clamp(-maxY, maxY).toDouble(),
    );
  }

  void _startGesture(ScaleStartDetails details) {
    _gestureStartScale = _scale;
    _gestureStartOffset = _offset;
    final center = _viewportSize.center(Offset.zero);
    _gestureStartScenePoint =
        (details.localFocalPoint - center - _gestureStartOffset) / _scale;
  }

  void _updateGesture(ScaleUpdateDetails details) {
    final nextScale = _clampScale(_gestureStartScale * details.scale);
    final center = _viewportSize.center(Offset.zero);
    final nextOffset =
        details.localFocalPoint - center - _gestureStartScenePoint * nextScale;

    setState(() {
      _scale = nextScale;
      _offset = _clampOffset(nextOffset, nextScale);
    });
  }

  void _endGesture(ScaleEndDetails details) {
    setState(() {
      _scale = _clampScale(_scale);
      _offset = _clampOffset(_offset, _scale);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);

        final imageWidth = math.max(1, widget.width).toDouble();
        final imageHeight = math.max(1, widget.height).toDouble();
        final aspectRatio = imageWidth / imageHeight;
        var canvasWidth = constraints.maxWidth;
        var canvasHeight = canvasWidth / aspectRatio;

        if (canvasHeight > constraints.maxHeight) {
          canvasHeight = constraints.maxHeight;
          canvasWidth = canvasHeight * aspectRatio;
        }
        _canvasSize = Size(canvasWidth, canvasHeight);
        _scale = _clampScale(_scale);
        _offset = _clampOffset(_offset, _scale);

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _startGesture,
                onScaleUpdate: _updateGesture,
                onScaleEnd: _endGesture,
                child: SizedBox.expand(
                  child: Center(
                    child: Transform.translate(
                      offset: _offset,
                      child: Transform.scale(
                        scale: _scale,
                        child: SizedBox(
                          width: canvasWidth,
                          height: canvasHeight,
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.overlay != null)
                Positioned.fill(child: IgnorePointer(child: widget.overlay)),
            ],
          ),
        );
      },
    );
  }
}

class _PreviewImage extends StatelessWidget {
  const _PreviewImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Image.file(
      File(path),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        return const Center(child: Icon(Icons.broken_image_outlined, size: 48));
      },
    );
  }
}

class _PreviewBadge extends StatelessWidget {
  const _PreviewBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CompareClipper extends CustomClipper<Rect> {
  const _CompareClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * fraction, size.height);
  }

  @override
  bool shouldReclip(_CompareClipper oldClipper) {
    return oldClipper.fraction != fraction;
  }
}
