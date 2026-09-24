# PYLO Widget providers - must not be stripped by R8/ProGuard
-keep class com.example.task_app.PyloHomeWidgetProvider { *; }
-keep class com.example.task_app.PyloHabitsWidgetProvider { *; }
-keep class com.example.task_app.PyloProgressWidgetProvider { *; }
-keep class com.example.task_app.PyloQuickAddWidgetProvider { *; }
-keep class com.example.task_app.PyloFocusWidgetProvider { *; }
-keep class com.example.task_app.PyloChecklistWidgetProvider { *; }
-keep class com.example.task_app.PyloBirthdaysWidgetProvider { *; }
-keep class com.example.task_app.WidgetBootReceiver { *; }

# home_widget package
-keep class es.antonborri.home_widget.** { *; }

# Flutter generated plugin registrant
-keep class io.flutter.plugins.** { *; }

# Google ML Kit - keep component registrars
# ML Kit discovers its component registrars reflectively (Class.forName plus a
# no-arg constructor) from service metadata in the merged manifest, so the
# registrar classes, their constructors and the internal module classes they
# reference must survive R8 in release builds.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }

# Keep constructors used by ML Kit component discovery
-keepclassmembers class com.google.mlkit.** {
    <init>(...);
}

-keepclassmembers class com.google.android.gms.internal.mlkit_** {
    <init>(...);
}

# Keep ML Kit component registrar classes
-keep class * implements com.google.mlkit.common.sdkinternal.MlKitComponentRegistrar { *; }