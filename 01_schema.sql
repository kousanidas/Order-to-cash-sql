-- =============================================================================
-- Order-to-Cash  |  01_schema.sql
--
-- SQLite 3.35 or later. Run this first, on an empty file:
--     sqlite3 o2c.db < 01_schema.sql
--
-- Twelve tables. Eleven are modelled and typed. The twelfth,
-- raw_quote_register, is every column TEXT on purpose - it is the quotation
-- register exactly as it comes out of the spreadsheet, and the whole point of
-- 03_cleaning.sql is to turn that into something you can query. Casting it on
-- the way in would throw away the mess that the project is about.
-- =============================================================================

PRAGMA foreign_keys = ON;

DROP VIEW  IF EXISTS v_otif;
DROP VIEW  IF EXISTS v_order_lines;
DROP VIEW  IF EXISTS v_orders;
DROP VIEW  IF EXISTS v_raw_register;
DROP TABLE IF EXISTS cleaning_log;
DROP TABLE IF EXISTS raw_quote_register;
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS invoices;
DROP TABLE IF EXISTS dispatches;
DROP TABLE IF EXISTS order_lines;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS quotation_lines;
DROP TABLE IF EXISTS quotations;
DROP TABLE IF EXISTS payment_terms;
DROP TABLE IF EXISTS items;
DROP TABLE IF EXISTS customers;


-- ----------------------------------------------------------------- customers
CREATE TABLE customers (
    customer_id     TEXT PRIMARY KEY,
    market_type     TEXT NOT NULL CHECK (market_type IN
                        ('Domestic', 'Export', 'Deemed Export')),
    country         TEXT NOT NULL,
    region          TEXT NOT NULL,
    onboarded_date  TEXT NOT NULL            -- ISO yyyy-mm-dd
);

-- --------------------------------------------------------------------- items
-- vessel_diameter_mm is only meaningful for pressure vessels and is NULL
-- everywhere else. Query 4 splits lead time by it.
CREATE TABLE items (
    item_id             TEXT PRIMARY KEY,
    product_line        TEXT NOT NULL CHECK (product_line IN
                            ('Pressure Vessel', 'Pultrusion', 'Grating')),
    category            TEXT NOT NULL,
    description         TEXT NOT NULL,
    uom                 TEXT NOT NULL,
    vessel_diameter_mm  INTEGER
);

-- ------------------------------------------------------------- payment_terms
-- credit_days is what the due date is calculated from. advance_pct is there
-- because a third of the real wordings ask for money up front.
CREATE TABLE payment_terms (
    terms_code   TEXT PRIMARY KEY,
    description  TEXT NOT NULL,
    credit_days  INTEGER NOT NULL,
    advance_pct  REAL NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------- quotations
-- revision_no is 0 for a first issue. The real register records revisions by
-- appending " REV-03" to the quote number rather than keeping a version table,
-- so one quote_no can appear at several revisions.
CREATE TABLE quotations (
    quote_id          INTEGER PRIMARY KEY,
    quote_no          TEXT NOT NULL,
    revision_no       INTEGER NOT NULL DEFAULT 0,
    customer_id       TEXT NOT NULL REFERENCES customers(customer_id),
    inquiry_date      TEXT,
    quote_date        TEXT NOT NULL,
    validity_date     TEXT,
    incoterms         TEXT,
    salesperson_code  TEXT NOT NULL,
    status            TEXT NOT NULL,
    UNIQUE (quote_no, revision_no)
);

CREATE TABLE quotation_lines (
    quote_id   INTEGER NOT NULL REFERENCES quotations(quote_id),
    line_no    INTEGER NOT NULL,
    item_id    TEXT    NOT NULL REFERENCES items(item_id),
    qty        REAL    NOT NULL CHECK (qty > 0),
    unit_price REAL    NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (quote_id, line_no)
);

-- -------------------------------------------------------------------- orders
-- quote_id is NULLABLE and that is the single most important thing in this
-- schema. Most orders in the real register arrive as a repeat PO with no
-- formal quotation behind them - 77% of vessel orders. An inner join from
-- orders to quotations silently throws most of the book away, which is exactly
-- the mistake query 1 is built to avoid.
--
-- promised_delivery_date is also nullable: the register records one on only
-- 24% of orders. Where it is blank the PO supplies it, and cleaning_log
-- records how many were filled that way.
CREATE TABLE orders (
    order_id                INTEGER PRIMARY KEY,
    quote_id                INTEGER REFERENCES quotations(quote_id),
    po_no                   TEXT,
    po_date                 TEXT NOT NULL,
    job_no                  INTEGER UNIQUE,
    customer_id             TEXT NOT NULL REFERENCES customers(customer_id),
    promised_delivery_date  TEXT,
    promised_date_source    TEXT NOT NULL CHECK (promised_date_source IN
                                ('register', 'po_document', 'none')),
    terms_code              TEXT REFERENCES payment_terms(terms_code),
    ld_clause               TEXT,
    ld_clause_source        TEXT,
    order_status            TEXT NOT NULL,
    cancellation_date       TEXT
);

CREATE TABLE order_lines (
    order_id    INTEGER NOT NULL REFERENCES orders(order_id),
    line_no     INTEGER NOT NULL,
    item_id     TEXT    NOT NULL REFERENCES items(item_id),
    ordered_qty REAL    NOT NULL CHECK (ordered_qty > 0),
    unit_price  REAL    NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (order_id, line_no)
);

-- ----------------------------------------------------------------- dispatches
-- One row per physical movement. A line can go out in more than one dispatch,
-- which is why "in full" has to be summed per line rather than read off a
-- single row.
CREATE TABLE dispatches (
    dispatch_id    INTEGER PRIMARY KEY,
    order_id       INTEGER NOT NULL REFERENCES orders(order_id),
    line_no        INTEGER NOT NULL,
    dispatch_date  TEXT    NOT NULL,
    dispatched_qty REAL    NOT NULL CHECK (dispatched_qty > 0),
    ship_mode      TEXT    NOT NULL,
    delay_reason   TEXT,
    FOREIGN KEY (order_id, line_no) REFERENCES order_lines(order_id, line_no)
);

-- ------------------------------------------------------------------ invoices
-- invoice_date equals the dispatch date, per the brief. Export invoices are in
-- USD with an FX rate to INR and are zero-rated for GST; domestic invoices are
-- in INR at 18%. taxable_value is in the invoice currency, so anything that
-- adds across markets has to multiply by fx_rate_to_inr first.
CREATE TABLE invoices (
    invoice_id      INTEGER PRIMARY KEY,
    invoice_no      TEXT NOT NULL UNIQUE,
    dispatch_id     INTEGER NOT NULL UNIQUE REFERENCES dispatches(dispatch_id),
    order_id        INTEGER NOT NULL REFERENCES orders(order_id),
    customer_id     TEXT NOT NULL REFERENCES customers(customer_id),
    invoice_date    TEXT NOT NULL,
    currency        TEXT NOT NULL CHECK (currency IN ('INR', 'USD')),
    fx_rate_to_inr  REAL NOT NULL CHECK (fx_rate_to_inr > 0),
    taxable_value   REAL NOT NULL CHECK (taxable_value >= 0),
    gst_amount      REAL NOT NULL CHECK (gst_amount >= 0),
    due_date        TEXT NOT NULL
);

-- ------------------------------------------------------------------ payments
-- payment_type separates a part payment from a settlement, because a customer
-- who always pays half on time and half very late looks punctual on a simple
-- average of payment dates.
CREATE TABLE payments (
    payment_id    INTEGER PRIMARY KEY,
    invoice_id    INTEGER NOT NULL REFERENCES invoices(invoice_id),
    payment_date  TEXT NOT NULL,
    amount        REAL NOT NULL CHECK (amount > 0),
    payment_type  TEXT NOT NULL CHECK (payment_type IN
                      ('Advance', 'Part', 'Full', 'Final'))
);

-- -------------------------------------------------------- raw_quote_register
-- EVERY COLUMN IS TEXT. This is deliberate and it is the point of the project.
--
-- Dates arrive in three formats, one of them impossible (31-11-2024). Status
-- has 45 spellings for 13 states. Job numbers come in six bands. The quote
-- number column sometimes holds a status word or a GEM tender ID. LD and
-- "LD Clause" are two columns for one idea, and both hold things that are
-- neither - delivery months, the word "Lost", payment terms.
--
-- 03_cleaning.sql reads this table and never writes to it.
CREATE TABLE raw_quote_register (
    sl_no              TEXT,
    party              TEXT,
    project            TEXT,
    incoterms          TEXT,
    quote_from         TEXT,
    quote_no           TEXT,
    quote_date         TEXT,
    validity_date      TEXT,
    vertical           TEXT,
    category           TEXT,
    item               TEXT,
    item_qty           TEXT,
    inquiry            TEXT,
    inquiry_date       TEXT,
    job_no             TEXT,
    po_no              TEXT,
    po_date            TEXT,
    po_validity_date   TEXT,
    dp_date            TEXT,
    status             TEXT,
    ld                 TEXT,
    ld_clause          TEXT,
    payment_terms      TEXT,
    po_quote_value     TEXT,
    concerned_person   TEXT
);

-- --------------------------------------------------------------- cleaning_log
-- Every cleaning decision lands here: what was found, how many rows, and
-- whether it was fixed or only flagged. A cleaning step nobody can audit is
-- indistinguishable from making the numbers up, so this table is part of the
-- deliverable rather than a debugging aid.
CREATE TABLE cleaning_log (
    log_id       INTEGER PRIMARY KEY,
    step         TEXT NOT NULL,
    column_name  TEXT,
    issue        TEXT NOT NULL,
    rows_found   INTEGER NOT NULL,
    action       TEXT NOT NULL CHECK (action IN ('FLAGGED', 'MAPPED', 'FILLED',
                                                 'PARSED', 'EXCLUDED')),
    note         TEXT
);


-- ------------------------------------------------------------------- indexes
CREATE INDEX idx_orders_customer   ON orders(customer_id);
CREATE INDEX idx_orders_quote      ON orders(quote_id);
CREATE INDEX idx_orders_po_date    ON orders(po_date);
CREATE INDEX idx_ol_order          ON order_lines(order_id);
CREATE INDEX idx_disp_order        ON dispatches(order_id, line_no);
CREATE INDEX idx_inv_order         ON invoices(order_id);
CREATE INDEX idx_inv_customer      ON invoices(customer_id);
CREATE INDEX idx_inv_due           ON invoices(due_date);
CREATE INDEX idx_pay_invoice       ON payments(invoice_id);
CREATE INDEX idx_quot_customer     ON quotations(customer_id);
