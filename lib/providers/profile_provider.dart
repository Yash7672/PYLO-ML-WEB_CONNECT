import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/profile_model.dart';

class ProfileNotifier extends StateNotifier<Profile> {
  ProfileNotifier() : super(Profile()) {
    _loadProfile();
  }

  SharedPreferences? _cachedPrefs;

  Future<SharedPreferences> _getPrefs() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  Future<void> _loadProfile() async {
    try {
      final prefs = await _getPrefs();
      final profile = Profile(
        name: prefs.getString('profile_name') ?? state.name,
        email: prefs.getString('profile_email') ?? state.email,
        phone: prefs.getString('profile_phone') ?? state.phone,
        bio: prefs.getString('profile_bio') ?? state.bio,
        imagePath: prefs.getString('profile_image_path'),
      );
      state = profile;
    } catch (e) {
      debugPrint('Error loading profile: $e');
    }
  }

  Future<void> updateProfile(Profile profile) async {
    try {
      final prefs = await _getPrefs();
      // Batch all preference writes
      await Future.wait([
        prefs.setString('profile_name', profile.name),
        prefs.setString('profile_email', profile.email),
        prefs.setString('profile_phone', profile.phone),
        prefs.setString('profile_bio', profile.bio),
        if (profile.imagePath != null)
          prefs.setString('profile_image_path', profile.imagePath!)
        else
          prefs.remove('profile_image_path'),
      ]);
      state = profile;
    } catch (e) {
      debugPrint('Error updating profile: $e');
    }
  }
}

final profileProvider =
    StateNotifierProvider<ProfileNotifier, Profile>((ref) => ProfileNotifier());
