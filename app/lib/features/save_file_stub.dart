import 'dart:convert';

import 'package:url_launcher/url_launcher.dart';

/// Non-web fallback: hand the file to the OS as a data URI.
Future<void> saveTextFile(String fileName, String content, String mime) async {
  await launchUrl(Uri.dataFromString(content, mimeType: mime.split(';').first, encoding: utf8));
}
