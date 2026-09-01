import 'package:flutter/animation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keepsy/ui/shelf/develop_store.dart';

class _Vsync implements TickerProvider {
  final List<Ticker> tickers = [];

  @override
  Ticker createTicker(TickerCallback onTick) {
    final t = Ticker(onTick);
    tickers.add(t);
    return t;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Vsync vsync;
  late DevelopStore store;

  setUp(() {
    vsync = _Vsync();
    store = DevelopStore(
        vsync: vsync, duration: const Duration(milliseconds: 1300));
  });

  tearDown(() {
    store.dispose();
    for (final t in vsync.tickers) {
      t.dispose();
    }
  });

  test('an unseen album starts milky and a seen one starts developed', () {
    expect(store.sync('a', 5).value, 0);
    expect(store.sync('b', 0).value, 1);
  });

  test('the same album keeps one animation across rebuilds', () {
    final first = store.sync('a', 5);
    expect(identical(store.sync('a', 5), first), isTrue,
        reason: 'a rebuilt card must not get a fresh controller');
  });

  test('going seen starts developing rather than jumping', () {
    store.sync('a', 5);
    final anim = store.sync('a', 0);
    expect(anim.status, AnimationStatus.forward);
    expect(anim.value, 0);
  });

  test('a later upload snaps back to milky', () {
    store.sync('a', 0);
    expect(store.sync('a', 3).value, 0);
  });

  test('retain disposes albums that left the shelf', () {
    store.sync('a', 0);
    store.sync('b', 0);
    store.retain({'a'});
    expect(store.read('a'), isNotNull);
    expect(store.read('b'), isNull);
  });
}
