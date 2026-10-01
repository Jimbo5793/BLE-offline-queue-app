import 'package:flutter/material.dart';

void main() => runApp(const BeaconQApp());

class BeaconQApp extends StatelessWidget {
  const BeaconQApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BeaconQ',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3D5AFE),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(child: Text('BeaconQ')),
      ),
    );
  }
}
