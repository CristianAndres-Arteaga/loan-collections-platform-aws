-- database/demo-data.sql
-- Datos de demostracion para el dashboard (Modulo 12a).
-- Fechas RELATIVAS a CURRENT_DATE: la demo siempre muestra cuotas vencidas,
-- pagadas y por vencer, sin importar el dia en que se cargue.
-- Offsets >= 5 dias: RDS evalua CURRENT_DATE en UTC y la app usa
-- America/La_Paz (UTC-4); asi ninguna cuota cambia de estado por la zona horaria.
-- Uso: psql ... -v ON_ERROR_STOP=1 -f database/demo-data.sql

BEGIN;

-- Guarda de idempotencia: abortar si la demo ya fue cargada.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM clients WHERE document_number IN ('4823901', '5129847', '6034512', '3398721')) THEN
        RAISE EXCEPTION 'demo-data.sql ya fue cargado (clientes demo existentes)';
    END IF;
END $$;

INSERT INTO loan_products (product_name, interest_rate, term_months)
VALUES ('Microcredito 3 meses', 18.00, 3);

INSERT INTO clients (first_name, last_name, document_type, document_number, email, phone, address) VALUES
    ('Carla', 'Mendoza', 'CI', '4823901', 'carla.mendoza@example.com', '+591 70000001', 'Av. Arce 1520, La Paz'),
    ('Luis',  'Quispe',  'CI', '5129847', 'luis.quispe@example.com',   '+591 70000002', 'Calle Sagarnaga 210, La Paz'),
    ('Maria', 'Flores',  'CI', '6034512', 'maria.flores@example.com',  '+591 70000003', 'Av. 6 de Agosto 2400, La Paz'),
    ('Jorge', 'Vargas',  'CI', '3398721', 'jorge.vargas@example.com',  '+591 70000004', 'Calle 21 de Calacoto 815, La Paz');

-- Cuota = principal * (1 + 18% * 3/12) / 3
INSERT INTO loans (client_id, product_id, loan_officer_id, principal_amount, interest_rate, term_months, disbursement_date, status)
SELECT c.client_id,
       (SELECT product_id FROM loan_products WHERE product_name = 'Microcredito 3 meses'),
       (SELECT user_id FROM users WHERE username = 'jperez'),
       v.principal, 18.00, 3, CURRENT_DATE - v.days_ago, v.status
FROM (VALUES
    ('4823901', 1500.00, 100, 'active'),    -- 3ra cuota vencida sin pagar
    ('5129847', 3000.00,  75, 'active'),    -- pago parcial en la 2da cuota
    ('6034512',  900.00,  50, 'active'),    -- 1ra cuota vencida
    ('3398721', 2000.00,  95, 'paid_off')   -- prestamo cancelado completo
) AS v(document_number, principal, days_ago, status)
JOIN clients c ON c.document_number = v.document_number;

INSERT INTO installments (loan_id, installment_number, due_date, amount_due, status)
SELECT l.loan_id, v.num, CURRENT_DATE + v.due_offset, v.amount, v.status
FROM (VALUES
    ('4823901', 1, -70,  522.50, 'paid'),
    ('4823901', 2, -40,  522.50, 'paid'),
    ('4823901', 3, -10,  522.50, 'pending'),  -- vencida: nadie la marca 'late' (no hay job)
    ('5129847', 1, -45, 1045.00, 'paid'),
    ('5129847', 2, -15, 1045.00, 'partially_paid'),
    ('5129847', 3,  15, 1045.00, 'pending'),
    ('6034512', 1, -20,  313.50, 'pending'),  -- vencida
    ('6034512', 2,  10,  313.50, 'pending'),
    ('6034512', 3,  40,  313.50, 'pending'),
    ('3398721', 1, -65,  696.67, 'paid'),
    ('3398721', 2, -35,  696.67, 'paid'),
    ('3398721', 3,  -5,  696.66, 'paid')
) AS v(document_number, num, due_offset, amount, status)
JOIN clients c ON c.document_number = v.document_number
JOIN loans   l ON l.client_id = c.client_id;

-- Pagos coherentes con el estado de cada cuota (pagadas 2 dias antes del vencimiento).
INSERT INTO payments (installment_id, amount_paid, payment_date, payment_method)
SELECT i.installment_id,
       COALESCE(v.partial_amount, i.amount_due),
       (i.due_date - 2)::timestamp AT TIME ZONE 'America/La_Paz' + INTERVAL '10 hours',
       v.method
FROM (VALUES
    ('4823901', 1, NULL::numeric, 'transfer'),
    ('4823901', 2, NULL,          'qr'),
    ('5129847', 1, NULL,          'cash'),
    ('5129847', 2, 500.00,        'cash'),
    ('3398721', 1, NULL,          'transfer'),
    ('3398721', 2, NULL,          'transfer'),
    ('3398721', 3, NULL,          'qr')
) AS v(document_number, num, partial_amount, method)
JOIN clients      c ON c.document_number = v.document_number
JOIN loans        l ON l.client_id = c.client_id
JOIN installments i ON i.loan_id = l.loan_id AND i.installment_number = v.num;

COMMIT;
