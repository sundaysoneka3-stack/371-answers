-- ICT371 Q1: Pharmacy Stock and Daily Sales  (PostgreSQL 14+, pg_cron)
-- Prerequisite (superuser): pg_cron in shared_preload_libraries, then:
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path = q1, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL
);
CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q1, public AS $$
DECLARE v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be positive)', p_quantity;
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;
    RETURN v_price * p_quantity;
END $$;

-- (c) Procedure ------------------------------------------------------------
-- All checks happen before any write, so a rejected sale changes nothing.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql SET search_path = q1, public AS $$
DECLARE v_price NUMERIC; v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;
    SELECT unit_price, stock_qty INTO v_price, v_stock
      FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;   -- row lock
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: % available, % requested', v_stock, p_quantity;
    END IF;
    INSERT INTO sales(medicine_id, quantity, unit_price, sold_on)
         VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);   -- price frozen at sale time
    UPDATE medicines SET stock_qty = stock_qty - p_quantity        -- deducted once
     WHERE medicine_id = p_medicine_id;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_medicine_stock_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = q1, public AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit(medicine_id, old_qty, new_qty, changed_at)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_medicine_stock_audit();

-- (a) Seed data (sales loaded through the procedure) ------------------------
INSERT INTO medicines(medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 100),
 ('Amoxicillin 250mg', 8.00,  12),
 ('Ibuprofen 200mg',   4.00,  15),
 ('Cough Syrup',       6.50,   8);

CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(2,  5, CURRENT_DATE - 1);
CALL pr_record_sale(3,  4, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE);
CALL pr_record_sale(2,  3, CURRENT_DATE);
CALL pr_record_sale(3,  2, CURRENT_DATE);

-- Tests: function and rejected sales (tables stay unchanged)
SELECT fn_sale_value(1, 4) AS value_of_4_paracetamol;      -- 10.00
DO $$ BEGIN CALL pr_record_sale(2, 999, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_sale_value(99, 1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM stock_audit ORDER BY audit_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty AS remaining_stock
  FROM medicines
 WHERE stock_qty < 10;

SELECT * FROM v_low_stock;                       -- after the sales above

-- (f) Index ----------------------------------------------------------------
-- Equality column (medicine_id) first, range column (sold_on) second: the
-- B-tree jumps to one medicine and scans just the date range in order.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT * FROM sales
 WHERE medicine_id = 1
   AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
-- Upsert makes reruns idempotent: values are replaced, never added again.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql SET search_path = q1, public AS $$
BEGIN
    INSERT INTO daily_sales(sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
      FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
       SET total_qty    = EXCLUDED.total_qty,
           total_amount = EXCLUDED.total_amount;
END $$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);         -- rerun: no duplicate/double count
SELECT * FROM daily_sales;

-- 00:15 daily, for the previous day (pg_cron uses GMT unless cron.timezone is set)
SELECT cron.schedule('q1-refresh-sales', '15 0 * * *',
       $cron$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$cron$);
