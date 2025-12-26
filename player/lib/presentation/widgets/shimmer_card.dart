import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/app_theme.dart';

class ShimmerCard extends StatelessWidget {
  final double width;
  final double height;

  const ShimmerCard({
    super.key,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.shimmerBase,
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
      ),
    );
  }
}

class ShimmerRail extends StatelessWidget {
  final double cardWidth;
  final double cardHeight;
  final int count;

  const ShimmerRail({
    super.key,
    this.cardWidth = 120,
    this.cardHeight = 180,
    this.count = 5,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Shimmer.fromColors(
            baseColor: AppColors.shimmerBase,
            highlightColor: AppColors.shimmerHighlight,
            child: Container(
              width: 150,
              height: 20,
              decoration: BoxDecoration(
                color: AppColors.shimmerBase,
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
              ),
            ),
          ),
        ),
        SizedBox(
          height: cardHeight + 40,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: count,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ShimmerCard(width: cardWidth, height: cardHeight),
              );
            },
          ),
        ),
      ],
    );
  }
}
