ALTER TABLE reconciliation_safety_state
    ADD COLUMN latch_engaged BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE reconciliation_safety_state
    ADD COLUMN latch_reason TEXT;

ALTER TABLE reconciliation_safety_state
    ADD COLUMN latch_updated_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE reconciliation_safety_state
    ADD COLUMN latch_released_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE reconciliation_safety_state
    ADD COLUMN latch_released_by VARCHAR(128);
