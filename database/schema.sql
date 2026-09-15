-- Loan Collections Platform - Schema inicial (Modulo 2)
-- Reglas de diseño: DECIMAL para dinero, ON DELETE RESTRICT, CHECK constraints,
-- soft-delete (is_active), indice compuesto en installments(due_date, status).

CREATE TABLE clients (
    client_id       BIGSERIAL PRIMARY KEY,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    document_type   VARCHAR(20)  NOT NULL,
    document_number VARCHAR(30)  NOT NULL UNIQUE,
    email           VARCHAR(150),
    phone           VARCHAR(30),
    address         VARCHAR(250),
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
    user_id     BIGSERIAL PRIMARY KEY,
    username    VARCHAR(50)  NOT NULL UNIQUE,
    full_name   VARCHAR(150) NOT NULL,
    email       VARCHAR(150) NOT NULL UNIQUE,
    role        VARCHAR(30)  NOT NULL
                CHECK (role IN ('loan_officer', 'collections_agent', 'admin')),
    is_active   BOOLEAN NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE loan_products (
    product_id      BIGSERIAL PRIMARY KEY,
    product_name    VARCHAR(100) NOT NULL,
    interest_rate   DECIMAL(5,2) NOT NULL,
    term_months     INT NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE loans (
    loan_id             BIGSERIAL PRIMARY KEY,
    client_id           BIGINT NOT NULL REFERENCES clients(client_id) ON DELETE RESTRICT,
    product_id          BIGINT NOT NULL REFERENCES loan_products(product_id) ON DELETE RESTRICT,
    loan_officer_id     BIGINT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    principal_amount    DECIMAL(12,2) NOT NULL,
    interest_rate       DECIMAL(5,2) NOT NULL, -- snapshot del producto al desembolsar
    term_months         INT NOT NULL,
    disbursement_date   DATE NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'paid_off', 'defaulted', 'cancelled')),
    is_active           BOOLEAN NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE installments (
    installment_id      BIGSERIAL PRIMARY KEY,
    loan_id              BIGINT NOT NULL REFERENCES loans(loan_id) ON DELETE RESTRICT,
    installment_number  INT NOT NULL,
    due_date            DATE NOT NULL,
    amount_due          DECIMAL(12,2) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'paid', 'partially_paid', 'late')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_installments_due_status ON installments (due_date, status);

CREATE TABLE payments (
    payment_id       BIGSERIAL PRIMARY KEY,
    installment_id   BIGINT NOT NULL REFERENCES installments(installment_id) ON DELETE RESTRICT,
    amount_paid      DECIMAL(12,2) NOT NULL,
    payment_date     TIMESTAMPTZ NOT NULL DEFAULT now(),
    payment_method   VARCHAR(30) NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE collection_actions (
    action_id     BIGSERIAL PRIMARY KEY,
    loan_id       BIGINT NOT NULL REFERENCES loans(loan_id) ON DELETE RESTRICT,
    agent_id      BIGINT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    action_type   VARCHAR(30) NOT NULL
                  CHECK (action_type IN ('call', 'email', 'visit', 'letter', 'legal_notice')),
    outcome       VARCHAR(100),
    notes         TEXT,
    action_date   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
    audit_id     BIGSERIAL PRIMARY KEY,
    table_name   VARCHAR(50) NOT NULL,
    record_id    BIGINT NOT NULL,
    action       VARCHAR(10) NOT NULL
                 CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    old_value    JSONB,
    new_value    JSONB,
    changed_by   BIGINT REFERENCES users(user_id) ON DELETE RESTRICT,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);