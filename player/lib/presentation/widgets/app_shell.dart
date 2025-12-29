import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/config/web_config.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/layout/breakpoints.dart';
import '../../core/theme/colors.dart';

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

  void _onItemTapped(int index) {
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= Breakpoints.tablet;

        if (isDesktop) {
          return Scaffold(
            body: Row(
              children: [
                _DesktopSidebar(
                  selectedIndex: selectedIndex,
                  onItemTapped: _onItemTapped,
                  showBackToMydia: showBackToMydia,
                ),
                Expanded(child: widget.child),
              ],
            ),
          );
        }

        return Scaffold(
          body: Stack(
            children: [
              widget.child,
              if (showBackToMydia)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 8,
                  child: const _BackToMydiaButton(compact: true),
                ),
            ],
          ),
          bottomNavigationBar: _ModernBottomNav(
            selectedIndex: selectedIndex,
            onItemTapped: _onItemTapped,
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

  const _DesktopSidebar({
    required this.selectedIndex,
    required this.onItemTapped,
    this.showBackToMydia = false,
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
                          onTap: () => onItemTapped(0),
                        ),
                        const SizedBox(height: 4),
                        _SidebarItem(
                          icon: Icons.movie_outlined,
                          selectedIcon: Icons.movie_rounded,
                          label: 'Movies',
                          isSelected: selectedIndex == 1,
                          onTap: () => onItemTapped(1),
                        ),
                        const SizedBox(height: 4),
                        _SidebarItem(
                          icon: Icons.tv_outlined,
                          selectedIcon: Icons.tv_rounded,
                          label: 'TV Shows',
                          isSelected: selectedIndex == 2,
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
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isSelected || _isHovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: widget.isSelected
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
                  color: widget.isSelected
                      ? AppColors.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Icon(
                widget.isSelected ? widget.selectedIcon : widget.icon,
                size: 22,
                color: isActive ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: 14),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
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

  const _ModernBottomNav({
    required this.selectedIndex,
    required this.onItemTapped,
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
                onTap: () => onItemTapped(0),
              ),
              _NavItem(
                icon: Icons.movie_outlined,
                selectedIcon: Icons.movie_rounded,
                label: 'Movies',
                isSelected: selectedIndex == 1,
                onTap: () => onItemTapped(1),
              ),
              _NavItem(
                icon: Icons.tv_outlined,
                selectedIcon: Icons.tv_rounded,
                label: 'Shows',
                isSelected: selectedIndex == 2,
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
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
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
            color: widget.isSelected
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
                  widget.isSelected ? widget.selectedIcon : widget.icon,
                  key: ValueKey(widget.isSelected),
                  color: widget.isSelected
                      ? AppColors.primary
                      : AppColors.textSecondary,
                  size: 24,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight:
                      widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: widget.isSelected
                      ? AppColors.primary
                      : AppColors.textSecondary,
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
