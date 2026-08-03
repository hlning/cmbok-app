import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[RemoteConfig] $message');
}

/// 远程配置服务（单例 ChangeNotifier）
/// 同步 Windows 端：拉取公告(notification.json)与最新地址(url_config.json)，缓存到本地。
/// - [copyApiUrl]：拷贝漫画 API 地址，由 ComicApi 每次请求动态读取，远程更新即时生效。
/// - [zlibraryDomain]：z-library 初始默认域名，仅 ZlibraryService 在无持久化重定向域名时使用
///   （已重定向到可用域名的用户不受影响，远程配置不覆盖，避免回归）。
/// - [notification]：公告文本，首页弹窗展示。
class RemoteConfigService extends ChangeNotifier {
  RemoteConfigService._();
  static final RemoteConfigService _instance = RemoteConfigService._();
  factory RemoteConfigService() => _instance;

  static const _kCopyUrl = 'remote_copy_url';
  static const _kZlibraryDomain = 'remote_zlibrary_domain';
  static const _kNotification = 'remote_notification';

  String _copyApiUrl = AppConstants.defaultCopyApiUrl;
  String _zlibraryDomain =
      _hostOf(AppConstants.zLibraryApiUrl) ?? 'zh.zlibrary.by';
  String _notification = '';

  String get copyApiUrl => _copyApiUrl;
  String get zlibraryDomain => _zlibraryDomain;
  String get notification => _notification;

  /// 初始化：先读缓存（即时可用），再后台检测远程更新（不阻塞启动）。
  /// ComicApi 动态读取 copyApiUrl、弹窗监听 notification，刷新返回后自动生效。
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedCopy = prefs.getString(_kCopyUrl);
      if (cachedCopy != null && cachedCopy.isNotEmpty) {
        _copyApiUrl = _normalizeCopyUrl(cachedCopy);
      }
      final cachedZl = prefs.getString(_kZlibraryDomain);
      if (cachedZl != null && cachedZl.isNotEmpty) {
        _zlibraryDomain = cachedZl;
      }
      _notification = prefs.getString(_kNotification) ?? '';
      _log(
        '缓存: copyApiUrl=$_copyApiUrl, zlibraryDomain=$_zlibraryDomain, '
        'notification=${_notification.isEmpty ? "(空)" : _notification}',
      );
    } catch (e) {
      _log('加载缓存失败: $e');
    }
    _refresh(); // 后台检测更新（不阻塞启动）；动态生效（失败保留缓存）
    notifyListeners();
  }

  /// 拉取两个 JSON（并发，各自容错，任一失败不影响另一个）；有变化则持久化 + notifyListeners
  Future<void> _refresh() async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      _log('获取 prefs 失败（保留缓存）: $e');
      return;
    }
    final results = await Future.wait([
      _fetchUrlConfig(dio, prefs),
      _fetchNotification(dio, prefs),
    ]);
    if (results.any((c) => c)) notifyListeners();
  }

  /// 拉取 url_config.json：更新拷贝漫画地址 / z-library 默认域名。返回是否有变化。
  Future<bool> _fetchUrlConfig(Dio dio, SharedPreferences prefs) async {
    try {
      final res = await dio.get<dynamic>(AppConstants.urlConfigUrl);
      final cfg = _asMap(res.data);
      if (cfg == null) return false;
      var changed = false;
      final copy = (cfg['copy_url'] ?? '').toString().trim();
      if (copy.isNotEmpty) {
        final normalized = _normalizeCopyUrl(copy);
        if (normalized != _copyApiUrl) {
          _copyApiUrl = normalized;
          await prefs.setString(_kCopyUrl, normalized);
          changed = true;
          _log('copy_url 更新: $normalized');
        }
      }
      final zl = (cfg['zlibrary_url'] ?? '').toString().trim();
      if (zl.isNotEmpty) {
        final host = _hostOf(zl) ?? zl;
        if (host != _zlibraryDomain) {
          _zlibraryDomain = host;
          await prefs.setString(_kZlibraryDomain, host);
          changed = true;
          _log('zlibrary_url 更新: $host');
        }
      }
      return changed;
    } catch (e) {
      _log('url_config 拉取失败（保留缓存）: $e');
      return false;
    }
  }

  /// 拉取 notification.json：更新公告文本。返回是否有变化。
  Future<bool> _fetchNotification(Dio dio, SharedPreferences prefs) async {
    try {
      final res = await dio.get<dynamic>(AppConstants.notificationUrl);
      final n = _asMap(res.data)?['notification']?.toString().trim() ?? '';
      if (n != _notification) {
        _notification = n;
        await prefs.setString(_kNotification, n);
        _log('notification 更新: ${n.isEmpty ? "(空)" : n}');
        return true;
      }
      return false;
    } catch (e) {
      _log('notification 拉取失败（保留缓存）: $e');
      return false;
    }
  }

  /// 规范化拷贝漫画地址：保证末尾 /（ComicApi 拼接 ${baseUrl}api/v3/... 依赖）
  static String _normalizeCopyUrl(String url) {
    final s = url.trim();
    return s.endsWith('/') ? s : '$s/';
  }

  /// 从 url 中取 host（兼容 "zh.zlibrary.by" 与 "https://zh.zlibrary.by/"）
  static String? _hostOf(String url) {
    final s = url.trim();
    if (s.isEmpty) return null;
    var uri = Uri.tryParse(s);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    // 无 scheme 时 Uri.tryParse 取不到 host，补 https:// 再解析
    uri = Uri.tryParse('https://$s');
    return (uri != null && uri.host.isNotEmpty) ? uri.host : null;
  }

  /// 容错解析为 Map：Dio 默认按 application/json 自动解析为 Map，
  /// 个别情况下返回 String，则再 jsonDecode。
  static Map? _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final d = jsonDecode(data);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return null;
  }
}
