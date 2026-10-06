-- =============================================================================
-- Order-to-Cash  |  05_validation_checks.sql
--
--     sqlite3 o2c.db < 05_validation_checks.sql
--
-- One row per check. The verdict column is one of three things, and the
-- difference between them matters:
--
--   PASS      the check is satisfied
--   FAIL      something is wrong with the pipeline and the output cannot be
--             trusted until it is fixed
--   EXPECTED  the check found exactly the data-quality problem it was built to
--             find. These are modelled on purpose, they are listed in
--             cleaning_log, and a run with none of them would mean the
--             messiness had been quietly cleaned away.
--
-- The check the brief asked for and this file does NOT contain: job numbers
-- ascending with PO date within each band. Measurement killed it. In the real
-- registers the Spearman correlation between job number and PO date is -0.030
-- across 1,267 rows in the dominant band, so there is no such ordering to
-- validate. Testing for it would have meant testing my own invention. Job
-- numbers are still checked for uniqueness and banding below.
-- =============================================================================

-- ---------------------------------------------------- 1. row counts
SELECT '01 row counts' AS check_name,
       'register 625, orders 397-ish, every table non-empty' AS expected,
       'register ' || (SELECT COUNT(*) FROM raw_quote_register)
         || ', quotations ' || (SELECT COUNT(*) FROM quotations)
         || ', orders ' || (SELECT COUNT(*) FROM orders)
         || ', dispatches ' || (SELECT COUNT(*) FROM dispatches)
         || ', invoices ' || (SELECT COUNT(*) FROM invoices)
         || ', payments ' || (SELECT COUNT(*) FROM payments) AS actual,
       CASE WHEN (SELECT COUNT(*) FROM raw_quote_register) = 625
             AND (SELECT COUNT(*) FROM customers) > 0
             AND (SELECT COUNT(*) FROM items) > 0
             AND (SELECT COUNT(*) FROM quotations) > 0
             AND (SELECT COUNT(*) FROM orders) > 0
             AND (SELECT COUNT(*) FROM dispatches) > 0
             AND (SELECT COUNT(*) FROM invoices) > 0
             AND (SELECT COUNT(*) FROM payments) > 0
            THEN 'PASS' ELSE 'FAIL' END AS verdict;

-- ---------------------------------------------------- 2. row counts per line
SELECT '02 rows per product line' AS check_name,
       'Pressure Vessel 204, Pultrusion 277, Grating 144 - FY24-25 shape' AS expected,
       GROUP_CONCAT(item || ' ' || n, ', ') AS actual,
       CASE WHEN SUM(CASE WHEN (item = 'Pressure Vessel' AND n = 204)
                            OR (item = 'Pultrusion' AND n = 277)
                            OR (item = 'Grating' AND n = 144)
                          THEN 1 ELSE 0 END) = 3
            THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (SELECT item, COUNT(*) AS n FROM raw_quote_register GROUP BY item ORDER BY item);

-- ---------------------------------------------------- 3. orphaned foreign keys
-- PRAGMA foreign_key_check is the real test; these spell out the joins that
-- the analysis queries actually depend on.
SELECT '03 orphaned foreign keys' AS check_name, '0 across every relationship' AS expected,
       CAST(n AS TEXT) || ' orphans' AS actual,
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (
    SELECT (SELECT COUNT(*) FROM orders o
            WHERE o.customer_id NOT IN (SELECT customer_id FROM customers))
         + (SELECT COUNT(*) FROM orders o
            WHERE o.quote_id IS NOT NULL
              AND o.quote_id NOT IN (SELECT quote_id FROM quotations))
         + (SELECT COUNT(*) FROM order_lines ol
            WHERE ol.order_id NOT IN (SELECT order_id FROM orders))
         + (SELECT COUNT(*) FROM order_lines ol
            WHERE ol.item_id NOT IN (SELECT item_id FROM items))
         + (SELECT COUNT(*) FROM dispatches d
            WHERE NOT EXISTS (SELECT 1 FROM order_lines ol
                              WHERE ol.order_id = d.order_id AND ol.line_no = d.line_no))
         + (SELECT COUNT(*) FROM invoices i
            WHERE i.dispatch_id NOT IN (SELECT dispatch_id FROM dispatches))
         + (SELECT COUNT(*) FROM payments p
            WHERE p.invoice_id NOT IN (SELECT invoice_id FROM invoices))
         + (SELECT COUNT(*) FROM quotation_lines ql
            WHERE ql.quote_id NOT IN (SELECT quote_id FROM quotations))
         + (SELECT COUNT(*) FROM orders o
            WHERE o.terms_code IS NOT NULL
              AND o.terms_code NOT IN (SELECT terms_code FROM payment_terms)) AS n
);

-- ---------------------------------------------------- 4. dispatch never precedes its PO
SELECT '04 dispatch on or after PO date' AS check_name, '0 violations' AS expected,
       CAST(COUNT(*) AS TEXT) || ' dispatches before their own PO' AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM dispatches d JOIN orders o ON o.order_id = d.order_id
WHERE d.dispatch_date < o.po_date;

-- ---------------------------------------------------- 5. invoice date equals dispatch date
SELECT '05 invoice date = dispatch date' AS check_name, '0 mismatches' AS expected,
       CAST(COUNT(*) AS TEXT) || ' mismatches' AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM invoices i JOIN dispatches d ON d.dispatch_id = i.dispatch_id
WHERE i.invoice_date <> d.dispatch_date;

-- ---------------------------------------------------- 6a. quote on or before PO, modelled tables
-- The ERP would not accept a PO dated before its own quotation, so the
-- normalised tables must be clean. The register is a different matter - see 6b.
SELECT '06a quote <= PO (modelled tables)' AS check_name, '0 violations' AS expected,
       CAST(COUNT(*) AS TEXT) || ' of ' ||
       (SELECT COUNT(*) FROM orders WHERE quote_id IS NOT NULL)
         || ' quoted orders have a PO before the quote' AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM orders o JOIN quotations q ON q.quote_id = o.quote_id
WHERE o.po_date < q.quote_date;

-- ---------------------------------------------------- 6b. and in the raw register
-- Here it SHOULD appear. The real register holds quote dates typed in after
-- the PO they belong to, and that is reproduced. If this ever reads 0, the
-- register has been tidied up and the date-sanity part of the cleaning step
-- has nothing to catch.
SELECT '06b quote <= PO (raw register)' AS check_name,
       'at least one violation, modelled on purpose' AS expected,
       CAST(COUNT(*) AS TEXT) || ' register rows with a quote date after the PO' AS actual,
       CASE WHEN COUNT(*) >= 1 THEN 'EXPECTED' ELSE 'FAIL' END AS verdict
FROM v_raw_register
WHERE quote_date IS NOT NULL AND po_date IS NOT NULL AND quote_date > po_date;

-- ---------------------------------------------------- 7. invoice reconciles to qty x price
-- Tolerance is 2 rupees, not zero: an export invoice is divided by the FX rate
-- and rounded to cents, so multiplying back cannot land exactly.
SELECT '07 invoice value = dispatched qty x price' AS check_name,
       '0 rows off by more than 2 INR' AS expected,
       CAST(COUNT(*) AS TEXT) || ' of ' || (SELECT COUNT(*) FROM invoices)
         || ' invoices out of tolerance' AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM invoices i
JOIN dispatches d  ON d.dispatch_id = i.dispatch_id
JOIN order_lines ol ON ol.order_id = d.order_id AND ol.line_no = d.line_no
WHERE ABS(i.taxable_value * i.fx_rate_to_inr
          - d.dispatched_qty * ol.unit_price) > 2;

-- ---------------------------------------------------- 8. GST is right for the market
SELECT '08 GST by market' AS check_name,
       'Domestic and Deemed Export 18% in INR, Export 0% in USD' AS expected,
       GROUP_CONCAT(market_type || ' ' || currency || ' ' || eff || '%', ', ') AS actual,
       CASE WHEN SUM(bad) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (
    SELECT c.market_type, i.currency,
           ROUND(SUM(i.gst_amount) / NULLIF(SUM(i.taxable_value), 0) * 100, 1) AS eff,
           SUM(CASE
                 WHEN c.market_type = 'Export'
                      AND (i.currency <> 'USD' OR i.gst_amount <> 0) THEN 1
                 WHEN c.market_type IN ('Domestic', 'Deemed Export')
                      AND (i.currency <> 'INR'
                           OR ABS(i.gst_amount - i.taxable_value * 0.18) > 1) THEN 1
                 ELSE 0 END) AS bad
    FROM invoices i JOIN customers c ON c.customer_id = i.customer_id
    GROUP BY c.market_type, i.currency
);

-- ---------------------------------------------------- 9. FX rate used correctly
SELECT '09 FX rate by currency' AS check_name,
       'INR invoices at 1.0, USD invoices between 83 and 90' AS expected,
       CAST(COUNT(*) AS TEXT) || ' invoices with the wrong FX rate' AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM invoices
WHERE (currency = 'INR' AND fx_rate_to_inr <> 1.0)
   OR (currency = 'USD' AND fx_rate_to_inr NOT BETWEEN 83 AND 90);

-- ---------------------------------------------------- 10. job numbers unique and banded
SELECT '10 job numbers unique and banded' AS check_name,
       'all distinct, every band in 10/30/40/50/60/70k, about 96% in 10xxx' AS expected,
       CAST(COUNT(*) AS TEXT) || ' job numbers, ' || COUNT(DISTINCT job_no)
         || ' distinct, ' || COUNT(DISTINCT (job_no / 10000) * 10000) || ' bands, '
         || ROUND(100.0 * SUM(CASE WHEN job_no / 10000 = 1 THEN 1 ELSE 0 END)
                  / COUNT(*), 1) || '% in 10xxx' AS actual,
       CASE WHEN COUNT(*) = COUNT(DISTINCT job_no)
             AND COUNT(DISTINCT (job_no / 10000) * 10000) >= 5
             AND ABS(100.0 * SUM(CASE WHEN job_no / 10000 = 1 THEN 1 ELSE 0 END)
                     / COUNT(*) - 96.3) <= 4
            THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM orders WHERE job_no IS NOT NULL;

-- ---------------------------------------------------- 11. payments never exceed the invoice
SELECT '11 payments do not exceed the invoice' AS check_name, '0 overpayments' AS expected,
       CAST(COUNT(*) AS TEXT) || ' invoices paid more than billed' AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (
    SELECT i.invoice_id
    FROM invoices i
    JOIN payments p ON p.invoice_id = i.invoice_id
    GROUP BY i.invoice_id
    HAVING SUM(p.amount) > i.taxable_value + i.gst_amount + 1
);

-- ---------------------------------------------------- 12. no payment before its invoice, bar advances
SELECT '12 payment timing' AS check_name,
       'only Advance payments may predate the invoice' AS expected,
       CAST(COUNT(*) AS TEXT) || ' non-advance payments before their invoice' AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM payments p JOIN invoices i ON i.invoice_id = p.invoice_id
WHERE p.payment_date < i.invoice_date AND p.payment_type <> 'Advance';

-- ---------------------------------------------------- 13. dispatched qty never negative or zero
SELECT '13 dispatched quantities sane' AS check_name,
       '0 non-positive, 0 lines shipped more than ordered by over 1%' AS expected,
       CAST((SELECT COUNT(*) FROM dispatches WHERE dispatched_qty <= 0) AS TEXT)
         || ' non-positive, ' || CAST(COUNT(*) AS TEXT) || ' over-shipped' AS actual,
       CASE WHEN (SELECT COUNT(*) FROM dispatches WHERE dispatched_qty <= 0) = 0
             AND COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (
    SELECT ol.order_id, ol.line_no
    FROM order_lines ol
    JOIN dispatches d ON d.order_id = ol.order_id AND d.line_no = ol.line_no
    GROUP BY ol.order_id, ol.line_no
    HAVING SUM(d.dispatched_qty) > ol.ordered_qty * 1.01
);

-- ---------------------------------------------------- 14. cancelled orders never ship
SELECT '14 cancelled orders never ship' AS check_name, '0 violations' AS expected,
       CAST(COUNT(*) AS TEXT) || ' cancelled orders with a dispatch' AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM orders o
WHERE o.cancellation_date IS NOT NULL
  AND EXISTS (SELECT 1 FROM dispatches d WHERE d.order_id = o.order_id);

-- ---------------------------------------------------- 15. OTIF lands in the expected range
-- The brief is explicit: if this comes out above 95% the variance has been
-- flattened somewhere and it should be fixed, not published.
SELECT '15 OTIF in range' AS check_name, 'between 55% and 75%' AS expected,
       'OTIF ' || ROUND(100.0 * SUM(otif) / COUNT(*), 1) || '% on '
         || COUNT(*) || ' orders due (on time '
         || ROUND(100.0 * SUM(on_time) / COUNT(*), 1) || '%, in full '
         || ROUND(100.0 * SUM(in_full) / COUNT(*), 1) || '%)' AS actual,
       CASE WHEN 100.0 * SUM(otif) / COUNT(*) BETWEEN 55 AND 75
            THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM v_otif;

-- ---------------------------------------------------- 16. the funnel is not an inner join
-- If this ever reads 100%, someone has made orders.quote_id NOT NULL and the
-- whole repeat-PO story has been lost.
SELECT '16 orders without a quotation' AS check_name,
       'a clear majority - most orders are repeat POs' AS expected,
       ROUND(100.0 * SUM(CASE WHEN quote_id IS NULL THEN 1 ELSE 0 END)
             / COUNT(*), 1) || '% of orders have no quotation' AS actual,
       CASE WHEN 100.0 * SUM(CASE WHEN quote_id IS NULL THEN 1 ELSE 0 END)
                 / COUNT(*) BETWEEN 40 AND 80
            THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM orders;

-- ---------------------------------------------------- 17. the register is still messy
-- A register that parses cleanly means the mess has been removed and the
-- cleaning step has nothing left to demonstrate.
SELECT '17 register still carries its faults' AS check_name,
       'free-text DP dates, an impossible date, a wrong year, status words in '
         || 'the quote-number column' AS expected,
       (SELECT COUNT(*) FROM v_raw_register WHERE dp_is_free_text)
         || ' free-text DP, '
         || (SELECT COUNT(*) FROM v_raw_register WHERE date_impossible)
         || ' impossible date, '
         || (SELECT COUNT(*) FROM v_raw_register WHERE year_suspect)
         || ' wrong year, '
         || (SELECT COUNT(*) FROM v_raw_register WHERE quote_no_holds_other)
         || ' status words in quote_no' AS actual,
       CASE WHEN (SELECT COUNT(*) FROM v_raw_register WHERE dp_is_free_text) > 0
             AND (SELECT COUNT(*) FROM v_raw_register WHERE date_impossible) > 0
             AND (SELECT COUNT(*) FROM v_raw_register WHERE year_suspect) > 0
             AND (SELECT COUNT(*) FROM v_raw_register WHERE quote_no_holds_other) > 0
            THEN 'EXPECTED' ELSE 'FAIL' END AS verdict;

-- ---------------------------------------------------- 18. nothing invented in the vocabulary
SELECT '18 no invented vocabulary' AS check_name,
       'no Verbally Confirmed, no Closed/Not Received, no Appl:Y' AS expected,
       (SELECT COUNT(*) FROM raw_quote_register WHERE status = 'Verbally Confirmed')
         || ' Verbally Confirmed, '
         || (SELECT COUNT(*) FROM raw_quote_register WHERE status = 'Closed/Not Received')
         || ' Closed/Not Received, '
         || (SELECT COUNT(*) FROM raw_quote_register
             WHERE COALESCE(ld, '') LIKE '%Appl:Y%'
                OR COALESCE(ld_clause, '') LIKE '%Appl:Y%')
         || ' Appl:Y' AS actual,
       CASE WHEN (SELECT COUNT(*) FROM raw_quote_register
                  WHERE status IN ('Verbally Confirmed', 'Closed/Not Received')
                     OR COALESCE(ld, '') LIKE '%Appl:Y%'
                     OR COALESCE(ld_clause, '') LIKE '%Appl:Y%') = 0
            THEN 'PASS' ELSE 'FAIL' END AS verdict;

-- ------------------------------------- 18b. confidentiality: identity columns
-- An ALLOWLIST, not a denylist, and that is the whole point. A denylist would
-- have to spell out the real names it is looking for, which would put them
-- back in the repo. This instead says what the synthetic vocabulary IS, and
-- anything outside it fails - so a real value reappearing is caught without a
-- real value ever being written down here.
--
-- Columns covered: every one that could carry a person, a place or a customer.
-- confidentiality_sweep.py runs the same check plus the pattern scans.
SELECT '18b identity columns within allowlist' AS check_name,
       'every person, place and market value is one of the declared synthetic ones'
                                                                      AS expected,
       CAST(n AS TEXT) || ' value(s) outside the allowlist' AS actual,
       CASE WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (
    SELECT
      (SELECT COUNT(DISTINCT concerned_person) FROM raw_quote_register
       WHERE concerned_person IS NOT NULL AND concerned_person NOT IN
         ('Ishan Kabir','Niharika Vora','Zubin Tandon','Harita Nambiar',
          'Farhan Qureshi','Qamar Bhatt','Yash Nagpal','Ketan Oza','Hemal Zaveri',
          'IK','NV','ZT','HN','FQ','QB','YN','KO','HZ',
          'Qamar Bhatt /Harita Nambiar'))
    + (SELECT COUNT(DISTINCT salesperson_code) FROM quotations
       WHERE salesperson_code NOT IN
         ('Ishan Kabir','Niharika Vora','Zubin Tandon','Harita Nambiar',
          'Farhan Qureshi','Qamar Bhatt','Yash Nagpal','Ketan Oza','Hemal Zaveri',
          'IK','NV','ZT','HN','FQ','QB','YN','KO','HZ',
          'Qamar Bhatt /Harita Nambiar'))
    + (SELECT COUNT(DISTINCT incoterms) FROM raw_quote_register
       WHERE incoterms IS NOT NULL AND incoterms NOT IN
         ('Ex-Works [FACTORY]','EX-WORKS [FACTORY]','Ex-works [FACTORY]',
          'EX-WORKS KOLKATA','Ex-Works','FOB','ExW','EX-WORKS [PLANT 2]',
          'Ex works','FOR','EXW','FOR [SITE]'))
    + (SELECT COUNT(DISTINCT quote_from) FROM raw_quote_register
       WHERE quote_from IS NOT NULL AND quote_from NOT IN
         ('Kolkata','NA','KOLKATA','[PLANT 2]'))
    + (SELECT COUNT(DISTINCT vertical) FROM raw_quote_register
       WHERE vertical IS NOT NULL AND vertical NOT IN
         ('Domestic','DOMESTIC','Internal','External','Export','Export-KAG',
          'Export-Non-KAG','Qamar Bhatt /Harita Nambiar'))
    + (SELECT COUNT(DISTINCT customer_id) FROM customers
       WHERE customer_id NOT GLOB 'C[0-9][0-9][0-9][0-9]') AS n
);

-- ---------------------------------------------------- 19. every status maps to something
SELECT '19 status mapping is complete' AS check_name,
       '0 UNMAPPED - every wording in the data has a rule' AS expected,
       (SELECT COUNT(*) FROM v_raw_register WHERE status_clean = 'UNMAPPED')
         || ' unmapped, ' || (SELECT COUNT(DISTINCT status_raw) FROM v_raw_register)
         || ' wordings collapsed to '
         || (SELECT COUNT(DISTINCT status_clean) FROM v_raw_register)
         || ' states' AS actual,
       CASE WHEN (SELECT COUNT(*) FROM v_raw_register
                  WHERE status_clean = 'UNMAPPED') = 0
            THEN 'PASS' ELSE 'FAIL' END AS verdict;

-- ---------------------------------------------------- 20. cleaning_log is populated
SELECT '20 cleaning log written' AS check_name,
       'every cleaning decision recorded, with a mix of actions' AS expected,
       (SELECT COUNT(*) FROM cleaning_log) || ' entries across '
         || (SELECT COUNT(DISTINCT action) FROM cleaning_log) || ' action types' AS actual,
       CASE WHEN (SELECT COUNT(*) FROM cleaning_log) >= 15
             AND (SELECT COUNT(DISTINCT action) FROM cleaning_log) >= 4
            THEN 'PASS' ELSE 'FAIL' END AS verdict;
