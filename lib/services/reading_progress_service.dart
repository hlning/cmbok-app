import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/comic.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[ReadingProgress] $message');
  }
}

/// 单本漫画的阅读进度
class ComicReadingProgress {
  /// 续读章节 id
  final String lastChapterId;
  final String lastChapterTitle;
  final int lastChapterOrder;
  /// 续读页码（从 0 起）
  final int lastPageIndex;
  /// 已读（至少打开过）的章节 id 集合
  final Set<String> seenChapterIds;
  /// 最近更新时间戳（ms）
  final int updatedAt;

  const ComicReadingProgress({
    required this.lastChapterId,
    required this.lastChapterTitle,
    required this.lastChapterOrder,
    required this.lastPageIndex,
    required this.seenChapterIds,
    required this.updatedAt,
  });

  factory ComicReadingProgress.fromJson(Map<String, dynamic> j) {
    final seen = <String>{};
    final raw = j['seenChapterIds'];
    if (raw is List) {
      for (final id in raw) {
        if (id is String && id.isNotEmpty) seen.add(id);
      }
    }
    return ComicReadingProgress(
      lastChapterId: j['lastChapterId'] as String? ?? '',
      lastChapterTitle: j['lastChapterTitle'] as String? ?? '',
      lastChapterOrder: j['lastChapterOrder'] as int? ?? 0,
      lastPageIndex: j['lastPageIndex'] as int? ?? 0,
      seenChapterIds: seen,
      updatedAt: j['updatedAt'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'lastChapterId': lastChapterId,
        'lastChapterTitle': lastChapterTitle,
        'lastChapterOrder': lastChapterOrder,
        'lastPageIndex': lastPageIndex,
        'seenChapterIds': seenChapterIds.toList(),
        'updatedAt': updatedAt,
      };

  ComicReadingProgress copyWith({
    String? lastChapterId,
    String? lastChapterTitle,
    int? lastChapterOrder,
    int? lastPageIndex,
    Set<String>? seenChapterIds,
    int? updatedAt,
  }) {
    return ComicReadingProgress(
      lastChapterId: lastChapterId ?? this.lastChapterId,
      lastChapterTitle: lastChapterTitle ?? this.lastChapterTitle,
      lastChapterOrder: lastChapterOrder ?? this.lastChapterOrder,
      lastPageIndex: lastPageIndex ?? this.lastPageIndex,
      seenChapterIds: seenChapterIds ?? this.seenChapterIds,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 阅读进度服务（单例 + ChangeNotifier）
/// 按漫画 pathWord 记录续读章节/页码与已读章节集合，持久化到 SharedPreferences。
/// UI 用 ListenableBuilder 或 addListener 监听变化。
class ReadingProgressService extends ChangeNotifier {
  ReadingProgressService._();
  static final ReadingProgressService _instance = ReadingProgressService._();
  factory ReadingProgressService() => _instance;

  static const _key = 'reading_progress';

  final Map<String, ComicReadingProgress> _map = {};

  /// 初始化：从本地加载
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final obj = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in obj.entries) {
          if (entry.value is Map) {
            _map[entry.key] = ComicReadingProgress.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
      _log('已加载 ${_map.length} 本漫画阅读进度');
    } catch (e) {
      _log('加载阅读进度失败: $e');
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
      _log('保存阅读进度失败: $e');
    }
  }

  /// 获取某本漫画的阅读进度（无则 null）
  ComicReadingProgress? getProgress(String pathWord) => _map[pathWord];

  /// 章节是否已读（至少打开过）
  bool isChapterSeen(String pathWord, String chapterId) {
    return _map[pathWord]?.seenChapterIds.contains(chapterId) ?? false;
  }

  /// 记录打开某章节：更新续读点与已读集合，pageIndex 为当前页。
  /// 触发持久化与 notifyListeners（章节切换时进度变化，UI 需刷新）。
  void recordChapter(String pathWord, ComicChapter chapter, int pageIndex) {
    final existing = _map[pathWord];
    final seen = existing?.seenChapterIds ?? <String>{};
    seen.add(chapter.id);
    _map[pathWord] = ComicReadingProgress(
      lastChapterId: chapter.id,
      lastChapterTitle: chapter.title,
      lastChapterOrder: chapter.order,
      lastPageIndex: pageIndex,
      seenChapterIds: seen,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _persist();
    notifyListeners();
  }

  /// 翻页时更新当前页（仅当章节一致）。只持久化，不 notifyListeners，
  /// 避免频繁翻页造成下载页等监听方过度重建。
  void updatePageIndex(String pathWord, String chapterId, int pageIndex) {
    final p = _map[pathWord];
    if (p == null || p.lastChapterId != chapterId) return;
    if (p.lastPageIndex == pageIndex) return;
    _map[pathWord] = p.copyWith(lastPageIndex: pageIndex);
    _persist();
  }

  /// 清除某本漫画的阅读进度（整本删除下载时调用）
  Future<void> clearComic(String pathWord) async {
    if (_map.remove(pathWord) == null) return;
    await _persist();
    notifyListeners();
  }
}
