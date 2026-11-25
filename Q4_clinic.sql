-- ICT371 Q4: Clinic Appointment Scheduling  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path = q4, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL
        CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);
CREATE TABLE clinic_summary (
    summary_date   DATE PRIMARY KEY,
    booked_count   INTEGER NOT NULL,
    attended_count INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

-- Safety net against concurrent bookings (trigger below gives the friendly message)
CREATE UNIQUE INDEX uq_active_doctor_slot
    ON appointments (doctor_id, appointment_day, slot_time)
 WHERE status <> 'CANCELLED';

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = q4, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;
    RETURN (SELECT COUNT(*) FROM appointments
             WHERE doctor_id = p_doctor_id
               AND appointment_day = p_day
               AND status <> 'CANCELLED');           -- COUNT gives 0 when none
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql SET search_path = q4, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;
    INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
         VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_appointment_clash() RETURNS trigger
LANGUAGE plpgsql SET search_path = q4, public AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (SELECT 1 FROM appointments a
                    WHERE a.doctor_id       = NEW.doctor_id
                      AND a.appointment_day = NEW.appointment_day
                      AND a.slot_time       = NEW.slot_time
                      AND a.status <> 'CANCELLED'
                      AND (TG_OP = 'INSERT'
                           OR a.appointment_id <> NEW.appointment_id)) -- exclude itself on UPDATE
        THEN
            RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
                  NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_clash();

-- (a) Seed data -------------------------------------------------------------
INSERT INTO patients(full_name) VALUES ('Esther Zulu'), ('Kelvin Mumba'), ('Ruth Tembo');
INSERT INTO doctors(full_name)  VALUES ('Dr. Banda'), ('Dr. Phiri'), ('Dr. Chanda');

-- past records (direct inserts; trigger still checks them)
INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1, 1, CURRENT_DATE - 2, '09:00', 'ATTENDED'),
 (3, 2, CURRENT_DATE - 1, '09:00', 'CANCELLED'),
 (1, 2, CURRENT_DATE - 1, '09:00', 'ATTENDED');   -- reuses the cancelled slot: allowed
-- future bookings through the procedure
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '11:00');

SELECT fn_daily_load(1, CURRENT_DATE) AS dr1_today,      -- 1
       fn_daily_load(3, CURRENT_DATE) AS dr3_today;      -- 0 (no bookings)

-- Tests
DO $$ BEGIN CALL pr_book_appointment(3, 1, CURRENT_DATE, '09:00');   -- clash
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(3, 1, CURRENT_DATE - 1, '10:00'); -- past
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(3, 1, CURRENT_DATE + 2, '13:00'); -- bad slot
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- UPDATE that does not clash with itself:
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 4;

-- (e) View: only names and slot, no IDs or other patient data ----------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
  FROM appointments a
  JOIN patients p ON p.patient_id = a.patient_id
  JOIN doctors  d ON d.doctor_id  = a.doctor_id
 WHERE a.appointment_day = CURRENT_DATE
   AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index ----------------------------------------------------------------
-- Non-unique: many appointments share a day and doctor. Day first (the most
-- common filter, also supports day-only searches), then doctor.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments
 WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql SET search_path = q4, public AS $$
BEGIN
    INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
      FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
       SET booked_count    = EXCLUDED.booked_count,
           attended_count  = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;
END $$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);     -- rerun replaces
SELECT * FROM clinic_summary;                         -- 0 booked, 1 attended, 1 cancelled

SELECT cron.schedule('q4-refresh-clinic-summary', '0 1 * * *',
       $cron$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$cron$);
