import 'package:keepsy/data/api/auth_api.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/name_cache.dart';

// drop auth tokens and wipe the plaintext bearing media
// cache (L1 RAM + L2 sealed files) + the display name cache. Deliberately does
// NOT touch cache_root_key, identity or album MKs : all three are DEVICE bound,
// not session bound. cache_root_key in particular MUST survive : it is
// established once per process at boot, so deleting it here strands blobs that
// an in process re login re seals under the still in RAM key, forcing a full
// re download on the next
Future<void> performLogout({
  required AuthService auth,
  required MediaCacheManager mediaCache,
  required NameCache nameCache,
  Future<void> Function()? disconnectRealtime,
}) async {
  // Drop the websocket first so no live events land against a session we are
  // tearing down : a failed disconnect mustnt block the wipe
  if (disconnectRealtime != null) {
    try {
      await disconnectRealtime();
    } catch (_) {}
  }
  await auth.logout();
  await mediaCache.clearAll();
  await nameCache.clear();
}
