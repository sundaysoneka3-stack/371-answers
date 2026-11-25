-- ICT371 Q3: Library Returns and Overdue Fines  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path = q3, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER      NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE         NOT NULL,
    due_on        DATE         NOT NULL,
    returned_on   DATE,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE,
    new_returned_on  DATE,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

-- (b) Function: K2 per day after due date; due-date return = no fine --------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q3, public AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of is required';
    END IF;
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));   -- returned loans stop accruing
    RETURN 2 * GREATEST(v_end - v_due, 0);
END $$;

-- (c) Procedure: return date and final fine stored together ----------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql SET search_path = q3, public AS $$
DECLARE v_borrowed DATE; v_ret DATE; v_fine NUMERIC;
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;
    IF v_ret IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
    END IF;
    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);   -- returned_on still NULL -> uses p_as_of
    UPDATE loans
       SET returned_on = p_returned_on, fine_amount = v_fine   -- one atomic UPDATE
     WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_loan_return_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = q3, public AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_return_audit();

-- (a) Seed data -------------------------------------------------------------
INSERT INTO books(title) VALUES
 ('Database Systems'), ('Operating Systems'), ('Computer Networks');

INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Chipo',   CURRENT_DATE - 24, CURRENT_DATE - 10),  -- 1 open, overdue (10 days)
 (2, 'Mwila',   CURRENT_DATE - 17, CURRENT_DATE -  3),  -- 2 open, overdue (3 days)
 (3, 'Tamara',  CURRENT_DATE -  3, CURRENT_DATE + 11),  -- 3 open, on time
 (1, 'Joseph',  CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 4 returned late
 (2, 'Natasha', CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 5 returned on due date
 (3, 'Brian',   CURRENT_DATE - 30, CURRENT_DATE - 16);  -- 6 returned early

CALL pr_return_loan(4, CURRENT_DATE - 21);   -- 5 days late  -> K10
CALL pr_return_loan(5, CURRENT_DATE - 16);   -- on due date  -> K0
CALL pr_return_loan(6, CURRENT_DATE - 20);   -- early        -> K0

SELECT loan_id, due_on, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;           -- 3 rows

SELECT fn_loan_fine(1, CURRENT_DATE) AS open_overdue_fine;   -- 20
-- Tests
DO $$ BEGIN CALL pr_return_loan(4, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
  FROM loans l
  JOIN books b ON b.book_id = l.book_id
 WHERE l.returned_on IS NULL
   AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index ----------------------------------------------------------------
-- Partial index: holds only unreturned loans (a small, hot subset), keyed by book.
CREATE INDEX idx_loans_book_open ON loans (book_id) WHERE returned_on IS NULL;

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
-- Assumption: "overdue" = unreturned as of p_as_of AND due before p_as_of.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql SET search_path = q3, public AS $$
BEGIN
    INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)), 0)
      FROM loans l
     WHERE l.borrowed_on <= p_as_of
       AND (l.returned_on IS NULL OR l.returned_on > p_as_of)   -- still out on that date
       AND l.due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
       SET overdue_count = EXCLUDED.overdue_count,
           total_fine    = EXCLUDED.total_fine;
END $$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);                 -- rerun replaces the row
SELECT * FROM overdue_summary;                         -- expected: 2 loans, total fine K26 (K20 + K6)

SELECT cron.schedule('q3-refresh-overdue', '10 0 * * *',
       $cron$CALL q3.pr_refresh_overdue(CURRENT_DATE)$cron$);
