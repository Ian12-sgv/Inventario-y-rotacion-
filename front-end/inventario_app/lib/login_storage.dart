import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SavedLoginCredentials {
  const SavedLoginCredentials({
    required this.username,
    required this.password,
  });

  final String username;
  final String password;

  Map<String, dynamic> toJson() => {
        'username': username,
        'password': password,
      };

  factory SavedLoginCredentials.fromJson(Map<String, dynamic> json) {
    return SavedLoginCredentials(
      username: (json['username'] ?? '').toString(),
      password: (json['password'] ?? '').toString(),
    );
  }
}

class LoginStorage {
  static const String _fileName = 'last_login.json';

  static Future<File> _resolveFile() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File(p.join(directory.path, _fileName));
  }

  static Future<SavedLoginCredentials?> load() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;

      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;

      return SavedLoginCredentials.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save({
    required String username,
    required String password,
  }) async {
    final file = await _resolveFile();
    final payload = SavedLoginCredentials(
      username: username,
      password: password,
    );
    await file.writeAsString(jsonEncode(payload.toJson()));
  }
}
