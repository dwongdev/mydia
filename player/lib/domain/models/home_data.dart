import 'continue_watching_item.dart';
import 'recently_added_item.dart';
import 'up_next_item.dart';

class HomeData {
  final List<ContinueWatchingItem> continueWatching;
  final List<RecentlyAddedItem> recentlyAdded;
  final List<UpNextItem> upNext;
  final List<RecentlyAddedItem> favorites;

  const HomeData({
    required this.continueWatching,
    required this.recentlyAdded,
    required this.upNext,
    required this.favorites,
  });

  factory HomeData.fromJson(Map<String, dynamic> json) {
    return HomeData(
      continueWatching: (json['continueWatching'] as List<dynamic>?)
              ?.map((e) =>
                  ContinueWatchingItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      recentlyAdded: (json['recentlyAdded'] as List<dynamic>?)
              ?.map(
                  (e) => RecentlyAddedItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      upNext: (json['upNext'] as List<dynamic>?)
              ?.map((e) => UpNextItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      favorites: (json['favorites'] as List<dynamic>?)
              ?.map(
                  (e) => RecentlyAddedItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  bool get isEmpty =>
      continueWatching.isEmpty &&
      recentlyAdded.isEmpty &&
      upNext.isEmpty &&
      favorites.isEmpty;
}
