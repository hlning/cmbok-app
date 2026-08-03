import 'package:flutter/material.dart';
import '../services/book_view_mode.dart';
import '../services/settings_service.dart';
import '../services/view_mode.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_segmented_toggle.dart';

/// 显示设置页：漫画/图书搜索页视图 + 启动默认首页。
/// 与搜索页右上角的视图切换共用 ViewMode / BookViewMode，二者同步并持久化。
class DisplaySettingsPage extends StatelessWidget {
  const DisplaySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('显示设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCard(
            isDark,
            title: '启动默认首页',
            subtitle: 'App 启动时直接进入的页面',
            trailing: ListenableBuilder(
              listenable: SettingsService(),
              builder: (context, _) => _buildHomeDropdown(isDark),
            ),
          ),
          const SizedBox(height: 12),
          _buildCard(
            isDark,
            title: '漫画搜索页视图',
            subtitle: '漫画搜索与漫画收藏页的卡片布局',
            trailing: ListenableBuilder(
              listenable: ViewMode(),
              builder: (context, _) => JellySegmentedToggle(
                index: ViewMode().isGrid ? 0.0 : 1.0,
                onChanged: (i) => ViewMode().set(i == 0),
                segments: const [
                  JellySegmentData(icon: Icons.grid_view_rounded),
                  JellySegmentData(icon: Icons.view_list_rounded),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildCard(
            isDark,
            title: '图书搜索页视图',
            subtitle: '图书搜索与图书收藏页的卡片布局',
            trailing: ListenableBuilder(
              listenable: BookViewMode(),
              builder: (context, _) => JellySegmentedToggle(
                index: BookViewMode().isGrid ? 0.0 : 1.0,
                onChanged: (i) => BookViewMode().set(i == 0),
                segments: const [
                  JellySegmentData(icon: Icons.grid_view_rounded),
                  JellySegmentData(icon: Icons.view_list_rounded),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 启动默认首页下拉选择（5 个 tab）
  Widget _buildHomeDropdown(bool isDark) {
    final s = SettingsService();
    const options = <(int, IconData, String)>[
      (0, Icons.palette_rounded, '漫画'),
      (1, Icons.book_rounded, '图书'),
      (2, Icons.favorite_rounded, '收藏'),
      (3, Icons.download_for_offline_rounded, '下载'),
      (4, Icons.person_rounded, '我的'),
    ];
    return DropdownButton<int>(
      value: s.defaultHomePage.index,
      underline: const SizedBox(),
      isDense: true,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
      ),
      dropdownColor: isDark ? JellyTheme.cardDark : Colors.white,
      items: options
          .map((o) => DropdownMenuItem(
                value: o.$1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(o.$2, size: 18, color: JellyTheme.primary),
                    const SizedBox(width: 6),
                    Text(o.$3),
                  ],
                ),
              ))
          .toList(),
      onChanged: (v) {
        if (v != null) {
          s.setDefaultHomePage(DefaultHomePage.values[v]);
        }
      },
    );
  }

  /// 通用设置卡片：左侧标题+副标题，右侧控件
  Widget _buildCard(
    bool isDark, {
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}
