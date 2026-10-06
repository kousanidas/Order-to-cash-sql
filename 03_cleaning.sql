-- =============================================================================
-- Order-to-Cash  |  03_cleaning.sql
--
-- Run after 02_generate_data.py:
--     sqlite3 o2c.db < 03_cleaning.sql
--
-- Builds two views - v_raw_register (the cleaned register, which every later
-- query reads from) and v_otif (the OTIF definition, kept in one place so no
-- query can quietly redefine it) - and writes every decision to cleaning_log.
-- The raw table is never updated.
--
-- Two rules this file follows:
--   1. Nothing is silently fixed. A bad row is flagged and counted. Guessing
--      what somebody meant to type is not the analyst's call.
--   2. Every mapping is visible. Appendix A in 04_analysis_queries.sql prints
--      every raw status wording against the state it was mapped to, so a reader
--      can disagree with a specific line.
--
-- THE TRAP WORTH KNOWING ABOUT. SQLite's date() does not reject an impossible
-- date, it rolls it forward: date('2024-11-31') returns 2024-12-01. The
-- register contains exactly that value. A plain CAST would turn 31 November
-- into 1 December and nobody would ever see it. So every parse here is
-- round-tripped and compared against what went in, and anything that does not
-- come back identical is flagged instead of accepted.
-- =============================================================================

DELETE FROM cleaning_log;
DROP VIEW IF EXISTS v_otif;
DROP VIEW IF EXISTS v_raw_register;

CREATE VIEW v_raw_register AS
WITH reordered AS (
    SELECT
        r.*,
        -- Three formats, all as text. Reordered into yyyy-mm-dd by position;
        -- nothing is parsed yet, so an impossible day survives to be caught.
        CASE
            WHEN r.quote_date IS NULL OR LENGTH(TRIM(r.quote_date)) <> 10 THEN NULL
            WHEN SUBSTR(r.quote_date, 3, 1) = '.' THEN
                 SUBSTR(r.quote_date, 7, 4) || '-' || SUBSTR(r.quote_date, 4, 2)
                 || '-' || SUBSTR(r.quote_date, 1, 2)
            WHEN SUBSTR(r.quote_date, 3, 1) = '-' THEN
                 SUBSTR(r.quote_date, 7, 4) || '-' || SUBSTR(r.quote_date, 4, 2)
                 || '-' || SUBSTR(r.quote_date, 1, 2)
            WHEN SUBSTR(r.quote_date, 5, 1) = '-' THEN r.quote_date
        END AS quote_iso_raw,
        CASE
            WHEN r.po_date IS NULL OR LENGTH(TRIM(r.po_date)) <> 10 THEN NULL
            WHEN SUBSTR(r.po_date, 3, 1) IN ('.', '-') THEN
                 SUBSTR(r.po_date, 7, 4) || '-' || SUBSTR(r.po_date, 4, 2)
                 || '-' || SUBSTR(r.po_date, 1, 2)
            WHEN SUBSTR(r.po_date, 5, 1) = '-' THEN r.po_date
        END AS po_iso_raw,
        CASE
            WHEN r.dp_date IS NULL OR LENGTH(TRIM(r.dp_date)) <> 10 THEN NULL
            WHEN SUBSTR(r.dp_date, 3, 1) IN ('.', '-') THEN
                 SUBSTR(r.dp_date, 7, 4) || '-' || SUBSTR(r.dp_date, 4, 2)
                 || '-' || SUBSTR(r.dp_date, 1, 2)
            WHEN SUBSTR(r.dp_date, 5, 1) = '-' THEN r.dp_date
        END AS dp_iso_raw,
        CASE
            WHEN r.validity_date IS NULL OR LENGTH(TRIM(r.validity_date)) <> 10 THEN NULL
            WHEN SUBSTR(r.validity_date, 3, 1) IN ('.', '-') THEN
                 SUBSTR(r.validity_date, 7, 4) || '-' || SUBSTR(r.validity_date, 4, 2)
                 || '-' || SUBSTR(r.validity_date, 1, 2)
            WHEN SUBSTR(r.validity_date, 5, 1) = '-' THEN r.validity_date
        END AS validity_iso_raw
    FROM raw_quote_register r
)
SELECT
    CAST(x.sl_no AS INTEGER)                                AS sl_no,
    x.party                                                 AS customer_id,
    c.market_type                                           AS customer_market,
    x.project,
    x.item                                                  AS product_line,
    x.category,

    -- ------------------------------------------------------------ dates
    -- date() only after the round-trip test, so a rolled-over day is rejected
    CASE WHEN DATE(x.quote_iso_raw) = x.quote_iso_raw THEN x.quote_iso_raw END
                                                            AS quote_date,
    CASE WHEN DATE(x.po_iso_raw) = x.po_iso_raw THEN x.po_iso_raw END
                                                            AS po_date,
    CASE WHEN DATE(x.dp_iso_raw) = x.dp_iso_raw THEN x.dp_iso_raw END
                                                            AS dp_date,
    CASE WHEN DATE(x.validity_iso_raw) = x.validity_iso_raw THEN x.validity_iso_raw END
                                                            AS validity_date,

    -- a date that rolled over: it looked like a date and came back different
    (x.dp_iso_raw IS NOT NULL AND DATE(x.dp_iso_raw) <> x.dp_iso_raw)
    OR (x.po_iso_raw IS NOT NULL AND DATE(x.po_iso_raw) <> x.po_iso_raw)
                                                            AS date_impossible,
    -- a year outside the window is a typo, not a date
    (x.po_iso_raw IS NOT NULL
     AND CAST(SUBSTR(x.po_iso_raw, 1, 4) AS INTEGER) NOT BETWEEN 2023 AND 2027)
                                                            AS year_suspect,
    -- the DP cell holds prose rather than a date
    (x.dp_date IS NOT NULL AND x.dp_iso_raw IS NULL)        AS dp_is_free_text,
    CASE
        WHEN x.po_date IS NULL THEN NULL
        WHEN SUBSTR(x.po_date, 3, 1) = '.' THEN 'dd.mm.yyyy'
        WHEN SUBSTR(x.po_date, 3, 1) = '-' THEN 'dd-mm-yyyy'
        WHEN SUBSTR(x.po_date, 5, 1) = '-' THEN 'yyyy-mm-dd'
        ELSE 'unrecognised'
    END                                                     AS po_date_format,

    -- ------------------------------------------------------- quote number
    -- The prefix plus a token plus a serial is a quote number. A status word or a
    -- GEM tender ID in that cell is not, and counting those as quotations is
    -- the single easiest way to overstate the funnel.
    (x.quote_no IS NOT NULL AND UPPER(SUBSTR(TRIM(x.quote_no), 1, 3)) IN ('VQ/', 'VQ-'))
                                                            AS quote_no_is_real,
    (x.quote_no IS NOT NULL
     AND UPPER(SUBSTR(TRIM(x.quote_no), 1, 4)) = 'GEM/')     AS quote_no_is_tender,
    (x.quote_no IS NOT NULL
     AND UPPER(SUBSTR(TRIM(x.quote_no), 1, 3)) NOT IN ('VQ/', 'VQ-')
     AND UPPER(SUBSTR(TRIM(x.quote_no), 1, 4)) <> 'GEM/')    AS quote_no_holds_other,
    x.quote_no,
    CASE WHEN INSTR(UPPER(x.quote_no), 'REV') > 0 THEN 1 ELSE 0 END
                                                            AS quote_is_revision,

    -- --------------------------------------------------------- job number
    CASE WHEN x.job_no GLOB '[0-9]*' THEN CAST(x.job_no AS INTEGER) END
                                                            AS job_no,
    CASE WHEN x.job_no GLOB '[0-9]*'
         THEN (CAST(x.job_no AS INTEGER) / 10000) * 10000 END
                                                            AS job_band,
    x.po_no,
    (x.job_no IS NOT NULL OR x.po_no IS NOT NULL)           AS became_order,

    -- -------------------------------------------------------------- status
    -- 45 wordings in the real register for 13 states. Collapsing case first
    -- does most of the work; the rest is an explicit decision.
    --
    -- "Open" is deliberately ambiguous in the source - it is used both for a
    -- live quotation and for an order not yet delivered. It is split here by
    -- whether the row has a PO or job number. That is a judgement, it changes
    -- the conversion numbers, and it is logged.
    CASE UPPER(TRIM(x.status))
        WHEN 'PO RECEIVED & DELIVERED' THEN 'Delivered'
        WHEN 'PO RECEIVED'             THEN 'Order in progress'
        WHEN 'WORK IN PROGRESS'        THEN 'Order in progress'
        WHEN 'ORDER CONFIRMED'         THEN 'Order in progress'
        WHEN 'LOA'                     THEN 'Order in progress'
        WHEN 'LOA RECEIVED'            THEN 'Order in progress'
        WHEN 'PENDING'                 THEN 'Order in progress'
        WHEN 'CANCEL'                  THEN 'Cancelled'
        WHEN 'CANCELED'                THEN 'Cancelled'
        WHEN 'CANCELLED'               THEN 'Cancelled'
        WHEN 'ON HOLD'                 THEN 'On hold'
        WHEN 'UNDER HOLD'              THEN 'On hold'
        WHEN 'BUDGETARY'               THEN 'Quote live'
        WHEN 'UNDER DISCUSSION'        THEN 'Quote live'
        WHEN 'RFQ SUBMITTED'           THEN 'Quote live'
        WHEN 'QUOTATION SUBMITTED'     THEN 'Quote live'
        WHEN 'RETENDER'                THEN 'Retender'
        WHEN 'LOST'                    THEN 'Lost'
        WHEN 'CLOSED'                  THEN 'Closed'
        WHEN 'NOT RECEIVED'            THEN 'Not received'
        WHEN 'PO NOT RECEIVED'         THEN 'Not received'
        WHEN 'OPEN' THEN
            CASE WHEN x.job_no IS NOT NULL OR x.po_no IS NOT NULL
                 THEN 'Order in progress' ELSE 'Quote live' END
        WHEN 'SUPPLY-KOL'              THEN 'UNUSABLE'
        WHEN 'BILL'                    THEN 'UNUSABLE'
        ELSE 'UNMAPPED'
    END                                                     AS status_clean,
    x.status                                                AS status_raw,

    -- ------------------------------------------------------------------ LD
    -- Two columns for one idea. "LD Clause" wins where it is populated,
    -- because that is the column meant for the clause, and the source is kept
    -- so the choice is auditable. What LD actually holds is often not a clause
    -- at all, and those cases are classified rather than thrown away.
    COALESCE(x.ld_clause, x.ld)                             AS ld_merged,
    CASE WHEN x.ld_clause IS NOT NULL THEN 'ld_clause'
         WHEN x.ld IS NOT NULL THEN 'ld'
    END                                                     AS ld_source,
    (x.ld IS NOT NULL AND x.ld_clause IS NOT NULL)           AS ld_both_populated,
    CASE
        WHEN COALESCE(x.ld_clause, x.ld) IS NULL THEN NULL
        WHEN COALESCE(x.ld_clause, x.ld) IN ('NA', 'Not Applicable', 'No', 'YES',
                                             '—', 'Not mentioned')
             THEN 'applicability flag'
        WHEN COALESCE(x.ld_clause, x.ld) = 'Lost' THEN 'status in the wrong column'
        WHEN INSTR(COALESCE(x.ld_clause, x.ld), '%') > 0 THEN 'genuine clause'
        WHEN INSTR(LOWER(COALESCE(x.ld_clause, x.ld)), 'payment') > 0
             THEN 'payment terms in the wrong column'
        WHEN INSTR(COALESCE(x.ld_clause, x.ld), '00:00:00') > 0
             THEN 'excel timestamp'
        WHEN SUBSTR(COALESCE(x.ld_clause, x.ld), 1, 3) IN
             ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep',
              'Oct', 'Nov', 'Dec')
             THEN 'delivery month in the wrong column'
        WHEN INSTR(LOWER(COALESCE(x.ld_clause, x.ld)), 'ld ') > 0
             OR INSTR(LOWER(COALESCE(x.ld_clause, x.ld)), 'agreement') > 0
             THEN 'genuine clause'
        ELSE 'other prose'
    END                                                     AS ld_kind,

    -- -------------------------------------------------------------- market
    -- Two unrelated taxonomies share this column: Domestic/Export is a
    -- geography, Internal/External is who the customer is. Mixing them is why
    -- the field under-reports export share.
    x.vertical                                              AS vertical_raw,
    CASE
        WHEN x.vertical IS NULL THEN NULL
        WHEN UPPER(x.vertical) LIKE 'EXPORT%' THEN 'Export'
        WHEN UPPER(x.vertical) = 'DOMESTIC' THEN 'Domestic'
        WHEN UPPER(x.vertical) IN ('INTERNAL', 'EXTERNAL') THEN 'NOT A MARKET'
        ELSE 'UNMAPPED'
    END                                                     AS vertical_clean,
    -- FLAGGED, not fixed: the register says Domestic, the customer master says
    -- otherwise. Which one is right is not something this data can settle.
    (x.vertical IS NOT NULL
     AND UPPER(x.vertical) NOT LIKE 'EXPORT%'
     AND c.market_type <> 'Domestic')                        AS export_mislabelled,

    -- --------------------------------------------------------------- people
    -- The same person appears as a full name and as initials, so any count by
    -- salesperson double-counts until the two are tied together.
    CASE TRIM(x.concerned_person)
        WHEN 'IK' THEN 'Ishan Kabir'      WHEN 'NV' THEN 'Niharika Vora'
        WHEN 'ZT' THEN 'Zubin Tandon'     WHEN 'HN' THEN 'Harita Nambiar'
        WHEN 'FQ' THEN 'Farhan Qureshi'   WHEN 'QB' THEN 'Qamar Bhatt'
        WHEN 'YN' THEN 'Yash Nagpal'      WHEN 'KO' THEN 'Ketan Oza'
        WHEN 'HZ' THEN 'Hemal Zaveri'
        ELSE TRIM(x.concerned_person)
    END                                                     AS salesperson,
    (TRIM(x.concerned_person) LIKE '%/%')                    AS salesperson_two_names,
    x.concerned_person                                      AS salesperson_raw,

    -- ---------------------------------------------------------------- value
    CASE WHEN x.po_quote_value GLOB '[0-9]*'
         THEN CAST(x.po_quote_value AS REAL) END            AS value_inr,
    x.incoterms,
    -- the same term in up to seven casings
    CASE WHEN x.incoterms IS NULL THEN NULL
         ELSE REPLACE(UPPER(TRIM(x.incoterms)), 'EX WORKS', 'EX-WORKS') END
                                                            AS incoterms_clean,
    CAST(NULLIF(x.item_qty, '') AS REAL)                    AS item_qty
FROM reordered x
LEFT JOIN customers c ON c.customer_id = x.party;


-- =============================================================================
-- cleaning_log - what was found, how many, and what was done about it
-- =============================================================================

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'dates', 'quote/po/dp/validity',
       'stored as text in three formats: dd.mm.yyyy, dd-mm-yyyy, yyyy-mm-dd',
       COUNT(*), 'PARSED',
       'Reordered by position, then round-tripped through date() and compared. '
       || 'A plain CAST would accept a rolled-over day.'
FROM raw_quote_register
WHERE po_date IS NOT NULL OR quote_date IS NOT NULL;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'dates', 'dp_date', 'impossible calendar date', COUNT(*), 'FLAGGED',
       'SQLite date() rolls 2024-11-31 forward to 2024-12-01 instead of '
       || 'rejecting it. Caught by comparing the parse against the input. '
       || 'Left in the raw table and excluded from lead-time queries.'
FROM v_raw_register WHERE date_impossible;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'dates', 'po_date', 'year outside the reporting window', COUNT(*), 'FLAGGED',
       'A PO dated 2205. Not fixed - guessing the intended year is not the '
       || 'analyst''s call. Excluded from lead-time and ageing queries.'
FROM v_raw_register WHERE year_suspect;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'dates', 'dp_date', 'free text instead of a date', COUNT(*), 'FLAGGED',
       'Real wordings kept as found: AEAP, AS EARLY AS POSSIBLE, '
       || '"8-10 weeks from receipt of PO, drawing approval and manufacturing '
       || 'clearance", WEDNESDAY(25/03/2026).'
FROM v_raw_register WHERE dp_is_free_text;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'status', 'status', 'many wordings for one state', COUNT(DISTINCT status_raw),
       'MAPPED',
       'Collapsed to ' || (SELECT COUNT(DISTINCT status_clean) FROM v_raw_register)
       || ' states. Case folded first, then an explicit CASE. Appendix A in '
       || '04_analysis_queries.sql prints the whole mapping so it can be argued with.'
FROM v_raw_register;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'status', 'status', '"Open" means two different things', COUNT(*), 'MAPPED',
       'Used for both a live quotation and an undelivered order. Split by '
       || 'whether the row carries a PO or job number. This changes the '
       || 'conversion rate, so it is a decision, not a tidy-up.'
FROM v_raw_register WHERE UPPER(TRIM(status_raw)) = 'OPEN';

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'status', 'status', 'value carries no usable meaning', COUNT(*), 'FLAGGED',
       'Values like Supply-Kol and Bill. Excluded from the funnel rather than '
       || 'forced into a state.'
FROM v_raw_register WHERE status_clean IN ('UNUSABLE', 'UNMAPPED');

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'quote_no', 'quote_no', 'status word typed into the quote-number column',
       COUNT(*), 'FLAGGED',
       'Counting these as quotations inflates the denominator of every '
       || 'conversion rate. They are excluded from the quotation table.'
FROM v_raw_register WHERE quote_no_holds_other;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'quote_no', 'quote_no', 'GEM tender ID instead of a quote number',
       COUNT(*), 'FLAGGED',
       'Government e-Marketplace tender references. A real inquiry, but not a '
       || 'quotation this company issued.'
FROM v_raw_register WHERE quote_no_is_tender;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'ld', 'ld / ld_clause', 'two columns for one concept', COUNT(*), 'MAPPED',
       'ld_clause wins where populated; ld_source records which column each '
       || 'value came from.'
FROM v_raw_register WHERE ld_merged IS NOT NULL;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'ld', 'ld / ld_clause', 'both columns populated on the same row',
       COUNT(*), 'FLAGGED',
       'The two do not agree. ld_clause is taken and the other value is kept '
       || 'visible in the raw table.'
FROM v_raw_register WHERE ld_both_populated;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'ld', 'ld', 'value is not a liquidated-damages clause at all: ' || ld_kind,
       COUNT(*), 'FLAGGED',
       'Classified rather than discarded, because the contamination is the '
       || 'finding: this column is used as a dumping ground.'
FROM v_raw_register
WHERE ld_kind IN ('delivery month in the wrong column', 'status in the wrong column',
                  'payment terms in the wrong column', 'excel timestamp')
GROUP BY ld_kind;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'market', 'vertical', 'holds two unrelated taxonomies', COUNT(*), 'FLAGGED',
       'Domestic/Export is a geography; Internal/External is who the customer '
       || 'is. Rows labelled Internal or External carry no market at all.'
FROM v_raw_register WHERE vertical_clean = 'NOT A MARKET';

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'market', 'vertical', 'register says Domestic, customer master says export',
       COUNT(*), 'FLAGGED',
       'FLAGGED, NOT FIXED, as the brief requires. Which source is right is '
       || 'not something this data can settle, and overwriting the register '
       || 'would destroy the evidence that the two disagree.'
FROM v_raw_register WHERE export_mislabelled;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'people', 'concerned_person', 'same person recorded as a name and as initials',
       COUNT(DISTINCT salesperson_raw) - COUNT(DISTINCT salesperson), 'MAPPED',
       'Initials tied back to the full name. Without this, a count by '
       || 'salesperson splits one person across two rows of the output.'
FROM v_raw_register;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'people', 'concerned_person', 'two people in one cell', COUNT(*), 'FLAGGED',
       'Cannot be split without knowing who owned the row.'
FROM v_raw_register WHERE salesperson_two_names;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'coverage', 'po_quote_value', 'no value recorded on an order row',
       COUNT(*), 'FLAGGED',
       'The register is a hand-kept book and leaves this blank on about a '
       || 'third of orders. The order tables carry the value from the PO, so '
       || 'any figure taken from the register alone understates the book.'
FROM v_raw_register WHERE became_order AND value_inr IS NULL;

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'coverage', 'dp_date', 'promised delivery date taken from the PO document',
       COUNT(*), 'FILLED',
       'The register records a promised date on only '
       || (SELECT COUNT(*) FROM orders WHERE promised_date_source = 'register')
       || ' of ' || (SELECT COUNT(*) FROM orders) || ' orders. The rest come '
       || 'from the PO, and orders.promised_date_source says which is which. '
       || 'Left at the register''s coverage, OTIF could only be computed on a '
       || 'quarter of the book.'
FROM orders WHERE promised_date_source = 'po_document';

INSERT INTO cleaning_log (step, column_name, issue, rows_found, action, note)
SELECT 'coverage', 'promised_delivery_date', 'no delivery date agreed at all',
       COUNT(*), 'EXCLUDED', 'Excluded from OTIF - there is nothing to measure against.'
FROM orders WHERE promised_date_source = 'none';


-- =============================================================================
-- v_otif - the OTIF definition, in one place
--
-- ON TIME  every line fully dispatched on or before the promised date
-- IN FULL  dispatched qty >= ordered qty, per line
-- Cancelled orders are excluded. Orders whose promised date has not yet
-- arrived are excluded too - they are the open order book, not a failure.
-- Grace days are a parameter, set to 0 as the brief asks; change the 0 below.
-- =============================================================================

CREATE VIEW v_otif AS
WITH due AS (
    SELECT o.order_id, o.customer_id, o.po_date,
           o.promised_delivery_date AS promised,
           o.promised_date_source
    FROM orders o
    WHERE o.cancellation_date IS NULL
      AND o.promised_delivery_date IS NOT NULL
      AND DATE(o.promised_delivery_date, '+0 day') <= '2026-08-31'
),
per_line AS (
    SELECT d.order_id, ol.line_no, ol.ordered_qty,
           COALESCE(SUM(dp.dispatched_qty), 0) AS dispatched_qty,
           MAX(dp.dispatch_date)               AS last_dispatch
    FROM due d
    JOIN order_lines ol ON ol.order_id = d.order_id
    LEFT JOIN dispatches dp ON dp.order_id = ol.order_id AND dp.line_no = ol.line_no
    GROUP BY d.order_id, ol.line_no
)
SELECT
    d.order_id, d.customer_id, d.po_date, d.promised, d.promised_date_source,
    i.product_line,
    MIN(CASE WHEN p.dispatched_qty >= p.ordered_qty THEN 1 ELSE 0 END) AS in_full,
    CASE WHEN MAX(COALESCE(p.last_dispatch, '9999-12-31')) <= d.promised
         THEN 1 ELSE 0 END                                             AS on_time,
    CASE WHEN MIN(CASE WHEN p.dispatched_qty >= p.ordered_qty THEN 1 ELSE 0 END) = 1
          AND MAX(COALESCE(p.last_dispatch, '9999-12-31')) <= d.promised
         THEN 1 ELSE 0 END                                             AS otif,
    MAX(COALESCE(p.last_dispatch, '9999-12-31'))                       AS last_dispatch,
    -- An order that never shipped is late by however long it has been sitting,
    -- measured to the as-of date. Falling back to the promised date would
    -- report it as 0 days late, which is the opposite of the truth.
    CAST(JULIANDAY(MAX(COALESCE(p.last_dispatch, '2026-08-31')))
         - JULIANDAY(d.promised) AS INTEGER)                           AS days_late
FROM due d
JOIN per_line p ON p.order_id = d.order_id
JOIN order_lines ol2 ON ol2.order_id = d.order_id AND ol2.line_no = 1
JOIN items i ON i.item_id = ol2.item_id
GROUP BY d.order_id;
