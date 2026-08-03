import 'package:flutter/material.dart';
import '../theme/jelly_theme.dart';

/// 果冻风格胶囊搜索框（固定在顶部，胶囊形状）
class JellySearchBar extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final Function(String)? onSubmitted;
  final Function(String)? onChanged;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onFocusChange;
  final VoidCallback? onCleared;
  final bool autofocus;

  const JellySearchBar({
    super.key,
    required this.controller,
    this.hintText = '搜索漫画',
    this.onSubmitted,
    this.onChanged,
    this.onTap,
    this.onFocusChange,
    this.onCleared,
    this.autofocus = false,
  });

  @override
  State<JellySearchBar> createState() => _JellySearchBarState();
}

class _JellySearchBarState extends State<JellySearchBar> {
  bool _isFocused = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (mounted) setState(() => _isFocused = _focusNode.hasFocus);
      widget.onFocusChange?.call(_focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hintColor = isDark ? Colors.white38 : const Color(0xFF9CA3AF);

    // 外层间距由调用方控制，便于与其他控件（如视图切换）并排
    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D4A) : Colors.white,
        borderRadius: BorderRadius.circular(25), // 胶囊形状（半径=高度的一半）
        boxShadow: [
          BoxShadow(
            color: isDark
                ? JellyTheme.primary.withValues(alpha: 0.15)
                : Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onTap: () => widget.onTap?.call(),
        onSubmitted: (value) => widget.onSubmitted?.call(value),
        onChanged: widget.onChanged,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
          fontSize: 15,
          height: 1.0,
          color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
        ),
        decoration: InputDecoration(
          // 关闭主题默认的灰色填充，让输入框透明白底胶囊
          filled: false,
          hintText: widget.hintText,
          hintStyle: TextStyle(fontSize: 15, color: hintColor),
          prefixIcon: Icon(
            Icons.search_rounded,
            color: _isFocused ? JellyTheme.navSelectedFg : hintColor,
            size: 22,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 44,
            minHeight: 44,
          ),
          suffixIcon: widget.controller.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear_rounded, color: hintColor, size: 18),
                  onPressed: () {
                    widget.controller.clear();
                    widget.onChanged?.call('');
                    widget.onCleared?.call();
                    _focusNode.unfocus();
                  },
                )
              : null,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
        ),
      ),
    );
  }
}
