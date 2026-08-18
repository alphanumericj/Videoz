import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'editor_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize media_kit's native backend (libmpv) before any Player is made.
  MediaKit.ensureInitialized();
  runApp(const VideozApp());
}

class VideozApp extends StatelessWidget {
  const VideozApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Videoz',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3A6EA5),
          brightness: Brightness.dark,
        ),
      ),
      home: const EditorPage(),
    );
  }
}
