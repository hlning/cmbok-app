import 'package:flutter/material.dart';
import '../theme/jelly_theme.dart';

/// 果冻风格底部导航栏（非悬浮，果冻弹性指示器）
class JellyNavBar extends StatefulWidget {
  final int currentIndex;
  final Function(int) onTap;
  final List<JellyNavItem> items;

  const JellyNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  }) : assert(items.length >= 2 && items.length <= 5);

  @override
  State<JellyNavBar> createState() => _JellyNavBarState();
}

class _JellyNavBarState extends State<JellyNavBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  int _previousIndex = 0;

  // 果冻弹性曲线（直接 transform，避免在 build 中创建 CurvedAnimation 造成监听器泄漏）
  static const _curve = ElasticOutCurve(0.7);

  // 导航栏尺寸：整体加高，底部间距稍高于顶部，左右上角圆角
  static const _barHeight = 80.0; // 整体高度（原 64）
  static const _topPad = 14.0; // 顶部间距
  static const _bottomPad = 22.0; // 底部间距（> 顶部，内容整体偏上）
  static const _topRadius = 20.0; // 左、右上角圆角
  static const _pillPad = 8.0; // 指示器左右内边距

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 850), // 切换速度放慢（原 600）
      vsync: this,
    )..value = 1.0; // 初始处于静止态，指示器归位到当前项
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onItemTap(int index) {
    if (index != widget.currentIndex) {
      _previousIndex = widget.currentIndex;
      _controller.reset();
      _controller.forward();
      widget.onTap(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A2E) : Colors.white,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(_topRadius), // 左、右上角圆角
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _barHeight, // 整体高度加高
          child: Padding(
            // 底部间距稍高于顶部，内容整体偏上
            padding: const EdgeInsets.only(top: _topPad, bottom: _bottomPad),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = constraints.maxWidth / widget.items.length;
                final bandHeight = constraints.maxHeight;
                return Stack(
                  children: [
                    // 果冻背景指示器（弹性滑动 + 弹性缩放）
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        final progress = _curve.transform(_controller.value);
                        final left =
                            _previousIndex * itemWidth +
                            (widget.currentIndex - _previousIndex) *
                                itemWidth *
                                progress;
                        final scale = 0.88 + 0.12 * progress;
                        return Positioned(
                          top: 0,
                          left: left + _pillPad,
                          width: itemWidth - _pillPad * 2,
                          height: bandHeight,
                          child: Transform.scale(
                            scale: scale,
                            child: Container(
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF443EB1)
                                    : JellyTheme.navSelectedBg,
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    // 导航项（固定宽度，纵向拉伸保证点击区域）
                    Positioned.fill(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: List.generate(widget.items.length, (index) {
                          return SizedBox(
                            width: itemWidth,
                            child: _JellyNavItem(
                              item: widget.items[index],
                              isSelected: index == widget.currentIndex,
                              onTap: () => _onItemTap(index),
                            ),
                          );
                        }),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 果冻导航项组件
class _JellyNavItem extends StatelessWidget {
  final JellyNavItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _JellyNavItem({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  // 图标尺寸：选中/未选中一致
  static const _iconSize = 22.0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isSelected
        ? (isDark ? Colors.white : JellyTheme.navSelectedFg)
        : (isDark ? Colors.white54 : JellyTheme.navUnselected);

    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      // 图标在上、文字在下，始终显示
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            item.emoji != null
                ? Text(
                    item.emoji!,
                    style: const TextStyle(fontSize: 22, height: 1.0),
                  )
                : Icon(item.icon, color: color, size: _iconSize),
            const SizedBox(height: 2),
            Text(
              item.label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 导航项数据
class JellyNavItem {
  final IconData? icon;
  final String? emoji;
  final String label;

  const JellyNavItem({this.icon, this.emoji, required this.label})
    : assert(icon != null || emoji != null);
}
