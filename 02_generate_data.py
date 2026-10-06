"""
Order-to-Cash  |  02_generate_data.py

Takes the raw quotation register from raw_register.py, turns it into the
normalised order-to-cash tables, and loads the whole lot into o2c.db.

    python3 02_generate_data.py

Run 01_schema.sql first. Seed is 42 and nothing outside the standard library
is used, so the database comes out the same every time.

ONE IDEA RUNS THROUGH THIS FILE. The raw register is a spreadsheet somebody
keeps by hand, and it is a lossy record of events that did happen: a third of
orders have no PO date typed in, three quarters have no promised delivery date,
and 37% have no value. The normalised tables model what the ERP knows, so they
are more complete than the register - and the two disagree in places. Every
disagreement is written to cleaning_log by 03_cleaning.sql rather than smoothed
over here. That gap IS the project.

Numbers come from measured_facts.json wherever the real registers could supply
one. Anything the register cannot speak to - how often a dispatch slips, how
customers pay - is set in the DESIGN block below and tagged CHOSEN.
"""

import csv
import datetime as dt
import json
import os
import random
import re
import sqlite3
from collections import defaultdict

import raw_register

HERE = os.path.dirname(os.path.abspath(__file__))
DB = f"{HERE}/o2c.db"
FACTS = json.load(open(f"{HERE}/measured_facts.json"))

random.seed(42)

AS_OF = dt.date(2026, 8, 31)
START = dt.date(2024, 4, 1)

# =============================================================================
# DESIGN - the things the quotation register cannot tell me
#
# The register records what was promised, not what was shipped, and it holds no
# payments at all. So dispatch and payment behaviour is CHOSEN. Both are set to
# land inside the ranges the brief asks for, and both are stated in the README
# as assumptions rather than findings.
# =============================================================================

# CHOSEN. Dispatch behaviour. The brief wants overall OTIF between 55% and 75%;
# 0.70 x 0.92 puts it near 64%, far enough inside the range that ordinary
# sampling noise will not push it out.
P_ON_TIME = 0.70
P_IN_FULL = 0.92
SLIP_DAYS = [(0.10, 1), (0.25, 4), (0.50, 11), (0.75, 24), (0.90, 46)]
EARLY_DAYS = [(0.10, 1), (0.50, 6), (0.90, 18)]
SPLIT_DISPATCH_SHARE = 0.18     # share of lines that go out in two movements

# CHOSEN. Payment behaviour, as at the as-of date.
P_PAID_ON_TIME = 0.46
P_PAID_LATE = 0.32
P_PART_PAID = 0.13
#   the remaining 0.09 is unpaid
LATE_PAY_DAYS = [(0.10, 3), (0.50, 21), (0.90, 74)]
ADVANCE_SHARE = 0.22            # invoices preceded by an advance

# CHOSEN. Export invoicing.
FX_RANGE = (83.0, 90.0)
GST_RATE = 0.18

SHIP_MODES = (["Road", "Flat rack", "40HC", "20FT", "Rail", "Air"],
              [52, 12, 14, 10, 10, 2])
DELAY_REASONS = (["Customer hold on drawing approval", "Raw material not received",
                  "Inspection call delayed by customer", "Transport not arranged",
                  "Capacity clash with another job", "Payment milestone not met",
                  "Dimensional rework after inspection", "Site not ready"],
                 [22, 20, 14, 12, 11, 9, 7, 5])

REGIONS = {"Domestic": [("India", "East"), ("India", "West"), ("India", "South"),
                        ("India", "North")],
           "Deemed Export": [("India", "West"), ("India", "South")],
           "Export": [("United Kingdom", "Europe"), ("Spain", "Europe"),
                      ("Netherlands", "Europe"), ("United Arab Emirates", "Middle East"),
                      ("Saudi Arabia", "Middle East"), ("Singapore", "APAC"),
                      ("Australia", "APAC"), ("United States", "Americas")]}


def pick(opts, wts):
    return random.choices(opts, weights=wts, k=1)[0]


def draw(points, floor, ceiling):
    """Same quantile draw as the register generator - see raw_register.py."""
    u = random.random()
    lo_p, lo_v = points[0]
    hi_p, hi_v = points[-1]
    if u < lo_p:
        return floor + (lo_v - floor) * (u / lo_p)
    if u > hi_p:
        return hi_v + (ceiling - hi_v) * ((u - hi_p) / (1 - hi_p))
    for (p1, v1), (p2, v2) in zip(points, points[1:]):
        if p1 <= u <= p2:
            return v1 + (v2 - v1) * (u - p1) / (p2 - p1)
    return hi_v


def iso(d):
    return d.strftime("%Y-%m-%d")


def parse_text_date(s):
    """The three formats the register uses. Anything else is not a date."""
    if not isinstance(s, str) or not s.strip():
        return None
    for f in ("%d.%m.%Y", "%d-%m-%Y", "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(s.strip(), f).date()
        except ValueError:
            pass
    return None


# =============================================================================
# 1. The raw register
# =============================================================================

ROWS, RAW_COLS, META = raw_register.build_register()
MARKET = META["customer_markets"]

with open(f"{HERE}/data/raw_quote_register.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=RAW_COLS, extrasaction="ignore")
    w.writeheader()
    for r in ROWS:
        w.writerow({c: r[c] for c in RAW_COLS})
json.dump(META, open(f"{HERE}/data/generation_log.json", "w"), indent=2)


# =============================================================================
# 2. customers
# =============================================================================

customers = []
for code, market in sorted(MARKET.items()):
    country, region = random.choice(REGIONS[market])
    customers.append({
        "customer_id": code,
        "market_type": market,
        "country": country,
        "region": region,
        # onboarded before the window opens, or during it
        "onboarded_date": iso(START - dt.timedelta(days=random.randint(30, 2600))),
    })
CUST_MARKET = {c["customer_id"]: c["market_type"] for c in customers}


# =============================================================================
# 3. items
#
# The register keeps one free-text description per row, not an item master, so
# this is built rather than measured. Vessel diameters are the real size ladder
# the company builds to, which query 4 splits lead time by.
# =============================================================================

VESSEL_SIZES = [1400, 1600, 1800, 2000, 2400, 2600, 3000]
items = []
for mm in VESSEL_SIZES:
    items.append({"item_id": f"PV-{mm}", "product_line": "Pressure Vessel",
                  "category": "FRP Vessel", "uom": "Nos",
                  "description": f"FRP pressure vessel, {mm} mm dia",
                  "vessel_diameter_mm": mm})
for n, (cat, desc, uom) in enumerate([
        ("Pultrusion", "Pultruded handrail section", "Mtr"),
        ("Pultrusion", "Pultruded angle profile", "Mtr"),
        ("Pultrusion", "Pultruded channel profile", "Mtr"),
        ("Pultrusion", "Pultruded tube 50x50", "Mtr"),
        ("Pultrusion", "Pultruded ladder stringer", "Nos")], 1):
    items.append({"item_id": f"PU-{n:02d}", "product_line": "Pultrusion",
                  "category": cat, "description": desc, "uom": uom,
                  "vessel_diameter_mm": None})
for n, (cat, desc, uom) in enumerate([
        ("Moulded Grating", "Moulded grating 38 mm, 1x4 m panel", "Sqm"),
        ("Moulded Grating", "Moulded grating 25 mm, 1x4 m panel", "Sqm"),
        ("Pultruded Grating", "Pultruded grating 40 mm panel", "Sqm"),
        ("Grating", "Grating with anti-skid grit top", "Sqm"),
        ("Grating", "Stair tread with nosing", "Nos")], 1):
    items.append({"item_id": f"GR-{n:02d}", "product_line": "Grating",
                  "category": cat, "description": desc, "uom": uom,
                  "vessel_diameter_mm": None})
ITEMS_BY_LINE = defaultdict(list)
for it in items:
    ITEMS_BY_LINE[it["product_line"]].append(it["item_id"])
VESSEL_DIA = {it["item_id"]: it["vessel_diameter_mm"] for it in items}
SIZE_FACTOR = {int(k): v for k, v in FACTS["vessel_size_lead_factor"]["factors"].items()}


# =============================================================================
# 4. payment_terms
#
# Codes are mine; the descriptions are the real wordings, word for word.
# credit_days is read off the wording, and that reading is a judgement - "100%
# against delivery" is called 0 days here, which is what makes it count as
# overdue the day after dispatch.
# =============================================================================

payment_terms = [
    ("PT01", "45 Days Credit", 45, 0),
    ("PT02", "100%Against Delivery", 0, 0),
    ("PT03", "Current dated cheque against delivery", 0, 0),
    ("PT04", "100% payment advance along with PO", 0, 100),
    ("PT05", "Payment due immediately from date of invoice", 0, 0),
    ("PT06", "100% prior to dispatch of materials", 0, 100),
    ("PT07", "45 days credit – MSME / 90 days – non-MSME", 45, 0),
    ("PT08", "100% basic payment + 100% taxes & duties within 45 days from date "
             "of delivery", 45, 0),
    ("PT09", "30% advance with PO balance, 70% post material readiness", 30, 30),
    ("PT10", "100% Payment Prior to Dispatch", 0, 100),
    ("PT11", "100% against the receipt of materials", 0, 0),
    ("PT12", "25% on order confirmation, 25% after fabrication of cylinders/heads "
             "against photographs, 45% before dispatch, 5% upon arrival (as agreed "
             "via email attachment).", 0, 50),
    # The real wording names two trade-receivables platforms by brand. They are
    # public market infrastructure rather than anything about this company, so
    # whether they are sensitive is genuinely unclear - masked as a precaution
    # and flagged in the README limitations rather than decided either way.
    ("PT13", "100% through a TReDS-style receivables platform [PLATFORM], with 180 "
             "usance days from date of dispatch, with 10% PBG valid for 24 months",
     180, 0),
    ("PT14", "To be short closed.", 0, 0),
]
PT_WEIGHTS = [7, 5, 4, 3, 2, 2, 2, 1, 1, 1, 1, 2, 1, 1]
PT_CREDIT = {c: d for c, _, d, _ in payment_terms}
PT_ADVANCE = {c: a for c, _, _, a in payment_terms}


# =============================================================================
# 5. quotations and quotation_lines
#
# A register row becomes a quotation only if its quote-number cell really holds
# a quote number. 353 real rows hold a status word or a GEM tender ID there
# instead, and those are NOT quotations - treating them as such is the mistake
# this step exists to avoid.
# =============================================================================

QPAT = re.compile(r"^VQ\s*[/-](?:\s*[A-Z&\.]{1,6}\s*[/-]){1,3}\s*\d{1,4}", re.I)
REVPAT = re.compile(r"rev\s*[.\-]?\s*(\d+)", re.I)

quotations, quotation_lines = [], []
quote_id_of_row = {}
qid = 0
seen_quote_rev = set()

for r in ROWS:
    qno = r["Quote No."]
    if not (isinstance(qno, str) and QPAT.match(qno)):
        continue
    m = REVPAT.search(qno)
    rev = int(m.group(1)) if m else 0
    base = REVPAT.sub("", qno).strip()
    while (base, rev) in seen_quote_rev:        # keep the UNIQUE constraint honest
        rev += 1
    seen_quote_rev.add((base, rev))
    qid += 1
    qdate = r.get("_qd_true") or parse_text_date(r["Quote Date"])
    if qdate is None:
        # the register did not type the date in; the quote still happened
        qdate = r.get("_po_date") or dt.date(2025, 1, 1)
    quotations.append({
        "quote_id": qid, "quote_no": base, "revision_no": rev,
        "customer_id": r["Party"],
        "inquiry_date": iso(parse_text_date(r["Inquiry Date"]))
                        if parse_text_date(r["Inquiry Date"]) else None,
        "quote_date": iso(qdate),
        "validity_date": iso(parse_text_date(r["Validity Date"]))
                         if parse_text_date(r["Validity Date"]) else None,
        "incoterms": r["Incoterms"] or None,
        "salesperson_code": r["Concerned Person"],
        "status": r["Status"],
    })
    quote_id_of_row[id(r)] = qid

    line_total = r["_value"]
    n_lines = pick([1, 2, 3], [70, 22, 8])
    splits = [random.random() + 0.3 for _ in range(n_lines)]
    splits = [x / sum(splits) for x in splits]
    for ln_no, frac in enumerate(splits, 1):
        item = random.choice(ITEMS_BY_LINE[r["Item"]])
        qty = max(1, int(round(draw(
            [(p, FACTS["item_qty"][f"p{int(p*100)}"]) for p in (0.1, 0.25, 0.5, 0.75, 0.9)],
            1, 2650) * frac)))
        quotation_lines.append({"quote_id": qid, "line_no": ln_no, "item_id": item,
                                "qty": qty,
                                "unit_price": round(line_total * frac / qty, 2)})


# =============================================================================
# 6. orders and order_lines
#
# promised_delivery_date: taken from the register where the DP cell holds a real
# date (24% of orders), otherwise from the PO document. The source is recorded
# on every row so no query has to guess, and 03_cleaning.sql counts how many
# came from where. Leaving it at 24% would cap OTIF coverage at a quarter of
# the book; filling it silently would hide that most of it is inferred.
# =============================================================================

STOPPED = set(FACTS["status_vocabulary"]["_states"]["order_stopped"])
CANCELLED_WORDS = {"Cancel", "CANCEL", "CANCELED", "CANCELLED", "Cancelled"}

orders, order_lines = [], []
oid = 0
for r in ROWS:
    if not (r.get("_job") or r["PO No"]):
        continue
    oid += 1
    po_date = r["_po_date"]
    line = r["Item"]
    # The diameter was decided in raw_register.py, because the DP date printed
    # in the register is a promise and has to carry the same size ladder the
    # order tables use. Deciding it here instead left register-sourced promises
    # unscaled, and query 4's ladder disappeared into the mix.
    r["_fixed_item"] = f"PV-{r['_dia']}" if r.get("_dia") else None

    dp_from_register = parse_text_date(r["DP Date"])
    if dp_from_register is not None:
        promised, source = dp_from_register, "register"
    else:
        lead = draw([(p, FACTS["lead_times_days"]["po_to_dp_full"][line][f"p{int(p*100)}"])
                     for p in (0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99)], 1, 200)
        # Bigger vessels take longer, and by roughly how much is measured - but
        # from the production trackers, not from the quotation registers, which
        # hold no diameter at all. Without this, query 4 asks whether lead time
        # scales with size and gets back noise.
        if r.get("_dia"):
            lead *= SIZE_FACTOR[r["_dia"]]
        promised, source = po_date + dt.timedelta(days=int(round(lead))), "po_document"
    # a handful of orders genuinely never had a date agreed
    if random.random() < 0.03:
        promised, source = None, "none"

    status = r["Status"]
    cancelled = status in CANCELLED_WORDS
    terms = pick([c for c, _, _, _ in payment_terms], PT_WEIGHTS)

    # LD: the register has two columns and they disagree. The ERP keeps one, so
    # a rule is needed. "LD Clause" wins when it is populated because it is the
    # column meant for the clause; what LD held is recorded as the source.
    if r["LD Clause"]:
        ld, ld_src = r["LD Clause"], "ld_clause_column"
    elif r["LD"]:
        ld, ld_src = r["LD"], "ld_column"
    else:
        ld, ld_src = None, None

    orders.append({
        "order_id": oid,
        "quote_id": quote_id_of_row.get(id(r)),
        "po_no": r["PO No"] or None,
        "po_date": iso(po_date),
        "job_no": int(r["Job No"]) if r["Job No"] else None,
        "customer_id": r["Party"],
        "promised_delivery_date": iso(promised) if promised else None,
        "promised_date_source": source,
        "terms_code": terms,
        "ld_clause": ld,
        "ld_clause_source": ld_src,
        "order_status": status,
        "cancellation_date": iso(po_date + dt.timedelta(days=random.randint(5, 90)))
                             if cancelled else None,
    })

    total = r["_value"]
    n_lines = pick([1, 2, 3], [64, 26, 10])
    splits = [random.random() + 0.3 for _ in range(n_lines)]
    splits = [x / sum(splits) for x in splits]
    # A vessel job is for N vessels of ONE size - that is how the real POs read
    # ("2600 mm x 4 pcs", "1800 mm x 1 pc"). Letting the lines carry different
    # diameters also made query 4 count one order under several sizes.
    for ln_no, frac in enumerate(splits, 1):
        item = r["_fixed_item"] or random.choice(ITEMS_BY_LINE[line])
        qty = max(1, int(round(draw(
            [(p, FACTS["item_qty"][f"p{int(p*100)}"]) for p in (0.1, 0.25, 0.5, 0.75, 0.9)],
            1, 2650) * frac)))
        order_lines.append({"order_id": oid, "line_no": ln_no, "item_id": item,
                            "ordered_qty": qty,
                            "unit_price": round(total * frac / qty, 2)})

ORDER_BY_ID = {o["order_id"]: o for o in orders}
LINES_BY_ORDER = defaultdict(list)
for ol in order_lines:
    LINES_BY_ORDER[ol["order_id"]].append(ol)


# =============================================================================
# 7. dispatches
#
# An order ships only if there was time to ship it before the as-of date.
# Cancelled orders never ship. Whatever is left undelivered is the open order
# book that query 10 reports, so it has to arise from the dates rather than
# being set aside on purpose.
# =============================================================================

IN_PROGRESS = set(FACTS["status_vocabulary"]["_states"]["order_in_progress"])

dispatches = []
did = 0
for o in orders:
    if o["cancellation_date"]:
        continue
    # An order the register still calls "Work in Progress" or "PO Received" has
    # not shipped. Dispatching it anyway would put the database at odds with
    # its own status column, and these are exactly the rows that make up the
    # open order book in query 10.
    if o["order_status"] in IN_PROGRESS:
        continue
    po = dt.date.fromisoformat(o["po_date"])
    promised = (dt.date.fromisoformat(o["promised_delivery_date"])
                if o["promised_delivery_date"] else po + dt.timedelta(days=45))

    on_time = random.random() < P_ON_TIME
    # The split gap is drawn FIRST. An order meant to be on time has to fit
    # BOTH movements in before the promised date, or the second one quietly
    # makes it late - which is what dragged OTIF to 54.9%, under the brief's
    # 55% floor, while the on-time draw said 70%.
    split_gap = random.randint(3, 25)
    if on_time:
        early = int(round(draw(EARLY_DAYS, 0, 40)))
        actual = min(promised - dt.timedelta(days=early),
                     promised - dt.timedelta(days=split_gap))
        reason = None
    else:
        actual = promised + dt.timedelta(days=int(round(draw(SLIP_DAYS, 1, 180))))
        reason = pick(*DELAY_REASONS)
    if actual < po:
        actual = po + dt.timedelta(days=1)
    if actual > AS_OF:
        continue                      # still open at the as-of date

    in_full = random.random() < P_IN_FULL
    for ol in LINES_BY_ORDER[o["order_id"]]:
        qty = ol["ordered_qty"]
        if not in_full:
            qty = max(1, int(round(qty * random.uniform(0.55, 0.95))))
        if random.random() < SPLIT_DISPATCH_SHARE and qty >= 2:
            first = max(1, int(qty * random.uniform(0.4, 0.7)))
            parts = [(first, actual),
                     (qty - first, actual + dt.timedelta(days=split_gap))]
        else:
            parts = [(qty, actual)]
        for q, d in parts:
            if q <= 0 or d > AS_OF:
                continue
            did += 1
            dispatches.append({"dispatch_id": did, "order_id": o["order_id"],
                               "line_no": ol["line_no"], "dispatch_date": iso(d),
                               "dispatched_qty": q, "ship_mode": pick(*SHIP_MODES),
                               "delay_reason": reason if d > promised else None})

PRICE = {(ol["order_id"], ol["line_no"]): ol["unit_price"] for ol in order_lines}


# =============================================================================
# 8. invoices
#
# One invoice per dispatch, dated the same day, per the brief. Export is USD
# and zero-rated; domestic and deemed export are INR at 18%. Deemed export IS
# taxable under Indian GST - the supplier charges it and the buyer claims it
# back - so it is not lumped in with export here.
# =============================================================================

invoices = []
iid = 0
fx_by_month = {}
for d in dispatches:
    o = ORDER_BY_ID[d["order_id"]]
    market = CUST_MARKET[o["customer_id"]]
    inr_value = round(d["dispatched_qty"] * PRICE[(d["order_id"], d["line_no"])], 2)
    ddate = dt.date.fromisoformat(d["dispatch_date"])
    if market == "Export":
        key = (ddate.year, ddate.month)
        if key not in fx_by_month:
            fx_by_month[key] = round(random.uniform(*FX_RANGE), 2)
        fx = fx_by_month[key]
        currency, taxable, gst = "USD", round(inr_value / fx, 2), 0.0
    else:
        currency, fx, taxable = "INR", 1.0, inr_value
        gst = round(inr_value * GST_RATE, 2)
    iid += 1
    credit = PT_CREDIT[o["terms_code"]]
    invoices.append({
        "invoice_id": iid,
        "invoice_no": f"VQ/{ddate.strftime('%y%m')}/{iid:05d}",
        "dispatch_id": d["dispatch_id"], "order_id": d["order_id"],
        "customer_id": o["customer_id"], "invoice_date": d["dispatch_date"],
        "currency": currency, "fx_rate_to_inr": fx,
        "taxable_value": taxable, "gst_amount": gst,
        "due_date": iso(ddate + dt.timedelta(days=credit)),
    })


# =============================================================================
# 9. payments
#
# A customer's habit has to persist, or query 7 is measuring noise: each
# customer gets a payment character once, and every invoice follows it.
# =============================================================================

CHARACTER = {}
for c in customers:
    u = random.random()
    CHARACTER[c["customer_id"]] = ("prompt" if u < 0.40 else
                                   "slow" if u < 0.75 else
                                   "erratic" if u < 0.92 else "bad")
BEHAVIOUR = {
    "prompt":  (0.80, 0.14, 0.04, 0.02),
    "slow":    (0.22, 0.56, 0.14, 0.08),
    "erratic": (0.30, 0.26, 0.30, 0.14),
    "bad":     (0.06, 0.24, 0.32, 0.38),
}

payments = []
pid = 0
for inv in invoices:
    o = ORDER_BY_ID[inv["order_id"]]
    gross = round(inv["taxable_value"] + inv["gst_amount"], 2)
    due = dt.date.fromisoformat(inv["due_date"])
    invd = dt.date.fromisoformat(inv["invoice_date"])
    w = list(BEHAVIOUR[CHARACTER[inv["customer_id"]]])
    # An invoice raised two years ago is either settled or written off by now -
    # it does not just sit there. Without this, every unpaid and part-paid
    # invoice in a 29-month window ends up in the 90-plus bucket and the
    # ageing report came out with 82% of the book over 90 days overdue.
    months_old = (AS_OF - due).days / 30.0
    if months_old > 8:
        chase = min(0.85, 0.10 * (months_old - 8))
        moved = (w[2] + w[3]) * chase
        w[2] *= (1 - chase)
        w[3] *= (1 - chase)
        w[1] += moved            # chased up, paid late
    outcome = pick(["on_time", "late", "part", "unpaid"], w)

    adv_pct = PT_ADVANCE[o["terms_code"]]
    paid_already = 0.0
    if adv_pct > 0 or random.random() < ADVANCE_SHARE:
        frac = (adv_pct / 100.0) if adv_pct > 0 else random.uniform(0.10, 0.30)
        amt = round(gross * frac, 2)
        adv_date = invd - dt.timedelta(days=random.randint(1, 30))
        if amt > 0 and adv_date <= AS_OF:
            pid += 1
            payments.append({"payment_id": pid, "invoice_id": inv["invoice_id"],
                             "payment_date": iso(max(adv_date, START)),
                             "amount": amt, "payment_type": "Advance"})
            paid_already = amt

    remaining = round(gross - paid_already, 2)
    if remaining <= 0 or outcome == "unpaid":
        continue

    if outcome == "on_time":
        pay_date = due - dt.timedelta(days=random.randint(0, max(1, PT_CREDIT[o["terms_code"]] // 2)))
        pay_date = max(pay_date, invd)
        if pay_date <= AS_OF:
            pid += 1
            payments.append({"payment_id": pid, "invoice_id": inv["invoice_id"],
                             "payment_date": iso(pay_date), "amount": remaining,
                             "payment_type": "Full" if paid_already == 0 else "Final"})
    elif outcome == "late":
        pay_date = due + dt.timedelta(days=int(round(draw(LATE_PAY_DAYS, 1, 260))))
        if pay_date <= AS_OF:
            pid += 1
            payments.append({"payment_id": pid, "invoice_id": inv["invoice_id"],
                             "payment_date": iso(pay_date), "amount": remaining,
                             "payment_type": "Full" if paid_already == 0 else "Final"})
    else:                                     # part paid and still short
        part = round(remaining * random.uniform(0.3, 0.75), 2)
        pay_date = due + dt.timedelta(days=random.randint(-10, 60))
        if part > 0 and pay_date <= AS_OF:
            pid += 1
            payments.append({"payment_id": pid, "invoice_id": inv["invoice_id"],
                             "payment_date": iso(max(pay_date, invd)),
                             "amount": part, "payment_type": "Part"})
            # A part payment is usually chased to a close. Without this
            # follow-up every part-paid invoice stayed short for ever, and the
            # ageing report came out with 93% of the outstanding value sitting
            # in the 90-plus bucket - an artefact of the model, not a finding.
            if (AS_OF - due).days / 30.0 > 6 and random.random() < 0.72:
                final_date = pay_date + dt.timedelta(days=random.randint(20, 150))
                if final_date <= AS_OF:
                    pid += 1
                    payments.append({"payment_id": pid,
                                     "invoice_id": inv["invoice_id"],
                                     "payment_date": iso(final_date),
                                     "amount": round(remaining - part, 2),
                                     "payment_type": "Final"})


# =============================================================================
# 10. Load
# =============================================================================

RAW_MAP = [("sl_no", "SL No"), ("party", "Party"), ("project", "Project"),
           ("incoterms", "Incoterms"), ("quote_from", "Quote From"),
           ("quote_no", "Quote No."), ("quote_date", "Quote Date"),
           ("validity_date", "Validity Date"), ("vertical", "Vertical"),
           ("category", "Category"), ("item", "Item"), ("item_qty", "Item Qty"),
           ("inquiry", "Inquiry"), ("inquiry_date", "Inquiry Date"),
           ("job_no", "Job No"), ("po_no", "PO No"), ("po_date", "PO Date"),
           ("po_validity_date", "PO Validity Date"), ("dp_date", "DP Date"),
           ("status", "Status"), ("ld", "LD"), ("ld_clause", "LD Clause"),
           ("payment_terms", "Payment Terms"), ("po_quote_value", "PO / Quote Value"),
           ("concerned_person", "Concerned Person")]


def insert(con, table, rows, cols):
    if not rows:
        return 0
    q = f"INSERT INTO {table} ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})"
    con.executemany(q, [[r[c] for c in cols] for r in rows])
    return len(rows)


con = sqlite3.connect(DB)
con.execute("PRAGMA foreign_keys = ON")
for t in ("payments", "invoices", "dispatches", "order_lines", "orders",
          "quotation_lines", "quotations", "payment_terms", "items", "customers",
          "raw_quote_register", "cleaning_log"):
    con.execute(f"DELETE FROM {t}")

n = {}
n["customers"] = insert(con, "customers", customers,
                        ["customer_id", "market_type", "country", "region",
                         "onboarded_date"])
n["items"] = insert(con, "items", items,
                    ["item_id", "product_line", "category", "description", "uom",
                     "vessel_diameter_mm"])
con.executemany("INSERT INTO payment_terms VALUES (?,?,?,?)", payment_terms)
n["payment_terms"] = len(payment_terms)
n["quotations"] = insert(con, "quotations", quotations,
                         ["quote_id", "quote_no", "revision_no", "customer_id",
                          "inquiry_date", "quote_date", "validity_date", "incoterms",
                          "salesperson_code", "status"])
n["quotation_lines"] = insert(con, "quotation_lines", quotation_lines,
                              ["quote_id", "line_no", "item_id", "qty", "unit_price"])
n["orders"] = insert(con, "orders", orders,
                     ["order_id", "quote_id", "po_no", "po_date", "job_no",
                      "customer_id", "promised_delivery_date", "promised_date_source",
                      "terms_code", "ld_clause", "ld_clause_source", "order_status",
                      "cancellation_date"])
n["order_lines"] = insert(con, "order_lines", order_lines,
                          ["order_id", "line_no", "item_id", "ordered_qty",
                           "unit_price"])
n["dispatches"] = insert(con, "dispatches", dispatches,
                         ["dispatch_id", "order_id", "line_no", "dispatch_date",
                          "dispatched_qty", "ship_mode", "delay_reason"])
n["invoices"] = insert(con, "invoices", invoices,
                       ["invoice_id", "invoice_no", "dispatch_id", "order_id",
                        "customer_id", "invoice_date", "currency", "fx_rate_to_inr",
                        "taxable_value", "gst_amount", "due_date"])
n["payments"] = insert(con, "payments", payments,
                       ["payment_id", "invoice_id", "payment_date", "amount",
                        "payment_type"])
con.executemany(
    f"INSERT INTO raw_quote_register ({','.join(c for c, _ in RAW_MAP)}) "
    f"VALUES ({','.join('?' * len(RAW_MAP))})",
    [[(str(r[src]) if r[src] not in ("", None) else None) for _, src in RAW_MAP]
     for r in ROWS])
n["raw_quote_register"] = len(ROWS)
con.commit()

print("loaded o2c.db")
for t, c in n.items():
    print(f"  {t:22s} {c:6d}")
linked = sum(1 for o in orders if o["quote_id"])
print(f"\norders linked to a quotation: {linked} of {len(orders)} "
      f"({100 * linked / len(orders):.1f}%) - the rest are repeat POs with no quote")
src = defaultdict(int)
for o in orders:
    src[o["promised_date_source"]] += 1
print("promised-date source:", dict(src))
con.close()
