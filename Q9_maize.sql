-- ICT371 Q9: Farmer Cooperative Maize Deliveries  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path = q9, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);
-- unit_rate / total_value are filled by the BEFORE trigger, which runs before
-- NOT NULL is checked, so callers only supply the basic fields.
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(8,2)  NOT NULL,
    total_value  NUMERIC(12,2) NOT NULL,
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q9, public AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    ELSIF p_grade = 'A' THEN RETURN 5;
    ELSIF p_grade = 'B' THEN RETURN 4;
    ELSIF p_grade = 'C' THEN RETURN 3;
    END IF;
    RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
END $$;

-- (d) Trigger: one pricing rule for procedure and direct SQL ----------------
CREATE OR REPLACE FUNCTION trg_delivery_pricing() RETURNS trigger
LANGUAGE plpgsql SET search_path = q9, public AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade::text);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_pricing();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql SET search_path = q9, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id %', p_farmer_id;
    END IF;
    PERFORM fn_maize_rate(p_grade);                  -- rejects NULL / unsupported grade
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive';
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    -- unit_rate and total_value are deliberately omitted: the trigger supplies them
    INSERT INTO deliveries(farmer_id, grade, weight_kg, delivered_on, is_paid)
         VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- (a) Seed data (loaded after the trigger exists) ----------------------------
INSERT INTO farmers(farmer_number, full_name) VALUES
 ('F001', 'Joseph Zulu'), ('F002', 'Mercy Daka'), ('F003', 'Isaac Tembo');

CALL pr_receive_delivery(1, 'A', 100,  CURRENT_DATE - 3);
CALL pr_receive_delivery(1, 'B', 250,  CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'C', 80.5, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 40,   CURRENT_DATE - 1);
CALL pr_receive_delivery(1, 'C', 60,   CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'B', 120,  CURRENT_DATE - 1);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3, 4);   -- both payment states

-- Direct SQL follows the same pricing rule (supplied rate is overwritten):
INSERT INTO deliveries(farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (3, 'A', 10, 999, 999, CURRENT_DATE);                            -- becomes 5.00 / 50.00
SELECT delivery_id, grade, weight_kg, unit_rate, total_value, is_paid FROM deliveries ORDER BY 1;

-- Tests
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;   -- 5, 4, 3
DO $$ BEGIN PERFORM fn_maize_rate('D');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO deliveries(farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
            VALUES (1, 'A', 0, 5, 0, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value), 0) AS total_unpaid
  FROM farmers f
  LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
 GROUP BY f.farmer_id, f.farmer_number, f.full_name;   -- farmers with none show 0

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Index ----------------------------------------------------------------
-- farmer_id (equality) then delivered_on (range) serves "one farmer between
-- two dates" with a single contiguous index range scan.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM deliveries
 WHERE farmer_id = 1
   AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql SET search_path = q9, public AS $$
BEGIN
    INSERT INTO daily_purchases(purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
      FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
       SET total_weight = EXCLUDED.total_weight,
           total_value  = EXCLUDED.total_value;       -- replace, not add
END $$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);           -- rerun: same totals
SELECT * FROM daily_purchases;

SELECT cron.schedule('q9-refresh-purchases', '30 1 * * *',
       $cron$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$cron$);
