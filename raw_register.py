"""
Order-to-Cash, step 1: build the raw quotation register.

What this produces is the ONE table everything else is built from: the
quotation register as it would actually come out of the company's spreadsheet,
before anyone has cleaned it. Dates are text, statuses are typed free-hand, and
plenty of cells are empty. That is the point - the cleaning is the work, and it
happens later in SQL, not here.

Everything in the output is invented. The SHAPE comes from measurement:
measured_facts.json holds the figures I took off the nine real quotation
register files (4,712 rows), and every number in CONFIG below either comes from
that file or is marked as a choice. If a figure is not in measured_facts.json
it is not a measurement, and it says so.

Seed is fixed and nothing outside the standard library is used, so re-running
gives the same file.
"""

import csv
import datetime as dt
import json
import random
from collections import Counter, defaultdict

random.seed(42)

import os
HERE = os.path.dirname(os.path.abspath(__file__))
FACTS = json.load(open(f"{HERE}/measured_facts.json"))


def qpoints(block, keys):
    """Pull the named quantiles out of a measured_facts block, in order."""
    return [(int(k[1:]) / 100.0, block[k]) for k in keys]

# =============================================================================
# CONFIG
#
# Provenance tag on every block:
#   MEASURED - taken from measured_facts.json, i.e. off the real registers
#   BRIEF    - set by the project brief, not something I measured
#   CHOSEN   - my decision; the reason is on the Assumptions tab
# =============================================================================

# --- BRIEF, on the FY24-25 basis. ONE basis is used and it is the FY24-25
# --- shape: Pultrusion largest, Grating smallest. The all-registers shape is
# --- the other way round (Pressure Vessel largest) and the two are never
# --- blended. The README states the basis.
# --- These are NOT the measured counts:
# --- FY24-25 across the real registers is 166 / 234 / 105, and all three years
# --- together is 692 / 600 / 318. The brief's figures keep the real FY24-25
# --- rank order (Pultrusion largest, Grating smallest), and row count is a free
# --- choice for synthetic data, so I follow the brief and record the measured
# --- numbers beside it rather than calling the brief's figures measured.
TARGET_ROWS = {"Pressure Vessel": 204, "Pultrusion": 277, "Grating": 144}

# --- BRIEF. Window and position.
START = dt.date(2024, 4, 1)
END = dt.date(2026, 8, 31)
AS_OF = dt.date(2026, 8, 31)

# --- MEASURED. The funnel as a 2x2 of (has a quote number) x (became an order),
# --- per line, scaled to TARGET_ROWS below. Keeping all four cells rather than
# --- two percentages is what makes conversion AND no-quote share both land on
# --- their measured values instead of only one of them.
FUNNEL = {ln: FACTS["funnel"][ln] for ln in TARGET_ROWS}

# --- MEASURED. Quantiles, taken as far out into the tail as the real data can
# --- support. Values go to p99 because grating's single 220m row would
# --- otherwise drag a tenth of the line above 3m. Lead times stop at p95
# --- because beyond that the real register holds wrong-year typos, not lead
# --- times - Pultrusion's maximum works out at 56 years.
VALUE_Q = {ln: qpoints(FACTS["order_value_inr"]["full"][ln],
                       ["p10", "p25", "p50", "p75", "p90", "p95", "p99"])
           for ln in TARGET_ROWS}
VALUE_MAX = {ln: FACTS["order_value_inr"]["full"][ln]["max"] for ln in TARGET_ROWS}
Q2PO_Q = {ln: qpoints(FACTS["lead_times_days"]["quote_to_po_full"][ln],
                      ["p10", "p25", "p50", "p75", "p90", "p95"])
          for ln in TARGET_ROWS}
PO2DP_Q = {ln: qpoints(FACTS["lead_times_days"]["po_to_dp_full"][ln],
                       ["p10", "p25", "p50", "p75", "p90", "p95", "p99"])
           for ln in TARGET_ROWS}
LEAD_CEILING = 200        # CHOSEN: days. Above this the real values are typos.

# --- MEASURED, but from the production trackers rather than the quotation
# --- registers - the registers hold no vessel diameter, so they cannot say
# --- whether lead time scales with size. Planned days per job against the
# --- 2.0 m base. The size has to be decided HERE rather than downstream,
# --- because the DP date printed in the register is a promise and it has to
# --- carry the same ladder as the one the order tables use. 1600 is
# --- interpolated, not measured; 3000 sits on two real jobs.
VESSEL_SIZES = [1400, 1600, 1800, 2000, 2400, 2600, 3000]
SIZE_FACTOR = {int(k): v for k, v
               in FACTS["vessel_size_lead_factor"]["factors"].items()}
QTY_Q = qpoints(FACTS["item_qty"], ["p10", "p25", "p50", "p75", "p90", "p95", "p99"])
QTY_MAX = FACTS["item_qty"]["max"]

# --- MEASURED. Share of rows where the lead time comes out negative, because
# --- the register really does hold POs dated before their own quote.
NEG_LEAD = {
    "quote_to_po": {"Pressure Vessel": 0.000, "Pultrusion": 0.000, "Grating": 0.032},
    "po_to_dp": {"Pressure Vessel": 0.015, "Pultrusion": 0.000, "Grating": 0.031},
}

# --- MEASURED. Field fill rates among rows that became orders. The register is
# --- genuinely this sparse - a third of orders carry no PO date at all.
FILL = FACTS["field_fill_rates_pct"]

# --- MEASURED. Job-number bands as a share of the 1,885 numeric job numbers in
# --- the real registers. The 10xxx band is 96% of them. The Assumptions tab
# --- explains why this does not follow the brief's "roughly even across four
# --- bands", which would overstate the small bands by about sixty times.
JOB_BANDS = {10000: 0.9634, 30000: 0.0218, 40000: 0.0021, 50000: 0.0042,
             60000: 0.0074, 70000: 0.0011}
JOB_BAND_MIN = 1          # CHOSEN: keep every band present, however rare

# --- MEASURED. Value concentration to hit, per line.
CONC = FACTS["customer_concentration"]
# --- CHOSEN. Customer counts scaled down with the row count. Real counts are
# --- 19 / 9 / 113 on 692 / 600 / 318 rows; these keep the same ordering and
# --- still leave enough names for a Pareto query to say something.
CUSTOMERS_PER_LINE = {"Pressure Vessel": 12, "Pultrusion": 7, "Grating": 40}

# --- MEASURED. 8.1% of real quote numbers carry a revision marker.
REVISION_SHARE = 0.081

# --- BRIEF. Cancellation rate.
CANCEL_SHARE = 0.04

# --- DERIVED from measurement, not guessed. The real Vertical column LABELS
# --- 13.7% of vessel rows, 4.7% of pultrusion and 3.5% of grating as export of
# --- any kind. The brief says true vessel export is about 20%. Those two facts
# --- together give the under-report rate: 0.137 / 0.20 = 0.69 labelled, so 31%
# --- of true exports are written up as Domestic. Rounded to 30%, and the true
# --- shares for the other two lines are then back-solved from their measured
# --- labelled shares. An earlier version used 70% mislabelling, which would
# --- have put the labelled share at 6% against a measured 13.7%.
EXPORT_MISLABEL = 0.30
TRUE_EXPORT_SHARE = {"Pressure Vessel": 0.200, "Pultrusion": 0.067, "Grating": 0.050}
# --- CHOSEN. Deemed Export exists in the real register (31 rows) but on none of
# --- these three product lines, so there is nothing to measure. The brief asks
# --- for the market, so it gets a small share.
DEEMED_EXPORT_SHARE = 0.02

# --- BRIEF. The structured "Appl:Y, Penalty per week..." format is set to zero
# --- rows. Worth being clear that the brief's REASON for this is wrong: the
# --- format IS in the real register - 7 rows, all in one tab, with the maximum
# --- percentage climbing 5.00 -> 5.05 down consecutive rows, which is one
# --- person dragging one cell in Excel rather than six contract terms. It is
# --- real, but it is 0.15% of rows. Set this to a positive number to put it
# --- back; at 625 rows the faithful figure would be 1.
APPL_Y_ROWS = 0


# =============================================================================
# Reference data. The vocabulary is real; names and codes are invented.
# =============================================================================

# MEASURED, casing variants included. The same term appears in five spellings.
# Place names are masked: [FACTORY] stands for the real factory town, [PLANT 2]
# for the real second works, and [SITE] for a real site abbreviation I could not
# resolve. The CASING variants are kept, because the same term appearing in
# seven spellings is the measured feature the cleaning step exists to handle,
# and masking the place does not cost that.
INCOTERMS = ["Ex-Works [FACTORY]", "EX-WORKS [FACTORY]", "EX-WORKS KOLKATA",
             "Ex-Works", "Ex-works [FACTORY]", "FOB", "ExW",
             "EX-WORKS [PLANT 2]", "Ex works", "FOR", "EXW", "FOR [SITE]"]
INCOTERMS_W = [221, 170, 121, 31, 30, 26, 26, 21, 20, 17, 17, 16]

# Kolkata is the generic city the fictional setting already uses and stays.
# The second entry was a real location and is masked as [PLANT 2].
QUOTE_FROM = ["Kolkata", "NA", "KOLKATA", "[PLANT 2]"]
QUOTE_FROM_W = [1400, 10, 3, 1]

# CHOSEN, and for one reason only: confidentiality. The real register's quote
# numbers start with the real company's own two-letter prefix. Rebuilding the
# real scheme from the real prefix, the real tokens and serials counting from 1
# produced 28 generated quote numbers byte-identical to real ones - not a
# coincidence, an inevitability. An invented prefix breaks that while leaving
# the FORM (prefix / token / serial / financial year, both separators, the
# revision suffixes) exactly as measured.
QUOTE_PREFIX = "VQ"

# MEASURED. Quote-number middle token by line. FV only ever appears on vessels.
# "KAG" stands in for a real customer abbreviation that the real register uses
# as a token; it is an invented code, checked against all 4,712 real rows.
QUOTE_TOKEN = {
    "Pressure Vessel": (["FV", "FGS", "KAG"], [213, 2, 1]),
    "Pultrusion": (["FG", "PG", "FGS", "FGP", "KAG"], [290, 47, 29, 3, 1]),
    "Grating": (["FG", "FGS", "PG", "G&P", "FGP", "KAG"], [122, 58, 15, 3, 1, 1]),
}

# MEASURED. 45 distinct status strings in the real register for about 13 real
# states. Built straight from measured_facts.json so the weights are the real
# counts rather than numbers typed in here by hand.
#
# Two things the brief got wrong and which are now fixed. "Verbally Confirmed"
# is not a status at all - it appears in the QUOTE NO. column. And the real
# string is "Not Received", not "Closed/Not Received"; "Closed" is separate.
#
# One real status value, 6 rows, is NOT reproduced at all: it named a real
# customer, and this repo is public. Nothing is substituted for it.
_STATES = FACTS["status_vocabulary"]["_states"]
_COUNTS = FACTS["status_vocabulary"]["all_values_as_typed"]


def status_set(state):
    """Real wordings for one state, weighted by how often each is really typed."""
    vals = _STATES[state]
    return vals, [_COUNTS[v] for v in vals]


STATUS_DELIVERED = status_set("delivered")
STATUS_IN_PROGRESS = status_set("order_in_progress")
STATUS_STOPPED = status_set("order_stopped")
STATUS_QUOTE_LIVE = status_set("quote_live")
STATUS_QUOTE_DEAD = status_set("quote_dead")
STATUS_UNUSABLE = status_set("unusable")

# MEASURED. Two unrelated taxonomies share this one column: Domestic/Export is
# a geography, Internal/External is who the customer is.
VERTICAL = FACTS["vertical_vocabulary"]["by_line"]

# MEASURED. The real file has TWO columns for one concept, and the messy one is
# far more used than the clean one:
#
#   LD         231 non-null, 48 distinct strings - a dumping ground
#   LD Clause    3 non-null,  2 distinct strings - all but unused
#
# Both are reproduced, so the cleaning step has to coalesce them and log the
# contamination instead of quietly picking one. Everything below goes in the LD
# column, grouped by what the value actually IS rather than what the column is
# called.
LD_VALUES = (
    # applicability flags
    [("NA", 52), ("Not Applicable", 1), ("No", 1), ("YES", 1), ("—", 1)]
    # delivery months typed into the LD column - wrong column, kept as found
    + [("Aug,25", 23), ("Dec,25", 17), ("Sept,25", 16), ("Jan,26", 15), ("Nov,25", 11),
       ("Oct,25", 7), ("July,25", 4), ("Nov-25,Dec-25", 4), ("Dec-25,Jan-26", 3),
       ("April,25", 2), ("Oct-25,Dec-25", 2), ("Jul-25,Aug-25,Sept-25", 1),
       ("Sept-25,Oct-25,Nov-25,Dec-25", 1), ("June-25 & July-25", 1),
       ("Jul-25 & Aug-25", 1), ("Nov-25,Dec-25,Jan-26", 1), ("Sept-25 & Oct-25", 1)]
    # a status, also the wrong column
    + [("Lost", 19)]
    # Excel serial dates that came through as timestamps
    + [("2025-07-01 00:00:00", 16), ("2025-08-01 00:00:00", 1)]
    # genuine clause text
    + [("0.5% per week", 3),
       ("Not mentioned", 2),
       ("0.5% for the first 2 weeks and 1% thereafter, subject to a maximum of 5%", 1),
       ("0.50 % per week or part thereof for the portion executed / supplied", 1),
       ("0.5% of total subcontract value/week or part thereof; max. 5%", 1),
       ("0.5% per Week of delay for 1st 4 Weeks thereafter 1.5% per week", 1),
       ("2%/month if material not lifted within 15 days of inspection call", 1),
       ("For LD Purpose, Date of site readiness clearance will only be considered", 1),
       ("Ref. As per original agreement", 1),
       ("LD charges will be applicable on actual handover date to 3PL and same will "
        "be considered by warehouse team for LD applicability", 1)]
    # payment terms typed into the LD column
    + [("100% basic payment along with 100% Taxes & Duties within 45 days", 2),
       ("Payment terms - 25% Adv. & 75% on 90 Days LC", 1)]
)

# MEASURED. The whole contents of the real "LD CLAUSE" column: three cells.
# Three are reproduced here too. At 625 rows that is a higher RATE than the real
# 0.064%, and it is deliberate - matching the rate would leave the column empty
# and there would be nothing for the cleaning step to coalesce. Matching the
# absolute count keeps the point (the column exists and is barely used) while
# leaving something to find.
LD_CLAUSE_VALUES = [("Not mentioned", 2),
                    ("LD charges will be applicable on actual handover date to 3PL and same "
                     "will be considered by warehouse team for LD applicability", 1)]
LD_CLAUSE_ROWS = 3

# MEASURED. Real payment-terms wordings. Only ~3% of order rows carry one.
PAYMENT_TERMS = FACTS["payment_terms"]["real_values_seen"]

# MEASURED. Real free-text delivery promises, word for word. "31-11-2024" is in
# the list on purpose: November has 30 days, so it can never parse.
DP_FREE_TEXT = list(FACTS["dp_date"]["free_text_values"].keys())
DP_FREE_TEXT_W = list(FACTS["dp_date"]["free_text_values"].values())

# CHOSEN. Invented people, and they really are invented this time. An earlier
# version of this file used four names and seven sets of initials copied
# straight out of the real register's CONCERNED PERSON column, while the
# comment here claimed the opposite. Every name, every surname token and every
# pair of initials below was checked against all 4,712 real rows and appears
# nowhere in them.
#
# What IS copied is only the pattern: the same person turns up as a full name
# and as initials, so any count by salesperson double-counts until someone
# ties the two together.
SALES_PEOPLE = [
    ("Ishan Kabir", "IK"), ("Niharika Vora", "NV"), ("Zubin Tandon", "ZT"),
    ("Harita Nambiar", "HN"), ("Farhan Qureshi", "FQ"), ("Qamar Bhatt", "QB"),
    ("Yash Nagpal", "YN"), ("Ketan Oza", "KO"), ("Hemal Zaveri", "HZ"),
]
SALES_SPLIT = 0.40      # CHOSEN: share of rows recorded as initials, not a name

CATEGORY_TEXT = {
    "Pressure Vessel": ["FRP Vessel", "VESSEL", "Vessel", "Pressure Vessel",
                        "FRP Pressure Vessel"],
    "Pultrusion": ["Pultrusion", "PULTRUSION", "Pultruded Profiles",
                   "Pultrusion - Handrail"],
    "Grating": ["Grating", "GRATING", "Moulded Grating", "Pultruded Grating"],
}

PROJECT_WORDS = [
    "Tank Farm Revamp", "ETP Upgradation", "Caustic Storage", "Walkway & Handrail",
    "Cooling Tower Replacement", "Desalination Package", "Bio Tank Package",
    "Platform Extension", "Chlorine Dosing Skid", "Effluent Line Replacement",
    "Clarifier Internals", "RO Skid Package", "Brine Handling", "Scrubber Package",
    "Sea Water Intake", "Pickling Line Covers", "Acid Dilution Unit",
    "Filter Press Area", "Sump Covers", "Cable Trench Covers", "Pump House Flooring",
]
SITE_WORDS = ["Phase-1", "Phase-2", "Unit-3", "Package B", "Rev-A", "Site Supply",
              "EPC Scope", "", "", ""]

# MEASURED. Real values found in the QUOTE NO. column where a quote number
# should be - status words, typed straight into the wrong field. Named here
# rather than inline so confidentiality_sweep.py can read the declared
# vocabulary from one place instead of keeping its own copy.
QUOTE_NO_JUNK = ["Open", "po received & delivered", "PO received", "Closed",
                 "Work in Process", "verbally confirmed", "Quoted Verbally",
                 "Rfq submitted"]
QUOTE_NO_JUNK_W = [30, 25, 15, 10, 8, 6, 3, 3]

COLS = ["SL No", "Party", "Project", "Incoterms", "Quote From", "Quote No.",
        "Quote Date", "Validity Date", "Vertical", "Category", "Item", "Item Qty",
        "Inquiry", "Inquiry Date", "Job No", "PO No", "PO Date", "PO Validity Date",
        "DP Date", "Status", "LD", "LD Clause", "Payment Terms",
        "PO / Quote Value", "Concerned Person"]


# =============================================================================
# Helpers
# =============================================================================

def pick(options, weights):
    return random.choices(options, weights=weights, k=1)[0]


def quantile_draw(points, floor, ceiling):
    """Draw from a distribution described by measured quantiles.

    `points` is a list of (probability, value) pairs, lowest first. Straight
    lines between them, and a straight line out to the floor below the first
    and the ceiling above the last. Crude, but it means the numbers land on the
    measured medians and spreads instead of on a shape I guessed at.

    How far out the quantiles go matters more than it looks. With only p90 and
    then a jump to the observed maximum, a tenth of all grating rows came out
    above 3m rupees against a real maximum of 220m that sits on one single row.
    Measuring p95 and p99 as well fixed that, and it also fixed the customer
    concentration, which one fat draw had been dragging upwards.
    """
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


def largest_remainder(shares, total):
    """Split `total` across `shares` so the parts add back to `total` exactly."""
    raw = {k: v * total for k, v in shares.items()}
    out = {k: int(v) for k, v in raw.items()}
    short = total - sum(out.values())
    order = sorted(raw, key=lambda k: raw[k] - out[k], reverse=True)
    for i in range(short):
        out[order[i % len(order)]] += 1
    return out


def rand_date(a, b):
    return a + dt.timedelta(days=random.randint(0, (b - a).days))


def fmt_date(d, style=None):
    """Dates go out as TEXT in three different formats, as in the real file."""
    if style is None:
        style = pick(["dd.mm.yyyy", "dd-mm-yyyy", "yyyy-mm-dd"], [60, 25, 15])
    if style == "dd.mm.yyyy":
        return d.strftime("%d.%m.%Y")
    if style == "dd-mm-yyyy":
        return d.strftime("%d-%m-%Y")
    return d.strftime("%Y-%m-%d")


def maybe(pct):
    """True `pct` percent of the time. Takes the measured fill rates directly."""
    return random.random() * 100 < pct


# =============================================================================
# 1. Customers, each with a size weight so concentration can be hit
# =============================================================================

def assign_markets(weights, export_share, deemed_share):
    """Label customers Export / Deemed Export / Domestic by weight, not by count.

    Walks customers from the SMALLEST upwards, taking them until their weights
    add up to the target share of rows. Going the other way takes the dominant
    customer first, and on this power law that one customer is 65-82% of the
    rows on its own, which overshot a 20% target to 83%.

    Taking the small ones also matches the real book: one large domestic
    customer sits above a tail of smaller export accounts, so most customers by
    head count are export while most ROWS are domestic.
    """
    total = sum(weights)
    order = sorted(range(len(weights)), key=lambda i: weights[i])
    out = ["Domestic"] * len(weights)
    # Smallest TARGET first. Running the 20% export pass before the 2% deemed
    # pass left no small customers for deemed, and whatever it then took was
    # far too big - on the vessel line that put non-domestic at 32% against a
    # 22% target.
    for label, target in sorted((("Export", export_share),
                                 ("Deemed Export", deemed_share)),
                                key=lambda t: t[1]):
        if target <= 0:
            continue
        got = 0.0
        for i in order:
            if out[i] != "Domestic":
                continue
            if got >= target * 0.85:
                break
            share = weights[i] / total
            if got + share <= target * 1.15:
                out[i] = label
                got += share
        if got == 0.0:
            for i in order:
                if out[i] == "Domestic":
                    out[i] = label
                    break
    return out


def build_customers():
    """One customer list per line, each customer carrying a size weight.

    The weight follows i ** -alpha, and alpha is searched so the top-5 share of
    total weight matches the measured top-5 value share for that line. The
    search is just a loop; there is no need for anything cleverer with one
    parameter and one target.
    """
    out = {}
    code_n = 1
    for ln, n in CUSTOMERS_PER_LINE.items():
        target = CONC[ln]["top5_pct"] / 100.0
        best, best_err = 1.0, 9.9
        a = 0.05
        while a <= 6.0:
            w = [(i + 1) ** -a for i in range(n)]
            top5 = sum(sorted(w, reverse=True)[:5]) / sum(w)
            err = abs(top5 - target)
            if err < best_err:
                best, best_err = a, err
            a += 0.05
        w = [(i + 1) ** -best for i in range(n)]
        # Market belongs to the CUSTOMER, not to the row. Drawing it per row
        # would let one customer be domestic on Monday and export on Tuesday,
        # and then the register's Vertical column could not meaningfully
        # disagree with anything.
        #
        # Which customers are export has to be chosen by their share of ROWS,
        # not by counting heads. Row counts here follow a steep power law, so
        # picking export customers at random put them in the thin tail and the
        # realised export share came out at 4% against a target of 20%.
        markets = assign_markets(w, TRUE_EXPORT_SHARE[ln], DEEMED_EXPORT_SHARE)
        custs = []
        for i in range(n):
            custs.append({"code": f"C{code_n:04d}", "weight": w[i],
                          "market": markets[i]})
            code_n += 1
        out[ln] = {"customers": custs, "alpha": round(best, 2)}
    return out


CUST = build_customers()


# =============================================================================
# 2. How many rows of each funnel type, per line
# =============================================================================

def plan_rows():
    plan = {}
    for ln, target in TARGET_ROWS.items():
        f = FUNNEL[ln]
        base = f["rows"]
        shares = {
            "won_and_quoted": f["won_and_quoted"] / base,
            "won_without_quote_no": f["won_without_quote_no"] / base,
            "quoted_not_won": f["quoted_not_won"] / base,
            "neither": f["neither"] / base,
        }
        plan[ln] = largest_remainder(shares, target)
    return plan


PLAN = plan_rows()


# =============================================================================
# 3. Build the rows
# =============================================================================

def vertical_for(line, is_export):
    """Pick a Vertical value. True exports often get written up as Domestic."""
    mix = {k: v[line] for k, v in VERTICAL.items() if v[line] > 0}
    if is_export:
        if random.random() < EXPORT_MISLABEL:
            return "Domestic" if random.random() < 0.9 else "DOMESTIC"
        exp = {k: v for k, v in mix.items() if k.lower().startswith("export")}
        return pick(list(exp), list(exp.values())) if exp else "Export"
    dom = {k: v for k, v in mix.items() if not k.lower().startswith("export")}
    return pick(list(dom), list(dom.values()))


def quote_no_for(line, serial, quote_date):
    tokens, w = QUOTE_TOKEN[line]
    tok = pick(tokens, w)
    sep = "/" if random.random() < (697 / 786) else "-"
    fy_start = quote_date.year if quote_date.month >= 4 else quote_date.year - 1
    fy = f"{str(fy_start)[2:]}-{str(fy_start + 1)[2:]}"
    digits = pick(["%03d", "%02d", "%d"], [70, 20, 10]) % serial
    base = sep.join([QUOTE_PREFIX, tok, digits, fy])
    if random.random() < REVISION_SHARE:
        base += pick([" REV-%02d", "  REV-%02d", " REV -%02d", " Rev.%d"],
                     [40, 20, 20, 20]) % random.randint(1, 8)
    return base


def build():
    rows = []
    serial = defaultdict(int)

    for line, cells in PLAN.items():
        custs = CUST[line]["customers"]
        codes = [c["code"] for c in custs]
        weights = [c["weight"] for c in custs]
        market = {c["code"]: c["market"] for c in custs}
        cat_w = [50, 20, 15, 10, 5][:len(CATEGORY_TEXT[line])]

        for kind, n in cells.items():
            for _ in range(n):
                r = {c: "" for c in COLS}
                won = kind.startswith("won")
                quoted = kind in ("won_and_quoted", "quoted_not_won")

                cust = pick(codes, weights)
                r["Party"] = cust
                r["Item"] = line
                r["Category"] = pick(CATEGORY_TEXT[line], cat_w)
                proj = random.choice(PROJECT_WORDS)
                tail = random.choice(SITE_WORDS)
                r["Project"] = (proj + (" - " + tail if tail else "")).strip()

                # --- dates. Everything hangs off one anchor so the order of
                # --- events stays right even where the register leaves gaps.
                if won:
                    po_date = rand_date(START, END)
                    # Every order was quoted at some point, whether or not the
                    # quote NUMBER made it into the register. In the real file
                    # 64.5% of order rows carry a quote date but only about a
                    # third carry a quote number that parses - the date gets
                    # typed in while the number is left blank or something else
                    # lands in that cell. So the date is modelled on all orders.
                    lead = quantile_draw(Q2PO_Q[line], 0, LEAD_CEILING)
                    if random.random() < NEG_LEAD["quote_to_po"][line]:
                        lead = -random.randint(1, 20)
                    q_date = po_date - dt.timedelta(days=int(round(lead)))
                else:
                    q_date = rand_date(START, END)
                    po_date = None

                # --- quote side
                if won and maybe(FILL["QUOTE DATE"]):
                    r["Quote Date"] = fmt_date(q_date)

                if quoted:
                    serial[line] += 1
                    r["Quote No."] = quote_no_for(line, serial[line], q_date)
                    if not won and maybe(90):
                        r["Quote Date"] = fmt_date(q_date)
                    if maybe(30):
                        r["Validity Date"] = fmt_date(
                            q_date + dt.timedelta(days=random.choice([30, 45, 60, 90])))
                    if maybe(FILL["INQUIRY DATE"]):
                        r["Inquiry Date"] = fmt_date(
                            q_date - dt.timedelta(days=random.randint(1, 25)))
                        r["Inquiry"] = pick(["Mail", "Tender", "Call", "Portal", "GEM"],
                                            [50, 20, 15, 10, 5])
                elif won:
                    # Direct repeat PO, no formal quote. On some of these rows a
                    # status word has been typed into the quote-number column.
                    if random.random() < 0.22:
                        r["Quote No."] = pick(QUOTE_NO_JUNK, QUOTE_NO_JUNK_W)

                # one diameter per vessel job, as the real POs read
                r["_dia"] = random.choice(VESSEL_SIZES) if line == "Pressure Vessel" else None

                # --- order side
                is_export = market[cust] != "Domestic"
                r["_export"] = is_export
                r["_market"] = market[cust]
                if won:
                    r["_job"] = maybe(98)
                    if maybe(97):
                        r["PO No"] = f"P{random.randint(10 ** 9, 10 ** 10 - 1)}"
                    if not r["_job"] and not r["PO No"]:
                        r["_job"] = True
                    if maybe(FILL["PO DATE"]):
                        r["PO Date"] = fmt_date(po_date)
                    if maybe(FILL["PO VALIDITY DATE"]):
                        r["PO Validity Date"] = fmt_date(
                            po_date + dt.timedelta(days=random.choice([30, 60, 90])))

                    # promised delivery date - only a quarter of orders carry one
                    if maybe(FILL["DP DATE"]):
                        free = 1 - FACTS["dp_date"]["parseable_share_of_non_blank_pct"] / 100
                        if random.random() < free:
                            r["DP Date"] = pick(DP_FREE_TEXT, DP_FREE_TEXT_W)
                        else:
                            dlead = quantile_draw(PO2DP_Q[line], 1, LEAD_CEILING)
                            if r["_dia"]:
                                dlead *= SIZE_FACTOR[r["_dia"]]
                            if random.random() < NEG_LEAD["po_to_dp"][line]:
                                dlead = -random.randint(1, 30)
                            r["DP Date"] = fmt_date(
                                po_date + dt.timedelta(days=int(round(dlead))))

                    r["_po_date"] = po_date
                    r["_delivered"] = po_date < AS_OF - dt.timedelta(days=45)

                # --- status
                if won:
                    if random.random() < CANCEL_SHARE:
                        r["Status"] = pick(*STATUS_STOPPED)
                    elif r["_delivered"]:
                        r["Status"] = pick(*STATUS_DELIVERED)
                    else:
                        r["Status"] = pick(*STATUS_IN_PROGRESS)
                elif quoted:
                    r["Status"] = (pick(*STATUS_QUOTE_DEAD) if random.random() < 0.45
                                   else pick(*STATUS_QUOTE_LIVE))
                else:
                    r["Status"] = pick(*STATUS_QUOTE_DEAD)

                # --- value. Drawn straight from the measured quantiles, with no
                # --- per-customer multiplier. Concentration is already carried
                # --- by how many rows each customer gets; multiplying the value
                # --- by customer size as well counted it twice and pushed both
                # --- the medians and the top-5 shares well above measured.
                val = quantile_draw(VALUE_Q[line], 2000, VALUE_MAX[line])
                if maybe(FILL["PO / QUOTE VALUE"] if won else 60):
                    r["PO / Quote Value"] = round(val, 2)
                r["_value"] = val

                # --- the remaining sparse columns
                if maybe(FILL["VERTICAL"] if won else 80):
                    r["Vertical"] = vertical_for(line, is_export)
                if maybe(FILL["INCOTERMS"] if won else 30):
                    r["Incoterms"] = pick(INCOTERMS, INCOTERMS_W)
                if maybe(95):
                    r["Quote From"] = pick(QUOTE_FROM, QUOTE_FROM_W)
                if maybe(FILL["ITEM QTY"] if won else 18):
                    r["Item Qty"] = max(1, int(round(
                        quantile_draw(QTY_Q, 1, QTY_MAX))))
                if maybe(FILL["PAYMENT TERMS"] if won else 2):
                    r["Payment Terms"] = random.choice(PAYMENT_TERMS)
                if maybe(FILL["LD"] if won else 3):
                    vals = [v for v, _ in LD_VALUES]
                    wts = [w for _, w in LD_VALUES]
                    r["LD"] = pick(vals, wts)

                name, initials = random.choice(SALES_PEOPLE)
                r["Concerned Person"] = initials if random.random() < SALES_SPLIT else name

                rows.append(r)

    random.shuffle(rows)
    return rows


ROWS = build()


# =============================================================================
# 4. Job numbers - banded and unique, deliberately NOT ordered by date
# =============================================================================

def assign_job_numbers(rows):
    orders = [r for r in rows if r.get("_job")]
    n = len(orders)

    counts = largest_remainder(JOB_BANDS, n)
    for b in counts:
        counts[b] = max(counts[b], JOB_BAND_MIN)
    while sum(counts.values()) > n:
        counts[max(counts, key=lambda b: counts[b])] -= 1

    random.shuffle(orders)
    i = 0
    for band, k in counts.items():
        group = orders[i:i + k]
        i += k
        # NO ordering is imposed. The real register's Spearman correlation
        # between job number and PO date is -0.030 in the dominant 10xxx band
        # across 1,267 rows, so numbers are plainly not allocated in date
        # order - most likely per project or per customer. Manufacturing an
        # order the source does not have, then validating against it, would be
        # testing my own invention. Numbers are unique and banded; which
        # number a given order gets is random inside its band.
        used = set()
        for r in group:
            n = band + random.randint(1, 999)
            while n in used:
                n = band + random.randint(1, 999)
            used.add(n)
            r["Job No"] = n
    return counts


BAND_COUNTS = assign_job_numbers(ROWS)


# =============================================================================
# 5. The specific errors that are in the real register, put back one by one
# =============================================================================

def inject_known_errors(rows):
    log = []

    def tag(r):
        return str(r["Job No"] or r["PO No"] or r["Quote No."] or "?")

    dated = [r for r in rows if r["PO Date"]]
    r = random.choice(dated)
    r["PO Date"] = r["PO Date"].replace(str(r["_po_date"].year), "2205")
    log.append(("PO Date", "year typed as 2205", tag(r)))

    cand = [x for x in rows if x["DP Date"]]
    if cand:
        r = random.choice(cand)
        r["DP Date"] = "31-11-2024"
        log.append(("DP Date", "31-11-2024, and November has 30 days", tag(r)))

    r = random.choice([x for x in rows if x["Vertical"]])
    r["Vertical"] = "Qamar Bhatt /Harita Nambiar"
    log.append(("Vertical", "two names where a market should be", tag(r)))

    r = random.choice(rows)
    r["Concerned Person"] = "Qamar Bhatt /Harita Nambiar"
    log.append(("Concerned Person", "two people in one cell", tag(r)))

    # The three cells that are the entire contents of the real "LD CLAUSE"
    # column. Put on order rows that already have something in LD, so the
    # cleaning step meets the case where both columns are populated and has to
    # decide which one wins.
    both = [x for x in rows if x["LD"] and x.get("_job")]
    plain = [x for x in rows if not x["LD"] and x.get("_job")]
    vals = [v for v, w in LD_CLAUSE_VALUES for _ in range(w)]
    targets = (random.sample(both, min(2, len(both)))
               + random.sample(plain, LD_CLAUSE_ROWS - min(2, len(both))))
    for r, v in zip(targets, vals):
        r["LD Clause"] = v
        log.append(("LD Clause", "second LD column populated"
                    + (" while LD also holds a value" if r["LD"] else ""), tag(r)))

    # "Supply-Kol" and "Bill" are real status values, one row each in 4,712.
    # Forced in so the cleaning step's UNUSABLE branch has something to catch -
    # at their real rate they would never appear in 625 rows.
    for v in [x for x, _ in [("Supply-Kol", 1), ("Bill", 1)]]:
        r = random.choice([x for x in rows if x.get("_job")])
        r["Status"] = v
        log.append(("Status", f"value carries no usable meaning: {v}", tag(r)))

    # The real register holds POs dated before their own quote, and DP dates
    # before their own PO. Left to the random draw these land about once per
    # run or not at all, and a date-order check that finds nothing is a weak
    # check - so one of each is forced in.
    cand = [x for x in rows if x["Quote Date"] and x["PO Date"] and x.get("_po_date")]
    if cand:
        r = random.choice(cand)
        r["Quote Date"] = fmt_date(r["_po_date"] + dt.timedelta(days=random.randint(5, 25)))
        log.append(("Quote Date", "quote dated after its own PO", tag(r)))
    cand = [x for x in rows if x["PO Date"] and x["DP Date"] and x.get("_po_date")
            and x is not r]
    if cand:
        r2 = random.choice(cand)
        r2["DP Date"] = fmt_date(r2["_po_date"] - dt.timedelta(days=random.randint(5, 30)))
        log.append(("DP Date", "promised delivery before the PO date", tag(r2)))

    for _ in range(4):
        r = random.choice([x for x in rows if not x["Quote No."]])
        # serial range deliberately above every real GEM reference seen in the
        # source (which run 4785587-6826398), so a generated one cannot
        # coincide with a real government tender reference
        r["Quote No."] = f"GEM/202{random.randint(4, 6)}/B/{random.randint(7000000, 7999999)}"
        log.append(("Quote No.", "GEM tender ID, not a quote number", tag(r)))

    if APPL_Y_ROWS > 0:
        for k, r in enumerate(random.sample([x for x in rows if not x["LD Clause"]],
                                            APPL_Y_ROWS)):
            r["LD Clause"] = f"Appl:Y, Penalty per week:0.50, Max %Age Imposed:5.{k:02d}"
            log.append(("LD Clause", "Excel fill-down artefact", tag(r)))
    return log


ERROR_LOG = inject_known_errors(ROWS)


# =============================================================================
# 6. Hand the rows over
#
# No file is written on import. 02_generate_data.py calls build_register(),
# writes data/raw_quote_register.csv and loads it into the database.
# Running this file directly writes the CSV so the raw table can be eyeballed
# on its own.
# =============================================================================

for _i, _r in enumerate(ROWS, 1):
    _r["SL No"] = _i

META = {"rows": len(ROWS),
        "band_counts": {str(k): v for k, v in BAND_COUNTS.items()},
        "customers": {ln: {"n": len(v["customers"]), "alpha": v["alpha"]}
                      for ln, v in CUST.items()},
        "customer_codes": {ln: [c["code"] for c in v["customers"]]
                           for ln, v in CUST.items()},
        "customer_markets": {c["code"]: c["market"]
                             for v in CUST.values() for c in v["customers"]},
        "plan": PLAN,
        "errors": [{"column": a, "what": b, "row": c} for a, b, c in ERROR_LOG]}


def build_register():
    """The raw register as a list of dicts, plus a note of how it was built."""
    return ROWS, COLS, META


if __name__ == "__main__":
    with open(f"{HERE}/data/raw_quote_register.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLS, extrasaction="ignore")
        w.writeheader()
        for r in ROWS:
            w.writerow({c: r[c] for c in COLS})
    json.dump(META, open(f"{HERE}/data/generation_log.json", "w"), indent=2)
    print(f"wrote {len(ROWS)} rows x {len(COLS)} columns")
    print("per line:", dict(Counter(r["Item"] for r in ROWS)))
    print("job-number bands:", BAND_COUNTS)
    print("errors injected:", len(ERROR_LOG))
