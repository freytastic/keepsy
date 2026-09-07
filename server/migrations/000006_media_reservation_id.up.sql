-- Keys may be reused, so each reservation needs its own identity
ALTER TABLE media
    ADD COLUMN reservation_id UUID NOT NULL DEFAULT gen_random_uuid();
