# task_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## GitHub Pages Deployment

This repository is configured to deploy the Flutter web build to GitHub Pages using the workflow in `.github/workflows/flutter_web_pages.yml`.

To deploy:

1. Push your changes to the `main` branch.
2. GitHub Actions will build the web app and publish the output from `build/web`.
3. Enable GitHub Pages in repository settings and select the `gh-pages` branch.

You can also run the workflow manually from the Actions tab.

## Release Android build (cloud sync)

The release APK reads its Supabase publishable/anon key from the build-time
define `SUPABASE_ANON_KEY` (see `lib/services/cloud/supabase_config.dart`).
Without it the APK is built with cloud sync disabled and Settings shows
"Cloud sync not configured".

### One-time setup

1. Copy `dart_defines/.env.local.example` to `dart_defines/.env.local`.
2. Set `SUPABASE_ANON_KEY=<your anon/public key>` in that file.
   `dart_defines/.env.local` is git-ignored — the key never enters the repo.
   Never use a `service_role`/secret key here.

### Build the release APK

```
powershell -ExecutionPolicy Bypass -File .\build_release_apk.ps1
```

The script fails fast if the key is missing or empty, so a release APK can
never be produced with cloud sync accidentally disabled. Use `-Arm64Only` for
an ARM64-only APK. Manual equivalent:

```
flutter build apk --release --dart-define-from-file=dart_defines/.env.local
```

The GitHub Actions `build-apk` job reads the key from the `SUPABASE_ANON_KEY`
repository secret and refuses to build when the secret is unset.
