import 'package:flutter_test/flutter_test.dart';
import 'package:bettaiah_pos/main.dart';
void main() {
  test('currency formatting uses two decimal places', () {
    expect(money(12345), '₹123.45');
    expect(toCents('12.50'), 1250);
  });
}
