import 'package:keepsy/data/api/auth_api.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';

// drop auth tokens and wipe the plaintext bearing media
// cache (L1 RAM + L2 sealed files). Deliberately does NOT touch cache_root_key,
// identity or album MKs : all three are DEVICE bound, not session bound
// cache_root_key in particular MUST survive : it is established once per process
// at boot, so deleting it here strands blobs that an in process re login
// re seals under the still in RAM key, forcing a full re download on the next
Future<void> performLogout({
  required AuthService auth,
  required MediaCacheManager mediaCache,
}) async {
  await auth.logout();
  await mediaCache.clearAll();
}
