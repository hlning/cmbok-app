import 'dart:async';
import 'dart:math' show pi, sin, cos;

import 'package:flutter/material.dart';
import '../services/zlibrary_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/staggered_entrance.dart';

/// z-library 登录/注册页面（扁平风、内容丰富、灵动）。
/// 一个全屏页面内用分段切换在「登录 / 注册」间过渡。
/// 登录或注册成功 pop(true)，取消 pop()。
/// 取代原 ZlibraryLoginDialog / ZlibraryRegisterDialog。
class ZlibraryAuthPage extends StatefulWidget {
  const ZlibraryAuthPage({super.key});

  @override
  State<ZlibraryAuthPage> createState() => _ZlibraryAuthPageState();
}

class _ZlibraryAuthPageState extends State<ZlibraryAuthPage>
    with TickerProviderStateMixin {
  // 模式
  bool _isLogin = true;

  // 登录表单
  final _emailCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  bool _obscureLogin = true;
  String? _loginError;

  // 注册表单
  final _regEmailCtrl = TextEditingController();
  final _regPwdCtrl = TextEditingController();
  final _regNameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _obscureReg = true;
  String? _regError;
  String? _regInfo;
  bool _sendingCode = false;
  int _countdown = 0;
  Timer? _countdownTimer;

  // 背景漂浮动画
  late final AnimationController _bgCtrl;

  @override
  void initState() {
    super.initState();
    _bgCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
  }

  @override
  void dispose() {
    _bgCtrl.dispose();
    _countdownTimer?.cancel();
    _emailCtrl.dispose();
    _pwdCtrl.dispose();
    _regEmailCtrl.dispose();
    _regPwdCtrl.dispose();
    _regNameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  // -------------------- 动作 --------------------

  Future<void> _doLogin() async {
    final email = _emailCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    if (email.isEmpty || pwd.isEmpty) {
      setState(() => _loginError = '请输入邮箱和密码');
      return;
    }
    setState(() => _loginError = null);
    final ok = await ZlibraryService().login(email, pwd);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _loginError = '登录失败，请检查邮箱与密码');
    }
  }

  Future<void> _sendCode() async {
    if (_countdown > 0 || _sendingCode) return;
    final email = _regEmailCtrl.text.trim();
    final pwd = _regPwdCtrl.text;
    final name = _regNameCtrl.text.trim();
    if (email.isEmpty || pwd.isEmpty || name.isEmpty) {
      setState(() => _regError = '请填写邮箱、密码和昵称');
      return;
    }
    setState(() {
      _regError = null;
      _regInfo = null;
      _sendingCode = true;
    });
    final ok = await ZlibraryService().sendCode(email, pwd, name);
    if (!mounted) return;
    setState(() => _sendingCode = false);
    if (ok) {
      setState(() {
        _regInfo = '验证码已发送到邮箱，请查收';
        _regError = null;
      });
      _startCountdown();
    } else {
      setState(() => _regError = '验证码发送失败，请稍后重试');
    }
  }

  Future<void> _doRegister() async {
    final email = _regEmailCtrl.text.trim();
    final pwd = _regPwdCtrl.text;
    final name = _regNameCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (email.isEmpty || pwd.isEmpty || name.isEmpty) {
      setState(() => _regError = '请填写邮箱、密码和昵称');
      return;
    }
    if (code.isEmpty) {
      setState(() => _regError = '请输入验证码');
      return;
    }
    setState(() => _regError = null);
    final ok = await ZlibraryService().register(email, pwd, name, code);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _regError = '注册失败，请检查验证码或稍后重试');
    }
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown -= 1);
      if (_countdown <= 0) t.cancel();
    });
  }

  // -------------------- UI --------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? JellyTheme.backgroundDark
          : JellyTheme.backgroundLight,
      body: Stack(
        children: [
          IgnorePointer(child: _buildAnimatedBackground()),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        StaggeredEntrance(index: 0, child: _buildBrand(isDark)),
                        const SizedBox(height: 20),
                        StaggeredEntrance(
                          index: 1,
                          child: _buildSegmentedToggle(isDark),
                        ),
                        const SizedBox(height: 18),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 320),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.05),
                                end: Offset.zero,
                              ).animate(anim),
                              child: child,
                            ),
                          ),
                          // 顶对齐：避免注册切回登录时较矮的登录表单居中导致的「上跳」
                          layoutBuilder: (currentChild, previousChildren) =>
                              Stack(
                            alignment: Alignment.topCenter,
                            children: <Widget>[
                              ...previousChildren,
                              ?currentChild,
                            ],
                          ),
                          child: _isLogin
                              ? _buildLoginForm(isDark)
                              : _buildRegisterForm(isDark),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// 背景缓慢漂浮的扁平色块（灵动）
  Widget _buildAnimatedBackground() {
    return AnimatedBuilder(
      animation: _bgCtrl,
      builder: (ctx, _) {
        final t = _bgCtrl.value * 2 * pi;
        return Stack(
          children: [
            Positioned(
              left: -70 + sin(t) * 26,
              top: -40 + cos(t * 1.2) * 20,
              child: _blob(JellyTheme.primary, 190, 0.10),
            ),
            Positioned(
              right: -60 + cos(t * 0.9) * 24,
              bottom: -70 + sin(t * 1.1) * 22,
              child: _blob(JellyTheme.accent, 210, 0.12),
            ),
            Positioned(
              right: 30 + sin(t * 1.3) * 18,
              top: 220 + cos(t) * 16,
              child: _blob(JellyTheme.primaryLight, 120, 0.08),
            ),
          ],
        );
      },
    );
  }

  Widget _blob(Color color, double size, double alpha) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: alpha),
      ),
    );
  }

  Widget _buildBrand(bool isDark) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: JellyTheme.primary.withValues(alpha: isDark ? 0.22 : 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Center(
            child: Image.asset(
              'assets/icons/logo.png',
              width: 36,
              height: 36,
              errorBuilder: (_, _, _) => Icon(
                Icons.menu_book_rounded,
                color: JellyTheme.primary,
                size: 32,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Cmbok',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: titleColor,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          '图书账号',
          style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
        ),
      ],
    );
  }

  /// 扁平分段切换：滑动指示器在「登录 / 注册」间过渡
  Widget _buildSegmentedToggle(bool isDark) {
    return LayoutBuilder(
      builder: (ctx, c) {
        const pad = 4.0;
        final segW = (c.maxWidth - pad * 2) / 2;
        return Container(
          padding: const EdgeInsets.all(pad),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2D2D4A) : const Color(0xFFEEF0F7),
            borderRadius: BorderRadius.circular(16),
          ),
          child: SizedBox(
            height: 42,
            child: Stack(
              children: [
                AnimatedPositioned(
                  left: _isLogin ? 0 : segW,
                  top: 0,
                  bottom: 0,
                  width: segW,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  child: Container(
                    decoration: BoxDecoration(
                      color: JellyTheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: _segLabel('登录', _isLogin)),
                    Expanded(child: _segLabel('注册', !_isLogin)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _segLabel(String text, bool selected) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _isLogin = text == '登录'),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : JellyTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  // ---------- 登录表单 ----------

  Widget _buildLoginForm(bool isDark) {
    return Column(
      key: const ValueKey('login'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StaggeredEntrance(index: 0, child: _buildBenefitsCard(isDark)),
        const SizedBox(height: 16),
        StaggeredEntrance(
          index: 1,
          child: _flatField(
            _emailCtrl,
            '邮箱',
            icon: Icons.mail_outline_rounded,
            keyboardType: TextInputType.emailAddress,
          ),
        ),
        const SizedBox(height: 12),
        StaggeredEntrance(
          index: 2,
          child: _flatField(
            _pwdCtrl,
            '密码',
            icon: Icons.lock_outline_rounded,
            obscure: _obscureLogin,
            suffix: IconButton(
              icon: Icon(
                _obscureLogin
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
                color: JellyTheme.textSecondary,
              ),
              onPressed: () => setState(() => _obscureLogin = !_obscureLogin),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _errorText(_loginError),
        const SizedBox(height: 6),
        StaggeredEntrance(
          index: 3,
          child: _PrimaryButton(label: '登录', onPressed: _doLogin),
        ),
        const SizedBox(height: 12),
        _switchHint('没有账号？去注册', () => setState(() => _isLogin = false)),
      ],
    );
  }

  /// 登录权益卡：真实配额（登录后 10 本/天 vs 内置 5 本/天）
  Widget _buildBenefitsCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: JellyTheme.primary.withValues(alpha: isDark ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: JellyTheme.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        children: [
          _benefitRow(
            Icons.check_circle_rounded,
            JellyTheme.success,
            '登录后每日可下载 ${ZlibraryService.loggedDailyLimit} 本',
          ),
          const SizedBox(height: 8),
          _benefitRow(
            Icons.info_outline_rounded,
            JellyTheme.textSecondary,
            '未登录内置账号 ${ZlibraryService.builtinDailyLimit} 本/天',
          ),
        ],
      ),
    );
  }

  Widget _benefitRow(IconData icon, Color color, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: JellyTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 注册表单 ----------

  Widget _buildRegisterForm(bool isDark) {
    return Column(
      key: const ValueKey('register'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StaggeredEntrance(index: 0, child: _buildRegisterInfoCard(isDark)),
        const SizedBox(height: 16),
        StaggeredEntrance(
          index: 1,
          child: _flatField(
            _regEmailCtrl,
            '邮箱',
            icon: Icons.mail_outline_rounded,
            keyboardType: TextInputType.emailAddress,
          ),
        ),
        const SizedBox(height: 12),
        StaggeredEntrance(
          index: 2,
          child: _flatField(
            _regPwdCtrl,
            '密码',
            icon: Icons.lock_outline_rounded,
            obscure: _obscureReg,
            suffix: IconButton(
              icon: Icon(
                _obscureReg
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
                color: JellyTheme.textSecondary,
              ),
              onPressed: () => setState(() => _obscureReg = !_obscureReg),
            ),
          ),
        ),
        const SizedBox(height: 12),
        StaggeredEntrance(
          index: 3,
          child: _flatField(
            _regNameCtrl,
            '昵称',
            icon: Icons.person_outline_rounded,
          ),
        ),
        const SizedBox(height: 12),
        StaggeredEntrance(
          index: 4,
          child: Row(
            children: [
              Expanded(
                child: _flatField(
                  _codeCtrl,
                  '验证码',
                  icon: Icons.verified_user_outlined,
                ),
              ),
              const SizedBox(width: 10),
              _sendCodeButton(),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _infoText(_regInfo),
        _errorText(_regError),
        const SizedBox(height: 6),
        StaggeredEntrance(
          index: 5,
          child: _PrimaryButton(label: '完成注册', onPressed: _doRegister),
        ),
        const SizedBox(height: 12),
        _switchHint('已有账号？去登录', () => setState(() => _isLogin = true)),
      ],
    );
  }

  Widget _buildRegisterInfoCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: JellyTheme.accent.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: JellyTheme.accent.withValues(alpha: 0.20)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.card_giftcard_rounded,
            size: 18,
            color: JellyTheme.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '注册自有账号，享每日 ${ZlibraryService.loggedDailyLimit} 本下载额度',
              style: const TextStyle(
                fontSize: 13,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sendCodeButton() {
    final disabled = _countdown > 0 || _sendingCode;
    final label = _countdown > 0 ? '${_countdown}s' : '发送验证码';
    return SizedBox(
      height: 52,
      child: FilledButton.tonal(
        onPressed: disabled ? null : _sendCode,
        style: FilledButton.styleFrom(
          backgroundColor: JellyTheme.primary.withValues(alpha: 0.12),
          foregroundColor: JellyTheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        child: _sendingCode
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: JellyTheme.primary,
                ),
              )
            : Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }

  // ---------- 通用组件 ----------

  Widget _flatField(
    TextEditingController ctrl,
    String hint, {
    IconData? icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: JellyTheme.textSecondary),
        prefixIcon: icon != null
            ? Icon(icon, size: 20, color: JellyTheme.textSecondary)
            : null,
        suffixIcon: suffix,
        filled: true,
        fillColor: isDark ? const Color(0xFF2D2D4A) : const Color(0xFFF2F3F8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
    );
  }

  Widget _errorText(String? msg) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: msg == null
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey(msg),
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                msg,
                style: const TextStyle(color: JellyTheme.error, fontSize: 12),
              ),
            ),
    );
  }

  Widget _infoText(String? msg) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: msg == null
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey(msg),
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                msg,
                style: const TextStyle(color: JellyTheme.success, fontSize: 12),
              ),
            ),
    );
  }

  Widget _switchHint(String text, VoidCallback onTap) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: JellyTheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// 扁平主按钮：按压缩放反馈 + loading 态
class _PrimaryButton extends StatefulWidget {
  final String label;
  final Future<void> Function() onPressed;
  const _PrimaryButton({required this.label, required this.onPressed});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _loading = false;
  bool _pressed = false;

  Future<void> _tap() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await widget.onPressed();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _loading ? null : (_) => setState(() => _pressed = true),
      onTapUp: _loading ? null : (_) => setState(() => _pressed = false),
      onTapCancel: _loading ? null : () => setState(() => _pressed = false),
      onTap: _loading ? null : _tap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: JellyTheme.primary,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: _loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    widget.label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
