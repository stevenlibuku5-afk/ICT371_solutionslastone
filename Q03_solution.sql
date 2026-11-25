-- Question 3: Library Returns and Overdue Fines (PostgreSQL)

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on DATE NULL,
    fine_amount NUMERIC(10, 2) NOT NULL DEFAULT 0.00
);

CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0,
    total_fine NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_effective_date DATE;
    v_overdue_days INT;
BEGIN
    SELECT due_on, returned_on INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % not found', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        v_effective_date := LEAST(p_as_of, v_returned_on);
    ELSE
        v_effective_date := p_as_of;
    END IF;

    v_overdue_days := GREATEST(0, v_effective_date - v_due_on);
    RETURN (v_overdue_days * 2)::NUMERIC(10, 2);
END;
$$;

CREATE OR REPLACE FUNCTION fn_audit_loan_return()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION fn_audit_loan_return();

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_fine NUMERIC(10, 2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be null';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % not found', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan ID % has already been returned', p_loan_id;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date cannot precede borrowed date';
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

INSERT INTO books (title) VALUES
('Database System Concepts'),
('Clean Architecture'),
('PostgreSQL Up and Running');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
(1, 'Alice Phiri', CURRENT_DATE - 20, CURRENT_DATE - 6, NULL, 0.00),
(2, 'Brian Mulenga', CURRENT_DATE - 15, CURRENT_DATE - 1, NULL, 0.00),
(3, 'Clara Lungu', CURRENT_DATE - 5, CURRENT_DATE + 5, NULL, 0.00),
(1, 'David Zulu', CURRENT_DATE - 2, CURRENT_DATE + 12, NULL, 0.00),
(2, 'Esther Nyirenda', CURRENT_DATE - 14, CURRENT_DATE - 4, NULL, 0.00),
(3, 'Frank Sakala', CURRENT_DATE - 10, CURRENT_DATE, NULL, 0.00);

CALL pr_return_loan(5, CURRENT_DATE - 2);
CALL pr_return_loan(6, CURRENT_DATE);

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS current_fine
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN ANALYZE
SELECT * FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_total_fine NUMERIC(12, 2);
BEGIN
    SELECT
        COUNT(*),
        COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    INTO v_count, v_total_fine
    FROM loans
    WHERE returned_on IS NULL
      AND due_on < p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_total_fine)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_overdue_summary', '10 0 * * *', $$CALL pr_refresh_overdue(CURRENT_DATE);$$);
