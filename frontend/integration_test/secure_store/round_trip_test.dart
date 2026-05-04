import 'package:integration_test/integration_test.dart';
import 'package:keepsy/secure_store/secure_key_store.dart';

// Reuses the same parameterized contract suite as the host side mock test,
// pointed at the real platform backed store. Relative import keeps test/ off
// the runtime classpath of integration_test/
import '../../test/secure_store/contract_test.dart' as contract;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  contract.runContractTests(
      'Real platform store', () => createSecureKeyStore());
}
