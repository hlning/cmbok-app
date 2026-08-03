import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/book_content.dart';
import '../services/book_download_service.dart';
import '../services/book_paginator.dart';
import '../services/book_parser.dart';
import '../services/book_reading_progress_service.dart';
import '../services/platform_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/book_page_curl.dart';

/// 图书阅读页：EPUB / TXT app 内阅读，其余格式由 [open] 路由到外部应用。
/// 固定 TextPainter 度量分页翻页（不再支持连续滚动，不受阅读模式设置控制）。
class BookReaderPage extends StatefulWidget {
  final BookDownloadTask task;

  const BookReaderPage({super.key, required this.task});

  /// 统一入口：epub/txt 进阅读器，其余格式调系统外部应用打开。
  static Future<void> open(BuildContext context, BookDownloadTask task) async {
    final ext = (task.extension ?? 'epub').toLowerCase();
    if (ext == 'epub' || ext == 'txt') {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookReaderPage(task: task)),
      );
      return;
    }
    if (task.localPath == null || !await File(task.localPath!).exists()) {
      if (!context.mounted) return;
      _toast(context, '文件不存在，请重新下载');
      return;
    }
    final ok = await PlatformService.openFile(task.localPath!, _mimeOf(ext));
    if (!ok) {
      if (!context.mounted) return;
      _toast(context, '未找到可打开此格式的应用');
    }
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  static String _mimeOf(String ext) {
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'mobi':
      case 'azw':
      case 'azw3':
        return 'application/x-mobipocket-ebook';
      case 'cbz':
        return 'application/vnd.comicbook+zip';
      case 'cbr':
        return 'application/vnd.comicbook-rar';
      case 'fb2':
        return 'application/x-fictionbook+xml';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'rtf':
        return 'application/rtf';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

class _BookReaderPageState extends State<BookReaderPage> {
  BookContent? _content;
  bool _loading = true;
  String? _error;

  bool _showControls = false;

  // 单击翻页判定：记录按下位置与时间，区分单击 / 长按选字 / 拖动翻页
  Offset? _tapDownPos;
  DateTime? _tapDownTime;

  // 排版参数（与 SettingsService 同步）
  late BookTypography _typo;

  // 翻页模式
  final PageController _pageController = PageController();
  List<BookPage> _pages = const [];
  int _currentPage = 0;
  // 常驻 HUD（页码/进度）监听此 notifier，翻页时局部刷新，不重建 PageView
  final ValueNotifier<int> _currentPageNotifier = ValueNotifier(0);
  bool _paginating = false;
  int _paginateDone = 0;
  int _paginateTotal = 0;
  final Map<String, double> _imageRatios = {};
  String _paginateKey = '';

  List<BookBlock> get _blocks => _content?.flatBlocks ?? [];
  List<int> get _chapterStarts => _content?.chapterStarts ?? [];

  @override
  void initState() {
    super.initState();
    // 沉浸阅读：隐藏顶部状态栏（保留底部导航栏），正文填满顶部
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.bottom],
    );
    _typo = _typoFromSettings();
    SettingsService().addListener(_onSettingsChanged);
    _load();
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onSettingsChanged);
    _pageController.dispose();
    _currentPageNotifier.dispose();
    // 离开阅读器：恢复状态栏（App 默认 edge-to-edge）
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  BookTypography _typoFromSettings() {
    final s = SettingsService();
    return BookTypography(
      fontSize: s.bookFontSize,
      lineHeight: s.bookLineHeight,
      padding: s.bookHorizontalPadding,
      verticalPadding: s.bookVerticalPadding,
      fontFamily: s.bookFontFamilyName,
    );
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    final newTypo = _typoFromSettings();
    if (newTypo.fontSize != _typo.fontSize ||
        newTypo.lineHeight != _typo.lineHeight ||
        newTypo.padding != _typo.padding ||
        newTypo.verticalPadding != _typo.verticalPadding ||
        newTypo.fontFamily != _typo.fontFamily) {
      _typo = newTypo;
    }
    setState(() {});
    // 仿真切回翻页模式后 PageView 重建，需把控制器同步到当前页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (SettingsService().bookReadingMode == BookReadingMode.pageTurn &&
          _pageController.hasClients) {
        _pageController.jumpToPage(_currentPage);
      }
    });
  }

  Future<void> _load() async {
    final task = widget.task;
    final path = task.localPath;
    if (path == null || !await File(path).exists()) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = '文件不存在，请重新下载';
        });
      return;
    }
    try {
      final ext = (task.extension ?? 'epub').toLowerCase();
      final content = ext == 'txt'
          ? await BookParser.parseTxt(File(path))
          : await BookParser.parseEpub(File(path));
      if (!mounted) return;
      setState(() {
        _content = content;
        _loading = false;
      });
      // 预解码图片宽高比供分页度量用
      if (content.images.isNotEmpty) {
        await _decodeImageRatios(content);
      }
      _restoreProgress();
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = '$e';
        });
    }
  }

  Future<void> _decodeImageRatios(BookContent content) async {
    for (final entry in content.images.entries) {
      try {
        final img = await decodeImageFromList(entry.value);
        _imageRatios[entry.key] = img.height == 0
            ? 1.5
            : img.width / img.height;
      } catch (_) {
        // 解码失败按默认比例
      }
    }
  }

  void _restoreProgress() {
    // 翻页模式：续读位置在 _paginate 末尾按 preserveBlockIndex 跳转
  }

  /// 分页缓存键：视口尺寸 + 排版参数 + bookId。_buildPaged 与 _paginate 共用同一格式，
  /// 确保两者判等一致，避免字号变化后用过期分页渲染导致底部溢出。
  String _paginateKeyOf(double vpW, double vpH) =>
      '${vpW.toInt()}x${vpH.toInt()}:${_typo.fontSize}:${_typo.lineHeight}:${_typo.padding}:${_typo.verticalPadding}:${_typo.fontFamily}:${widget.task.bookId}';

  /// pageTurn 模式：按当前视口与排版参数分页（章间让出 UI 线程，显示进度）。
  /// [preserveBlockIndex] 为重排前所在 block，重排后跳到包含它的页。
  Future<void> _paginate({
    required double vpW,
    required double vpH,
    required int preserveBlockIndex,
  }) async {
    final content = _content;
    if (content == null || _paginating) return;
    final key = _paginateKeyOf(vpW, vpH);
    if (key == _paginateKey && _pages.isNotEmpty) return;
    _paginateKey = key;
    // 捕获本次分页所用排版参数，避免分页途中用户调参导致混合参数
    final typo = _typo;

    setState(() {
      _paginating = true;
      _paginateDone = 0;
      _paginateTotal = _chapterStarts.length;
    });

    final allBlocks = content.flatBlocks;
    final starts = content.chapterStarts;
    final pages = <BookPage>[];
    for (var ci = 0; ci < starts.length; ci++) {
      final start = starts[ci];
      final end = ci + 1 < starts.length ? starts[ci + 1] : allBlocks.length;
      final sub = allBlocks.sublist(start, end);
      final p = BookPaginator(
        blocks: sub,
        viewportWidth: vpW,
        viewportHeight: vpH,
        typo: typo,
        imageAspectRatios: _imageRatios,
      ).paginate();
      for (final page in p) {
        pages.add(
          BookPage(
            firstBlockIndex: page.firstBlockIndex + start,
            entries: page.entries,
          ),
        );
      }
      if (mounted) setState(() => _paginateDone = ci + 1);
      await Future.delayed(Duration.zero);
    }
    if (!mounted) return;
    final target = BookPaginator.pageIndexOf(
      pages,
      preserveBlockIndex.clamp(0, allBlocks.length - 1),
    );
    setState(() {
      _pages = pages;
      _paginating = false;
      _currentPage = target;
    });
    _currentPageNotifier.value = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(target);
      }
    });
  }

  void _onPointerDown(PointerDownEvent e) {
    _tapDownPos = e.position;
    _tapDownTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    // 控件栏显示时，点击交给控件层处理（按钮 / 中间空白关闭），不翻页
    if (_showControls) return;
    final pos = _tapDownPos;
    final t = _tapDownTime;
    _tapDownPos = null;
    _tapDownTime = null;
    if (pos == null || t == null) return;
    final dist = (e.position - pos).distance;
    final dt = DateTime.now().difference(t).inMilliseconds;
    // 长按选字（>350ms）或拖动翻页（位移大）交给下层，仅短按单击才翻页
    if (dist > 18 || dt > 350) return;
    final w = MediaQuery.sizeOf(context).width;
    final dx = e.position.dx;
    if (dx < w / 3) {
      _onTapLeft();
    } else if (dx > w * 2 / 3) {
      _onTapRight();
    } else {
      _toggleControls();
    }
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  void _onTapLeft() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onTapRight() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _goChapter(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= _chapterStarts.length) return;
    final blockIndex = _chapterStarts[chapterIndex];
    final page = BookPaginator.pageIndexOf(_pages, blockIndex);
    // 仿真模式无 PageView，_pageController 未挂载，直接切 _currentPage；
    // pageTurn 模式经 PageView 滚动（onPageChanged 会同步 _currentPage 与进度）。
    if (SettingsService().bookReadingMode == BookReadingMode.simulation) {
      _turnTo(page);
    } else if (_pageController.hasClients) {
      _pageController.jumpToPage(page);
    }
    setState(() => _showControls = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? JellyTheme.backgroundDark
        : JellyTheme.backgroundLight;
    final textColor = isDark
        ? Colors.white.withValues(alpha: 0.92)
        : JellyTheme.textPrimaryLight;
    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          _buildBody(isDark, textColor, bgColor),
          _buildHud(isDark),
          _buildControls(isDark, textColor),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark, Color textColor, Color bgColor) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: JellyTheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                '打开失败：$_error',
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor),
              ),
              const SizedBox(height: 16),
              if (widget.task.localPath != null)
                TextButton.icon(
                  onPressed: () async {
                    final ok = await PlatformService.openFile(
                      widget.task.localPath!,
                      BookReaderPage._mimeOf(
                        (widget.task.extension ?? 'epub').toLowerCase(),
                      ),
                    );
                    if (!ok && mounted) {
                      BookReaderPage._toast(context, '未找到可打开此格式的应用');
                    }
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('用其他应用打开'),
                ),
            ],
          ),
        ),
      );
    }
    if (_content == null || _blocks.isEmpty) {
      return Center(
        child: Text('暂无内容', style: TextStyle(color: textColor)),
      );
    }
    return _buildPaged(textColor, bgColor);
  }

  // ---------------- pageTurn 模式 ----------------

  Widget _buildPaged(Color textColor, Color bgColor) {
    return SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vpW = constraints.maxWidth;
          final vpH = constraints.maxHeight;
          // 仿真背景图需铺满全屏（含原状态栏区），故上下不交由 SafeArea，
          // 改为手动按安全区给文字留白；分页用扣掉安全区后的高度，与原一致。
          final safeTop = MediaQuery.paddingOf(context).top;
          final safeBottom = MediaQuery.paddingOf(context).bottom;
          final textVpH = vpH - safeTop - safeBottom;
          // 视口或排版参数变化 -> 重新分页（保留当前 block）
          final key = _paginateKeyOf(vpW, textVpH);
          final needRepaginate = key != _paginateKey;
          if (needRepaginate && !_paginating) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final preserve = _pages.isEmpty
                  ? (BookReadingProgressService()
                            .getProgress(widget.task.bookId)
                            ?.blockIndex ??
                        0)
                  : _pages[_currentPage.clamp(0, _pages.length - 1)]
                        .firstBlockIndex;
              _paginate(vpW: vpW, vpH: textVpH, preserveBlockIndex: preserve);
            });
          }
          // 待重排时旧分页已按旧字号度量，直接显示占位，避免用新字号渲染溢出底部
          if (_paginating || _pages.isEmpty || needRepaginate) {
            return _buildPaginatingView(textColor);
          }
          final contentWidth = vpW - _typo.padding * 2;
          return _buildReaderContent(
            textColor,
            contentWidth,
            safeTop,
            safeBottom,
          );
        },
      ),
    );
  }

  Widget _buildReaderContent(
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
  ) {
    if (SettingsService().bookReadingMode == BookReadingMode.simulation) {
      return _buildSimulation(textColor, contentWidth, safeTop, safeBottom);
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      child: PageView.builder(
        controller: _pageController,
        physics: const ClampingScrollPhysics(),
        itemCount: _pages.length,
        onPageChanged: (i) {
          _currentPage = i;
          _currentPageNotifier.value = i;
          BookReadingProgressService().recordBlock(
            widget.task.bookId,
            _pages[i].firstBlockIndex,
            i,
            _pages.length,
          );
        },
        itemBuilder: (context, index) =>
            _buildPageView(index, textColor, contentWidth, safeTop, safeBottom),
      ),
    );
  }

  Widget _buildSimulation(
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
  ) {
    return BookPageCurl(
      // 翻起页自带背景图底：栅格化出"背景图+文字"的不透明页，卷曲时文字附在
      // 背景图纸面上；nextPage/prevPage 保持透明，翻页时露出底层背景图。
      page: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/reader_backgroud.jpg',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
          _buildPageView(
            _currentPage,
            textColor,
            contentWidth,
            safeTop,
            safeBottom,
          ),
        ],
      ),
      nextPage: _currentPage < _pages.length - 1
          ? _buildPageView(
              _currentPage + 1,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
            )
          : null,
      prevPage: _currentPage > 0
          ? _buildPageView(
              _currentPage - 1,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
            )
          : null,
      background: Image.asset(
        'assets/images/reader_backgroud.jpg',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
      canNext: _currentPage < _pages.length - 1,
      canPrev: _currentPage > 0,
      onTurnNext: () => _turnTo(_currentPage + 1),
      onTurnPrev: () => _turnTo(_currentPage - 1),
      onTapCenter: _toggleControls,
    );
  }

  Widget _buildPageView(
    int index,
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
  ) {
    final entries = _pages[index].entries;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _typo.padding,
        safeTop + _typo.verticalPadding,
        _typo.padding,
        safeBottom + _typo.verticalPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            _buildEntry(entries[i], textColor, contentWidth),
            if (i < entries.length - 1) SizedBox(height: _typo.blockSpacing),
          ],
        ],
      ),
    );
  }

  void _turnTo(int index) {
    if (index < 0 || index >= _pages.length) return;
    setState(() => _currentPage = index);
    _currentPageNotifier.value = index;
    BookReadingProgressService().recordBlock(
      widget.task.bookId,
      _pages[index].firstBlockIndex,
      index,
      _pages.length,
    );
  }

  Widget _buildPaginatingView(Color textColor) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _paginateTotal > 0
                ? '排版中 $_paginateDone/$_paginateTotal 章'
                : '排版中...',
            style: TextStyle(color: textColor),
          ),
        ],
      ),
    );
  }

  // ---------------- 块渲染（两模式共用） ----------------

  Widget _buildEntry(PageEntry entry, Color textColor, double contentWidth) {
    final block = entry.block;
    if (block is ParagraphBlock) {
      final text = entry.partialText ?? block.text;
      return SelectableText(
        text,
        style: _typo.paragraphStyle().copyWith(color: textColor),
        strutStyle: _typo.paragraphStrut,
      );
    }
    if (block is HeadingBlock) {
      final text = entry.partialText ?? block.text;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          text,
          style: _typo.headingStyle(block.level).copyWith(color: textColor),
          strutStyle: _typo.headingStrut(block.level),
        ),
      );
    }
    if (block is ImageBlock) {
      final bytes = _content?.images[block.imageKey];
      if (bytes == null) return const SizedBox.shrink();
      return Image.memory(
        bytes,
        width: contentWidth,
        fit: BoxFit.fitWidth,
        gaplessPlayback: true,
      );
    }
    if (block is DividerBlock) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1),
      );
    }
    return const SizedBox.shrink();
  }

  // ---------------- 常驻 HUD（时间 / 页码 / 进度） ----------------

  Widget _buildHud(bool isDark) {
    final color = (isDark ? Colors.white : Colors.black).withValues(
      alpha: 0.45,
    );
    final style = TextStyle(fontSize: 11, color: color);
    final hPad = _typo.padding; // 左右边距
    final vPad = _typo.verticalPadding; // 上下边距
    // HUD 上下跟随垂直边距，并比正文留 20px 间距，避免压到首行/末行
    final top = MediaQuery.paddingOf(context).top + vPad - 20;
    final bottom = MediaQuery.paddingOf(context).bottom + vPad - 20;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: top,
            left: hPad,
            child: _ClockText(style: style),
          ),
          Positioned(
            top: top,
            right: hPad,
            child: ValueListenableBuilder<int>(
              valueListenable: _currentPageNotifier,
              builder: (_, p, _) {
                final total = _pages.length;
                return Text(total > 0 ? '${p + 1}/$total' : '', style: style);
              },
            ),
          ),
          Positioned(
            bottom: bottom,
            left: hPad,
            right: hPad,
            child: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _currentPageNotifier,
                    builder: (_, _, _) {
                      return Text(
                        _currentChapterTitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      );
                    },
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _currentPageNotifier,
                  builder: (_, p, _) {
                    final total = _pages.length;
                    if (total <= 0) return const SizedBox.shrink();
                    final pct = ((p + 1) / total * 100)
                        .clamp(0, 100)
                        .toStringAsFixed(0);
                    return Text('$pct%', style: style);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 控制层 ----------------

  Widget _buildControls(bool isDark, Color textColor) {
    final barColor = isDark
        ? Colors.black.withValues(alpha: 0.55)
        : Colors.white.withValues(alpha: 0.92);
    final iconColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Column(
          children: [
            // 顶部栏
            Container(
              color: barColor,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back_rounded, color: iconColor),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: iconColor,
                            ),
                          ),
                          if (_content != null)
                            Text(
                              _currentChapterTitle(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: iconColor),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: const SizedBox.expand(),
              ),
            ),
            // 底部栏
            Container(
              color: barColor,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: _chapterStarts.isNotEmpty
                              ? () => _goChapter(_currentChapterIndex() - 1)
                              : null,
                          icon: Icon(Icons.chevron_left, color: iconColor),
                          label: Text(
                            '上一章',
                            style: TextStyle(color: iconColor),
                          ),
                        ),
                        Text(
                          _indicatorText(),
                          style: TextStyle(fontSize: 12, color: iconColor),
                        ),
                        TextButton.icon(
                          onPressed: _chapterStarts.isNotEmpty
                              ? () => _goChapter(_currentChapterIndex() + 1)
                              : null,
                          icon: Icon(Icons.chevron_right, color: iconColor),
                          label: Text(
                            '下一章',
                            style: TextStyle(color: iconColor),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Expanded(child: SizedBox()),
                        TextButton.icon(
                          onPressed: _showTypoSheet,
                          icon: Icon(
                            Icons.text_fields_rounded,
                            color: iconColor,
                          ),
                          label: Text('排版', style: TextStyle(color: iconColor)),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _showToc,
                              icon: Icon(
                                Icons.menu_book_rounded,
                                color: iconColor,
                              ),
                              label: Text(
                                '目录',
                                style: TextStyle(color: iconColor),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _currentChapterIndex() {
    if (_pages.isEmpty) return 0;
    final idx = _currentPage.clamp(0, _pages.length - 1);
    return _chapterIndexForBlock(_pages[idx].firstBlockIndex);
  }

  int _chapterIndexForBlock(int blockIndex) {
    final starts = _chapterStarts;
    if (starts.isEmpty) return 0;
    var ans = 0;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] <= blockIndex) {
        ans = i;
      } else {
        break;
      }
    }
    return ans;
  }

  String _currentChapterTitle() {
    final ci = _currentChapterIndex();
    final chapters = _content?.chapters ?? const [];
    if (ci < chapters.length) return chapters[ci].title;
    return '';
  }

  String _indicatorText() {
    if (_pages.isEmpty) return '';
    return '${_currentPage + 1}/${_pages.length} 页';
  }

  // ---------------- 目录 ----------------

  void _showToc() {
    final chapters = _content?.chapters ?? const [];
    if (chapters.isEmpty) return;
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.75;
    final currentIndex = _currentChapterIndex();
    final itemScrollController = ItemScrollController();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '目录',
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim, secondaryAnim) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final textColor = isDark
            ? Colors.white.withValues(alpha: 0.92)
            : JellyTheme.textPrimaryLight;
        final subColor = isDark
            ? Colors.white.withValues(alpha: 0.5)
            : JellyTheme.textSecondary;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (itemScrollController.isAttached) {
            itemScrollController.jumpTo(index: currentIndex);
          }
        });
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: drawerWidth,
              height: double.infinity,
              decoration: BoxDecoration(
                color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 30,
                    offset: const Offset(-4, 0),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 8, 12),
                      child: Row(
                        children: [
                          const Text(
                            '目录',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: JellyTheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${chapters.length} 章',
                              style: TextStyle(
                                fontSize: 11,
                                color: JellyTheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: subColor,
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: subColor.withValues(alpha: 0.15)),
                    Expanded(
                      child: ScrollablePositionedList.builder(
                        itemScrollController: itemScrollController,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: chapters.length,
                        itemBuilder: (ctx, i) {
                          final cur = i == currentIndex;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                Navigator.pop(ctx);
                                _goChapter(i);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                                decoration: cur
                                    ? BoxDecoration(
                                        color: JellyTheme.primary.withValues(
                                          alpha: 0.1,
                                        ),
                                        border: Border(
                                          left: BorderSide(
                                            color: JellyTheme.primary,
                                            width: 3,
                                          ),
                                        ),
                                      )
                                    : null,
                                child: Text(
                                  chapters[i].title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: cur ? JellyTheme.primary : textColor,
                                    fontWeight: cur
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        final offset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
        return SlideTransition(position: offset, child: child);
      },
    );
  }

  // ---------------- 排版设置 ----------------

  void _showTypoSheet() {
    final s = SettingsService();
    // 草稿：滑块只改草稿，点「确认」才写入 SettingsService 触发重排
    double draftFontSize = s.bookFontSize;
    double draftLineHeight = s.bookLineHeight;
    double draftHPadding = s.bookHorizontalPadding;
    double draftVPadding = s.bookVerticalPadding;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _typoSlider(
                    label: '字号',
                    value: draftFontSize,
                    min: SettingsService.minBookFontSize,
                    max: SettingsService.maxBookFontSize,
                    divisions:
                        ((SettingsService.maxBookFontSize -
                                    SettingsService.minBookFontSize) *
                                2)
                            .round(),
                    display: draftFontSize.toStringAsFixed(0),
                    onChanged: (v) {
                      setSheet(() => draftFontSize = v);
                    },
                    isDark: isDark,
                  ),
                  _typoSlider(
                    label: '行距',
                    value: draftLineHeight,
                    min: SettingsService.minBookLineHeight,
                    max: SettingsService.maxBookLineHeight,
                    divisions:
                        ((SettingsService.maxBookLineHeight -
                                    SettingsService.minBookLineHeight) *
                                10)
                            .round(),
                    display: draftLineHeight.toStringAsFixed(1),
                    onChanged: (v) {
                      setSheet(() => draftLineHeight = v);
                    },
                    isDark: isDark,
                  ),
                  _typoSlider(
                    label: '左右边距',
                    value: draftHPadding,
                    min: SettingsService.minBookHorizontalPadding,
                    max: SettingsService.maxBookHorizontalPadding,
                    divisions:
                        (SettingsService.maxBookHorizontalPadding -
                                SettingsService.minBookHorizontalPadding)
                            .round(),
                    display: draftHPadding.toStringAsFixed(0),
                    onChanged: (v) {
                      setSheet(() => draftHPadding = v);
                    },
                    isDark: isDark,
                  ),
                  _typoSlider(
                    label: '上下边距',
                    value: draftVPadding,
                    min: SettingsService.minBookVerticalPadding,
                    max: SettingsService.maxBookVerticalPadding,
                    divisions:
                        (SettingsService.maxBookVerticalPadding -
                                SettingsService.minBookVerticalPadding)
                            .round(),
                    display: draftVPadding.toStringAsFixed(0),
                    onChanged: (v) {
                      setSheet(() => draftVPadding = v);
                    },
                    isDark: isDark,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () {
                          s.setBookFontSize(draftFontSize);
                          s.setBookLineHeight(draftLineHeight);
                          s.setBookHorizontalPadding(draftHPadding);
                          s.setBookVerticalPadding(draftVPadding);
                          Navigator.pop(ctx);
                        },
                        child: const Text('确认'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _typoSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              activeColor: JellyTheme.primary,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              display,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: JellyTheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 常驻 HUD 用的时间文本：每 30 秒检查一次，分钟变化才刷新自身。
class _ClockText extends StatefulWidget {
  final TextStyle style;
  const _ClockText({required this.style});

  @override
  State<_ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<_ClockText> {
  Timer? _timer;
  String _time = '';

  @override
  void initState() {
    super.initState();
    _update();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _update());
  }

  void _update() {
    final now = DateTime.now();
    final t =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    if (t != _time) setState(() => _time = t);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(_time, style: widget.style);
}
