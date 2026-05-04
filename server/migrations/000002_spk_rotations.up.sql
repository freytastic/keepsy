CREATE TABLE spk_rotations (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    old_spk_ts  BIGINT,
    new_spk_ts  BIGINT NOT NULL,
    ip          INET,
    user_agent  TEXT,
    rotated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_spk_rotations_user ON spk_rotations(user_id, rotated_at DESC);
