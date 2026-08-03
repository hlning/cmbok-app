import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/search_result.dart';
import 'builtin_accounts.dart';
import 'remote_config_service.dart';
import 'settings_service.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[Zlibrary] $message');
}

/// z-library 下载链接信息（对应 cmbook Zlibrary.getDownloadLink 返回）
class DownloadLink {
  final String filename;
  final String url;
  final Map<String, String> headers;
  const DownloadLink({
    required this.filename,
    required this.url,
    required this.headers,
  });
}

/// z-library 业务异常
class ZlibraryException implements Exception {
  final String code; // no_account / fail
  final String message;
  ZlibraryException(this.code, this.message);
  @override
  String toString() => 'ZlibraryException($code): $message';
}

/// z-library 登录/注册/搜索/下载链接服务 + 每日限额（单例 ChangeNotifier）
/// 对应 cmbook service/zlibrary_client.py + service/cmbok_service.py 图书部分。
/// 已登录自有账号时优先用自有 token，否则轮询内置账号。
class ZlibraryService extends ChangeNotifier {
  ZlibraryService._();
  static final ZlibraryService _instance = ZlibraryService._();
  factory ZlibraryService() => _instance;

  static const _kDomain = 'zlibrary_domain';
  static const _kEmail = 'zlibrary_email';
  static const _kUsername = 'zlibrary_username';
  static const _kRemixUserid = 'zlibrary_remix_userid';
  static const _kRemixUserkey = 'zlibrary_remix_userkey';

  /// 内置账号全局每日限额 / 自有账号每日限额（对应 cmbook BUILTIN_DAILY_LIMIT / LOGGED_DAILY_LIMIT）
  static const int builtinDailyLimit = 5;
  static const int loggedDailyLimit = 10;
  static const _kBuiltinCount = 'zlibrary_builtin_count'; // JSON {date, count}
  static const _kLoggedCount = 'zlibrary_logged_count'; // JSON {date, accounts{userid:count}}

  static const _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    followRedirects: false, // 手动处理 301/302 以更新并持久化域名
    responseType: ResponseType.plain, // 自行 jsonDecode，规避 Cloudflare HTML 页抛异常
    validateStatus: (_) => true, // 不按状态码抛异常，自行判断
  ));

  String _domain = ''; // 不含 scheme，如 zh.zlibrary.by
  String _email = '';
  String _username = '';
  String _remixUserid = '';
  String _remixUserkey = '';

  /// 自有账号服务端每日下载限额（来自 /eapi/user/profile；null=未取到，回退硬编码）
  int? _serverDownloadsLimit;

  /// 内置账号 token 缓存（避免每次搜索都重新登录）
  String? _builtinUserid;
  String? _builtinUserkey;

  String get domain => _domain;
  String get email => _email;
  String get username => _username;
  String get remixUserid => _remixUserid;
  bool get isLoggedIn =>
      _remixUserid.isNotEmpty && _remixUserkey.isNotEmpty;

  /// 自有账号服务端每日下载限额（未取到时为 null，调用方应回退 loggedDailyLimit）
  int? get serverDownloadsLimit => _serverDownloadsLimit;

  /// 初始化：加载登录态、域名、每日计数
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _domain = prefs.getString(_kDomain) ?? _defaultDomain();
    _email = prefs.getString(_kEmail) ?? '';
    _username = prefs.getString(_kUsername) ?? '';
    _remixUserid = prefs.getString(_kRemixUserid) ?? '';
    _remixUserkey = prefs.getString(_kRemixUserkey) ?? '';
    await _loadCounts();
    _log('init: domain=$_domain, loggedIn=$isLoggedIn');
    notifyListeners();
    if (isLoggedIn) refreshUserProfile(); // fire-and-forget：校准服务端限额与已下载数
  }

  static String _defaultDomain() => RemoteConfigService().zlibraryDomain;

  Future<void> _persistDomain() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDomain, _domain);
  }

  // -------------------- 登录 / 注册 --------------------

  /// 邮箱密码登录（自有账号）。成功保存 token。对应 cmbook Zlibrary.login
  Future<bool> login(String email, String password) async {
    final res = await _post('/eapi/user/login',
        data: {'email': email, 'password': password});
    if (_isSuccess(res) && res['user'] is Map) {
      final user = res['user'] as Map;
      final uid = (user['id'] ?? '').toString();
      final key = (user['remix_userkey'] ?? '').toString();
      if (uid.isEmpty || key.isEmpty) return false;
      _email = email;
      _username = (user['name'] ?? '').toString();
      _remixUserid = uid;
      _remixUserkey = key;
      await _persistAuth();
      _log('登录成功: $email');
      notifyListeners();
      refreshUserProfile(); // fire-and-forget：拉取服务端实际限额与已下载数
      return true;
    }
    _log('登录失败: $res');
    return false;
  }

  /// 发送注册验证码。对应 cmbook Zlibrary.sendCode
  Future<bool> sendCode(String email, String password, String name) async {
    final res = await _post('/papi/user/verification/send-code', data: {
      'email': email,
      'password': password,
      'name': name,
      'rx': 215,
      'action': 'registration',
      'site_mode': 'books',
      'isSinglelogin': 1,
    });
    return _isSuccess(res);
  }

  /// 提交验证码完成注册。rpc.php 返回不可靠，注册后用账号登录验证。
  /// 对应 cmbook ZlibraryRegister.run
  Future<bool> register(
      String email, String password, String name, String code) async {
    await _post('/rpc.php', data: {
      'email': email,
      'password': password,
      'name': name,
      'verifyCode': code,
      'rx': 215,
      'action': 'registration',
      'redirectUrl': '',
      'isModa': true,
      'gg_json_mode': 1,
    });
    return login(email, password); // 登录验证注册是否成功
  }

  Future<void> logout() async {
    _email = '';
    _username = '';
    _remixUserid = '';
    _remixUserkey = '';
    _serverDownloadsLimit = null;
    await _persistAuth();
    _log('退出登录');
    notifyListeners();
  }

  Future<void> _persistAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEmail, _email);
    await prefs.setString(_kUsername, _username);
    await prefs.setString(_kRemixUserid, _remixUserid);
    await prefs.setString(_kRemixUserkey, _remixUserkey);
  }

  // -------------------- 搜索 --------------------

  /// 搜索图书。已登录自有账号用自有 token，否则轮询内置账号。
  /// 对应 cmbook BookSearch.run + _do_search。
  /// [extensions] 为格式筛选（EPUB/PDF/...），null 或空=不筛选。
  Future<SearchResult<Book>> search(
    String message, {
    String? extensions,
    int page = 1,
    int limit = 30,
  }) async {
    if (isLoggedIn) {
      final res = await _doSearch(
          message, extensions, page, limit, _remixUserid, _remixUserkey);
      if (_isSuccess(res)) return _parseSearch(res);
      final useBuiltin = SettingsService().useBuiltinAccount;
      _log('自有账号搜索失败${useBuiltin ? '，回退内置账号' : ''}');
      if (!useBuiltin) {
        throw ZlibraryException('fail', '搜索失败，请稍后重试');
      }
    }
    // 未登录：默认使用内置账号搜索（不受"使用内置账号"开关限制），以提升体验；
    // 也覆盖已登录自有账号失败且回退内置账号的情况。
    final res = await _searchWithBuiltin(message, extensions, page, limit);
    if (!_isSuccess(res)) {
      throw ZlibraryException('no_account', '没有可用的内置账号');
    }
    return _parseSearch(res);
  }

  SearchResult<Book> _parseSearch(Map<String, dynamic> res) {
    final books = (res['books'] as List? ?? [])
        .whereType<Map>()
        .map((b) => Book.fromJson(Map<String, dynamic>.from(b)))
        .toList();
    final pag = (res['pagination'] as Map?) ?? {};
    final total = _asInt(pag['total_items']) ?? books.length;
    final totalPages = _asInt(pag['total_pages']) ?? 0;
    final current = _asInt(pag['current']) ?? 1;
    return SearchResult<Book>(
      items: books,
      total: total,
      currentPage: current,
      totalPages: totalPages,
    );
  }

  Future<Map<String, dynamic>> _searchWithBuiltin(
    String message,
    String? extensions,
    int page,
    int limit,
  ) async {
    // 优先复用缓存的内置 token
    if (_builtinUserid != null && _builtinUserkey != null) {
      final res = await _doSearch(
          message, extensions, page, limit, _builtinUserid!, _builtinUserkey!);
      if (_isSuccess(res)) return res;
      _builtinUserid = _builtinUserkey = null;
    }
    // 轮询内置账号登录
    for (final acc in kBuiltinAccounts) {
      final token = await _loginForToken(acc.email, acc.password);
      if (token == null) continue;
      _builtinUserid = token.userid;
      _builtinUserkey = token.userkey;
      final res =
          await _doSearch(message, extensions, page, limit, token.userid, token.userkey);
      if (_isSuccess(res)) return res;
    }
    return {'success': false};
  }

  Future<Map<String, dynamic>> _doSearch(
    String message,
    String? extensions,
    int page,
    int limit,
    String userid,
    String userkey,
  ) async {
    final data = <String, dynamic>{
      'message': message,
      'page': page,
      'limit': limit,
    };
    if (extensions != null && extensions.isNotEmpty) {
      data['extensions[]'] = extensions;
    }
    return _post('/eapi/book/search', data: data, cookies: _cookies(userid, userkey));
  }

  // -------------------- 下载链接 --------------------

  /// 获取下载链接。已登录自有账号用自有 token，否则按 round-robin 起点轮询内置账号。
  /// 对应 cmbook Zlibrary.getDownloadLink + BookDownload._download_with_builtin_account。
  /// [startIndex] 用于内置账号轮询起点（按已用计数均匀分散到各账号）。
  Future<DownloadLink?> getDownloadLink(
    String bookId,
    String bookHash, {
    int startIndex = 0,
  }) async {
    final useBuiltin = SettingsService().useBuiltinAccount;
    if (isLoggedIn) {
      final link =
          await _fetchDownloadLink(bookId, bookHash, _remixUserid, _remixUserkey);
      if (link != null) return link;
      _log('自有账号取下载链接失败${useBuiltin ? '，回退内置账号' : ''}');
      if (!useBuiltin) return null;
    } else if (!useBuiltin) {
      // 关闭内置账号且未登录：无可用账号
      return null;
    }
    final n = kBuiltinAccounts.length;
    for (var i = 0; i < n; i++) {
      final acc = kBuiltinAccounts[(startIndex + i) % n];
      final token = await _loginForToken(acc.email, acc.password);
      if (token == null) continue;
      final link =
          await _fetchDownloadLink(bookId, bookHash, token.userid, token.userkey);
      if (link != null) return link;
    }
    return null;
  }

  Future<DownloadLink?> _fetchDownloadLink(
    String bookId,
    String bookHash,
    String userid,
    String userkey,
  ) async {
    final res = await _get('/eapi/book/$bookId/$bookHash/file',
        cookies: _cookies(userid, userkey));
    if (!_isSuccess(res) || res['file'] is! Map) return null;
    final file = res['file'] as Map;
    if (!_isTruthy(file['allowDownload'])) return null;
    final ddl = (file['downloadLink'] ?? '').toString();
    if (ddl.isEmpty) return null;
    var filename = (file['description'] ?? '').toString();
    final author = file['author'];
    if (author != null) filename += ' ($author)';
    filename += '.${file['extension'] ?? 'epub'}';
    final headers = <String, String>{'User-Agent': _browserUa};
    try {
      headers['authority'] = ddl.split('/')[2];
    } catch (_) {}
    return DownloadLink(filename: filename, url: ddl, headers: headers);
  }

  // -------------------- 每日限额（对应 cmbook reserve/release）--------------------

  /// 今日内置账号已下载数（跨日归零）
  int get builtinCountToday {
    final today = _today();
    final d = _builtinCountCache['date'] as String? ?? '';
    return d == today ? (_builtinCountCache['count'] as int? ?? 0) : 0;
  }

  /// 今日自有账号已下载数（跨日归零）
  int get loggedCountToday {
    if (!isLoggedIn) return 0;
    final today = _today();
    final d = _loggedCountCache['date'] as String? ?? '';
    if (d != today) return 0;
    final accounts = _loggedCountCache['accounts'] as Map? ?? {};
    return (accounts[_remixUserid] as int?) ?? 0;
  }

  /// 预留一个内置下载名额（计数+1）。超限返回 null；成功返回轮询起点 index。
  int? reserveBuiltinDownload() {
    final today = _today();
    var count = (_builtinCountCache['date'] == today
        ? (_builtinCountCache['count'] as int? ?? 0)
        : 0);
    if (count >= builtinDailyLimit) return null;
    count++;
    _writeBuiltinCount(today, count);
    return (count - 1) % kBuiltinAccounts.length;
  }

  void releaseBuiltinDownload() {
    final today = _today();
    if (_builtinCountCache['date'] != today) return;
    final count = _builtinCountCache['count'] as int? ?? 0;
    if (count > 0) _writeBuiltinCount(today, count - 1);
  }

  bool reserveLoggedDownload() {
    if (!isLoggedIn) return false;
    final today = _today();
    var accounts =
        Map<String, dynamic>.from(_loggedCountCache['accounts'] as Map? ?? {});
    if (_loggedCountCache['date'] != today) accounts = {};
    final count = (accounts[_remixUserid] as int?) ?? 0;
    // 限额优先用服务端实际值（/eapi/user/profile），未取到回退硬编码
    if (count >= (_serverDownloadsLimit ?? loggedDailyLimit)) return false;
    accounts[_remixUserid] = count + 1;
    _writeLoggedCount(today, accounts);
    return true;
  }

  void releaseLoggedDownload() {
    if (!isLoggedIn) return;
    final today = _today();
    if (_loggedCountCache['date'] != today) return;
    var accounts =
        Map<String, dynamic>.from(_loggedCountCache['accounts'] as Map? ?? {});
    final count = (accounts[_remixUserid] as int?) ?? 0;
    if (count > 0) {
      accounts[_remixUserid] = count - 1;
      _writeLoggedCount(today, accounts);
    }
  }

  /// 拉取自有账号 profile，取服务端每日下载限额与已下载数，并以此校准本地计数。
  /// 失败静默保留旧值（_log）。对应 z-library /eapi/user/profile。
  Future<void> refreshUserProfile() async {
    if (!isLoggedIn) return;
    final res = await _get('/eapi/user/profile',
        cookies: _cookies(_remixUserid, _remixUserkey));
    if (!_isSuccess(res) || res['user'] is! Map) {
      _log('拉取 profile 失败: $res');
      return;
    }
    final user = res['user'] as Map;
    final serverToday = _asInt(user['downloads_today']) ?? 0;
    _serverDownloadsLimit = _asInt(user['downloads_limit']);
    // 以服务端已下载数为基准校准本地计数：取较大值。
    // 服务端是真实下限，本地多出的是在途未结算的乐观增量，不丢失。
    final today = _today();
    var accounts =
        Map<String, dynamic>.from(_loggedCountCache['accounts'] as Map? ?? {});
    if (_loggedCountCache['date'] != today) accounts = {};
    final local = (accounts[_remixUserid] as int?) ?? 0;
    if (serverToday > local) {
      accounts[_remixUserid] = serverToday;
      _writeLoggedCount(today, accounts);
    }
    _log('profile: downloads_today=$serverToday, '
        'downloads_limit=$_serverDownloadsLimit, 本地已用=${serverToday > local ? serverToday : local}');
    notifyListeners();
  }

  // -------------------- HTTP 基础（对应 cmbook __makePostRequest/__makeGetRequest）--------------------

  Map<String, String> _cookies(String userid, String userkey) => {
        'siteLanguageV2': 'en',
        'remix_userid': userid,
        'remix_userkey': userkey,
      };

  Future<Map<String, dynamic>> _post(
    String path, {
    Map<String, dynamic>? data,
    Map<String, String>? cookies,
    bool followed = false,
  }) async {
    try {
      final res = await _dio.post(
        'https://$_domain$path',
        data: data,
        options: Options(
          headers: _headers(cookies),
          contentType: Headers.formUrlEncodedContentType,
        ),
      );
      final redirected = _maybeRedirect(res.statusCode, res.headers.value('location'));
      if (redirected != null && !followed) {
        _domain = redirected;
        await _persistDomain();
        _log('域名重定向 -> $_domain');
        return _post(path, data: data, cookies: cookies, followed: true);
      }
      return _asJsonMap(res.data);
    } catch (e) {
      _log('POST $path 异常: $e');
      return {'success': false, 'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? params,
    Map<String, String>? cookies,
    bool followed = false,
  }) async {
    try {
      final res = await _dio.get(
        'https://$_domain$path',
        queryParameters: params,
        options: Options(headers: _headers(cookies)),
      );
      final redirected = _maybeRedirect(res.statusCode, res.headers.value('location'));
      if (redirected != null && !followed) {
        _domain = redirected;
        await _persistDomain();
        _log('域名重定向 -> $_domain');
        return _get(path, params: params, cookies: cookies, followed: true);
      }
      return _asJsonMap(res.data);
    } catch (e) {
      _log('GET $path 异常: $e');
      return {'success': false, 'error': '$e'};
    }
  }

  /// 301/302/303/307/308 且 Location 指向新域名 -> 返回新域名；否则 null
  String? _maybeRedirect(int? status, String? location) {
    if (status == null || ![301, 302, 303, 307, 308].contains(status)) return null;
    if (location == null || location.isEmpty) return null;
    final host = Uri.tryParse(location)?.host;
    if (host != null && host.isNotEmpty && host != _domain) return host;
    return null;
  }

  Map<String, String> _headers(Map<String, String>? cookies) {
    final h = <String, String>{
      'User-Agent': _browserUa,
      'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
      'accept-language': 'en-US,en;q=0.9',
    };
    if (cookies != null && cookies.isNotEmpty) {
      h['Cookie'] = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }
    return h;
  }

  bool _isSuccess(dynamic res) => res is Map && _isTruthy(res['success']);

  /// z-library eapi 的成功/允许标志返回的是整数 1 而非布尔 true
  /// （如 success、allowDownload），需按真值判断，对应 Python if res.get('success')。
  bool _isTruthy(dynamic v) => v == true || v == 1;

  Map<String, dynamic> _asJsonMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse('$v');
  }

  /// 内置账号登录取 token（仅内存，不持久化）
  Future<_Token?> _loginForToken(String email, String password) async {
    final res = await _post('/eapi/user/login',
        data: {'email': email, 'password': password});
    if (_isSuccess(res) && res['user'] is Map) {
      final user = res['user'] as Map;
      final uid = (user['id'] ?? '').toString();
      final key = (user['remix_userkey'] ?? '').toString();
      if (uid.isNotEmpty && key.isNotEmpty) return _Token(uid, key);
    }
    return null;
  }

  // -------------------- 计数持久化 --------------------

  Map<String, dynamic> _builtinCountCache = {};
  Map<String, dynamic> _loggedCountCache = {};

  Future<void> _loadCounts() async {
    final prefs = await SharedPreferences.getInstance();
    _builtinCountCache = _decode(prefs.getString(_kBuiltinCount));
    _loggedCountCache = _decode(prefs.getString(_kLoggedCount));
  }

  void _writeBuiltinCount(String today, int count) {
    _builtinCountCache = {'date': today, 'count': count};
    final raw = jsonEncode(_builtinCountCache);
    SharedPreferences.getInstance().then((p) => p.setString(_kBuiltinCount, raw));
  }

  void _writeLoggedCount(String today, Map<String, dynamic> accounts) {
    _loggedCountCache = {'date': today, 'accounts': accounts};
    final raw = jsonEncode(_loggedCountCache);
    SharedPreferences.getInstance().then((p) => p.setString(_kLoggedCount, raw));
  }

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return {};
  }

  String _today() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }
}

class _Token {
  final String userid;
  final String userkey;
  const _Token(this.userid, this.userkey);
}
