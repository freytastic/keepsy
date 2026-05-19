import 'package:sodium/sodium_sumo.dart' show SodiumSumo, SodiumSumoInit;
import 'package:keepsy/crypto/primitives.dart';

SodiumSumo? _sodium;

Future<SodiumSumo> ensureSodium() async {
  final s = _sodium;
  if (s != null) return s;
  final ns = await SodiumSumoInit.init();
  Sign.bindSodium(ns);
  Kex.bindSodium(ns);
  _sodium = ns;
  return ns;
}
