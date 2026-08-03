import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[BookReadingProgress] $message');
  }
}

/// 单本图书的阅读进度
/// - blockIndex：续读 block 索引（在 BookContent.flatBlocks 中，从 0 起），
///   用于跨排版续读跳转（内容维度，不受字号/屏幕影响）。
/// - pageIndex/pageTotal：阅读百分比用（页维度，与阅读器 HUD 一致）。
class BookReadingProgress {
  /// 续读 block 索引（在 BookContent.flatBlocks 中，从 0 起）
  final int blockIndex;

  /// 续读页索引（阅读器 HUD 百分比用；旧数据为 0）
  final int pageIndex;

  /// 总页数（阅读器 HUD 百分比用；旧数据为 0，此时无法算百分比）
  final int pageTotal;

  /// 最近更新时间戳（ms）
  final int updatedAt;

  const BookReadingProgress({
    required this.blockIndex,
    this.pageIndex = 0,
    this.pageTotal = 0,
    required this.updatedAt,
  });

  factory BookReadingProgress.fromJson(Map<String, dynamic> j) {
    return BookReadingProgress(
      blockIndex: j['blockIndex'] as int? ?? 0,
      pageIndex: j['pageIndex'] as int? ?? 0,
      pageTotal: j['pageTotal'] as int? ?? 0,
      updatedAt: j['updatedAt'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'blockIndex': blockIndex,
    'pageIndex': pageIndex,
    'pageTotal': pageTotal,
    'updatedAt': updatedAt,
  };
}

/// 图书阅读进度服务（单例 + ChangeNotifier）
/// 按 bookId 记录续读 blockIndex，持久化到 SharedPreferences。
/// 与漫画 ReadingProgressService 完全隔离（独立 key），零回归。
class BookReadingProgressService extends ChangeNotifier {
  BookReadingProgressService._();
  static final BookReadingProgressService _instance =
      BookReadingProgressService._();
  factory BookReadingProgressService() => _instance;

  static const _key = 'book_reading_progress';

  final Map<String, BookReadingProgress> _map = {};

  /// 初始化：从本地加载
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final obj = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in obj.entries) {
          if (entry.value is Map) {
            _map[entry.key] = BookReadingProgress.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
      _log('已加载 ${_map.length} 本图书阅读进度');
    } catch (e) {
      _log('加载图书阅读进度失败: $e');
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final obj = <String, dynamic>{};
      for (final entry in _map.entries) {
        obj[entry.key] = entry.value.toJson();
      }
      await prefs.setString(_key, jsonEncode(obj));
    } catch (e) {
      _log('保存图书阅读进度失败: $e');
    }
  }

  /// 获取某本图书的阅读进度（无则 null）
  BookReadingProgress? getProgress(String bookId) => _map[bookId];

  /// 记录续读 block 索引。仅持久化，不 notifyListeners，
  /// 避免频繁滚动/翻页造成监听方过度重建（图书卡片无需响应阅读进度）。
  void recordBlock(
    String bookId,
    int blockIndex,
    int pageIndex,
    int pageTotal,
  ) {
    final existing = _map[bookId];
    if (existing != null &&
        existing.blockIndex == blockIndex &&
        existing.pageIndex == pageIndex &&
        existing.pageTotal == pageTotal)
      return;
    _map[bookId] = BookReadingProgress(
      blockIndex: blockIndex,
      pageIndex: pageIndex,
      pageTotal: pageTotal,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _persist();
  }

  /// 清除某本图书的阅读进度（删除下载时调用）
  Future<void> clearBook(String bookId) async {
    if (_map.remove(bookId) == null) return;
    await _persist();
    notifyListeners();
  }
}
