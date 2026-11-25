-- Small schema loaded into the docker-compose database, and used by the
-- integration test. Safe to run more than once.

CREATE TABLE IF NOT EXISTS app_meta (
    key text PRIMARY KEY,
    value text NOT NULL
);

INSERT INTO app_meta (key, value)
VALUES ('schema_version', '1')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS customers (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id integer NOT NULL REFERENCES customers (id),
    amount_cents integer NOT NULL CHECK (amount_cents >= 0),
    status text NOT NULL DEFAULT 'open',
    created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO customers (email, name)
VALUES
    ('ada@example.com', 'Ada'),
    ('linus@example.com', 'Linus')
ON CONFLICT (email) DO NOTHING;

INSERT INTO orders (customer_id, amount_cents, status)
SELECT c.id, 2500, 'paid'
FROM customers c
WHERE c.email = 'ada@example.com'
  AND NOT EXISTS (
      SELECT 1
      FROM orders o
      WHERE o.customer_id = c.id
        AND o.amount_cents = 2500
  );
