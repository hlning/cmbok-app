import 'package:flutter/services.dart';

/// 平台原生能力（方法通道）：打开目录、取 APK 路径
class PlatformService {
  static const _channel = MethodChannel('cmbok/platform');

  /// 打开目录（Android 文件管理器）。成功返回 true；非安卓/无应用可处理返回 false。
  static Future<bool> openDirectory(String path) async {
    try {
      final r = await _channel.invokeMethod<bool>('openDir', {'path': path});
      return r ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 用系统外部应用打开文件（按 mimeType 选择阅读器）。成功返回 true；
  /// 无可用应用或非安卓返回 false。
  static Future<bool> openFile(String path, String mimeType) async {
    try {
      final r = await _channel.invokeMethod<bool>(
          'openFile', {'path': path, 'mimeType': mimeType});
      return r ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 取本应用 APK 路径（Android）。取不到返回 null。
  static Future<String?> getApkPath() async {
    try {
      return await _channel.invokeMethod<String>('getApkPath');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
