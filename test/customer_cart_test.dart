import 'package:flutter_test/flutter_test.dart';
import 'package:test4/models/customer_cart.dart';

void main() {
  group('CustomerCart totals', () {
    test('separates refill, container, deposit, and item totals', () {
      const cart = CustomerCart(
        id: 'cart-id',
        stationId: 'station-id',
        stationName: 'Station',
        items: [
          CustomerCartItem(
            id: 'refill-item',
            productId: 'refill-product',
            name: 'Refill',
            waterType: 'Purified',
            containerType: '5 gallon',
            containerOption: 'refill_existing',
            quantity: 2,
            refillPrice: 35,
            containerPrice: 0,
            deposit: 0,
            requiresEmptyContainer: true,
            returnPolicy: null,
          ),
          CustomerCartItem(
            id: 'new-item',
            productId: 'new-product',
            name: 'New container',
            waterType: 'Purified',
            containerType: '5 gallon',
            containerOption: 'new_gallon',
            quantity: 1,
            refillPrice: 30,
            containerPrice: 25,
            deposit: 10,
            requiresEmptyContainer: false,
            returnPolicy: null,
          ),
        ],
      );

      expect(cart.itemCount, 3);
      expect(cart.subtotal, 100);
      expect(cart.containerTotal, 25);
      expect(cart.depositTotal, 10);
      expect(cart.itemTotal, 135);
    });
  });
}
