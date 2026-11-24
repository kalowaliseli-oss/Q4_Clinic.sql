/* =====================================================================
   ICT371  QUESTION 4 - Clinic Appointment Scheduling             [50]
   Slots: 09:00, 10:00, 11:00, 12:00. Two NON-cancelled appointments may
   never share the same doctor + date + slot.
   ===================================================================== */
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4, public;

-- Test helper (not part of the marked answer)
CREATE PROCEDURE expect_error(p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'UNEXPECTED: statement succeeded -> %', p_sql;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected as expected -> %', SQLERRM;
END $$;


/* ---------------------------------------------------------------------
   (a) DATABASE AND SEED DATA                                       [6]
   - slot_time is TIME (as required) with a CHECK listing the four slots.
   - status is limited to BOOKED / ATTENDED / CANCELLED by a CHECK.
   - The slot rule itself is enforced by the trigger in (d), which is
     created BEFORE the seed appointments are inserted, so the seed data
     is checked too.
   - Past appointments (ATTENDED / CANCELLED) are inserted directly
     because pr_book_appointment correctly refuses past dates; future
     ones go through the procedure.
   --------------------------------------------------------------------- */
CREATE TABLE patients (
    patient_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id       INTEGER     NOT NULL REFERENCES patients (patient_id),
    doctor_id        INTEGER     NOT NULL REFERENCES doctors (doctor_id),
    appointment_day  DATE        NOT NULL,
    slot_time        TIME        NOT NULL
        CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status           VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date     DATE    PRIMARY KEY,
    booked_count     INTEGER NOT NULL CHECK (booked_count    >= 0),
    attended_count   INTEGER NOT NULL CHECK (attended_count  >= 0),
    cancelled_count  INTEGER NOT NULL CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES ('Mwila Banda'), ('Chanda Phiri'), ('Natasha Zulu');
INSERT INTO doctors  (full_name) VALUES ('Dr J. Mulenga'), ('Dr G. Tembo'), ('Dr P. Lungu');


/* ---------------------------------------------------------------------
   (b) FUNCTION fn_daily_load                                       [6]
   - Unknown doctor -> exception (EXISTS check).
   - COUNT(*) returns 0 (never NULL) when there are no rows, so a day
     without bookings returns 0 automatically.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor id %', p_doctor_id;
    END IF;
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM   appointments
    WHERE  doctor_id       = p_doctor_id
    AND    appointment_day = p_day
    AND    status <> 'CANCELLED';

    RETURN v_count;
END;
$$;


/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_book_appointment                                [8]
   - Validates patient, doctor, date (not NULL, not in the past) and slot.
   - Inserts status 'BOOKED'.
   - The clash check is NOT repeated here: the trigger in (d) performs it
     for every insert, so the rule lives in one place and also covers
     direct SQL.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient id %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor id %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book on % : date is missing or in the past', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot %: use 09:00, 10:00, 11:00 or 12:00', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;


/* ---------------------------------------------------------------------
   (d) TRIGGER: BEFORE INSERT OR UPDATE, FOR EACH ROW               [8]
   - A CANCELLED row can never clash, so it is let through at once.
   - Clash search = same doctor, same day, same slot, status not CANCELLED.
   - On UPDATE the row being changed must be excluded, otherwise it would
     "clash with itself" (e.g. changing BOOKED -> ATTENDED). Its id is
     taken from OLD into v_self_id; on INSERT v_self_id stays NULL and
     IS DISTINCT FROM NULL is true for every existing row.
   - pg_advisory_xact_lock(doctor, day) makes two simultaneous bookings
     for the same doctor/day wait for each other, so both cannot pass the
     EXISTS check at the same moment. The lock is released at commit.
   - BEFORE trigger: RAISE EXCEPTION stops the row before it is written.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_appointments_no_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_self_id appointments.appointment_id%TYPE;   -- NULL on INSERT
BEGIN
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_self_id := OLD.appointment_id;
    END IF;

    PERFORM pg_advisory_xact_lock(NEW.doctor_id, NEW.appointment_day - DATE '2000-01-01');

    IF EXISTS (
        SELECT 1
        FROM   appointments a
        WHERE  a.doctor_id       = NEW.doctor_id
        AND    a.appointment_day = NEW.appointment_day
        AND    a.slot_time       = NEW.slot_time
        AND    a.status <> 'CANCELLED'
        AND    a.appointment_id IS DISTINCT FROM v_self_id
    ) THEN
        RAISE EXCEPTION 'Slot clash: doctor % already has an appointment on % at %',
                        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointments_no_clash();


-- (a) continued: six appointments, no slot violations -----------------
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00', 'CANCELLED'),
    (3, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED');   -- same slot is OK: other one cancelled
CALL pr_book_appointment(1, 2, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE,     '11:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, '09:00');

SELECT * FROM appointments ORDER BY appointment_day, doctor_id, slot_time;

-- Tests for (b)
SELECT fn_daily_load(1, CURRENT_DATE - 1) AS dr1_yesterday,   -- 2 (cancelled not counted)
       fn_daily_load(3, CURRENT_DATE + 30) AS dr3_empty_day;  -- 0
CALL expect_error('SELECT fn_daily_load(99, CURRENT_DATE)');

-- Tests for (c)
CALL expect_error('CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, ''10:00'')');  -- bad patient
CALL expect_error('CALL pr_book_appointment(1, 99, CURRENT_DATE + 1, ''10:00'')');  -- bad doctor
CALL expect_error('CALL pr_book_appointment(1, 1, CURRENT_DATE - 3, ''10:00'')');   -- past date
CALL expect_error('CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, ''14:00'')');   -- bad slot

-- Tests for (d)
CALL expect_error('CALL pr_book_appointment(2, 1, CURRENT_DATE + 1, ''09:00'')');   -- clash
CALL expect_error($q$INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time)
                     VALUES (2, 2, CURRENT_DATE, '10:00')$q$);                     -- direct SQL clash
-- UPDATE of the same row must not clash with itself:
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;
-- Moving an appointment onto an occupied slot is rejected:
CALL expect_error($q$UPDATE appointments SET doctor_id = 1, appointment_day = CURRENT_DATE + 1, slot_time = '09:00'
                     WHERE appointment_id = 5$q$);
-- Re-activating a cancelled appointment whose slot is now taken is rejected:
CALL expect_error($q$UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 2$q$);


/* ---------------------------------------------------------------------
   (e) VIEW v_today_appointments                                    [5]
   - Only today's BOOKED rows.
   - Only the columns the brief asks for: no patient_id, no other patient
     details, never SELECT p.* (that is what "do not expose unrelated
     patient data" means). Staff can be granted access to the view only,
     not to the patients table.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.slot_time,
       p.full_name AS patient_name,
       d.full_name AS doctor_name
FROM   appointments a
JOIN   patients p ON p.patient_id = a.patient_id
JOIN   doctors  d ON d.doctor_id  = a.doctor_id
WHERE  a.appointment_day = CURRENT_DATE
AND    a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

-- Example of restricting a reception role to the view (optional):
-- CREATE ROLE reception;
-- GRANT USAGE ON SCHEMA q4 TO reception;
-- GRANT SELECT ON q4.v_today_appointments TO reception;


/* ---------------------------------------------------------------------
   (f) NON-UNIQUE INDEX                                              [5]
   Searches: WHERE appointment_day = ? AND doctor_id = ?
   - Must be NON-unique: cancelled rows may share day/doctor/slot, and a
     doctor has up to four appointments per day anyway.
   - appointment_day is placed FIRST because the clinic also searches by
     day alone (v_today_appointments, the daily summary job). A B-tree can
     use its leading column on its own, so this one index serves both
     "day" and "day + doctor" searches. It also speeds up the clash search
     in the trigger (day + doctor + filter on slot).
   --------------------------------------------------------------------- */
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

EXPLAIN
SELECT appointment_id, slot_time, status
FROM   appointments
WHERE  appointment_day = CURRENT_DATE
AND    doctor_id = 2;

SET enable_seqscan = off;     -- tiny table; show the plan used at real volume
EXPLAIN ANALYZE
SELECT appointment_id, slot_time, status
FROM   appointments
WHERE  appointment_day = CURRENT_DATE
AND    doctor_id = 2;
RESET enable_seqscan;


/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB                                                 [6]
   - COUNT(*) FILTER (WHERE ...) counts each status in one pass.
   - ON CONFLICT ... DO UPDATE replaces that date's summary on rerun.
   - '0 1 * * *' = 01:00 daily, for CURRENT_DATE - 1 (previous day).
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
SET search_path = q4, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM   appointments
    WHERE  appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET    booked_count    = EXCLUDED.booked_count,
           attended_count  = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces
CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM clinic_summary ORDER BY summary_date;

SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',
    $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$
);

SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q4_refresh_clinic_summary';
