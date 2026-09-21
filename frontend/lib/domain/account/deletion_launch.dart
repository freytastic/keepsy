import 'package:keepsy/data/api/account_api.dart';

import 'account_deletion.dart';

// Every deletion entry point must build and settle a plan before opening the UI

const int _maxPlanReviews = 3;

typedef ConfirmShared = Future<bool> Function(List<DeletionAlbum> shared);
typedef OpenDeletionScreen = Future<DeletionResult?> Function(
    DeletionPlan plan);

// Returns the settled result, or null when the user declined or the plan never
// stopped changing
Future<DeletionResult?> launchAccountDeletion({
  required AccountDeletion deletion,
  required ConfirmShared confirmShared,
  required OpenDeletionScreen openScreen,
}) async {
  for (var review = 0; review < _maxPlanReviews; review++) {
    final plan = await deletion.plan();
    if (plan.shared.isNotEmpty && !await confirmShared(plan.shared)) {
      return null;
    }
    final result = await openScreen(plan);
    // Re-review a plan that changed before confirmation
    if (result == DeletionResult.planChanged) continue;
    return result;
  }
  return null;
}
