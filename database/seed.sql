-- database/seed.sql
-- Datos minimos de prueba para desarrollo local

INSERT INTO users (username, full_name, email, role)
VALUES ('jperez', 'Juan Perez', 'jperez@test.com', 'loan_officer');

INSERT INTO clients (first_name, last_name, document_type, document_number)
VALUES ('Ana', 'Gomez', 'DNI', '12345678');

INSERT INTO loan_products (product_name, interest_rate, term_months)
VALUES ('Personal 12 meses', 15.50, 12);

INSERT INTO loans (client_id, product_id, loan_officer_id, principal_amount, interest_rate, term_months, disbursement_date)
VALUES (1, 1, 1, 1000.00, 15.50, 12, '2026-09-01');

INSERT INTO installments (loan_id, installment_number, due_date, amount_due)
VALUES (1, 1, '2026-08-01', 100.00);