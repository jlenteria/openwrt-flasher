import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const OpenWrtFlasherApp());
}

class OpenWrtFlasherApp extends StatelessWidget {
  const OpenWrtFlasherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenWrt Flasher',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
