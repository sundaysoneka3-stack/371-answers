-- ICT371 Q6: Monthly Payroll Processing  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path = q6, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL
        CHECK (EXTRACT(DAY FROM pay_month) = 1),          -- first day of a month
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q6, public AS $$
DECLARE v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
      FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END $$;

-- (c) Procedure ------------------------------------------------------------
-- A raised exception aborts the whole call, so no partial payroll is kept.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql SET search_path = q6, public AS $$
DECLARE rec RECORD;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;
    FOR rec IN
        SELECT employee_id, basic_salary + allowance AS gross
          FROM employees WHERE active ORDER BY employee_id
    LOOP
        INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.gross, fn_net_pay(rec.employee_id))
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows unchanged
    END LOOP;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = q6, public AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit(employee_id, old_salary, new_salary, changed_at)
        VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- (a) Seed data -------------------------------------------------------------
INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
 ('Alice Mwale',    5000, 500, 300, TRUE),
 ('Brian Kasonde',  4000, 400, 250, TRUE),
 ('Chanda Lungu',   3000, 200, 150, FALSE),   -- inactive from the start
 ('Dalitso Banda',  3500, 300, 200, TRUE);

CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- salary change (audited) and a later deactivation (history must remain)
UPDATE employees SET basic_salary = 5500 WHERE employee_id = 1;
UPDATE employees SET basic_salary = 5500 WHERE employee_id = 1;   -- unchanged: no 2nd audit row
UPDATE employees SET active = FALSE WHERE employee_id = 4;

CALL pr_process_payroll(DATE '2026-10-01');     -- rerun: existing rows unchanged
SELECT COUNT(*) AS payroll_rows FROM payroll;   -- still 6
SELECT * FROM salary_audit;                     -- exactly 1 row

-- Tests
SELECT fn_net_pay(1) AS alice_net;              -- 5500 + 500 - 300 = 5700
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-15');   -- not a month start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_net_pay(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- Invalid employee fails the whole call (nothing inserted for November):
INSERT INTO employees(full_name, basic_salary, allowance, deduction) VALUES ('Bad Calc', 100, 0, 500);
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-01');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS nov_rows FROM payroll WHERE pay_month = DATE '2026-11-01';   -- 0
DELETE FROM employees WHERE full_name = 'Bad Calc';

-- (e) View: inner join to employees keeps rows of employees who became inactive
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
  FROM payroll p
  JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index ----------------------------------------------------------------
-- uq_employee_month is (employee_id, pay_month): it cannot be used efficiently
-- for "all employees in one month" because pay_month is not its leading column.
-- This index leads with pay_month and does not duplicate the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on the 1st, previous month's first date -----------
SELECT cron.schedule('q6-monthly-payroll', '0 2 1 * *',
  $cron$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$cron$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6-monthly-payroll';
SELECT jobid, status, return_message, start_time, end_time
  FROM cron.job_run_details
 WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6-monthly-payroll')
 ORDER BY start_time DESC;
