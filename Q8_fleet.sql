-- ICT371 Q8: Transport Fleet Maintenance  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path = q8, public;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql SET search_path = q8, public AS $$
DECLARE v_km INT;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
      FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END $$;

-- (c) Procedure (does NOT touch the odometer; the trigger does) --------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql SET search_path = q8, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;
    INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
         VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (d) Trigger: BEFORE INSERT, fires once per new row, so the odometer moves once
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS trigger
LANGUAGE plpgsql SET search_path = q8, public AS $$
DECLARE v_current INT;
BEGIN
    SELECT current_odometer INTO v_current
      FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;   -- serialise trips
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % <= start %', NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at current odometer %, got %', v_current, NEW.start_odometer;
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (a) Seed data (trips loaded through the procedure, after the trigger) ------
INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1001', 10000,     4000),   -- 6000 km since service  -> due
 ('ABC 1002', 20000,    18000),   -- 2000 km                -> not due
 ('ABC 1003',  5000,        0);   -- exactly 5000 km        -> due

CALL pr_record_trip(1, CURRENT_DATE - 5, 10000, 10200);
CALL pr_record_trip(1, CURRENT_DATE - 3, 10200, 10450);
CALL pr_record_trip(2, CURRENT_DATE - 4, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20300, 20500);
CALL pr_record_trip(3, CURRENT_DATE - 3, 5000,  5100);
CALL pr_record_trip(3, CURRENT_DATE - 1, 5100,  5400);

SELECT vehicle_id, current_odometer, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;
-- 10450 true | 20500 false | 5400 true

-- Tests
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 10450, 10450);   -- end = start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 9000, 9500);     -- wrong start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 1, 2);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_service_due(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
  FROM vehicles
 WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) Index ----------------------------------------------------------------
-- vehicle_id (equality) then trip_on (range): one vehicle's trips for a period
-- are contiguous and already sorted by date in the index.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
 WHERE vehicle_id = 1
   AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql SET search_path = q8, public AS $$
BEGIN
    -- insert a new alert or refresh km (flagged_on keeps the first-flagged date)
    INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
      FROM vehicles
     WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
       SET km_since_service = EXCLUDED.km_since_service;

    -- remove alerts for vehicles that are no longer due (e.g. after service)
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                        WHERE v.vehicle_id = sa.vehicle_id
                          AND v.current_odometer - v.last_service_odometer >= 5000);
END $$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;         -- vehicles 1 and 3

UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 3;  -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;         -- only vehicle 1 remains

-- Every Monday 06:00
SELECT cron.schedule('q8-refresh-service-alerts', '0 6 * * 1',
       $cron$CALL q8.pr_refresh_service_alerts()$cron$);
