import 'package:flutter/foundation.dart';

bool get isDesktopPlatform {
  if (kIsWeb) return false;

  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;
}
