-- Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL)

CREATE TABLE farmers (
    farmer_id SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id SERIAL PRIMARY KEY,
    farmer_id INT NOT NULL REFERENCES farmers(farmer_id),
    grade CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate NUMERIC(10, 2) NOT NULL,
    total_value NUMERIC(12, 2) NOT NULL,
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    total_value NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE RAISE EXCEPTION 'Unsupported maize grade: %', p_grade;
    END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION fn_calculate_delivery_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight must be positive';
    END IF;

    NEW.grade := UPPER(TRIM(NEW.grade));
    NEW.unit_rate := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_calculate
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_calculate_delivery_value();

CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Farmer ID % not found', p_farmer_id;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be null';
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive';
    END IF;

    PERFORM fn_maize_rate(p_grade);

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

INSERT INTO farmers (farmer_number, full_name) VALUES
('FRM001', 'Andrew Musonda'),
('FRM002', 'Beatrice Kabwe'),
('FRM003', 'Caleb Simukonda');

CALL pr_receive_delivery(1, 'A', 500.00, CURRENT_DATE - 3);
CALL pr_receive_delivery(1, 'B', 300.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 450.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 200.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 600.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'C', 150.00, CURRENT_DATE);

UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 3;

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0.00) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN ANALYZE
SELECT * FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_weight NUMERIC(12, 2);
    v_value NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(weight_kg), 0.00), COALESCE(SUM(total_value), 0.00)
    INTO v_weight, v_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date)
    DO UPDATE SET
        total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_maize_purchases', '30 1 * * *', $$CALL pr_refresh_purchases(CURRENT_DATE - 1);$$);
