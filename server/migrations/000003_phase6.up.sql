-- keepsy_id : random Crockford-base32 handle (8 chars) for server blind discovery
-- distinct from the M bridge user_handle (sealed, on album_member_identities) :
-- this one is identity side and shareable. no default + NOT NULL means a clean
-- dev DB is required (no production data pre release : registration always sets it)
ALTER TABLE users ADD COLUMN keepsy_id TEXT NOT NULL;
CREATE UNIQUE INDEX idx_users_keepsy_id ON users(keepsy_id);

-- §6.3 join_complete receipt : last epoch the member proved it installed
-- NULL = never acknowledged. set_epoch flags members behind for >24h
ALTER TABLE album_member_identities ADD COLUMN last_received_epoch INT;
ALTER TABLE album_member_identities ADD COLUMN last_received_at TIMESTAMPTZ;
