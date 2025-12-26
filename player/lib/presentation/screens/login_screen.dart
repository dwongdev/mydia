import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/graphql/graphql_provider.dart';
import '../../core/theme/colors.dart';
import 'login/login_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _claimCodeController = TextEditingController();
  final _serverUrlFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _claimCodeFocus = FocusNode();

  bool _isLoadingSavedUrl = true;
  bool _obscurePassword = true;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _loadSavedServerUrl();
    _setupAnimations();
  }

  void _setupAnimations() {
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    _animationController.forward();
  }

  Future<void> _loadSavedServerUrl() async {
    final authService = ref.read(authServiceProvider);
    final savedUrl = await authService.getServerUrl();
    if (mounted) {
      setState(() {
        if (savedUrl != null) {
          _serverUrlController.text = savedUrl;
        }
        _isLoadingSavedUrl = false;
      });
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _claimCodeController.dispose();
    _serverUrlFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _claimCodeFocus.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final controller = ref.read(loginControllerProvider.notifier);
    await controller.login(
      _serverUrlController.text.trim(),
      _usernameController.text.trim(),
      _passwordController.text,
    );

    if (mounted) {
      final state = ref.read(loginControllerProvider);
      if (state.success) {
        context.go('/');
      }
    }
  }

  Future<void> _handleClaimCodeSubmit() async {
    final code = _claimCodeController.text.trim().toUpperCase();
    if (code.isEmpty) return;

    final controller = ref.read(loginControllerProvider.notifier);
    await controller.pairWithClaimCode(code);

    if (mounted) {
      final state = ref.read(loginControllerProvider);
      if (state.success) {
        context.go('/');
      }
    }
  }

  void _selectClaimCodeMode() {
    ref.read(loginControllerProvider.notifier).setMode(ConnectionMode.claimCode);
    _claimCodeController.clear();
  }

  void _selectDirectMode() {
    ref.read(loginControllerProvider.notifier).setMode(ConnectionMode.direct);
  }

  void _goBack() {
    ref.read(loginControllerProvider.notifier).goBackToSelection();
  }

  @override
  Widget build(BuildContext context) {
    final loginState = ref.watch(loginControllerProvider);
    final size = MediaQuery.of(context).size;
    final isCompact = size.height < 700;

    return Scaffold(
      body: Container(
        width: size.width,
        height: size.height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.background,
              Color(0xFF162032),
              AppColors.background,
            ],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: Stack(
          children: [
            _buildBackgroundDecoration(),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: isCompact ? 16 : 24,
                  ),
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildLogo(isCompact),
                          SizedBox(height: isCompact ? 24 : 32),
                          _buildContent(loginState, isCompact),
                          const SizedBox(height: 16),
                          _buildFooter(loginState),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(LoginState loginState, bool isCompact) {
    switch (loginState.mode) {
      case ConnectionMode.selection:
        return _buildModeSelectionCard(isCompact);
      case ConnectionMode.claimCode:
        return _buildClaimCodeCard(loginState, isCompact);
      case ConnectionMode.direct:
        return _buildDirectConnectionCard(loginState, isCompact);
    }
  }

  Widget _buildBackgroundDecoration() {
    return Stack(
      children: [
        Positioned(
          top: -80,
          right: -80,
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.primary.withValues(alpha: 0.12),
                  AppColors.primary.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -100,
          left: -80,
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.secondary.withValues(alpha: 0.08),
                  AppColors.secondary.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogo(bool isCompact) {
    final logoSize = isCompact ? 56.0 : 64.0;
    final iconSize = isCompact ? 32.0 : 36.0;
    final titleSize = isCompact ? 28.0 : 32.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: logoSize,
          height: logoSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primary, AppColors.secondary],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Icon(
            Icons.play_circle_filled_rounded,
            size: iconSize,
            color: Colors.white,
          ),
        ),
        SizedBox(height: isCompact ? 12 : 16),
        Text(
          'Mydia',
          style: TextStyle(
            fontSize: titleSize,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Stream your media library',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  // ===== MODE SELECTION =====
  Widget _buildModeSelectionCard(bool isCompact) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: EdgeInsets.all(isCompact ? 20 : 24),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.border.withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Welcome',
                  style: TextStyle(
                    fontSize: isCompact ? 20 : 22,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Connect to your Mydia server',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary.withValues(alpha: 0.7),
                  ),
                ),
                SizedBox(height: isCompact ? 24 : 32),

                // Claim Code Button (Primary)
                _buildModeButton(
                  onPressed: _selectClaimCodeMode,
                  icon: Icons.qr_code_rounded,
                  title: 'Enter Claim Code',
                  subtitle: 'Get a code from your server admin',
                  isPrimary: true,
                ),

                const SizedBox(height: 16),

                // Divider with "or"
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 1,
                        color: AppColors.border.withValues(alpha: 0.2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'or',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        height: 1,
                        color: AppColors.border.withValues(alpha: 0.2),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Direct Connection Button (Secondary)
                _buildModeButton(
                  onPressed: _selectDirectMode,
                  icon: Icons.dns_outlined,
                  title: 'Direct Connection',
                  subtitle: 'Advanced: Enter server URL directly',
                  isPrimary: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isPrimary,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isPrimary
                ? AppColors.primary.withValues(alpha: 0.1)
                : AppColors.surfaceVariant.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isPrimary
                  ? AppColors.primary.withValues(alpha: 0.3)
                  : AppColors.border.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isPrimary
                      ? AppColors.primary.withValues(alpha: 0.15)
                      : AppColors.surfaceVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: isPrimary ? AppColors.primary : AppColors.textSecondary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isPrimary ? AppColors.primary : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: isPrimary
                    ? AppColors.primary.withValues(alpha: 0.6)
                    : AppColors.textSecondary.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===== CLAIM CODE ENTRY =====
  Widget _buildClaimCodeCard(LoginState loginState, bool isCompact) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: EdgeInsets.all(isCompact ? 20 : 24),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.border.withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Back button and title
                Row(
                  children: [
                    IconButton(
                      onPressed: loginState.isLoading ? null : _goBack,
                      icon: const Icon(Icons.arrow_back_rounded),
                      iconSize: 20,
                      color: AppColors.textSecondary,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Enter Claim Code',
                        style: TextStyle(
                          fontSize: isCompact ? 18 : 20,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 40),
                  child: Text(
                    'Ask your server admin for a claim code',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                SizedBox(height: isCompact ? 20 : 24),

                // Claim code input (no server URL needed - relay looks it up)
                _buildClaimCodeInput(loginState),

                if (loginState.claimCodeMessage != null &&
                    loginState.claimCodeStatus != ClaimCodeStatus.error) ...[
                  const SizedBox(height: 16),
                  _buildProgressIndicator(loginState),
                ],

                if (loginState.error != null) ...[
                  const SizedBox(height: 14),
                  _buildErrorMessage(loginState.error!),
                ],

                SizedBox(height: isCompact ? 20 : 24),
                _buildClaimCodeButton(loginState),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClaimCodeInput(LoginState loginState) {
    return TextFormField(
      controller: _claimCodeController,
      focusNode: _claimCodeFocus,
      enabled: !loginState.isLoading,
      textAlign: TextAlign.center,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
        LengthLimitingTextInputFormatter(8),
        UpperCaseTextFormatter(),
      ],
      onFieldSubmitted: (_) => _handleClaimCodeSubmit(),
      style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
        letterSpacing: 4,
      ),
      decoration: InputDecoration(
        hintText: 'ABC123',
        hintStyle: TextStyle(
          color: AppColors.textDisabled.withValues(alpha: 0.4),
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: 4,
        ),
        filled: true,
        fillColor: AppColors.surfaceVariant.withValues(alpha: 0.4),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.border.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildProgressIndicator(LoginState loginState) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              loginState.claimCodeMessage ?? '',
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClaimCodeButton(LoginState loginState) {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: loginState.isLoading ? null : _handleClaimCodeSubmit,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: loginState.isLoading
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Connect',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(Icons.link_rounded, size: 18),
                ],
              ),
      ),
    );
  }

  // ===== DIRECT CONNECTION =====
  Widget _buildDirectConnectionCard(LoginState loginState, bool isCompact) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: EdgeInsets.all(isCompact ? 20 : 24),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.border.withValues(alpha: 0.2),
              ),
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Back button and title
                  Row(
                    children: [
                      IconButton(
                        onPressed: loginState.isLoading ? null : _goBack,
                        icon: const Icon(Icons.arrow_back_rounded),
                        iconSize: 20,
                        color: AppColors.textSecondary,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Direct Connection',
                          style: TextStyle(
                            fontSize: isCompact ? 18 : 20,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 40),
                    child: Text(
                      'Enter your server details',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  SizedBox(height: isCompact ? 20 : 24),

                  if (_isLoadingSavedUrl)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    )
                  else ...[
                    _buildTextField(
                      controller: _serverUrlController,
                      focusNode: _serverUrlFocus,
                      label: 'Server URL',
                      hint: 'https://mydia.example.com',
                      icon: Icons.dns_outlined,
                      enabled: !loginState.isLoading,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _usernameFocus.requestFocus(),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter a server URL';
                        }
                        if (!value.startsWith('http://') &&
                            !value.startsWith('https://')) {
                          return 'URL must start with http:// or https://';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    _buildTextField(
                      controller: _usernameController,
                      focusNode: _usernameFocus,
                      label: 'Username',
                      icon: Icons.person_outline_rounded,
                      enabled: !loginState.isLoading,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter a username';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    _buildTextField(
                      controller: _passwordController,
                      focusNode: _passwordFocus,
                      label: 'Password',
                      icon: Icons.lock_outline_rounded,
                      enabled: !loginState.isLoading,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _handleLogin(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: AppColors.textSecondary,
                          size: 18,
                        ),
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter a password';
                        }
                        return null;
                      },
                    ),
                    if (loginState.error != null) ...[
                      const SizedBox(height: 14),
                      _buildErrorMessage(loginState.error!),
                    ],
                    SizedBox(height: isCompact ? 20 : 24),
                    _buildLoginButton(loginState),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required IconData icon,
    required bool enabled,
    required String? Function(String?) validator,
    String? hint,
    bool obscureText = false,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    Widget? suffixIcon,
    void Function(String)? onFieldSubmitted,
  }) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(
          fontSize: 13,
          color: AppColors.textSecondary.withValues(alpha: 0.8),
        ),
        hintStyle: TextStyle(
          color: AppColors.textDisabled.withValues(alpha: 0.5),
          fontSize: 13,
        ),
        prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 18),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: AppColors.surfaceVariant.withValues(alpha: 0.4),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: AppColors.border.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5),
        ),
        errorStyle: const TextStyle(color: AppColors.error, fontSize: 11),
      ),
    );
  }

  Widget _buildErrorMessage(String error) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(
                color: AppColors.error,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginButton(LoginState loginState) {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: loginState.isLoading ? null : _handleLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: loginState.isLoading
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Sign in',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
      ),
    );
  }

  Widget _buildFooter(LoginState loginState) {
    final icon = loginState.mode == ConnectionMode.claimCode
        ? Icons.lock_rounded
        : Icons.shield_outlined;
    final text = loginState.mode == ConnectionMode.claimCode
        ? 'End-to-end encrypted'
        : 'Secure connection';

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          icon,
          size: 12,
          color: AppColors.textSecondary.withValues(alpha: 0.4),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }
}

/// Text input formatter that converts text to uppercase.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
