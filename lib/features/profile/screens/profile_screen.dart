import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/widgets/glass_components.dart';
import '../../../models/profile_model.dart';
import '../../../providers/profile_provider.dart';
import '../../../theme/app_theme.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _isEditing = false;
  bool? _imageExists;
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;
  late final TextEditingController _bioController;

  @override
  void initState() {
    super.initState();
    final profile = ref.read(profileProvider);
    _nameController = TextEditingController(text: profile.name);
    _emailController = TextEditingController(text: profile.email);
    _phoneController = TextEditingController(text: profile.phone);
    _bioController = TextEditingController(text: profile.bio);
    _checkImageExists(profile.imagePath);
  }

  Future<void> _checkImageExists(String? path) async {
    if (path == null || path.isEmpty) {
      if (mounted) setState(() => _imageExists = false);
      return;
    }
    final exists = await File(path).exists();
    if (mounted) setState(() => _imageExists = exists);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final current = ref.read(profileProvider);
    final updated = Profile(
      name: _nameController.text.trim(),
      email: _emailController.text.trim(),
      phone: _phoneController.text.trim(),
      bio: _bioController.text.trim(),
      imagePath: current.imagePath,
    );
    await ref.read(profileProvider.notifier).updateProfile(updated);
    if (mounted) {
      setState(() => _isEditing = false);
    }
  }

  Future<void> _pickImage() async {
    try {
      final results = await FilePicker.pickFiles(
        type: FileType.image,
      );
      if (results.isEmpty) return;

      final pickedFile = results.first;
      if (pickedFile.path == null) return;

      if (!mounted) return;
      final theme = Theme.of(context);
      final croppedFile = await ImageCropper().cropImage(
        sourcePath: pickedFile.path!,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Photo',
            toolbarColor: theme.colorScheme.surface,
            toolbarWidgetColor: theme.colorScheme.onSurface,
            initAspectRatio: CropAspectRatioPreset.square,
            lockAspectRatio: true,
            aspectRatioPresets: [CropAspectRatioPreset.square],
          ),
          IOSUiSettings(
            title: 'Crop Photo',
            aspectRatioLockEnabled: true,
            resetAspectRatioEnabled: false,
            aspectRatioPresets: [CropAspectRatioPreset.square],
          ),
        ],
      );
      if (croppedFile == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final savedPath = '${appDir.path}/profile_image.jpg';
      await File(croppedFile.path).copy(savedPath);

      final currentProfile = ref.read(profileProvider);
      final updated = currentProfile.copyWith(imagePath: savedPath);
      await ref.read(profileProvider.notifier).updateProfile(updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick image: $e')),
        );
      }
    }
  }

  Future<void> _removeImage() async {
    final currentProfile = ref.read(profileProvider);
    if (currentProfile.imagePath != null) {
      final file = File(currentProfile.imagePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
    final updated = currentProfile.copyWith(clearImage: true);
    await ref.read(profileProvider.notifier).updateProfile(updated);
  }

  void _showRemovePhotoDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove photo?'),
        content: const Text(
            'Your profile photo will be removed. Your name, email, phone, and bio will remain.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _removeImage();
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(Profile profile, ThemeData theme) {
    final hasImage = _imageExists == true;

    return GestureDetector(
      onTap: _pickImage,
      child: Stack(
        children: [
          CircleAvatar(
            radius: 42,
            backgroundColor: theme.colorScheme.primary,
            backgroundImage: hasImage
                ? ResizeImage(FileImage(File(profile.imagePath!)), width: 256)
                : null,
            child: hasImage
                ? null
                : Text(
                    profile.name.trim().isEmpty
                        ? 'U'
                        : profile.name.trim()[0].toUpperCase(),
                    style: TextStyle(
                        fontSize: 32,
                        color: isGlassTheme(context)
                            ? GlassColors.onAccent
                            : Colors.white),
                  ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(
                    color: isGlassTheme(context)
                        ? GlassColors.surfaceOpaqueDark
                        : Colors.white,
                    width: 2),
              ),
              child: Icon(Icons.camera_alt,
                  size: 16,
                  color: isGlassTheme(context)
                      ? GlassColors.onAccent
                      : Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final hasImage = _imageExists == true;

    // Re-check image existence when profile changes.
    ref.listen<Profile>(profileProvider, (prev, next) {
      if (prev?.imagePath != next.imagePath) {
        _checkImageExists(next.imagePath);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            icon: Icon(_isEditing ? Icons.check : Icons.edit),
            onPressed: () async {
              if (_isEditing) {
                await _saveProfile();
              } else {
                setState(() => _isEditing = true);
              }
            },
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Card(
          shape:
              const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildAvatar(profile, Theme.of(context)),
                const SizedBox(height: 8),
                if (hasImage)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _pickImage,
                        icon: const Icon(Icons.camera_alt, size: 16),
                        label: const Text('Change photo'),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _showRemovePhotoDialog,
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Remove photo'),
                      ),
                    ],
                  )
                else
                  TextButton.icon(
                    onPressed: _pickImage,
                    icon: const Icon(Icons.add_a_photo, size: 16),
                    label: const Text('Add photo'),
                  ),
                const SizedBox(height: 16),
                if (!_isEditing) ...[
                  Text(profile.name,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(profile.bio,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: isGlassTheme(context)
                              ? GlassColors.textSecondary
                              : Colors.grey[700])),
                  const SizedBox(height: 24),
                  ListTile(
                    leading: const Icon(Icons.email),
                    title: const Text('Email'),
                    subtitle: Text(profile.email),
                  ),
                  ListTile(
                    leading: const Icon(Icons.phone),
                    title: const Text('Phone'),
                    subtitle: Text(profile.phone),
                  ),
                ] else ...[
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailController,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phoneController,
                    decoration: const InputDecoration(labelText: 'Phone'),
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _bioController,
                    decoration: const InputDecoration(labelText: 'Bio'),
                    maxLines: 3,
                  ),
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }
}
