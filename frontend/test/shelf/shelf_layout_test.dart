import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/shelf/shelf_layout.dart';

void main() {
  test('a tall screen keeps the lead print at full size', () {
    expect(
        leadScale(viewHeight: 1000, above: 200, leadHeight: 400, below: 250),
        1.0);
  });

  test('the lead shrinks just enough for the pair to clear the bar', () {
    final s =
        leadScale(viewHeight: 771, above: 225, leadHeight: 410, below: 198);
    expect(s, closeTo(348 / 410, 0.001));
    expect(225 + 410 * s + 198, closeTo(771, 0.01));
  });

  test('a short screen never takes the lead below its floor', () {
    expect(
        leadScale(viewHeight: 600, above: 250, leadHeight: 410, below: 198),
        minLeadScale);
  });
}
