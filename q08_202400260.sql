-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- Student: Cecilia Shikabanga | Student No: 202400260

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE NOT NULL
);

-- Three vehicles in different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1234', 12000, 10000),   -- 2,000 km since service
    ('BCD 5678', 20000, 14000),   -- 6,000 km since service  -> already due
    ('CDE 9012',  8000,  4000);   -- 4,000 km since service  -> becomes due after trips

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END;
$$ LANGUAGE plpgsql STABLE;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- lock the vehicle row so two trips cannot both start from the same odometer
    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
            NEW.start_odometer, v_current;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % must be greater than start %',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    -- the ONLY place the odometer is updated (once per inserted trip)
    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (c) Procedure (does NOT touch the vehicle odometer) -------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE,
                                           p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (a) continued: six trips added THROUGH the procedure (trigger already installed)
CALL pr_record_trip(1, CURRENT_DATE - 6, 12000, 12400);
CALL pr_record_trip(1, CURRENT_DATE - 4, 12400, 12900);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20500);
CALL pr_record_trip(2, CURRENT_DATE - 3, 20500, 21000);
CALL pr_record_trip(3, CURRENT_DATE - 2, 8000,  8700);
CALL pr_record_trip(3, CURRENT_DATE - 1, 8700,  9300);   -- 5,300 km since service -> due

SELECT * FROM trips ORDER BY trip_id;
SELECT * FROM vehicles ORDER BY vehicle_id;              -- odometers moved to trip ends

-- Tests
SELECT vehicle_id, fn_service_due(vehicle_id) AS service_due FROM vehicles ORDER BY 1;  -- f, t, t
DO $$
BEGIN
    BEGIN PERFORM fn_service_due(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(99, CURRENT_DATE, 100, 200);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12900, 12900);    -- end not greater than start
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 15000, 15100);    -- start does not match odometer
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
          VALUES (1, CURRENT_DATE, 12900, 12800);                -- direct SQL, bad mileage
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) Index ----------------------------------------------------------------
-- Equality on vehicle_id then a range on trip_on -> composite (vehicle_id, trip_on).
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;   -- tiny table: force the plan to show the index
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- insert a new alert or update the km of an existing one (one alert per vehicle)
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    -- remove alerts for vehicles that are no longer due (serviced)
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;        -- vehicles 2 and 3

-- Vehicle 2 gets serviced -> its alert must disappear
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;        -- only vehicle 3

-- Every Monday at 06:00
-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_service_alerts_weekly', '0 6 * * 1',
        $$CALL pr_refresh_service_alerts()$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
