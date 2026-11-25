-- ICT371 Q7: Water Meter Readings and Billing  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q7 CASCADE;
CREATE SCHEMA q7;
SET search_path = q7, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
-- current >= previous is enforced by the trigger in (d) so that the rejection
-- message is explicit and also applies to direct SQL imports.
CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

-- (b) Function: first 10 units K5, above 10 K8 -------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql SET search_path = q7, public AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %', p_units;
    END IF;
    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql SET search_path = q7, public AS $$
DECLARE v_units NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;
    SELECT current_reading - previous_reading INTO v_units
      FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    INSERT INTO bills(reading_id, charge, amount_paid, due_on)
         VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_reading_check() RETURNS trigger
LANGUAGE plpgsql SET search_path = q7, public AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
              NEW.current_reading, NEW.previous_reading;   -- row is not stored
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check();

-- (a) Seed data -------------------------------------------------------------
INSERT INTO customers(full_name) VALUES ('Alick Phiri'), ('Betty Nkhoma'), ('Collins Mbewe');

INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, '2026-09-01', 100, 100),   -- 1: 0 units
 (1, '2026-10-01', 100, 110),   -- 2: exactly 10 units
 (2, '2026-09-01',  50,  65),   -- 3: 15 units
 (2, '2026-10-01',  65,  69),   -- 4: 4 units
 (3, '2026-09-01', 200, 230),   -- 5: 30 units
 (3, '2026-10-01', 230, 231);   -- 6: 1 unit

CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE - 30);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(4, CURRENT_DATE + 15);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(6, CURRENT_DATE + 15);

UPDATE bills SET amount_paid = charge WHERE reading_id = 2;   -- fully paid
UPDATE bills SET amount_paid = 40     WHERE reading_id = 3;   -- partly paid

SELECT reading_id, charge, amount_paid, due_on FROM bills ORDER BY reading_id;
-- charges: 0, 50, 90, 20, 50+160=210, 5

-- Tests
SELECT fn_water_charge(0) AS c0, fn_water_charge(10) AS c10, fn_water_charge(15) AS c15;  -- 0.00, 50.00, 90.00
DO $$ BEGIN PERFORM fn_water_charge(-1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(NULL);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);      -- already billed
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE);     -- unknown
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, '2026-11-01', 110, 100);          -- rejected, not stored
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_still_six FROM readings;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
  FROM bills b
  JOIN readings r  ON r.reading_id  = b.reading_id
  JOIN customers c ON c.customer_id = r.customer_id
 WHERE b.due_on < CURRENT_DATE
   AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) Index ----------------------------------------------------------------
-- Partial index over unpaid bills only, ordered by due date: overdue searches
-- are a due_on range scan and fully-paid bills (the majority over time) are
-- never stored in the index.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;

SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
  FROM bills
 WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql SET search_path = q7, public AS $$
BEGIN
    INSERT INTO receivable_snapshot(snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
      FROM bills WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
       SET total_due = EXCLUDED.total_due;          -- replace, never add
END $$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                       -- rerun safe
SELECT * FROM receivable_snapshot;                   -- 50 + 20 + 210 + 5 = 285

SELECT cron.schedule('q7-refresh-receivables', '30 0 * * *',
       $cron$CALL q7.pr_refresh_receivables()$cron$);
