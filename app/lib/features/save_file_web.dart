import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> saveTextFile(String fileName, String content, String mime) async {
  final blob = web.Blob([content.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  web.document.body!.append(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
}
