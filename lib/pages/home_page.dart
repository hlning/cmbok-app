import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/notification_popup.dart';
import '../widgets/update_dialog.dart';
import 'book_search_page.dart';
import 'download_page.dart';
import 'favorites_page.dart';
import 'me_page.dart';
import 'search_page.dart';

/// 主页面（果冻风底部导航）
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = SettingsService().defaultHomePage.index;

  // 果冻导航项（更好看的图标）
  final List<JellyNavItem> _navItems = const [
    JellyNavItem(icon: Icons.palette_rounded, label: '漫画'),
    JellyNavItem(icon: Icons.book_rounded, label: '图书'),
    JellyNavItem(icon: Icons.favorite_rounded, label: '收藏'),
    JellyNavItem(icon: Icons.download_for_offline_rounded, label: '下载'),
    JellyNavItem(icon: Icons.person_rounded, label: '我的'),
  ];

  @override
  void initState() {
    super.initState();
    if (SettingsService().checkUpdateOnStartup) {
      // 首帧后静默检查 app 新版本，仅发现新版本时弹窗
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _checkUpdateOnStartup(),
      );
    }
  }

  /// 启动自动检查更新：静默检查，仅发现新版本时弹窗（无 loading、无 toast）
  Future<void> _checkUpdateOnStartup() async {
    final result = await UpdateService.check();
    if (!mounted) return;
    if (result.error != null || !result.hasUpdate) return;
    showUpdateAvailableDialog(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const NotificationPopup(),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                SearchPage(isActive: _currentIndex == 0),
                BookSearchPage(isActive: _currentIndex == 1),
                FavoritesPage(isActive: _currentIndex == 2),
                DownloadPage(isActive: _currentIndex == 3),
                MePage(isActive: _currentIndex == 4),
              ],
            ),
          ),
        ],
      ),
      // 果冻风底部导航（非悬浮）
      bottomNavigationBar: JellyNavBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: _navItems,
      ),
    );
  }
}
