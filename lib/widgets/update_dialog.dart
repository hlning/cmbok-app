import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_service.dart';
import '../utils/constants.dart';

/// 展示"发现新版本"对话框；用户点"前往下载"时打开 release 页。
/// 供「我的」页手动检查更新 与 启动自动检查更新 复用。
void showUpdateAvailableDialog(BuildContext context, UpdateResult result) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('发现新版本'),
      content: Text(
        '最新版本 v${result.latestVersion}，当前 V${AppConstants.version}。\n是否前往下载？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            launchUrl(
              Uri.parse(result.releaseUrl ?? AppConstants.githubUrl),
              mode: LaunchMode.externalApplication,
            );
          },
          child: const Text('前往下载'),
        ),
      ],
    ),
  );
}
