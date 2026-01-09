import 'dart:ui';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_status.dart';
import '../../core/config/web_config.dart';
import '../../core/connection/connection_provider.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/graphql/graphql_provider.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';
import 'offline_banner.dart';

/// A small glowing dot indicator for relay mode.
/// Shows an animated orange/yellow glow when the app is connected via relay.
class _RelayModeIndicator extends ConsumerWidget {
  const _RelayModeIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);

    if (!connectionState.isRelayMode) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: connectionState.isTunnelActive
          ? 'Connected via relay'
          : 'Relay disconnected',
      child: _GlowingDot(isActive: connectionState.isTunnelActive),
    );
  }
}

/// Animated glowing dot with pulse effect.
class _GlowingDot extends StatefulWidget {
  final bool isActive;

  const _GlowingDot({required this.isActive});

  @override
  State<_GlowingDot> createState() => _GlowingDotState();
}

class _GlowingDotState extends State<_GlowingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    if (widget.isActive) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_GlowingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isActive && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isActive ? Colors.orange : Colors.red;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.6 * _animation.value),
                blurRadius: 8 * _animation.value,
                spreadRadius: 2 * _animation.value,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Modern app shell with adaptive navigation.
/// Shows sidebar on desktop (≥900px) and bottom nav on mobile.
class AppShell extends ConsumerStatefulWidget {
  final Widget child;
  final String location;

  const AppShell({
    super.key,
    required this.child,
    required this.location,
  });

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  AppLifecycleListener? _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // Only add lifecycle listener on native platforms (not web)
    if (!kIsWeb) {
      _lifecycleListener = AppLifecycleListener(
        onResume: _onAppResume,
      );
    }
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    super.dispose();
  }

  /// Called when app resumes from background.
  /// Checks if relay tunnel is dead and triggers reconnection.
  void _onAppResume() {
    debugPrint('[AppShell] App resumed from background');
    final connectionState = ref.read(connectionProvider);

    // Check if we were in relay mode but tunnel is now dead
    if (connectionState.isRelayMode && !connectionState.isTunnelActive) {
      debugPrint('[AppShell] Relay tunnel died while in background, reconnecting...');
      // Trigger full reconnection (includes key exchange)
      ref.read(authStateProvider.notifier).retryConnection();
    }
  }

  int _getSelectedIndex() {
    final location = widget.location;
    if (location.startsWith('/movies')) return 1;
    if (location.startsWith('/shows')) return 2;
    if (isDownloadSupported) {
      if (location.startsWith('/downloads')) return 3;
      if (location.startsWith('/settings')) return 4;
    } else {
      // On web, settings is at index 3 (no downloads)
      if (location.startsWith('/settings')) return 3;
    }
    return 0; // Home
  }

  /// Check if the app is currently in offline mode
  bool _isOfflineMode() {
    final authState = ref.watch(authStateProvider);
    return authState.maybeWhen(
      data: (status) => status == AuthStatus.offlineMode,
      orElse: () => false,
    );
  }

  /// Show a snackbar when a disabled nav item is tapped in offline mode
  void _showOfflineSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Connect to server to access this'),
        backgroundColor: AppColors.surfaceVariant,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  void _onItemTapped(int index, {bool isOffline = false}) {
    // In offline mode, only allow Downloads (index 3 when downloads supported)
    if (isOffline) {
      final downloadsIndex = isDownloadSupported ? 3 : -1;
      if (index != downloadsIndex) {
        _showOfflineSnackbar();
        return;
      }
    }

    switch (index) {
      case 0:
        context.go('/');
        break;
      case 1:
        context.go('/movies');
        break;
      case 2:
        context.go('/shows');
        break;
      case 3:
        if (isDownloadSupported) {
          context.go('/downloads');
        } else {
          context.go('/settings');
        }
        break;
      case 4:
        context.go('/settings');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = _getSelectedIndex();
    final showBackToMydia = isEmbedMode;
    final isOffline = _isOfflineMode();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= Breakpoints.tablet;

        if (isDesktop) {
          return Scaffold(
            body: Row(
              children: [
                _DesktopSidebar(
                  selectedIndex: selectedIndex,
                  onItemTapped: (index) => _onItemTapped(index, isOffline: isOffline),
                  showBackToMydia: showBackToMydia,
                  isOffline: isOffline,
                ),
                Expanded(
                  child: Column(
                    children: [
                      if (isOffline) const OfflineBanner(),
                      Expanded(child: widget.child),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          body: Column(
            children: [
              if (isOffline) const OfflineBanner(),
              Expanded(
                child: Stack(
                  children: [
                    widget.child,
                    if (showBackToMydia)
                      Positioned(
                        top: MediaQuery.of(context).padding.top + 8,
                        left: 8,
                        child: const _BackToMydiaButton(compact: true),
                      ),
                    // Relay mode indicator for mobile
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 12,
                      right: 12,
                      child: const _RelayModeIndicator(),
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: _ModernBottomNav(
            selectedIndex: selectedIndex,
            onItemTapped: (index) => _onItemTapped(index, isOffline: isOffline),
            isOffline: isOffline,
          ),
        );
      },
    );
  }
}

/// Desktop sidebar navigation with full labels
class _DesktopSidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemTapped;
  final bool showBackToMydia;
  final bool isOffline;

  const _DesktopSidebar({
    required this.selectedIndex,
    required this.onItemTapped,
    this.showBackToMydia = false,
    this.isOffline = false,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: Breakpoints.sidebarWidth,
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.95),
            border: Border(
              right: BorderSide(
                color: AppColors.divider.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
          ),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Back to Mydia link (shown in embed mode)
                if (showBackToMydia)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: _BackToMydiaButton(),
                  ),
                // Logo header
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      20, showBackToMydia ? 16 : 24, 20, 32),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [AppColors.primary, AppColors.secondary],
                          ),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Mydia',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const _RelayModeIndicator(),
                    ],
                  ),
                ),

                // Navigation items
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      children: [
                        _SidebarItem(
                          icon: Icons.home_outlined,
                          selectedIcon: Icons.home_rounded,
                          label: 'Home',
                          isSelected: selectedIndex == 0,
                          isDisabled: isOffline,
                          onTap: () => onItemTapped(0),
                        ),
                        const SizedBox(height: 4),
                        _SidebarItem(
                          icon: Icons.movie_outlined,
                          selectedIcon: Icons.movie_rounded,
                          label: 'Movies',
                          isSelected: selectedIndex == 1,
                          isDisabled: isOffline,
                          onTap: () => onItemTapped(1),
                        ),
                        const SizedBox(height: 4),
                        _SidebarItem(
                          icon: Icons.tv_outlined,
                          selectedIcon: Icons.tv_rounded,
                          label: 'TV Shows',
                          isSelected: selectedIndex == 2,
                          isDisabled: isOffline,
                          onTap: () => onItemTapped(2),
                        ),
                        if (isDownloadSupported) ...[
                          const SizedBox(height: 4),
                          _SidebarItem(
                            icon: Icons.download_outlined,
                            selectedIcon: Icons.download_rounded,
                            label: 'Downloads',
                            isSelected: selectedIndex == 3,
                            onTap: () => onItemTapped(3),
                          ),
                        ],
                        const Spacer(),
                        _SidebarItem(
                          icon: Icons.settings_outlined,
                          selectedIcon: Icons.settings_rounded,
                          label: 'Settings',
                          isSelected: isDownloadSupported
                              ? selectedIndex == 4
                              : selectedIndex == 3,
                          isDisabled: isOffline,
                          onTap: () => onItemTapped(isDownloadSupported ? 4 : 3),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Individual sidebar navigation item
class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isDisabled = false,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = !widget.isDisabled && (widget.isSelected || _isHovered);
    final effectiveColor = widget.isDisabled
        ? AppColors.textDisabled
        : isActive
            ? AppColors.primary
            : AppColors.textSecondary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.isDisabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: widget.isDisabled
                ? Colors.transparent
                : widget.isSelected
                    ? AppColors.primary.withValues(alpha: 0.15)
                    : _isHovered
                        ? AppColors.surfaceVariant.withValues(alpha: 0.5)
                        : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              // Active indicator bar
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 3,
                height: 24,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: widget.isSelected && !widget.isDisabled
                      ? AppColors.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Icon(
                widget.isSelected && !widget.isDisabled ? widget.selectedIcon : widget.icon,
                size: 22,
                color: effectiveColor,
              ),
              const SizedBox(width: 14),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: widget.isSelected && !widget.isDisabled ? FontWeight.w600 : FontWeight.w500,
                  color: widget.isDisabled
                      ? AppColors.textDisabled
                      : isActive
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mobile bottom navigation bar
class _ModernBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemTapped;
  final bool isOffline;

  const _ModernBottomNav({
    required this.selectedIndex,
    required this.onItemTapped,
    this.isOffline = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(
            color: AppColors.divider.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home_rounded,
                label: 'Home',
                isSelected: selectedIndex == 0,
                isDisabled: isOffline,
                onTap: () => onItemTapped(0),
              ),
              _NavItem(
                icon: Icons.movie_outlined,
                selectedIcon: Icons.movie_rounded,
                label: 'Movies',
                isSelected: selectedIndex == 1,
                isDisabled: isOffline,
                onTap: () => onItemTapped(1),
              ),
              _NavItem(
                icon: Icons.tv_outlined,
                selectedIcon: Icons.tv_rounded,
                label: 'Shows',
                isSelected: selectedIndex == 2,
                isDisabled: isOffline,
                onTap: () => onItemTapped(2),
              ),
              if (isDownloadSupported)
                _NavItem(
                  icon: Icons.download_outlined,
                  selectedIcon: Icons.download_rounded,
                  label: 'Downloads',
                  isSelected: selectedIndex == 3,
                  onTap: () => onItemTapped(3),
                ),
              _NavItem(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings_rounded,
                label: 'Settings',
                isSelected: isDownloadSupported
                    ? selectedIndex == 4
                    : selectedIndex == 3,
                isDisabled: isOffline,
                onTap: () => onItemTapped(isDownloadSupported ? 4 : 3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isDisabled = false,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    _controller.forward();
  }

  void _handleTapUp(TapUpDetails details) {
    _controller.reverse();
    widget.onTap();
  }

  void _handleTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.isDisabled
        ? AppColors.textDisabled
        : widget.isSelected
            ? AppColors.primary
            : AppColors.textSecondary;

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: widget.isSelected && !widget.isDisabled
                ? AppColors.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  widget.isSelected && !widget.isDisabled ? widget.selectedIcon : widget.icon,
                  key: ValueKey('${widget.isSelected}_${widget.isDisabled}'),
                  color: effectiveColor,
                  size: 24,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight:
                      widget.isSelected && !widget.isDisabled ? FontWeight.w600 : FontWeight.w500,
                  color: effectiveColor,
                ),
                child: Text(widget.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Button to navigate back to the main Mydia app.
/// Shown when the player is running in embed mode.
class _BackToMydiaButton extends StatefulWidget {
  final bool compact;

  const _BackToMydiaButton({this.compact = false});

  @override
  State<_BackToMydiaButton> createState() => _BackToMydiaButtonState();
}

class _BackToMydiaButtonState extends State<_BackToMydiaButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.compact) {
      // Compact floating button for mobile
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: navigateToMydiaApp,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.divider.withValues(alpha: 0.3),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.arrow_back_rounded,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
                SizedBox(width: 6),
                Text(
                  'Back to Mydia',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Full sidebar button
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: navigateToMydiaApp,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _isHovered
                ? AppColors.surfaceVariant.withValues(alpha: 0.5)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Icons.arrow_back_rounded,
                size: 20,
                color: _isHovered ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Text(
                'Back to Mydia',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color:
                      _isHovered ? AppColors.textPrimary : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
