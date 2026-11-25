-- ICT371 Q2: University Fee Payments  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path = q2, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL
);
CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER       NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q2, public AS $$
DECLARE v_fee NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;
    -- COALESCE: a student with no payments owes the full fee
    RETURN v_fee - COALESCE((SELECT SUM(amount) FROM payments
                              WHERE student_id = p_student_id), 0);
END $$;

-- (c) Procedure (does NOT write the audit row; the trigger does) -----------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql SET search_path = q2, public AS $$
DECLARE v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive';
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE; -- serialise payments
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;
    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;
    INSERT INTO payments(student_id, amount, paid_on)
         VALUES (p_student_id, p_amount, p_paid_on);               -- fee_due untouched
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_payment_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = q2, public AS $$
BEGIN
    INSERT INTO payment_audit(payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END $$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

-- (a) Seed data (payments through the procedure) ---------------------------
INSERT INTO students(student_number, full_name, fee_due) VALUES
 ('S1001', 'Mary Banda',    5000.00),
 ('S1002', 'Peter Phiri',   3000.00),
 ('S1003', 'Grace Mwansa',  4000.00);      -- S1003 has no payments

CALL pr_receive_payment(1, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);   -- S1002 now fully settled

SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1;
-- expected: 2000, 0, 4000
SELECT * FROM payment_audit ORDER BY audit_id;        -- 6 rows written by trigger

-- Tests: rejected payments
DO $$ BEGIN CALL pr_receive_payment(3, 0, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, NULL, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, 9999, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_fee_balance(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
  FROM students s
  LEFT JOIN payments p ON p.student_id = s.student_id
 GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;   -- settled students excluded

SELECT * FROM v_fee_balances;

-- (f) Index ----------------------------------------------------------------
-- Equality on student_id first, range on paid_on second: one index serves
-- both predicates, returns rows in date order and also covers student_id lookups.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payments
 WHERE student_id = 1
   AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql SET search_path = q2, public AS $$
BEGIN
    INSERT INTO daily_collections(collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
      FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
       SET payment_count = EXCLUDED.payment_count,
           total_amount  = EXCLUDED.total_amount;     -- replace on rerun
END $$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);        -- rerun is safe
SELECT * FROM daily_collections;

SELECT cron.schedule('q2-refresh-collections', '0 1 * * *',
       $cron$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$cron$);
