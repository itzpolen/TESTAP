import 'package:flutter/material.dart';

class MapLabel extends StatelessWidget {
  final String text;

  const MapLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      color: Colors.white70,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 7,
          color: Color(0xFF778078),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class MapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final road = Paint()
      ..color = Colors.white
      ..strokeWidth = 13
      ..style = PaintingStyle.stroke;

    final minor = Paint()
      ..color = const Color(0xFFD1DCD2)
      ..strokeWidth = 1.5;

    for (double x = -100; x < size.width + 200; x += 75) {
      canvas.drawLine(Offset(x, 0), Offset(x + 150, size.height), minor);
    }

    for (double y = -100; y < size.height + 200; y += 70) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y + 40), minor);
    }

    canvas.drawLine(
      Offset(-20, size.height * .68),
      Offset(size.width + 20, size.height * .30),
      road,
    );

    canvas.drawLine(
      Offset(size.width * .18, -20),
      Offset(size.width * .78, size.height + 20),
      road,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
