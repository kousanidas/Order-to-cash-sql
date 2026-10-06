-- =============================================================================
-- Order-to-Cash  |  04_analysis_queries.sql
--
-- Run 01, 02 and 03 first. Each query stands alone - run them one at a time
-- and read the comment above each one.
--
--     sqlite3 o2c.db < 04_analysis_queries.sql
--
-- TWO THINGS TO KNOW BEFORE READING ANY OF THESE
--
-- 1. SQLite has no PERCENTILE_CONT. Medians and p90s here use the nearest-rank
--    method: number the rows with ROW_NUMBER(), count them with COUNT(*) OVER (),
--    then pick the row at the rank you want. For an even count the median takes
--    the average of the two middle rows. It is not interpolated, so it can
--    differ by a day or two from what Postgres or Excel would return.
--
-- 2. orders.quote_id IS NULLABLE AND MOST OF IT IS NULL. Only 41% of orders
--    came from a formal quotation; the rest are repeat POs. So no query that
--    COUNTS or VALUES orders may inner-join to quotations - doing so silently
--    drops 59% of the order book and every number after it is wrong in the same
--    invisible direction. Q1 handles it with EXISTS and with aggregate CTEs
--    joined on the dimensions, never on quote_id.
--
--    Q2 is the one deliberate exception. It measures quote-to-PO lead time,
--    which does not exist for an order that had no quote, so an inner join is
--    the correct reading there - and it prints its own n so the coverage is
--    visible rather than implied.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. What share of quotes become orders, and how much business arrives with
--     no quote at all?
--
-- Business question: where does the funnel leak, by product line and market?
-- Tables:   quotations, quotation_lines, orders, customers, items
-- Features: CTEs, LEFT JOIN, conditional aggregation, NULLIF guard
--
-- The second half of this result is the part that matters. Conversion of
-- quoted work is one number; the share of orders that never had a quote is a
-- different one, and on the vessel line it is three quarters of the book. A
-- funnel built only on quotations would be describing a quarter of the
-- business and calling it the business.
-- -----------------------------------------------------------------------------
WITH q AS (
    SELECT q.quote_id, c.market_type, i.product_line,
           CASE WHEN EXISTS (SELECT 1 FROM orders o WHERE o.quote_id = q.quote_id)
                THEN 1 ELSE 0 END                               AS won
    FROM quotations q
    JOIN customers c        ON c.customer_id = q.customer_id
    JOIN quotation_lines ql ON ql.quote_id = q.quote_id AND ql.line_no = 1
    JOIN items i            ON i.item_id = ql.item_id
),
o AS (
    SELECT o.order_id, c.market_type, i.product_line,
           CASE WHEN o.quote_id IS NULL THEN 1 ELSE 0 END        AS no_quote
    FROM orders o
    JOIN customers c    ON c.customer_id = o.customer_id
    JOIN order_lines ol ON ol.order_id = o.order_id AND ol.line_no = 1
    JOIN items i        ON i.item_id = ol.item_id
),
dim AS (
    SELECT product_line, market_type FROM q
    UNION
    SELECT product_line, market_type FROM o
),
qa AS (
    SELECT product_line, market_type, COUNT(*) AS issued, SUM(won) AS won
    FROM q GROUP BY product_line, market_type
),
oa AS (
    SELECT product_line, market_type, COUNT(*) AS orders_total,
           SUM(no_quote) AS orders_no_quote
    FROM o GROUP BY product_line, market_type
)
SELECT
    d.product_line,
    d.market_type,
    COALESCE(qa.issued, 0)                                      AS quotes_issued,
    COALESCE(qa.won, 0)                                         AS quotes_won,
    ROUND(100.0 * qa.won / NULLIF(qa.issued, 0), 1)             AS conversion_pct,
    COALESCE(oa.orders_total, 0)                                AS orders_total,
    COALESCE(oa.orders_no_quote, 0)                             AS orders_with_no_quote,
    ROUND(100.0 * oa.orders_no_quote / NULLIF(oa.orders_total, 0), 1)
                                                                AS no_quote_share_pct
FROM dim d
LEFT JOIN qa ON qa.product_line = d.product_line AND qa.market_type = d.market_type
LEFT JOIN oa ON oa.product_line = d.product_line AND oa.market_type = d.market_type
ORDER BY d.product_line, d.market_type;


-- -----------------------------------------------------------------------------
-- Q2. How long from quote to order, by product line?
--
-- Business question: how much notice does planning actually get?
-- Tables:   quotations, orders, order_lines, items
-- Features: CTE, ROW_NUMBER() and COUNT(*) OVER () for percentiles,
--           JULIANDAY date arithmetic, HAVING
--
-- Only the 41% of orders that came from a quotation can appear here - the rest
-- have no quote date to measure from. n is printed for exactly that reason.
-- -----------------------------------------------------------------------------
WITH lead AS (
    SELECT
        i.product_line,
        CAST(JULIANDAY(o.po_date) - JULIANDAY(q.quote_date) AS INTEGER) AS days
    FROM orders o
    JOIN quotations q  ON q.quote_id = o.quote_id
    JOIN order_lines ol ON ol.order_id = o.order_id AND ol.line_no = 1
    JOIN items i       ON i.item_id = ol.item_id
    WHERE o.quote_id IS NOT NULL
),
ranked AS (
    SELECT product_line, days,
           ROW_NUMBER() OVER (PARTITION BY product_line ORDER BY days) AS rn,
           COUNT(*)     OVER (PARTITION BY product_line)               AS n
    FROM lead
)
SELECT
    product_line,
    n                                                            AS orders_measurable,
    MIN(days)                                                    AS fastest,
    ROUND(AVG(CASE WHEN rn IN ((n + 1) / 2, (n + 2) / 2) THEN days END), 0)
                                                                 AS median_days,
    MAX(CASE WHEN rn = CAST(ROUND(0.90 * n) AS INTEGER) THEN days END)
                                                                 AS p90_days,
    MAX(days)                                                    AS slowest,
    SUM(CASE WHEN days < 0 THEN 1 ELSE 0 END)                    AS po_before_quote
FROM ranked
GROUP BY product_line, n
HAVING n >= 5
ORDER BY median_days DESC;


-- -----------------------------------------------------------------------------
-- Q3. Do we deliver on time and in full, and is it getting better?
--
-- Business question: OTIF by product line and quarter, with the trend.
-- Tables:   v_otif (which wraps orders, order_lines, dispatches), items
-- Features: LAG() for the quarter-on-quarter move, conditional aggregation,
--           date arithmetic to build the financial quarter
--
-- The Indian financial year starts in April, so Apr-Jun is Q1. Note the
-- column is named quarter_label and the sort is on quarter_key: ORDER BY
-- resolves an output alias before an input column, so sorting on a formatted
-- label sorts it as text and puts Q1 of 2026 before Q2 of 2024.
-- -----------------------------------------------------------------------------
WITH q AS (
    SELECT
        v.product_line,
        CAST(STRFTIME('%Y', v.promised) AS INTEGER)
            - CASE WHEN CAST(STRFTIME('%m', v.promised) AS INTEGER) < 4
                   THEN 1 ELSE 0 END                                  AS fy_start,
        ((CAST(STRFTIME('%m', v.promised) AS INTEGER) + 8) % 12) / 3 + 1 AS fy_q,
        v.otif, v.on_time, v.in_full
    FROM v_otif v
),
agg AS (
    SELECT
        product_line, fy_start, fy_q,
        COUNT(*)                                        AS orders_due,
        SUM(otif)                                       AS otif_n,
        ROUND(100.0 * SUM(otif)    / COUNT(*), 1)       AS otif_pct,
        ROUND(100.0 * SUM(on_time) / COUNT(*), 1)       AS on_time_pct,
        ROUND(100.0 * SUM(in_full) / COUNT(*), 1)       AS in_full_pct
    FROM q
    GROUP BY product_line, fy_start, fy_q
)
SELECT
    product_line,
    'FY' || SUBSTR(CAST(fy_start AS TEXT), 3, 2) || '-'
          || SUBSTR(CAST(fy_start + 1 AS TEXT), 3, 2)
          || ' Q' || fy_q                                           AS quarter_label,
    orders_due, otif_pct, on_time_pct, in_full_pct,
    ROUND(otif_pct - LAG(otif_pct) OVER (PARTITION BY product_line
                                         ORDER BY fy_start, fy_q), 1)
                                                                    AS vs_prev_quarter
FROM agg
WHERE orders_due >= 5
ORDER BY product_line, fy_start, fy_q;


-- -----------------------------------------------------------------------------
-- Q4. Does delivery lead time scale with vessel size?
--
-- Business question: what should a planner promise for a size not built before,
--                    and do the bigger sizes actually hit it?
-- Tables:   orders, order_lines, items, dispatches
-- Features: CTE, percentiles by rank, correlated subquery for the last
--           dispatch, NULLIF-guarded ratio against the 2000 mm base
--
-- Pressure vessels only - diameter is NULL on the other two lines.
--
-- PROMISED and ACTUAL are reported side by side, and they say different things.
--
-- The result comes in two halves, and the reason is sample size. Per individual
-- diameter there are only about 25 orders, against a PO-to-delivery spread
-- whose p90 is four and a half times its median. At that n the size ladder is
-- inside the noise - run the per-size half and you get 2400 mm looking faster
-- than 1400 mm, which is not a finding, it is a small sample. So the sizes are
-- also pooled into three bands where n is 70-plus and the ladder does show.
--
-- Reporting both is the point. Hiding the per-size table would hide the reason
-- the banding was necessary.
--
-- One line_no = 1 filter matters here. A vessel job is for N vessels of one
-- size, so joining every order line counted a three-line order three times and
-- made the n column meaningless.
-- -----------------------------------------------------------------------------
WITH vessel AS (
    SELECT
        i.vessel_diameter_mm                                       AS dia_mm,
        CASE WHEN i.vessel_diameter_mm <= 1800 THEN '1 small (1400-1800)'
             WHEN i.vessel_diameter_mm <= 2400 THEN '2 medium (2000-2400)'
             ELSE '3 large (2600-3000)' END                        AS size_band,
        o.order_id,
        CAST(JULIANDAY(o.promised_delivery_date)
             - JULIANDAY(o.po_date) AS INTEGER)                    AS promised_days,
        CAST(JULIANDAY((SELECT MAX(d.dispatch_date) FROM dispatches d
                        WHERE d.order_id = o.order_id))
             - JULIANDAY(o.po_date) AS INTEGER)                    AS actual_days
    FROM orders o
    JOIN order_lines ol ON ol.order_id = o.order_id AND ol.line_no = 1
    JOIN items i        ON i.item_id = ol.item_id
    WHERE i.product_line = 'Pressure Vessel'
      AND o.cancellation_date IS NULL
      AND o.promised_delivery_date IS NOT NULL
),
banded AS (
    SELECT size_band, promised_days, actual_days,
           ROW_NUMBER() OVER (PARTITION BY size_band ORDER BY promised_days) AS rn_p,
           COUNT(*)     OVER (PARTITION BY size_band)                        AS n
    FROM vessel
),
band_stats AS (
    SELECT size_band, n AS orders,
           ROUND(AVG(CASE WHEN rn_p IN ((n + 1) / 2, (n + 2) / 2)
                          THEN promised_days END), 0)              AS median_promised,
           ROUND(AVG(promised_days), 0)                            AS mean_promised,
           ROUND(AVG(actual_days), 0)                              AS mean_actual
    FROM banded GROUP BY size_band, n
)
SELECT
    size_band                                                      AS grouping,
    orders, median_promised, mean_promised, mean_actual,
    ROUND(mean_promised
          / NULLIF((SELECT mean_promised FROM band_stats
                    WHERE size_band = '2 medium (2000-2400)'), 0), 2)
                                                                   AS factor_vs_medium
FROM band_stats
ORDER BY size_band;

-- the per-size detail, so the reader can see why the banding above was needed
WITH vessel AS (
    SELECT i.vessel_diameter_mm AS dia_mm, o.order_id,
           CAST(JULIANDAY(o.promised_delivery_date)
                - JULIANDAY(o.po_date) AS INTEGER)                 AS promised_days
    FROM orders o
    JOIN order_lines ol ON ol.order_id = o.order_id AND ol.line_no = 1
    JOIN items i        ON i.item_id = ol.item_id
    WHERE i.product_line = 'Pressure Vessel'
      AND o.cancellation_date IS NULL
      AND o.promised_delivery_date IS NOT NULL
)
SELECT dia_mm,
       COUNT(*)                                                    AS orders,
       ROUND(AVG(promised_days), 0)                                AS mean_promised,
       MIN(promised_days)                                          AS fastest,
       MAX(promised_days)                                          AS slowest,
       'n too small to rank sizes individually'                    AS caveat
FROM vessel
GROUP BY dia_mm
ORDER BY dia_mm;


-- -----------------------------------------------------------------------------
-- Q5. When we are late, why?
--
-- Business question: rank the delay causes by how often they bite and how much
--                    time they cost.
-- Tables:   dispatches, orders, v_otif
-- Features: JOIN to a view, RANK() on two different measures, HAVING,
--           conditional aggregation
--
-- Frequency and severity are ranked separately on purpose. The most common
-- reason and the most expensive reason are not the same one, and a single
-- ranked list hides that.
-- -----------------------------------------------------------------------------
WITH late AS (
    SELECT d.delay_reason, v.order_id, v.days_late
    FROM v_otif v
    JOIN dispatches d ON d.order_id = v.order_id
    WHERE v.on_time = 0
      AND d.delay_reason IS NOT NULL
    GROUP BY v.order_id, d.delay_reason
)
SELECT
    delay_reason,
    COUNT(*)                                                 AS late_orders,
    ROUND(AVG(days_late), 1)                                 AS avg_days_late,
    MAX(days_late)                                           AS worst_days_late,
    SUM(days_late)                                           AS total_days_lost,
    RANK() OVER (ORDER BY COUNT(*) DESC)                     AS rank_by_frequency,
    RANK() OVER (ORDER BY AVG(days_late) DESC)               AS rank_by_severity
FROM late
GROUP BY delay_reason
HAVING COUNT(*) >= 2
ORDER BY late_orders DESC;


-- -----------------------------------------------------------------------------
-- Q6. How much is owed, and how old is it?
--
-- Business question: receivables ageing as at 31 Aug 2026.
-- Tables:   invoices, payments, customers
-- Features: correlated subquery for payments to date, CASE bucketing,
--           GROUP BY with a total via UNION ALL, FX normalisation
--
-- Everything is converted to INR before it is added up. Export invoices are
-- raised in USD, so summing taxable_value across markets without multiplying
-- by fx_rate_to_inr adds dollars to rupees and understates the book by about
-- 85x on those rows.
-- -----------------------------------------------------------------------------
WITH bal AS (
    SELECT
        i.invoice_id, i.customer_id, i.due_date,
        (i.taxable_value + i.gst_amount) * i.fx_rate_to_inr            AS billed_inr,
        COALESCE((SELECT SUM(p.amount) FROM payments p
                  WHERE p.invoice_id = i.invoice_id), 0)
            * i.fx_rate_to_inr                                         AS paid_inr
    FROM invoices i
),
aged AS (
    SELECT
        invoice_id, customer_id,
        billed_inr - paid_inr                                          AS outstanding,
        CAST(JULIANDAY('2026-08-31') - JULIANDAY(due_date) AS INTEGER) AS days_overdue
    FROM bal
    WHERE billed_inr - paid_inr > 1
)
SELECT
    CASE
        WHEN days_overdue <= 0  THEN '0 not yet due'
        WHEN days_overdue <= 30 THEN '1 to 30 days'
        WHEN days_overdue <= 60 THEN '31 to 60 days'
        WHEN days_overdue <= 90 THEN '61 to 90 days'
        ELSE '90 plus days'
    END                                                      AS ageing_bucket,
    COUNT(*)                                                 AS invoices,
    COUNT(DISTINCT customer_id)                              AS customers,
    ROUND(SUM(outstanding))                                  AS outstanding_inr,
    ROUND(100.0 * SUM(outstanding) / SUM(SUM(outstanding)) OVER (), 1)
                                                             AS pct_of_total
FROM aged
GROUP BY ageing_bucket
ORDER BY ageing_bucket;


-- -----------------------------------------------------------------------------
-- Q7. Which customers pay late?
--
-- Business question: rank customers by payment behaviour, not by one bad
--                    invoice.
-- Tables:   invoices, payments, customers
-- Features: CTE chain, NTILE(4) to band customers, conditional aggregation,
--           HAVING to drop customers with too few invoices to judge
--
-- Average days-to-pay on its own is misleading: a customer who always pays
-- half on time and leaves the rest outstanding looks punctual. So the share of
-- invoices settled in full is reported alongside it.
-- -----------------------------------------------------------------------------
WITH settled AS (
    SELECT
        i.invoice_id, i.customer_id, i.due_date,
        (i.taxable_value + i.gst_amount)                      AS billed,
        COALESCE((SELECT SUM(p.amount) FROM payments p
                  WHERE p.invoice_id = i.invoice_id), 0)      AS paid,
        (SELECT MAX(p.payment_date) FROM payments p
         WHERE p.invoice_id = i.invoice_id
           AND p.payment_type IN ('Full', 'Final'))           AS settled_on
    FROM invoices i
),
per_cust AS (
    SELECT
        s.customer_id, c.market_type, c.region,
        COUNT(*)                                              AS invoices,
        SUM(CASE WHEN s.paid >= s.billed - 1 THEN 1 ELSE 0 END) AS settled_in_full,
        ROUND(AVG(CASE WHEN s.settled_on IS NOT NULL
                       THEN JULIANDAY(s.settled_on) - JULIANDAY(s.due_date) END), 1)
                                                              AS avg_days_vs_due,
        SUM(CASE WHEN s.settled_on > s.due_date THEN 1 ELSE 0 END) AS paid_late,
        ROUND(SUM(s.billed - s.paid))                         AS still_outstanding
    FROM settled s
    JOIN customers c ON c.customer_id = s.customer_id
    GROUP BY s.customer_id, c.market_type, c.region
)
SELECT
    customer_id, market_type, region, invoices,
    ROUND(100.0 * settled_in_full / invoices, 0)              AS settled_in_full_pct,
    ROUND(100.0 * paid_late / invoices, 0)                    AS paid_late_pct,
    avg_days_vs_due,
    still_outstanding,
    NTILE(4) OVER (ORDER BY avg_days_vs_due DESC)             AS worst_quartile
FROM per_cust
WHERE invoices >= 3
ORDER BY avg_days_vs_due DESC
LIMIT 15;


-- -----------------------------------------------------------------------------
-- Q8. What have we invoiced, month by month?
--
-- Business question: invoiced value with a running total and the month-on-month
--                    move.
-- Tables:   invoices
-- Features: running SUM() OVER with ORDER BY, LAG(), STRFTIME grouping
--
-- month_label is for reading and month_key is for sorting. ORDER BY in SQL
-- resolves an output-column alias before an input column, so ordering by a
-- formatted label like 'Aug 2026' sorts it alphabetically - April of every
-- year first. Keeping two columns avoids it.
-- -----------------------------------------------------------------------------
WITH monthly AS (
    SELECT
        STRFTIME('%Y-%m', invoice_date)                       AS month_key,
        COUNT(*)                                              AS invoices,
        ROUND(SUM((taxable_value + gst_amount) * fx_rate_to_inr)) AS invoiced_inr
    FROM invoices
    GROUP BY month_key
)
SELECT
    month_key,
    invoices,
    invoiced_inr,
    SUM(invoiced_inr) OVER (ORDER BY month_key
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                              AS running_total_inr,
    invoiced_inr - LAG(invoiced_inr) OVER (ORDER BY month_key) AS vs_prev_month,
    ROUND(100.0 * invoiced_inr
          / NULLIF(LAG(invoiced_inr) OVER (ORDER BY month_key), 0) - 100, 1)
                                                              AS pct_change
FROM monthly
ORDER BY month_key;


-- -----------------------------------------------------------------------------
-- Q9. How concentrated is the revenue?
--
-- Business question: Pareto by customer, within each product line.
-- Tables:   invoices, order_lines, items, customers
-- Features: ROW_NUMBER() for the rank, running SUM() OVER for the cumulative
--           share, SUM() OVER () for the denominator
--
-- Done per product line because the answer differs sharply between them, and a
-- single company-wide Pareto averages those differences away.
-- -----------------------------------------------------------------------------
WITH rev AS (
    SELECT
        i.product_line,
        inv.customer_id,
        SUM((inv.taxable_value + inv.gst_amount) * inv.fx_rate_to_inr) AS revenue_inr
    FROM invoices inv
    JOIN dispatches d  ON d.dispatch_id = inv.dispatch_id
    JOIN order_lines ol ON ol.order_id = d.order_id AND ol.line_no = d.line_no
    JOIN items i       ON i.item_id = ol.item_id
    GROUP BY i.product_line, inv.customer_id
),
ranked AS (
    SELECT
        product_line, customer_id, revenue_inr,
        ROW_NUMBER() OVER (PARTITION BY product_line
                           ORDER BY revenue_inr DESC)           AS rnk,
        SUM(revenue_inr) OVER (PARTITION BY product_line)       AS line_total,
        SUM(revenue_inr) OVER (PARTITION BY product_line
                               ORDER BY revenue_inr DESC
                               ROWS BETWEEN UNBOUNDED PRECEDING
                                        AND CURRENT ROW)        AS running_inr
    FROM rev
)
SELECT
    product_line, rnk, customer_id,
    ROUND(revenue_inr)                                          AS revenue_inr,
    ROUND(100.0 * revenue_inr / line_total, 1)                  AS share_pct,
    ROUND(100.0 * running_inr / line_total, 1)                  AS cumulative_pct
FROM ranked
WHERE rnk <= 5
ORDER BY product_line, rnk;


-- -----------------------------------------------------------------------------
-- Q10. What is sitting undelivered right now?
--
-- Business question: the open order book by product line and age.
-- Tables:   orders, order_lines, items, dispatches, customers
-- Features: NOT EXISTS for the anti-join, CASE bucketing, GROUP BY with
--           conditional aggregation, date arithmetic
--
-- NOT EXISTS rather than a LEFT JOIN with an IS NULL test: an order with
-- several lines would produce several rows through the join and need a
-- DISTINCT to undo, and the anti-join says what is meant.
-- -----------------------------------------------------------------------------
WITH open_orders AS (
    SELECT
        o.order_id, o.po_date, o.promised_delivery_date, o.order_status,
        o.promised_date_source,
        i.product_line,
        c.market_type,
        (SELECT SUM(ol2.ordered_qty * ol2.unit_price)
         FROM order_lines ol2 WHERE ol2.order_id = o.order_id)     AS order_value_inr,
        CAST(JULIANDAY('2026-08-31') - JULIANDAY(o.po_date) AS INTEGER) AS age_days
    FROM orders o
    JOIN order_lines ol ON ol.order_id = o.order_id AND ol.line_no = 1
    JOIN items i        ON i.item_id = ol.item_id
    JOIN customers c    ON c.customer_id = o.customer_id
    WHERE o.cancellation_date IS NULL
      AND NOT EXISTS (SELECT 1 FROM dispatches d WHERE d.order_id = o.order_id)
)
SELECT
    product_line,
    CASE WHEN age_days <= 30 THEN '0 to 30 days'
         WHEN age_days <= 60 THEN '31 to 60 days'
         WHEN age_days <= 90 THEN '61 to 90 days'
         ELSE '90 plus days' END                               AS age_bucket,
    COUNT(*)                                                   AS open_orders,
    ROUND(SUM(order_value_inr))                                AS open_value_inr,
    SUM(CASE WHEN promised_delivery_date < '2026-08-31' THEN 1 ELSE 0 END)
                                                               AS already_overdue,
    MAX(age_days)                                              AS oldest_days
FROM open_orders
GROUP BY product_line, age_bucket
ORDER BY product_line, age_bucket;


-- -----------------------------------------------------------------------------
-- Q11. How much business is lost, and in what way?
--
-- Business question: lost, cancelled and retendered work, with its value.
-- Tables:   v_raw_register (the cleaned register), orders
-- Features: reads the cleaning view rather than the raw table, conditional
--           aggregation, NULLIF guard, GROUP BY on a derived state
--
-- This one has to come from the register, not from the order tables: an order
-- that never existed leaves no row in orders. "Not received" is kept separate
-- from "Lost" because the register uses them differently - Lost means the work
-- went elsewhere, Not received means no answer ever came back.
-- -----------------------------------------------------------------------------
SELECT
    product_line,
    status_clean                                               AS outcome,
    COUNT(*)                                                   AS rows_n,
    COUNT(value_inr)                                           AS rows_with_a_value,
    ROUND(SUM(value_inr))                                      AS value_inr,
    ROUND(AVG(value_inr))                                      AS avg_value_inr,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY product_line), 1)
                                                               AS pct_of_line_rows
FROM v_raw_register
WHERE status_clean IN ('Lost', 'Cancelled', 'Retender', 'Not received', 'Closed')
GROUP BY product_line, status_clean
ORDER BY product_line, rows_n DESC;


-- -----------------------------------------------------------------------------
-- Q12. How much liquidated-damages exposure sits on the late orders?
--
-- Business question: of the orders that are late, how many carry an LD clause,
--                    and what is the value behind them?
-- Tables:   v_otif, orders, order_lines, v_raw_register
-- Features: JOIN view to view, CASE on the cleaned clause type, conditional
--           aggregation, HAVING
--
-- The honest answer is that this cannot be totalled. Only 42 of 625 register
-- rows carry anything in either LD column, and most of what is there is not a
-- clause: 22 cells hold a delivery month and one holds the word "Lost",
-- against 2 that hold a genuine percentage clause. So the output reports
-- exposure by what the cell actually HOLDS, and the count of late orders with
-- no clause recorded at all is the real finding.
-- -----------------------------------------------------------------------------
WITH late AS (
    SELECT
        v.order_id, v.product_line, v.days_late,
        o.job_no,
        (SELECT SUM(ol.ordered_qty * ol.unit_price)
         FROM order_lines ol WHERE ol.order_id = v.order_id)   AS order_value_inr,
        o.ld_clause, o.ld_clause_source
    FROM v_otif v
    JOIN orders o ON o.order_id = v.order_id
    WHERE v.on_time = 0
)
SELECT
    product_line,
    CASE
        WHEN ld_clause IS NULL                      THEN '4 nothing recorded'
        WHEN INSTR(ld_clause, '%') > 0              THEN '1 genuine clause'
        WHEN ld_clause IN ('NA', 'Not Applicable', 'No', 'Not mentioned')
                                                    THEN '2 explicitly none'
        ELSE '3 wrong kind of value in the field'
    END                                                        AS ld_status,
    COUNT(*)                                                   AS late_orders,
    ROUND(AVG(days_late), 1)                                   AS avg_days_late,
    ROUND(SUM(order_value_inr))                                AS value_at_risk_inr,
    ROUND(100.0 * COUNT(*)
          / SUM(COUNT(*)) OVER (PARTITION BY product_line), 1) AS pct_of_late
FROM late
GROUP BY product_line, ld_status
ORDER BY product_line, ld_status;


-- -----------------------------------------------------------------------------
-- Appendix A. The status mapping, printed in full
--
-- Not one of the twelve. It exists because the mapping in 03_cleaning.sql is a
-- judgement, and a judgement nobody can see is indistinguishable from making
-- the numbers up. This prints every raw wording against the state it was
-- mapped to, so a reader can disagree with a specific line rather than with
-- the idea.
--
-- Tables:   v_raw_register
-- Features: GROUP_CONCAT with DISTINCT, conditional aggregation
--
-- The wording to look at is "Open". It appears under BOTH "Quote live" and
-- "Order in progress", because the source uses it for a live quotation and for
-- an order not yet delivered, with nothing in the cell to tell them apart.
-- 03_cleaning.sql splits it on whether the row carries a PO or job number: 83
-- rows go to Quote live and 19 to Order in progress. Send all 102 one way
-- instead and Q1's conversion rate moves.
-- -----------------------------------------------------------------------------
SELECT
    status_clean                                        AS mapped_to,
    COUNT(*)                                            AS rows_n,
    COUNT(DISTINCT status_raw)                          AS wordings,
    GROUP_CONCAT(DISTINCT status_raw)                   AS as_typed_in_the_source
FROM v_raw_register
GROUP BY status_clean
ORDER BY rows_n DESC;
