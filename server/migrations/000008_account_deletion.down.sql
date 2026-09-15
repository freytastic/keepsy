-- Fails if a deleted account's signed history remains, which is the point
ALTER TABLE invite_blobs ADD CONSTRAINT invite_blobs_signer_token_fkey
    FOREIGN KEY (signer_token) REFERENCES album_member_identities(member_token);
ALTER TABLE manifests ADD CONSTRAINT manifests_signer_token_fkey
    FOREIGN KEY (signer_token) REFERENCES album_member_identities(member_token);
ALTER TABLE album_epoch_wraps ADD CONSTRAINT album_epoch_wraps_sender_token_fkey
    FOREIGN KEY (sender_token) REFERENCES album_member_identities(member_token);

DROP TABLE IF EXISTS account_deletion_receipts;
DROP TABLE IF EXISTS account_deletions;
ALTER TABLE users DROP COLUMN IF EXISTS deleting_at;
