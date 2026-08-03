import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../utils/constants.dart';
import 'settings_service.dart';
import 'zlibrary_service.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[BookDownload] $message');
}

enum BookDownloadStatus { queued, downloading, completed, failed, paused }

/// 同步返回的下载发起结果（UI 据此弹 toast）；后续状态由任务反映在下载管理页
enum BookDownloadResult { started, alreadyDownloading, limitExceeded, needLogin }

class BookDownloadTask {
  final String bookId;
  final String hash;
  final String title;
  final String? author;
  final String? extension;
  final String? cover;
  BookDownloadStatus status;
  double progress; // 0~1
  String? localPath;
  String? error;
  int? downloadedAt; // 完成时间戳（ms）
  // 运行时（不持久化）
  CancelToken? cancelToken;
  int startIndex; // 内置账号轮询起点（reserve 时确定）
  bool reserved; // 是否已占用每日限额名额
  bool resumeMode; // 续传标记（运行时）：true 时从已下载字节接着下

  BookDownloadTask({
    required this.bookId,
    required this.hash,
    required this.title,
    this.author,
    this.extension,
    this.cover,
    this.status = BookDownloadStatus.queued,
    this.progress = 0,
    this.localPath,
    this.error,
    this.downloadedAt,
    this.startIndex = 0,
    this.reserved = false,
    this.resumeMode = false,
  });

  factory BookDownloadTask.fromBook(
    Book book, {
    int startIndex = 0,
    bool reserved = false,
  }) =>
      BookDownloadTask(
        bookId: book.id,
        hash: book.hash,
        title: book.title,
        author: book.author,
        extension: book.extension,
        cover: book.cover,
        startIndex: startIndex,
        reserved: reserved,
      );

  factory BookDownloadTask.fromJson(Map<String, dynamic> j) {
    final status = BookDownloadStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => BookDownloadStatus.completed,
    );
    return BookDownloadTask(
      bookId: j['bookId'] as String? ?? '',
      hash: j['hash'] as String? ?? '',
      title: j['title'] as String? ?? '',
      author: j['author'] as String?,
      extension: j['extension'] as String?,
      cover: j['cover'] as String?,
      status: status,
      localPath: j['localPath'] as String?,
      downloadedAt: j['downloadedAt'] as int?,
      // 失败任务的名额已在失败时释放；completed/paused 仍占用名额
      reserved: status != BookDownloadStatus.failed,
    );
  }

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'hash': hash,
        'title': title,
        'author': author,
        'extension': extension,
        'cover': cover,
        'status': status.name,
        'localPath': localPath,
        'downloadedAt': downloadedAt,
      };
}

/// 图书下载服务（单例 + ChangeNotifier）
/// 对标漫画 DownloadService：队列 + 并发 + 暂停/继续/取消/重试 + 持久化。
/// 下载逻辑对应 cmbook BookDownload：限额预留 -> 取下载链接 -> 流式下载。
class BookDownloadService extends ChangeNotifier {
  BookDownloadService._();
  static final BookDownloadService _instance = BookDownloadService._();
  factory BookDownloadService() => _instance;

  static const _kRecords = 'book_download_records';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 120),
  ));

  final Map<String, BookDownloadTask> _tasks = {};
  Map<String, BookDownloadTask> get tasks => Map.unmodifiable(_tasks);

  BookDownloadTask? task(String bookId) => _tasks[bookId];
  bool isDownloaded(String bookId) =>
      _tasks[bookId]?.status == BookDownloadStatus.completed;

  List<BookDownloadTask> get activeTasks =>
      _tasks.values.where((t) => t.status != BookDownloadStatus.completed).toList();
  List<BookDownloadTask> get completedTasks =>
      _tasks.values.where((t) => t.status == BookDownloadStatus.completed).toList();

  int get _runningCount =>
      _tasks.values.where((t) => t.status == BookDownloadStatus.downloading).length;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kRecords);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          final t = BookDownloadTask.fromJson(item as Map<String, dynamic>);
          _tasks[t.bookId] = t;
        }
      }
      _log('已加载 ${_tasks.length} 条图书下载记录');
    } catch (e) {
      _log('加载记录失败: $e');
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final records = _tasks.values
          .where((t) =>
              t.status == BookDownloadStatus.completed ||
              t.status == BookDownloadStatus.paused ||
              t.status == BookDownloadStatus.failed)
          .map((t) => t.toJson())
          .toList();
      await prefs.setString(_kRecords, jsonEncode(records));
    } catch (e) {
      _log('保存记录失败: $e');
    }
  }

  Future<Directory> _booksDir() async {
    final base = await SettingsService.downloadBaseDir();
    final dir = Directory('${base.path}/${AppConstants.bookDir}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 清理文件名非法字符并截断到 [maxLen]（默认100），避免书名过长叠加 bookId
  /// 后超出文件系统/Windows 260 路径限制。
  String _sanitize(String s, {int maxLen = 100}) {
    var name = s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
    if (name.length > maxLen) name = name.substring(0, maxLen);
    return name;
  }

  /// 加入下载队列（立即返回，后台调度）。
  /// 名额在入队时预留（对应 cmbook 下载开始即 reserve）；失败/取消时释放。
  Future<BookDownloadResult> download(Book book) async {
    final existing = _tasks[book.id];
    if (existing != null &&
        existing.status != BookDownloadStatus.completed &&
        existing.status != BookDownloadStatus.failed) {
      return BookDownloadResult.alreadyDownloading;
    }

    final z = ZlibraryService();
    // 关闭内置账号且未登录：要求先登录
    if (!z.isLoggedIn && !SettingsService().useBuiltinAccount) {
      return BookDownloadResult.needLogin;
    }
    // 预留每日限额名额
    int? startIndex;
    bool reserved;
    if (z.isLoggedIn) {
      reserved = z.reserveLoggedDownload();
      startIndex = 0;
    } else {
      startIndex = z.reserveBuiltinDownload();
      reserved = startIndex != null;
    }
    if (!reserved) return BookDownloadResult.limitExceeded;

    final task = existing ?? BookDownloadTask.fromBook(book);
    task
      ..status = BookDownloadStatus.queued
      ..progress = 0
      ..error = null
      ..startIndex = startIndex ?? 0
      ..reserved = true
      ..resumeMode = false
      ..cancelToken = null;
    _tasks[book.id] = task;
    notifyListeners();
    _schedule();
    return BookDownloadResult.started;
  }

  /// 调度：按"同时下载量"并发启动排队任务
  void _schedule() {
    final max = SettingsService().maxConcurrentChapters;
    while (_runningCount < max) {
      final next = _nextQueued();
      if (next == null) break;
      _startTask(next);
    }
  }

  BookDownloadTask? _nextQueued() {
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.queued) return t;
    }
    return null;
  }

  void _startTask(BookDownloadTask task) {
    task.status = BookDownloadStatus.downloading;
    if (!task.resumeMode) {
      task.progress = 0;
    }
    task.cancelToken = CancelToken();
    notifyListeners();
    _downloadOne(task).whenComplete(_schedule);
  }

  Future<void> _downloadOne(BookDownloadTask task) async {
    final z = ZlibraryService();
    try {
      final link =
          await z.getDownloadLink(task.bookId, task.hash, startIndex: task.startIndex);
      if (!_tasks.containsKey(task.bookId)) return; // 已取消
      if (task.status == BookDownloadStatus.paused) return; // 已暂停
      if (link == null) {
        _releaseQuota(task, z);
        task
          ..status = BookDownloadStatus.failed
          ..error = '无可用账号';
        await _persist();
        notifyListeners();
        return;
      }
      final dir = await _booksDir();
      final ext = (task.extension?.isNotEmpty == true
              ? task.extension!
              : 'epub')
          .toLowerCase();
      final file = File('${dir.path}/${_sanitize(task.title)}_${task.bookId}.$ext');

      // 续传：从已下载字节数接着下（HTTP Range）
      int startByte = 0;
      if (task.resumeMode) {
        try {
          if (await file.exists()) startByte = await file.length();
        } catch (e) {
          _log('读取已下载大小失败: $e');
        }
        if (startByte > 0) _log('续传 ${task.title}：从 $startByte 字节继续');
      }

      if (startByte > 0) {
        await _downloadWithResume(link, file, startByte, task);
      } else {
        await _dio.download(
          link.url,
          file.path,
          options: Options(headers: link.headers),
          cancelToken: task.cancelToken,
          deleteOnError: false, // 保留暂停分片，供续传
          onReceiveProgress: (r, total) {
            if (total > 0) {
              final p = r / total;
              if ((p - task.progress).abs() >= 0.01 || p >= 1) {
                task.progress = p;
                notifyListeners();
              }
            }
          },
        );
      }
      if (!_tasks.containsKey(task.bookId)) return; // 已取消
      if (task.status == BookDownloadStatus.paused) return; // 已暂停
      task
        ..status = BookDownloadStatus.completed
        ..progress = 1
        ..localPath = file.path
        ..downloadedAt = DateTime.now().millisecondsSinceEpoch;
      await _persist();
      notifyListeners();
      _log('下载完成: ${task.title}');
      // 登录态：下载成功后刷新服务端已下载数，及时更新头像下方显示
      if (z.isLoggedIn) z.refreshUserProfile();
    } catch (e) {
      if (!_tasks.containsKey(task.bookId)) return; // 已取消，静默
      if (task.status == BookDownloadStatus.paused) return; // 已暂停，静默
      _releaseQuota(task, z);
      task
        ..status = BookDownloadStatus.failed
        ..error = '$e';
      await _persist();
      notifyListeners();
      _log('下载失败: ${task.title} - $e');
    }
  }

  /// 流式续传：带 Range 请求，206 则追加续传，200（服务端不支持 Range）则从头重下。
  /// 416 表示已下载字节已达全文大小（文件已完整），直接视为完成。
  Future<void> _downloadWithResume(
    DownloadLink link,
    File file,
    int startByte,
    BookDownloadTask task,
  ) async {
    final response = await _dio.get(
      link.url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          ...link.headers,
          HttpHeaders.rangeHeader: 'bytes=$startByte-',
          // 避免压缩，保证 Range/追加操作的是原始字节
          HttpHeaders.acceptEncodingHeader: 'identity',
        },
        // 接受 416（已下载字节已达全文大小），交由下面判断
        validateStatus: (s) => s != null && (s < 300 || s == 416),
      ),
      cancelToken: task.cancelToken,
    );
    final status = response.statusCode ?? 200;
    if (status == 416) return; // 文件已完整，无需再下
    int total;
    int written;
    FileMode mode;
    if (status == 206) {
      // Content-Range: bytes start-end/total
      final cr = response.headers.value('content-range') ?? '';
      final m = RegExp(r'/(\d+)$').firstMatch(cr);
      total = m != null ? int.parse(m.group(1)!) : 0;
      written = startByte;
      mode = FileMode.append;
    } else {
      // 服务端忽略 Range，返回完整内容 -> 从头重下
      total = int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
      written = 0;
      mode = FileMode.write;
    }
    final raf = await file.open(mode: mode);
    try {
      final body = response.data as ResponseBody;
      await for (final chunk in body.stream) {
        await raf.writeFrom(chunk);
        written += chunk.length;
        if (total > 0) {
          final p = written / total;
          if ((p - task.progress).abs() >= 0.01 || p >= 1) {
            task.progress = p;
            notifyListeners();
          }
        }
      }
    } finally {
      await raf.close();
    }
  }

  void _releaseQuota(BookDownloadTask task, ZlibraryService z) {
    if (!task.reserved) return;
    task.reserved = false;
    if (z.isLoggedIn) {
      z.releaseLoggedDownload();
    } else {
      z.releaseBuiltinDownload();
    }
  }

  /// 暂停：排队/下载中 -> 已暂停（停止在传下载，名额保留）
  void pauseTask(String bookId) {
    final t = _tasks[bookId];
    if (t == null) return;
    if (t.status != BookDownloadStatus.queued &&
        t.status != BookDownloadStatus.downloading) {
      return;
    }
    t.cancelToken?.cancel();
    t.status = BookDownloadStatus.paused;
    _persist();
    notifyListeners();
  }

  /// 继续：已暂停 -> 排队（续传：保留进度，从已下载字节接着下）
  void resumeTask(String bookId) {
    final t = _tasks[bookId];
    if (t == null || t.status != BookDownloadStatus.paused) return;
    t
      ..status = BookDownloadStatus.queued
      ..resumeMode = true
      ..cancelToken = null;
    notifyListeners();
    _schedule();
  }

  /// 重试：失败 -> 排队（失败时已释放名额，需重新预留；从头重下）
  void retryTask(String bookId) {
    final t = _tasks[bookId];
    if (t == null || t.status != BookDownloadStatus.failed) return;
    if (!t.reserved) {
      final z = ZlibraryService();
      // 关闭内置账号且未登录：要求先登录
      if (!z.isLoggedIn && !SettingsService().useBuiltinAccount) {
        t.error = '请先登录账号';
        notifyListeners();
        return;
      }
      int? startIndex;
      bool reserved;
      if (z.isLoggedIn) {
        reserved = z.reserveLoggedDownload();
        startIndex = 0;
      } else {
        startIndex = z.reserveBuiltinDownload();
        reserved = startIndex != null;
      }
      if (!reserved) {
        t.error = '今日下载已达上限';
        notifyListeners();
        return;
      }
      t
        ..startIndex = startIndex ?? 0
        ..reserved = true;
    }
    t
      ..status = BookDownloadStatus.queued
      ..progress = 0
      ..error = null
      ..resumeMode = false
      ..cancelToken = null;
    notifyListeners();
    _schedule();
  }

  /// 取消（排队/下载中/暂停/失败）：释放名额 + 移除
  void cancelTask(String bookId) {
    final t = _tasks[bookId];
    if (t == null) return;
    t.cancelToken?.cancel();
    _releaseQuota(t, ZlibraryService());
    _tasks.remove(bookId);
    _persist();
    notifyListeners();
  }

  /// 删除已下载任务（删文件 + 记录，不释放名额）
  Future<void> deleteTask(String bookId) async {
    final t = _tasks[bookId];
    if (t == null) return;
    if (t.localPath != null) {
      try {
        final f = File(t.localPath!);
        if (await f.exists()) await f.delete();
      } catch (e) {
        _log('删除文件失败: $e');
      }
    }
    _tasks.remove(bookId);
    await _persist();
    notifyListeners();
  }

  void pauseAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.queued ||
          t.status == BookDownloadStatus.downloading) {
        t.cancelToken?.cancel();
        t.status = BookDownloadStatus.paused;
        changed = true;
      }
    }
    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  /// 全部继续：已暂停 -> 排队（续传：保留进度）
  void resumeAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.paused) {
        t
          ..status = BookDownloadStatus.queued
          ..resumeMode = true
          ..cancelToken = null;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedule();
    }
  }

  /// 全部开始：已暂停 -> 排队（从头重新下载，重置进度）
  void restartAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.paused) {
        t
          ..status = BookDownloadStatus.queued
          ..progress = 0
          ..resumeMode = false
          ..cancelToken = null;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedule();
    }
  }

  void retryAll() {
    final failedKeys = _tasks.entries
        .where((e) => e.value.status == BookDownloadStatus.failed)
        .map((e) => e.key)
        .toList();
    for (final key in failedKeys) {
      retryTask(key);
    }
  }

  void cancelAll() {
    final keys = _tasks.entries
        .where((e) => e.value.status != BookDownloadStatus.completed)
        .map((e) => e.key)
        .toList();
    if (keys.isEmpty) return;
    for (final key in keys) {
      final t = _tasks[key]!;
      t.cancelToken?.cancel();
      _releaseQuota(t, ZlibraryService());
      _tasks.remove(key);
    }
    _persist();
    notifyListeners();
  }
}
