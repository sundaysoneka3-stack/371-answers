-- ICT371 Q10: Scholarship Application Assessment  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path = q10, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql SET search_path = q10, public AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25      -- inclusive
       AND p_income <= 3000
       AND p_mark   >= 70;
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql SET search_path = q10, public AS $$
DECLARE rec applications%ROWTYPE;
BEGIN
    SELECT * INTO rec FROM applications
     WHERE application_id = p_application_id FOR UPDATE;   -- avoid double assessment
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id %', p_application_id;
    END IF;
    IF rec.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed (%)', p_application_id, rec.status;
    END IF;
    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(rec.age_at_application,
                                                      rec.monthly_income,
                                                      rec.average_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = q10, public AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit(application_id, old_status, new_status, changed_at)
        VALUES (OLD.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

-- (a) Seed data: six PENDING applications, three students --------------------
INSERT INTO students(student_number, full_name) VALUES
 ('U001', 'Lilian Moyo'), ('U002', 'Martin Kunda'), ('U003', 'Naomi Sichone');

INSERT INTO applications(student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
 (1, 20, 2000.00, 80.00, CURRENT_DATE - 10),   -- 1 qualifies
 (1, 18, 3000.00, 70.00, CURRENT_DATE -  9),   -- 2 boundary: all minimums/maximums -> qualifies
 (2, 25, 1500.00, 95.00, CURRENT_DATE -  8),   -- 3 boundary age 25 -> qualifies
 (2, 26, 1000.00, 90.00, CURRENT_DATE -  7),   -- 4 too old -> rejected
 (3, 22, 3000.01, 85.00, CURRENT_DATE -  6),   -- 5 income just over -> rejected
 (3, 21, 2500.00, 69.99, CURRENT_DATE -  5);   -- 6 mark just under -> rejected

-- Tests of the function
SELECT fn_scholarship_eligible(18, 3000, 70) AS boundary_ok,      -- true
       fn_scholarship_eligible(17, 1000, 90) AS too_young;        -- false
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 90);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 90);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1000, 90);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View: no household income exposed ------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
  FROM applications a
  JOIN students s ON s.student_id = a.student_id
 WHERE a.status = 'APPROVED';

-- (f) Index ----------------------------------------------------------------
-- status (equality) first, then submitted_on (range): a single range scan
-- inside the chosen status.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

-- (g) Scheduled job --------------------------------------------------------
-- Only PENDING rows are selected, so reruns skip completed applications and
-- cannot create duplicate audit rows.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql SET search_path = q10, public AS $$
DECLARE rec RECORD;
BEGIN
    FOR rec IN SELECT application_id FROM applications
                WHERE status = 'PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END $$;

-- Assess one directly, then run the batch job, then rerun it
CALL pr_assess_application(1);
CALL pr_assess_pending();
CALL pr_assess_pending();                                   -- rerun: nothing changes

SELECT application_id, status FROM applications ORDER BY 1; -- 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;             -- exactly 6 rows
SELECT * FROM v_approved_applicants;

DO $$ BEGIN CALL pr_assess_application(1);                  -- already assessed
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(99);                 -- unknown
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (f) EXPLAIN for the status + date-range search
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM applications
 WHERE status = 'APPROVED'
   AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- Every Monday 08:00
SELECT cron.schedule('q10-assess-pending', '0 8 * * 1',
       $cron$CALL q10.pr_assess_pending()$cron$);
