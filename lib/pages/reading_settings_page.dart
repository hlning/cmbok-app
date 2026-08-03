import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_segmented_toggle.dart';

/// 阅读设置页：漫画阅读模式（翻页 / 拼页）
class ReadingSettingsPage extends StatelessWidget {
  const ReadingSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读设置')),
      body: ListenableBuilder(
        listenable: SettingsService(),
        builder: (context, _) {
          final s = SettingsService();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
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
                            '漫画阅读模式',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? Colors.white
                                  : JellyTheme.textPrimaryLight,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '翻页：左右翻页阅读\n拼页：上下连续滚动',
                            style: TextStyle(
                              fontSize: 12,
                              color: JellyTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    JellySegmentedToggle(
                      index: s.readingMode.index.toDouble(),
                      segments: const [
                        JellySegmentData(label: '翻页'),
                        JellySegmentData(label: '拼页'),
                      ],
                      segmentWidth: 56,
                      onChanged: (i) => s.setReadingMode(ReadingMode.values[i]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildBookReadingModeCard(isDark, s),
              const SizedBox(height: 12),
              _buildPreloadCard(isDark, s),
            ],
          );
        },
      ),
    );
  }

  /// 图书阅读模式卡片：翻页 / 仿真
  Widget _buildBookReadingModeCard(bool isDark, SettingsService s) {
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
                  '图书阅读模式',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '翻页：左右平移翻页\n仿真：纸张卷曲翻页',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          JellySegmentedToggle(
            index: s.bookReadingMode.index.toDouble(),
            segments: const [
              JellySegmentData(label: '翻页'),
              JellySegmentData(label: '仿真'),
            ],
            segmentWidth: 56,
            onChanged: (i) => s.setBookReadingMode(BookReadingMode.values[i]),
          ),
        ],
      ),
    );
  }

  /// 在线预加载图片数卡片：滑块选择 2~10（仿下载设置页滑块卡片样式）
  Widget _buildPreloadCard(bool isDark, SettingsService s) {
    final value = s.preloadImageCount;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '在线预加载图片',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$value',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: JellyTheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '在线阅读时预先加载后续图片，提升翻页流畅度（仅在线阅读生效）',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          Slider(
            value: value.toDouble(),
            min: SettingsService.minPreloadImages.toDouble(),
            max: SettingsService.maxPreloadImages.toDouble(),
            divisions:
                SettingsService.maxPreloadImages -
                SettingsService.minPreloadImages,
            activeColor: JellyTheme.primary,
            onChanged: (v) => s.setPreloadImageCount(v.round()),
          ),
          Row(
            children: [
              Text(
                '${SettingsService.minPreloadImages}',
                style: const TextStyle(
                  fontSize: 11,
                  color: JellyTheme.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${SettingsService.maxPreloadImages}',
                style: const TextStyle(
                  fontSize: 11,
                  color: JellyTheme.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
