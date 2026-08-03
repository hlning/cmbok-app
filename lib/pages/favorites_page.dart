import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/book.dart';
import '../models/comic.dart';
import '../services/book_favorites_service.dart';
import '../services/book_view_mode.dart';
import '../services/favorites_service.dart';
import '../services/view_mode.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_book_card.dart';
import '../widgets/jelly_comic_card.dart';
import '../widgets/jelly_comic_list_tile.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/staggered_entrance.dart';
import 'book_detail_page.dart';
import 'comic_detail_page.dart';

/// 收藏页面（顶部 Tab：漫画收藏 / 图书收藏）
class FavoritesPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发收藏卡片入场动画）
  final bool isActive;

  const FavoritesPage({super.key, this.isActive = false});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with TickerProviderStateMixin {
  late TabController _tabController;

  // 搜索浮层
  bool _searchVisible = false;
  late final AnimationController _searchAnim;
  final TextEditingController _favSearchController = TextEditingController();
  String _favQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _searchAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchAnim.dispose();
    _favSearchController.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searchVisible = true);
    _searchAnim.forward();
  }

  void _closeSearch() {
    _searchAnim.reverse().then((_) {
      if (mounted) {
        _favSearchController.clear();
        setState(() {
          _searchVisible = false;
          _favQuery = '';
        });
      }
    });
  }

  void _openDetail(Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ComicDetailPage(comic: comic)),
    );
  }

  String _formatPopular(int popular) {
    if (popular >= 10000) return '${(popular / 10000).toStringAsFixed(1)}万';
    return popular.toString();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // tab 总宽 = 屏幕一半：段宽*2 + 左右各5内边距 = 屏幕宽/2
    final tabSegWidth = (MediaQuery.of(context).size.width * 0.5 - 10) / 2;
    return Scaffold(
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 105,
                  child: Stack(
                    children: [
                      // 标题：左上角，间距小
                      Positioned(
                        top: 6,
                        left: 16,
                        child: Text(
                          '收藏',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? Colors.white
                                : JellyTheme.textPrimaryLight,
                          ),
                        ),
                      ),
                      // 控件组：水平居中，间距大（往下错开，层次感）
                      Positioned(
                        top: 45,
                        left: 12,
                        right: 12,
                        child: Row(
                          children: [
                            const Spacer(),
                            AnimatedBuilder(
                              animation: _tabController.animation!,
                              builder: (context, _) => JellySegmentedToggle(
                                index: _tabController.animation!.value,
                                onChanged: (i) => _tabController.animateTo(i),
                                segmentWidth: tabSegWidth,
                                segments: const [
                                  JellySegmentData(icon: Icons.palette_rounded),
                                  JellySegmentData(icon: Icons.book_rounded),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Material(
                              color: JellyTheme.primary,
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: _openSearch,
                                child: const SizedBox(
                                  width: 50,
                                  height: 50,
                                  child: Icon(
                                    Icons.search_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _ComicFavoritesTab(isActive: widget.isActive),
                    const _BookFavoritesTab(),
                  ],
                ),
              ),
            ],
          ),
          if (_searchVisible) _buildSearchOverlay(),
        ],
      ),
    );
  }

  /// 搜索浮层：高斯模糊蒙版 + 居中搜索框/结果（带出场动画）
  Widget _buildSearchOverlay() {
    return Positioned.fill(
      child: Stack(
        children: [
          // 高斯模糊蒙版（点击关闭）
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeSearch,
              behavior: HitTestBehavior.opaque,
              child: FadeTransition(
                opacity: _searchAnim,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(color: Colors.black.withValues(alpha: 0.2)),
                ),
              ),
            ),
          ),
          // 居中搜索框 + 结果（缩放淡入）
          Center(
            child: FadeTransition(
              opacity: _searchAnim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                  CurvedAnimation(
                    parent: _searchAnim,
                    curve: Curves.easeOutBack,
                  ),
                ),
                child: _buildSearchContent(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchContent() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final q = _favQuery.trim().toLowerCase();
    final comics = FavoritesService().comics
        .where(
          (c) =>
              q.isEmpty ||
              c.title.toLowerCase().contains(q) ||
              (c.alias?.toLowerCase().contains(q) ?? false) ||
              (c.author?.toLowerCase().contains(q) ?? false),
        )
        .toList();
    final books = BookFavoritesService().books
        .where(
          (b) =>
              q.isEmpty ||
              b.title.toLowerCase().contains(q) ||
              (b.author?.toLowerCase().contains(q) ?? false),
        )
        .toList();
    // 交错合并漫画/图书，使两者都有机会展示；再限制前 10 条
    final all = <dynamic>[];
    var ci = 0, bi = 0;
    while (ci < comics.length || bi < books.length) {
      if (ci < comics.length) {
        all.add(comics[ci]);
        ci++;
      }
      if (bi < books.length) {
        all.add(books[bi]);
        bi++;
      }
    }
    const maxResults = 10;
    final limited = all.take(maxResults).toList();
    final hasMore = all.length > maxResults;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          JellySearchBar(
            controller: _favSearchController,
            hintText: '搜索收藏',
            autofocus: true,
            onChanged: (v) => setState(() => _favQuery = v),
            onCleared: () => setState(() => _favQuery = ''),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.4,
            child: Material(
              color: isDark ? const Color(0xFF252542) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: all.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '无匹配结果',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: limited.length + (hasMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == limited.length) {
                          return Padding(
                            padding: const EdgeInsets.all(12),
                            child: Center(
                              child: Text(
                                '仅显示前 $maxResults 条，共 ${all.length} 条',
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          );
                        }
                        final item = limited[index];
                        if (item is Comic) return _buildComicResultTile(item);
                        return _buildBookResultTile(item as Book);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComicResultTile(Comic comic) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CachedNetworkImage(
          imageUrl: comic.cover,
          width: 40,
          height: 56,
          fit: BoxFit.cover,
          placeholder: (c, u) =>
              Container(color: Colors.grey[300], width: 40, height: 56),
          errorWidget: (c, u, e) => Container(
            color: Colors.grey[300],
            width: 40,
            height: 56,
            child: const Icon(Icons.broken_image, size: 20, color: Colors.grey),
          ),
        ),
      ),
      title: Text(comic.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          comic.author,
          comic.alias,
          if (comic.popular != null && comic.popular! > 0)
            '🔥${_formatPopular(comic.popular!)}',
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Icon(
        Icons.palette_rounded,
        size: 18,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
      onTap: () {
        _closeSearch();
        _openDetail(comic);
      },
    );
  }

  Widget _buildBookResultTile(Book book) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: (book.cover ?? '').isEmpty
            ? Container(
                color: Colors.grey[300],
                width: 40,
                height: 56,
                child: const Icon(
                  Icons.menu_book_rounded,
                  size: 20,
                  color: Colors.grey,
                ),
              )
            : CachedNetworkImage(
                imageUrl: book.cover!,
                width: 40,
                height: 56,
                fit: BoxFit.cover,
                placeholder: (c, u) =>
                    Container(color: Colors.grey[300], width: 40, height: 56),
                errorWidget: (c, u, e) => Container(
                  color: Colors.grey[300],
                  width: 40,
                  height: 56,
                  child: const Icon(
                    Icons.broken_image,
                    size: 20,
                    color: Colors.grey,
                  ),
                ),
              ),
      ),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          book.author,
          book.extension?.toUpperCase(),
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Icon(
        Icons.book_rounded,
        size: 18,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
      onTap: () {
        _closeSearch();
        _openBookDetail(book);
      },
    );
  }

  /// 打开图书详情（不传搜索结果 -> 详情页以作者搜索推荐）
  void _openBookDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(book: book)),
    );
  }
}

/// 漫画收藏（跟随搜索页视图模式，列数自适应 + 置顶按钮）
class _ComicFavoritesTab extends StatefulWidget {
  final bool isActive;

  const _ComicFavoritesTab({this.isActive = false});

  @override
  State<_ComicFavoritesTab> createState() => _ComicFavoritesTabState();
}

class _ComicFavoritesTabState extends State<_ComicFavoritesTab> {
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  int _session = 0; // 首次切到收藏 tab 时 +1，触发卡片瀑布入场动画
  bool _hasShownEntrance = false; // 是否已播过首次入场动画

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _ComicFavoritesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅首次切到收藏 tab 时重播入场动画，之后切回不再触发（避免闪烁）
    if (widget.isActive && !oldWidget.isActive && !_hasShownEntrance) {
      _hasShownEntrance = true;
      setState(() => _session++);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final show = _scrollController.position.pixels > 300;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([FavoritesService(), ViewMode()]),
      builder: (context, _) {
        final comics = FavoritesService().comics;
        final isGrid = ViewMode().isGrid;
        if (comics.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.favorite_border_rounded,
                  size: 64,
                  color: Colors.grey,
                ),
                SizedBox(height: 16),
                Text('还没有收藏的漫画', style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }
        return Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final cols = _adaptiveCols(
                  constraints.maxWidth,
                  min: isGrid ? 2 : 1,
                  target: isGrid ? 170 : 360,
                  max: isGrid ? 6 : 4,
                );
                return MasonryGridView.count(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(
                    top: 4,
                    left: 20,
                    right: 20,
                    bottom: 12,
                  ),
                  crossAxisCount: cols,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  itemCount: comics.length,
                  itemBuilder: (context, index) {
                    final comic = comics[index];
                    return StaggeredEntrance(
                      key: ValueKey('${_session}_${comic.id}'),
                      index: index,
                      child: isGrid
                          ? JellyComicCard(
                              comic: comic,
                              heroTag: comicCoverHeroTag('fav', comic),
                              onTap: () => _openDetail(context, comic),
                            )
                          : JellyComicListTile(
                              comic: comic,
                              heroTag: comicCoverHeroTag('fav', comic),
                              onTap: () => _openDetail(context, comic),
                            ),
                    );
                  },
                );
              },
            ),
            // 置顶按钮
            if (_showBackToTop)
              Positioned(
                bottom: 16,
                right: 16,
                child: AnimatedScale(
                  scale: _showBackToTop ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: Material(
                    color: JellyTheme.primary,
                    shape: const CircleBorder(),
                    elevation: 4,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _scrollToTop,
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          Icons.arrow_upward_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static int _adaptiveCols(
    double width, {
    required int min,
    int max = 6,
    double target = 170,
  }) {
    final available = width - 40;
    var cols = (available / target).floor();
    if (cols < min) cols = min;
    if (cols > max) cols = max;
    return cols;
  }

  static void _openDetail(BuildContext context, Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('fav', comic),
        ),
      ),
    );
  }
}

/// 图书收藏（跟随搜索页视图模式，列数自适应 + 置顶按钮）
class _BookFavoritesTab extends StatefulWidget {
  const _BookFavoritesTab();

  @override
  State<_BookFavoritesTab> createState() => _BookFavoritesTabState();
}

class _BookFavoritesTabState extends State<_BookFavoritesTab> {
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final show = _scrollController.position.pixels > 300;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _openDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            BookDetailPage(book: book, heroTag: bookCoverHeroTag('fav', book)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([BookFavoritesService(), BookViewMode()]),
      builder: (context, _) {
        final books = BookFavoritesService().books;
        final isGrid = BookViewMode().isGrid;
        if (books.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.favorite_border_rounded,
                  size: 64,
                  color: Colors.grey,
                ),
                SizedBox(height: 16),
                Text('还没有收藏的图书', style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }
        return Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final cols = _adaptiveCols(
                  constraints.maxWidth,
                  min: isGrid ? 2 : 1,
                  target: isGrid ? 170 : 360,
                  max: isGrid ? 6 : 4,
                );
                return MasonryGridView.count(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(
                    top: 4,
                    left: 20,
                    right: 20,
                    bottom: 12,
                  ),
                  crossAxisCount: cols,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  itemCount: books.length,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    return StaggeredEntrance(
                      key: ValueKey('book_${book.id}'),
                      index: index,
                      child: JellyBookCard(
                        book: book,
                        isGrid: isGrid,
                        heroTag: bookCoverHeroTag('fav', book),
                        onTap: () => _openDetail(book),
                      ),
                    );
                  },
                );
              },
            ),
            if (_showBackToTop)
              Positioned(
                bottom: 16,
                right: 16,
                child: AnimatedScale(
                  scale: _showBackToTop ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: Material(
                    color: JellyTheme.primary,
                    shape: const CircleBorder(),
                    elevation: 4,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _scrollToTop,
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          Icons.arrow_upward_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static int _adaptiveCols(
    double width, {
    required int min,
    int max = 6,
    double target = 170,
  }) {
    final available = width - 40;
    var cols = (available / target).floor();
    if (cols < min) cols = min;
    if (cols > max) cols = max;
    return cols;
  }
}
