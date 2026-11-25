-- Question 5: Hostel Room Allocation (PostgreSQL)

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    room_id INT NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocation_status_dates CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL,
    free_beds INT NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN
    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % not found', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;

CREATE OR REPLACE FUNCTION fn_validate_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (
            SELECT 1
            FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id)
        ) THEN
            RAISE EXCEPTION 'Student ID % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT capacity INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id
        FOR UPDATE;

        SELECT COUNT(*) INTO v_occupied
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION 'Room ID % has reached full capacity (%)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_validate
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_validate_allocation();

CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Student ID % not found', p_student_id;
    END IF;

    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be null';
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student ID % already has an active room allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'No free beds available in room ID %', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

INSERT INTO rooms (room_number, capacity) VALUES
('H101', 2),
('H102', 3),
('H103', 2);

INSERT INTO students (student_number, full_name) VALUES
('ST101', 'Kelvin Phiri'),
('ST102', 'Lydia Banda'),
('ST103', 'Moses Tembo'),
('ST104', 'Nancy Mulenga');

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
(4, 3, CURRENT_DATE - 30, CURRENT_DATE - 5, 'ENDED');

CALL pr_allocate_room(1, 1, CURRENT_DATE - 10);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 8);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 3);

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN ANALYZE
SELECT * FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id),
        r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_hostel_occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy();$$);
