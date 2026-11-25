-- Question 6: Monthly Payroll Processing (PostgreSQL)

CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12, 2) NOT NULL CHECK (basic_salary >= 0),
    allowance NUMERIC(12, 2) NOT NULL CHECK (allowance >= 0),
    deduction NUMERIC(12, 2) NOT NULL CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay NUMERIC(12, 2) NOT NULL,
    net_pay NUMERIC(12, 2) NOT NULL,
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12, 2) NOT NULL,
    new_salary NUMERIC(12, 2) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic NUMERIC(12, 2);
    v_allowance NUMERIC(12, 2);
    v_deduction NUMERIC(12, 2);
    v_net NUMERIC(12, 2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee ID % not found', p_employee_id;
    END IF;

    v_net := (v_basic + v_allowance) - v_deduction;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay (%) is negative for employee ID %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

CREATE OR REPLACE FUNCTION fn_audit_salary_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_audit_salary_change();

CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
    v_gross NUMERIC(12, 2);
    v_net NUMERIC(12, 2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'pay_month must be the first day of a month';
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
    LOOP
        v_gross := rec.basic_salary + rec.allowance;
        v_net := fn_net_pay(rec.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
('Oscar Mwansa', 8000.00, 1500.00, 800.00, TRUE),
('Patricia Zulu', 12000.00, 2000.00, 1200.00, TRUE),
('Quentin Banda', 6500.00, 1000.00, 500.00, TRUE);

CALL pr_process_payroll('2026-09-01');
UPDATE employees SET active = FALSE WHERE employee_id = 3;
CALL pr_process_payroll('2026-10-01');

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'monthly_payroll_job',
    '0 2 1 * *',
    $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);$$
);

-- Inspect scheduled jobs and execution history
SELECT jobid, schedule, command, active FROM cron.job WHERE jobname = 'monthly_payroll_job';
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
