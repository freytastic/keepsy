-- Set when deletion is accepted. The account then signs in, joins and publishes
-- nothing while the job removes it
ALTER TABLE users ADD COLUMN deleting_at TIMESTAMPTZ;

-- One durable job per account. Progress is the remaining membership rows, so a
-- crash resumes by re reading them. Deleting the user removes the job with it
CREATE TABLE account_deletions (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    requested_at    TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    attempts        INTEGER NOT NULL DEFAULT 0,
    -- Doubles as a lease: a claimed job is invisible until it succeeds or times out
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_account_deletions_due ON account_deletions(next_attempt_at);

-- Proof an accepted deletion exists, for a device whose response was lost and
-- whose sessions are already gone. Only a hash of a client random value, so it
-- links to no account
CREATE TABLE account_deletion_receipts (
    receipt_hash BYTEA PRIMARY KEY,
    -- The device gave up on this receipt, so no request carrying it may ever
    -- be accepted. Claimed on the same key as acceptance, so they serialize
    abandoned    BOOLEAN NOT NULL DEFAULT FALSE,
    accepted_at  TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);

CREATE INDEX idx_account_deletion_receipts_age ON account_deletion_receipts(accepted_at);

-- Signed history keeps the signer token as an opaque value, so deleting the
-- signer's membership never has to rewrite or drop what they signed
ALTER TABLE album_epoch_wraps DROP CONSTRAINT album_epoch_wraps_sender_token_fkey;
ALTER TABLE manifests DROP CONSTRAINT manifests_signer_token_fkey;
ALTER TABLE invite_blobs DROP CONSTRAINT invite_blobs_signer_token_fkey;
