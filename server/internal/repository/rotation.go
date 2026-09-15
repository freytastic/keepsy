package repository

// Combines durable rotation debt with current-wrap drift for every gate
// album must be a trusted SQL reference, never user input
func RotationRequiredExpr(album string) string {
	cur := `(SELECT MAX(epoch) FROM album_epochs WHERE album_id = ` + album + `)`
	return `(
	(SELECT rotation_required FROM albums WHERE id = ` + album + `)
	OR (` + cur + ` IS NOT NULL AND (
	  EXISTS (
	    SELECT 1 FROM album_members m
	    WHERE m.album_id = ` + album + ` AND m.revoked_at IS NULL
	      AND NOT EXISTS (
	        SELECT 1 FROM album_epoch_wraps w
	        WHERE w.album_id = m.album_id AND w.epoch = ` + cur + `
	          AND w.recipient_token = m.member_token))
	  OR EXISTS (
	    SELECT 1 FROM album_epoch_wraps w
	    WHERE w.album_id = ` + album + ` AND w.epoch = ` + cur + `
	      AND NOT EXISTS (
	        SELECT 1 FROM album_members m
	        WHERE m.album_id = w.album_id AND m.revoked_at IS NULL
	          AND m.member_token = w.recipient_token)))))`
}
