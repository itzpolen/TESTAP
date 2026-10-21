import 'package:flutter/material.dart';

class PaymentCancelScreen extends StatelessWidget {
  const PaymentCancelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final orderId = Uri.base.queryParameters['order_id'] ?? '';
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cancel, color: Colors.red, size: 100),
            SizedBox(height: 16),
            Text("Payment Cancelled", style: TextStyle(fontSize: 24)),
            Text("Order ID: $orderId"),
            SizedBox(height: 20),
            ElevatedButton(onPressed: () => Navigator.pushNamed(context, '/'), child: Text("Try Again"))
          ],
        ),
      ),
    );
  }
}