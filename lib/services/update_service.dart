import 'package:dio/dio.dart';
import '../utils/constants.dart';

/// 检查更新结果
class UpdateResult {
  final bool hasUpdate;
  final String? latestVersion;
  final String? releaseUrl;
  final String? error;
  const UpdateResult({
    this.hasUpdate = false,
    this.latestVersion,
    this.releaseUrl,
    this.error,
  });
}

/// 检查更新服务：通过 GitHub Releases API 获取最新版本号，与本地版本比较。
class UpdateService {
  static Future<UpdateResult> check() async {
    try {
      final res = await Dio().get<dynamic>(
        AppConstants.latestReleaseApiUrl,
        options: Options(
          headers: {'Accept': 'application/vnd.github+json'},
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
        ),
      );
      if (res.statusCode == 404) {
        return const UpdateResult(error: '暂未发布任何版本');
      }
      final data = res.data;
      if (res.statusCode == 200 && data is Map) {
        var tag = (data['tag_name'] ?? '').toString().trim();
        if (tag.isEmpty) return const UpdateResult(error: '无法获取版本信息');
        if (tag.startsWith('v') || tag.startsWith('V')) tag = tag.substring(1);
        final htmlUrl = (data['html_url'] ?? AppConstants.githubUrl).toString();
        return UpdateResult(
          hasUpdate: _isNewer(tag, AppConstants.version),
          latestVersion: tag,
          releaseUrl: htmlUrl,
        );
      }
      return const UpdateResult(error: '无法获取版本信息');
    } catch (e) {
      return const UpdateResult(error: '检查更新失败，请检查网络');
    }
  }

  /// 语义化版本比较：latest > current 返回 true
  static bool _isNewer(String latest, String current) {
    final l = latest.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final c = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final n = l.length > c.length ? l.length : c.length;
    for (var i = 0; i < n; i++) {
      final li = i < l.length ? l[i] : 0;
      final ci = i < c.length ? c[i] : 0;
      if (li > ci) return true;
      if (li < ci) return false;
    }
    return false;
  }
}
