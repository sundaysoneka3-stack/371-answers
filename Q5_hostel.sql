-- ICT371 Q5: Hostel Room Allocation  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path = q5, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);
-- Extra guard: one ACTIVE allocation per student, even under concurrency
CREATE UNIQUE INDEX uq_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = q5, public AS $$
DECLARE v_cap INT;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;
    RETURN v_cap - (SELECT COUNT(*) FROM allocations
                     WHERE room_id = p_room_id AND status = 'ACTIVE'); -- ENDED ignored
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql SET search_path = q5, public AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;      -- lock room
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
                WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;
    INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
         VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (d) Trigger: same rules for direct SQL -----------------------------------
CREATE OR REPLACE FUNCTION trg_allocation_rules() RETURNS trigger
LANGUAGE plpgsql SET search_path = q5, public AS $$
DECLARE v_cap INT; v_cnt INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id %', NEW.room_id;
        END IF;
        IF EXISTS (SELECT 1 FROM allocations
                    WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                      AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;
        SELECT COUNT(*) INTO v_cnt FROM allocations
         WHERE room_id = NEW.room_id AND status = 'ACTIVE'
           AND allocation_id IS DISTINCT FROM NEW.allocation_id;   -- exclude row being changed
        IF v_cnt >= v_cap THEN
            RAISE EXCEPTION 'Room % is at capacity (%)', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_rules();

-- (a) Seed data -------------------------------------------------------------
INSERT INTO students(student_number, full_name) VALUES
 ('H001','Anna Lungu'), ('H002','Bwalya Chola'), ('H003','Cathy Zimba'),
 ('H004','David Mulenga'), ('H005','Evelyn Sakala');
INSERT INTO rooms(room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);

-- history (ENDED) rows
INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status) VALUES
 (5, 3, CURRENT_DATE - 120, CURRENT_DATE - 60, 'ENDED'),   -- R103 stays empty
 (4, 1, CURRENT_DATE - 90,  CURRENT_DATE - 45, 'ENDED');
-- ACTIVE rows through the procedure
CALL pr_allocate_room(1, 1, CURRENT_DATE - 10);   -- R101 full (2/2)
CALL pr_allocate_room(2, 1, CURRENT_DATE - 9);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 8);    -- R102 partly (2/3)
CALL pr_allocate_room(4, 2, CURRENT_DATE - 7);

SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY 1;   -- 0, 1, 2

-- Tests
DO $$ BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);          -- full room
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);          -- already ACTIVE
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations(student_id, room_id, allocated_on, status)
            VALUES (5, 1, CURRENT_DATE, 'ACTIVE');              -- direct SQL, trigger blocks
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_free_beds(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
 GROUP BY r.room_id, r.room_number, r.capacity;   -- empty rooms still listed

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index ----------------------------------------------------------------
-- Partial index on ACTIVE rows only: capacity checks and occupancy counts only
-- ever look at ACTIVE rows, so the index stays small as ENDED history grows.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM allocations WHERE room_id = 2 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql SET search_path = q5, public AS $$
BEGIN
    INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
      FROM rooms r
      LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
     GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
       SET occupied_beds = EXCLUDED.occupied_beds,
           free_beds     = EXCLUDED.free_beds;
END $$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                        -- rerun: still one row per room
SELECT * FROM occupancy_snapshot ORDER BY room_id;

SELECT cron.schedule('q5-refresh-occupancy', '55 23 * * *',
       $cron$CALL q5.pr_refresh_occupancy()$cron$);
