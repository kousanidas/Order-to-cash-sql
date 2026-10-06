# Order-to-Cash — an FRP manufacturer's order book, in SQL

What happens to an order between the customer asking for a price and the money
arriving? This is a small SQLite database of that journey for one FRP
(fibreglass-reinforced plastic) manufacturer across three product lines —
**pressure vessels, pultrusion, grating** — with twelve analysis queries over
the top.

> **All data here is synthetic.** No real customer, project, employee, PO number
> or job number appears anywhere. What is real is the *shape*: conversion rates,
> lead times, order values, customer concentration, how often each field is
> filled in, and the specific ways the source data is wrong. Those came from
> profiling nine genuine quotation register files (4,712 rows) and are recorded,
> figure by figure, in `measured_facts.json`.

## The question behind it

A quotation register kept by hand is the only record of how work arrives. It
answers seven questions badly and none of them on its own:

- What share of quotes become orders, and does it differ by product line?
- How long from quote to order, and from order to delivery?
- Do we deliver on time and in full?
- How much is owed, and how overdue?
- Who pays late, and who actually makes up the revenue?
- What is sitting undelivered right now?
- How much work is lost or cancelled?

## The thing that shapes the whole project

**Most orders never had a quotation.** Across the order book, **59.4%** of
orders arrived as a repeat PO with no quote behind them — and on the vessel
line it is **76.8%**.

| Product line | Quotes issued | Converted | Orders | Orders with no quote |
|---|---:|---:|---:|---:|
| Pressure Vessel | 64 | 65.6% | 181 | **76.8%** |
| Pultrusion | 171 | 47.4% | 130 | 37.7% |
| Grating | 91 | 41.8% | 86 | 55.8% |

So `orders.quote_id` is nullable, and **no query that counts or values orders
inner-joins to quotations** — Q1 uses `EXISTS` and joins aggregate CTEs on the
dimensions instead. Write it as an inner join on `quote_id` and you silently
drop three fifths of the business, with every number after it wrong in the same
invisible direction. That one nullable column is the reason this project is
worth doing in SQL rather than a pivot table.

Q2 is the one deliberate inner join, and it is correct there: quote-to-PO lead
time does not exist for an order that never had a quote. It prints its own `n`
so the coverage is visible rather than implied.

It also means **conversion rate is the wrong headline**. Only **161 of 397
orders (41%)** carry a quotation at all, so conversion describes two fifths of
the book. The share of revenue arriving unquoted is the number a planner would
actually want.

## Cleaning, which is most of the work

`raw_quote_register` is loaded as **every column TEXT**, exactly as the
spreadsheet exports it. `03_cleaning.sql` builds two views — `v_raw_register`,
the cleaned register that everything else reads from, and `v_otif`, which holds
the OTIF definition in one place — and writes every decision to `cleaning_log`.
The raw table is never updated.

**21 entries covering 1,499 affected rows.** The ten largest, straight out of
`cleaning_log`:

| What | Rows | Action |
|---|---:|---|
| Dates parsed from three text formats | 499 | PARSED |
| Promised date taken from the PO, not the register | 302 | FILLED |
| `Vertical` holds two unrelated taxonomies | 236 | FLAGGED |
| No value recorded on an order row | 163 | FLAGGED |
| `Open` means two different things, split by context | 102 | MAPPED |
| Status word typed into the quote-number column | 57 | FLAGGED |
| `LD` and `LD Clause` are two columns for one concept | 42 | MAPPED |
| Status: 25 wordings collapsed to 10 states | 25 | MAPPED |
| `LD` holds a delivery month, not a clause | 22 | FLAGGED |
| Register says Domestic, customer master says export | 15 | FLAGGED |

The other eleven entries cover 36 rows between them: the salesperson
name-versus-initials mapping (9), orders with no delivery date agreed at all
(8, EXCLUDED), free-text DP dates (6), GEM tender IDs in the quote-number
column (4), unusable status values (2), rows with both LD columns populated
(2), and one each of an impossible calendar date, a PO dated 2205, an Excel
timestamp in the LD column, the word "Lost" in the LD column, and a cell with
two salespeople in it.

### The trap worth knowing about

The register contains a DP date of **31-11-2024**. November has 30 days.

SQLite does not reject it. `date('2024-11-31')` returns **`2024-12-01`** — it
rolls the day forward silently. A plain `CAST` or `date()` would have turned 31
November into 1 December and nobody would ever have seen it. So every date in
`03_cleaning.sql` is reordered by position, passed through `date()`, and
**compared back against what went in**; anything that does not come back
identical is flagged rather than accepted.

That is the difference between a cleaning step and a cleaning step you can
trust, and it is the single most useful thing in this repo.

### Status: 25 wordings, 10 states

The real register uses 45 distinct status strings for about 13 states; 25 of
them turn up in these 625 rows. Case folding does most of the work; the rest is
an explicit `CASE`. **Appendix A** in
`04_analysis_queries.sql` prints every raw wording against the state it was
mapped to, so a reader can disagree with a specific line rather than with the
idea.

One decision is worth calling out. **`Open` means two different things** — a
live quotation, and an order not yet delivered — with nothing in the cell to
tell them apart. All 102 `Open` rows are split by whether the row carries a PO
or job number: **83 to "quote live", 19 to "order in progress"**. Send them all
one way and the conversion rate moves, so it is a judgement rather than a
tidy-up, and it is in `cleaning_log`.

### The LD field is a dumping ground

The real file has *two* columns for liquidated damages — `LD` (231 values, 48
distinct) and `LD CLAUSE` (3 values). Both are reproduced. Between them they
hold applicability flags, genuine percentage clauses, **delivery months**, the
word **"Lost"**, **payment terms**, and Excel timestamps. The cleaning step
classifies what each cell actually *is* rather than assuming the column name is
true, and `ld_source` records which column each value came from.

## What the data showed

### Nobody records the LD clause on the orders that are late

Of 138 late orders, **121 (88%)** have nothing in either LD column. Query 12
was meant to total the exposure; the honest answer is that it cannot be
totalled, and that is the finding. The company cannot tell you what it owes in
penalties because the field is not kept.

### OTIF is 58.5%, and it is "on time" that is failing

| | Orders due | OTIF |
|---|---:|---:|
| Pressure Vessel | 154 | 59.7% |
| Grating | 79 | 59.5% |
| Pultrusion | 121 | 56.2% |
| **All** | **354** | **58.5%** |

In full is **91.2%**; on time is **61.0%**. Quantity is rarely the problem.
Dates are.

### The delay reasons split frequency from severity

Most frequent is *customer hold on drawing approval* — 28 late orders, 24.1
days average. The worst by severity is *dimensional rework after inspection*,
which hits only 4 orders but costs **53.8 days** each. And neither is the
biggest total loss: that is *transport not arranged*, 728 days across 21
orders.

Three different answers to "what should we fix first", which is why Q5 prints
frequency rank and severity rank side by side instead of one ordered list.

### Revenue is close to single-customer on every line

| Line | Top customer | Top 1 share | Top 5 share | Customers with revenue |
|---|---|---:|---:|---:|
| Pultrusion | C0013 | 89.3% | 100.0% | 4 |
| Grating | C0020 | 80.7% | 96.7% | 19 |
| Pressure Vessel | C0001 | 65.4% | 98.3% | 8 |

Concentration this steep is measured, not invented — but only partly, and the
difference is worth being exact about. Concentration is built in through how
many ROWS each customer gets, and that lands where it should: top-5 row shares
come out 96.1% / 100.0% / 79.2% for vessel / pultrusion / grating against
measured top-5 value shares of **94.1% / 99.2% / 75.2%**.

The top-5 *value* shares above run higher than that, and on grating much higher
(96.7% against a measured 75.2%). Order values are drawn from the measured
distribution independently of who the customer is, and that distribution has a
very long tail — one large order landing on an already-large account pushes the
value share well above the row share, and across 144 grating register rows
there is nothing like enough of them to average it out. So the direction is
real and the magnitude is overstated on that line; Pultrusion's 100.0% is
simply four customers.

The two sets of figures also come off different populations — row shares from
the register, value shares from invoices — so they are quoted side by side
rather than subtracted from one another.

### The receivables book is old

₹56.0 m outstanding, and **78% of it is more than 90 days overdue** (54
invoices, 12 customers). That is a consequence of the concentration above
rather than a separate problem — the same accounts that are most of the revenue
are most of the overdue balance, and query 7 names them.

### Bigger vessels take longer, but 625 rows cannot prove it per size

| Size band | Orders | Mean promised | Mean actual | Factor |
|---|---:|---:|---:|---:|
| Small (1400–1800) | 73 | 44 d | 45 d | 0.73 |
| Medium (2000–2400) | 51 | 60 d | 50 d | 1.00 |
| Large (2600–3000) | 48 | 114 d | 85 d | 1.90 |

Per *individual* diameter there are only ~25 orders against a PO-to-delivery
spread whose p90 is four and a half times its median, and at that n the ladder
disappears into the noise. Query 4 prints both halves, because hiding the
per-size table would hide why the banding was necessary.

## Running it

Needs **SQLite 3.25 or later** — the window functions (`ROW_NUMBER`, `RANK`,
`LAG`, `NTILE`, running `SUM OVER`) are the binding constraint, and nothing
here needs a later feature. macOS ships the `sqlite3` command line already and
well above that floor; `sqlite3 --version` will tell you.

```bash
sqlite3 o2c.db < 01_schema.sql
python3 02_generate_data.py
sqlite3 o2c.db < 03_cleaning.sql
sqlite3 o2c.db < 04_analysis_queries.sql
sqlite3 o2c.db < 05_validation_checks.sql
```

`02_generate_data.py` needs only the Python standard library, and the seed is
fixed at 42, so the database comes out identical every time.

If `sqlite3` is not on your machine, `run_sql.py` does the same thing through
Python and prints each query's header above its result:

```bash
python3 run_sql.py 04_analysis_queries.sql
```

Run `04_analysis_queries.sql` one query at a time and read the comment above
each — every query carries its business question, the tables it touches and the
SQL features it uses.

## Files

| File | What it is |
|---|---|
| `01_schema.sql` | 12 tables. `raw_quote_register` is all TEXT on purpose |
| `02_generate_data.py` | Builds the normalised tables and loads the database |
| `raw_register.py` | Builds the raw register itself; imported by the above |
| `03_cleaning.sql` | Two views, plus every decision written to `cleaning_log` |
| `04_analysis_queries.sql` | The 12 analysis queries |
| `05_validation_checks.sql` | 22 checks, one row each |
| `run_sql.py` | Runs any of the .sql files without the sqlite3 CLI |
| `confidentiality_sweep.py` | Allowlist + pattern sweep; exits non-zero on a finding |
| `o2c.db` | The built database, so it can be queried without rebuilding |
| `measured_facts.json` | Every figure measured off the real registers |
| `data/raw_quote_register.csv` | The raw table as CSV |
| `data/query_results.txt` | Actual output of all 12 queries |
| `data/validation_results.txt` | Output of `run_sql.py 05_validation_checks.sql --checks` |
| `data/generation_log.json` | Which rows carry which injected fault |

## The data model

```
customers ──┬── quotations ──── quotation_lines ──┐
            │        │                            ├── items
            ├── orders ──────── order_lines ──────┘
            │     │  └── quote_id is NULLABLE (59.4% are NULL)
            │     │
            │     └── dispatches ──── invoices ──── payments
            │                              │
            └──────────────────────────────┘

payment_terms ──── orders          (credit_days drives every due date)
raw_quote_register                 (standalone, all TEXT, never updated)
cleaning_log                       (one row per cleaning decision)
```

Two views sit on top: `v_raw_register` (the cleaned register) and `v_otif`
(the OTIF definition, in one place so no query can quietly redefine it).

**OTIF:** on time if every line is fully dispatched on or before the promised
date (0 grace days, configurable in `v_otif`); in full if dispatched qty ≥
ordered qty per line. Cancelled orders excluded. Orders whose promised date has
not yet arrived are excluded too — they are the open order book, not a failure.

## Validation

**22 checks: 20 PASS, 2 EXPECTED, 0 FAIL.** `PRAGMA foreign_key_check` returns
0 violations. `data/validation_results.txt` is the output of:

```bash
python3 run_sql.py 05_validation_checks.sql --checks
```

which prints one line per check, then the summary and the engine's own
foreign-key check. It exits non-zero if anything FAILs, so it can be run as a
gate rather than read by eye.

`EXPECTED` is a third verdict alongside PASS and FAIL, and the distinction
matters: it means the check found exactly the data-quality problem it was built
to find. A run with no EXPECTED results would mean the messiness had been
quietly cleaned away.

**One check the brief asked for is deliberately absent:** *job numbers ascending
with PO date within each band.* Measurement killed it. In the real registers the
Spearman correlation between job number and PO date is **−0.030** across 1,267
rows in the dominant band — there is no ordering to validate, and numbers are
probably allocated per project rather than chronologically. Testing for it would
have meant generating an order the source does not have and then validating
against my own invention. Job numbers are still checked for uniqueness and
banding.

## Assumptions, and where every number came from

Four provenance levels, used throughout the code comments:

**MEASURED** — off the nine real registers, recorded in `measured_facts.json`:
the funnel (77% / 38% / 56% no-quote share of orders; 65% / 47% / 42%
conversion of quoted), quote-to-PO and PO-to-delivery lead times, order values
to p99, customer concentration, job-number bands, field fill rates, the DP-date
parseable share and its real free text, the LD values, the 45 status wordings,
the `Vertical` vocabulary, Incoterms, and the quote-number format.

**DERIVED** — not measured directly, but back-solved from two measured figures
rather than guessed. One value is in this class: the rate at which true export
rows are written up as "Domestic" in the `Vertical` column. The register
*labels* 13.7% of vessel rows as export of any kind, and the specification puts
true vessel export near 20%; together those give an under-report rate of about
31%, rounded to **30%**. The true export shares for the other two lines (6.7%
pultrusion, 5.0% grating) are then back-solved from their own measured labelled
shares. An earlier version of this project guessed 70% for the same number,
which would have put the labelled share at 6% against a measured 13.7%.

**CHOSEN** — the register cannot speak to these, so they are set and declared:

- **Dispatch behaviour.** 70% of orders intended on time, 92% in full. The
  register records what was promised, never what shipped.
- **Payment behaviour.** Each customer gets a payment character once and every
  invoice follows it, because otherwise query 7 measures noise rather than
  habit. Two age rules then stop old debt accumulating as a modelling artefact:
  an invoice more than **eight** months past due has most of its unpaid and
  part-paid weight moved to "paid late" (without it, 82% of the outstanding
  value sat in the 90-plus bucket), and a part payment on an invoice more than
  **six** months past due is usually chased to a close (without that follow-up
  it was 93%). It is 78% now, which is a finding about concentration rather
  than an artefact.
- **Customer counts:** 12 / 7 / 40 against real counts of 19 / 9 / 113, scaled
  down with the row count. Because the measured concentration is so extreme,
  the thin-tail customers end up with no revenue at all — query 9 returns 5
  grating, 5 vessel and 4 pultrusion customers, and only 4 pultrusion customers
  have any revenue in the whole line. That is a consequence of matching real
  concentration at 625 rows, and it is a limitation.
- **FX 83–90 INR/USD; GST 18%.** Deemed exports are charged GST here, because
  under Indian GST the supplier charges it and the buyer reclaims it — they are
  not zero-rated like exports.

**BRIEF** — set by the project specification, not by measurement:

- **Row counts 204 / 277 / 144 (625 total).** These are **not** measured. The
  **basis is the FY24-25 shape** — Pultrusion largest, Grating smallest — which
  the measured FY24-25 counts (166 / 234 / 105) do have. The all-registers shape
  is the other way round (Pressure Vessel largest, 692 / 600 / 318). **The two
  are not blended anywhere**; one basis was picked and this is it.
- **Window** 1 Apr 2024 to 31 Aug 2026, as-of 31 Aug 2026; cancellation ~4%.

### Two places where measurement overruled the specification

**Job-number bands are not spread evenly.** The specification asked for roughly
even distribution across four bands. The real register is **96.3% in the 10xxx
band** — 1,816 rows against 8, 14 and 2 — and the brief's list also omits
30xxx, which at 41 rows is the second largest. Following it literally would have
overstated the small bands about sixtyfold. Measured weights are used; all six
bands are present.

**The `Appl:Y, Penalty per week…` LD format is set to zero rows** as asked, but
the stated reason for that was wrong. The format *is* in the real register — 7
rows, all in one tab, with the maximum percentage climbing 5.00, 5.00, 5.01 …
5.05 down consecutive rows. That is one person dragging one cell in Excel, not
six contract terms. It is real but it is 0.15% of rows, so the faithful count at
625 rows would be 1. Setting `APPL_Y_ROWS` in `raw_register.py` to a positive
number puts it back; it ships at 0.

Two of the five replacement LD values the specification supplied — *"As per PO
terms"* and *"LD applicable as per contract"* — appear **nowhere** in 4,712 real
rows, so they are not used either.

### One figure borrowed from a different source

The vessel size ladder (1400 mm = 0.67 × the 2000 mm base, up to 2600 mm =
2.05) is measured, but from the **production trackers**, not the quotation
registers — the registers hold no vessel diameter at all. Same company, same
sizes. Without it, query 4 asks whether lead time scales with size and gets
back noise. The 1600 mm factor is interpolated rather than measured, and the
3000 mm figure sits on two real jobs and comes out *below* 2600 mm, which is
almost certainly sample size rather than physics.

## Confidentiality

The source is a real company's quotation register, so every identifier in this
project is invented. That was not true of two earlier drafts, which is why
there is now a check rather than an assurance:

```bash
python3 confidentiality_sweep.py      # exits non-zero on any finding
```

It works from an **allowlist**, not a denylist — it states what the synthetic
vocabulary is and fails on anything outside it. A denylist would have to spell
out the real names it was hunting for, which would put them back in the repo.
On top of that it scans every cell of every table and every line of every
supporting file for email addresses, Indian mobile numbers, GSTIN, PAN and
government tender references in the real serial range, and nets any
person-shaped text appearing in a column where names are not expected.
Validation check 18b runs the allowlist half in SQL.

Replacements were checked token by token against all 4,712 rows of the source
and appear in none of them. Masked placeholders are `[FACTORY]`, `[PLANT 2]`,
`[SITE]`, `[PLATFORM]` and the customer-group token `KAG`.

### Three things masked as a precaution rather than confirmed as sensitive

- **`FOR [SITE]`** — the source incoterm used a three-letter site abbreviation
  I could not resolve to a place, an office or a customer. Masked because an
  unidentifiable abbreviation is not the same as a harmless one.
- **`[PLATFORM]`** in payment term PT13 — the real wording names two
  trade-receivables platforms by brand. They are public market infrastructure
  rather than anything about this company, so masked rather than judged.
- **`[PLANT 2]`** — a real second works location. Less specific than the
  factory town, but still a real place, so treated the same way.

### One thing deliberately *not* masked

Job numbers are **regenerated, not copied** — the generator does not read any
real job list, and validation check 12 asserts that. But they are banded
10xxx–70xxx to match the real allocation, and the real 10xxx band spans
10001–10924, so a generated number can coincide with a real one by chance.
Shipping an exclusion list would mean publishing the very numbers it was meant
to protect, so there is none. A collision carries no real size, quantity,
customer or date with it, and that is what makes it a coincidence rather than a
leak.

## What this cannot tell you

- **Why anything is late.** `delay_reason` is recorded against the dispatch,
  but there is no supplier, material-receipt or shop-floor data behind it.
- **Anything about cost or margin.** The register holds a selling value and
  nothing else. No cost, no labour hours, no scrap.
- **Whether the register or the customer master is right** where the two
  disagree on market. 15 rows are flagged and not fixed; settling it needs the
  shipping documents.
- **Stage-level progress inside manufacturing.** Out of scope on purpose — this
  is the commercial journey, quote to cash.
- **A reliable per-size lead time.** ~25 orders per diameter is not enough.
- **A broad Pareto.** Real concentration is extreme, so at 625 rows only 4 or 5
  customers per line carry meaningful revenue — 4 in the whole pultrusion line.
