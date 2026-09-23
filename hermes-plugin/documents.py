"""PDF forms and bank statements, for agents to work on with exact results.

**PDF forms.** ``form_read`` lists a PDF's fillable fields with their kinds, current values and
choices, and a little of its text; ``form_fill`` writes a filled copy next to it. The agent
decides the values; the filling is exact. The person then reviews and signs the copy on the
iPhone, in iOS's own PDF markup, before anything is sent. Uses pypdf (BSD), installed with the
plugin into its own ``vendor`` folder.

**Bank statements.** ``spending`` reads a CSV exported from any bank — separator, decimal
comma, date order and column names vary, Spanish and English headers alike — and adds it up in
code: income, spending, categories, merchants, months. A language model is bad at sums; this is
not. Categories come from a built-in list of merchants and words, and the agent can correct
any with ``rules``.
"""
from __future__ import annotations

import csv
import io
import re
import sys
import unicodedata
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
MAX_BYTES = 30 * 1024 * 1024


class DocumentError(Exception):
    pass


def _file(path: str, suffixes: Tuple[str, ...]) -> Path:
    """A file of the person's, by absolute or ~ path; never a credential store."""
    raw = str(path or "").strip()
    if raw.startswith("alice://file?path="):
        from urllib.parse import unquote

        raw = unquote(raw.split("path=", 1)[1].split("&", 1)[0])
    target = Path(raw).expanduser()
    if not target.is_absolute():
        raise DocumentError("Hace falta la ruta completa del archivo.")
    target = target.resolve()
    if target.suffix.lower() not in suffixes:
        raise DocumentError(f"El archivo tiene que ser {' o '.join(suffixes)}.")
    parts = {p.lower() for p in target.parts}
    if parts & {".ssh", ".gnupg", "keychains", "mcp-tokens", "pairing"}:
        raise DocumentError("Ese archivo no se puede leer.")
    if not target.is_file():
        raise DocumentError("No encuentro ese archivo.")
    if target.stat().st_size > MAX_BYTES:
        raise DocumentError("El archivo es demasiado grande.")
    return target


# ── PDF forms ────────────────────────────────────────────────────────────────────


def _pypdf():
    vendor = HERE / "vendor"
    if vendor.is_dir() and str(vendor) not in sys.path:
        sys.path.insert(0, str(vendor))
    try:
        import pypdf  # noqa: PLC0415
    except ImportError as exc:
        raise DocumentError("Falta el lector de PDF del plugin de Alice: vuelve a instalar el plugin.") from exc
    return pypdf


_KINDS = {"/Tx": "text", "/Btn": "check", "/Ch": "choice", "/Sig": "signature"}


def form_read(path: str) -> Dict[str, Any]:
    pypdf = _pypdf()
    target = _file(path, (".pdf",))
    try:
        reader = pypdf.PdfReader(str(target))
        raw = reader.get_fields() or {}
    except Exception as exc:  # noqa: BLE001 — a broken PDF is a message, not a crash
        raise DocumentError("No se puede leer ese PDF.") from exc
    fields = []
    for name, field in raw.items():
        kind = _KINDS.get(str(field.get("/FT") or ""), "other")
        options: List[str] = []
        if kind == "choice":
            for option in field.get("/Opt") or []:
                options.append(str(option[-1] if isinstance(option, list) else option))
        elif kind == "check":
            options = [str(state).lstrip("/") for state in (field.get("/_States_") or []) if str(state) != "/Off"]
        value = field.get("/V")
        fields.append({"name": name, "kind": kind, "value": None if value is None else str(value).lstrip("/"),
                       "options": options})
    text = ""
    for page in reader.pages[:2]:
        try:
            text += (page.extract_text() or "") + "\n"
        except Exception:  # noqa: BLE001
            break
    return {"path": str(target), "pages": len(reader.pages), "fields": fields,
            "text": re.sub(r"\n{3,}", "\n\n", text).strip()[:3000],
            "fillable": bool(fields)}


def form_fill(path: str, values: Dict[str, Any]) -> Dict[str, Any]:
    pypdf = _pypdf()
    target = _file(path, (".pdf",))
    if not isinstance(values, dict) or not values:
        raise DocumentError("Faltan los valores de los campos.")
    reader = pypdf.PdfReader(str(target))
    known = reader.get_fields() or {}
    unknown = [name for name in values if name not in known]
    usable = {name: ("/" + str(v).lstrip("/") if _KINDS.get(str(known[name].get("/FT") or "")) == "check"
                     else str(v)) for name, v in values.items() if name in known}
    if not usable:
        raise DocumentError("Ninguno de esos campos está en el PDF.")
    writer = pypdf.PdfWriter(clone_from=reader)
    for page in writer.pages:
        try:
            writer.update_page_form_field_values(page, usable, auto_regenerate=False)
        except Exception:  # noqa: BLE001 — a page without fields
            continue
    writer.set_need_appearances_writer(True)
    out = target.with_name(f"{target.stem}-rellenado.pdf")
    number = 2
    while out.exists():
        out = target.with_name(f"{target.stem}-rellenado-{number}.pdf")
        number += 1
    with open(out, "xb") as handle:
        writer.write(handle)
    from urllib.parse import quote

    return {"path": str(out), "filled": sorted(usable), "unknown": unknown,
            "link": f"alice://file?path={quote(str(out), safe='/')}"}


# ── Bank statements ──────────────────────────────────────────────────────────────

CATEGORIES: List[Tuple[str, Tuple[str, ...]]] = [
    ("Supermercado", ("mercadona", "carrefour", "lidl", "aldi", "dia ", "alcampo", "eroski", "consum",
                      "bonpreu", "caprabo", "hipercor", "el corte ingles super", "supercor", "condis",
                      "ahorramas", "froiz", "gadis", "spar", "supermerc", "grocery", "whole foods", "tesco")),
    ("Restaurantes", ("restaurant", "restaurante", "bar ", "cafe", "cafeteria", "glovo", "just eat", "uber eats",
                      "deliveroo", "telepizza", "mcdonald", "burger king", "kfc", "starbucks", "vips", "foodhall")),
    ("Transporte", ("uber", "cabify", "bolt", "renfe", "metro", "tmb", "emt", "alsa", "blablacar", "taxi",
                    "parking", "aparcamiento", "autopista", "peaje", "vueling", "iberia", "ryanair", "easyjet")),
    ("Combustible", ("repsol", "cepsa", "bp ", "galp", "shell", "gasolinera", "petronor", "ballenoil", "plenoil")),
    ("Suscripciones", ("netflix", "spotify", "hbo", "max.com", "disney", "prime video", "amazon prime", "apple.com",
                       "icloud", "google one", "youtube", "chatgpt", "openai", "anthropic", "claude", "dazn",
                       "movistar+", "adobe", "microsoft", "notion", "dropbox", "patreon")),
    ("Compras", ("amazon", "aliexpress", "zara", "el corte ingles", "mediamarkt", "pccomponentes", "decathlon",
                 "ikea", "primark", "h&m", "shein", "temu", "fnac", "leroy merlin", "apple store", "etsy")),
    ("Hogar y suministros", ("iberdrola", "endesa", "naturgy", "holaluz", "totalenergies", "agua", "aguas",
                             "canal de isabel", "gas natural", "movistar", "vodafone", "orange", "digi", "simyo",
                             "pepephone", "yoigo", "masmovil", "lowi", "o2 ", "comunidad", "alquiler", "hipoteca")),
    ("Salud", ("farmacia", "pharmacy", "clinica", "dentista", "hospital", "sanitas", "adeslas", "mapfre salud",
               "dkv", "optica", "fisioterap")),
    ("Ocio", ("cine", "teatro", "ticketmaster", "entradas", "steam", "playstation", "nintendo", "xbox",
              "gimnasio", "gym", "basic-fit", "dir ", "holmes place", "booking", "airbnb", "hotel")),
    ("Bizum y transferencias", ("bizum", "transferencia", "transfer", "traspaso")),
    ("Efectivo", ("cajero", "atm", "retirada", "reintegro")),
    ("Comisiones e impuestos", ("comision", "comisión", "intereses", "hacienda", "aeat", "impuesto", "tasa",
                                "seguridad social", "ibi")),
    ("Seguros", ("seguro", "mapfre", "axa", "allianz", "mutua", "linea directa", "generali", "zurich")),
]

_DATE_HEADERS = ("fecha", "date", "f. valor", "fecha valor", "fecha operacion", "fecha operación", "f.operacion",
                 "booking date", "transaction date", "value date")
_TEXT_HEADERS = ("concepto", "descripcion", "descripción", "description", "movimiento", "detalle", "detalles",
                 "merchant", "comercio", "details", "payee", "beneficiario", "referencia")
_AMOUNT_HEADERS = ("importe", "amount", "cantidad", "importe (eur)", "importe eur", "valor", "monto")
_DEBIT_HEADERS = ("cargo", "debe", "debit", "gasto", "salida", "withdrawal")
_CREDIT_HEADERS = ("abono", "haber", "credit", "ingreso", "entrada", "deposit")


def _plain(text: str) -> str:
    folded = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode("ascii")
    return " ".join(folded.lower().split())


def _amount(raw: str) -> Optional[float]:
    text = (raw or "").strip().replace("€", "").replace("EUR", "").replace("$", "").replace(" ", "").strip()
    if not text:
        return None
    negative = text.startswith("-") or (text.startswith("(") and text.endswith(")")) or text.endswith("-")
    text = text.strip("()+- ").replace(" ", "")
    if re.fullmatch(r"\d{1,3}(\.\d{3})+(,\d+)?|\d+,\d+", text):
        text = text.replace(".", "").replace(",", ".")
    elif re.fullmatch(r"\d{1,3}(,\d{3})+(\.\d+)?", text):
        text = text.replace(",", "")
    try:
        value = float(text)
    except ValueError:
        return None
    return -value if negative else value


def _date(raw: str) -> Optional[date]:
    text = (raw or "").strip()[:19]
    for form in ("%d/%m/%Y", "%d-%m-%Y", "%Y-%m-%d", "%d/%m/%y", "%d.%m.%Y", "%Y/%m/%d", "%d-%m-%y",
                 "%Y-%m-%d %H:%M:%S", "%d/%m/%Y %H:%M:%S"):
        try:
            return datetime.strptime(text, form).date()
        except ValueError:
            continue
    return None


def _decode(raw: bytes) -> str:
    for encoding in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def _column(header: List[str], names: Tuple[str, ...]) -> Optional[int]:
    plain = [_plain(h) for h in header]
    for name in names:
        wanted = _plain(name)
        for index, cell in enumerate(plain):
            if cell == wanted:
                return index
    for name in names:
        wanted = _plain(name)
        for index, cell in enumerate(plain):
            if wanted and wanted in cell:
                return index
    return None


def transactions(text: str) -> List[Dict[str, Any]]:
    """Rows as ``{date, text, amount}``; spending negative, income positive."""
    sample = text[:20000]
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=";,\t|")
        delimiter = dialect.delimiter
    except csv.Error:
        delimiter = ";" if sample.count(";") > sample.count(",") else ","
    rows = list(csv.reader(io.StringIO(text), delimiter=delimiter))
    # Banks put a title and account details above the table: the header is the first row
    # that names a date and an amount column.
    for start, header in enumerate(rows[:40]):
        date_col = _column(header, _DATE_HEADERS)
        amount_col = _column(header, _AMOUNT_HEADERS)
        debit_col = _column(header, _DEBIT_HEADERS)
        credit_col = _column(header, _CREDIT_HEADERS)
        if date_col is not None and (amount_col is not None or debit_col is not None):
            text_col = _column(header, _TEXT_HEADERS)
            break
    else:
        raise DocumentError("No encuentro las columnas de fecha e importe en ese CSV.")
    found = []
    for row in rows[start + 1:]:
        if len(row) <= date_col:
            continue
        when = _date(row[date_col])
        if when is None:
            continue
        if amount_col is not None and amount_col < len(row):
            amount = _amount(row[amount_col])
        else:
            debit = _amount(row[debit_col]) if debit_col is not None and debit_col < len(row) else None
            credit = _amount(row[credit_col]) if credit_col is not None and credit_col < len(row) else None
            amount = (credit or 0) - abs(debit or 0) if (debit or credit) else None
        if amount is None:
            continue
        description = row[text_col].strip() if text_col is not None and text_col < len(row) else ""
        if not description:
            description = " ".join(c for i, c in enumerate(row) if i not in (date_col, amount_col) and c.strip())[:80]
        found.append({"date": when, "text": " ".join(description.split()), "amount": round(amount, 2)})
    if not found:
        raise DocumentError("Ese CSV no tiene movimientos que se puedan leer.")
    return found


def categorize(text: str, amount: float, rules: Optional[Dict[str, str]] = None) -> str:
    plain = " " + _plain(text) + " "
    for needle, category in (rules or {}).items():
        if _plain(needle) and _plain(needle) in plain:
            return category
    if amount > 0:
        return "Ingresos"
    for category, words in CATEGORIES:
        if any(_plain(word) in plain for word in words):
            return category
    return "Otros"


def _merchant(text: str) -> str:
    plain = re.sub(r"\b(compra|pago|tarj(eta)?|card|purchase|recibo|adeudo|domiciliacion|en|de|con)\b", " ",
                   _plain(text))
    plain = re.sub(r"[\d*#/\\.-]+", " ", plain)
    words = [w for w in plain.split() if len(w) > 1][:3]
    return " ".join(words).title() or text[:30]


def spending(path: str, rules: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    target = _file(path, (".csv", ".txt", ".tsv"))
    rows = transactions(_decode(target.read_bytes()))
    income = round(sum(r["amount"] for r in rows if r["amount"] > 0), 2)
    spent = round(-sum(r["amount"] for r in rows if r["amount"] < 0), 2)
    by_category: Dict[str, List[float]] = defaultdict(list)
    by_merchant: Dict[str, float] = defaultdict(float)
    by_month: Dict[str, float] = defaultdict(float)
    uncategorized: List[str] = []
    for row in rows:
        category = categorize(row["text"], row["amount"], rules)
        row["category"] = category
        if row["amount"] < 0:
            by_category[category].append(-row["amount"])
            by_merchant[_merchant(row["text"])] += -row["amount"]
            by_month[row["date"].strftime("%Y-%m")] += -row["amount"]
            if category == "Otros" and row["text"] not in uncategorized:
                uncategorized.append(row["text"])
    categories = sorted(({"name": name, "amount": round(sum(v), 2), "count": len(v),
                          "share": round(sum(v) / spent, 3) if spent else 0}
                         for name, v in by_category.items()), key=lambda c: -c["amount"])
    largest = sorted((r for r in rows if r["amount"] < 0), key=lambda r: r["amount"])[:5]
    dates = [r["date"] for r in rows]
    return {
        "from": min(dates).isoformat(), "to": max(dates).isoformat(), "count": len(rows),
        "income": income, "spent": spent, "net": round(income - spent, 2), "currency": "EUR",
        "categories": categories,
        "merchants": [{"name": n, "amount": round(a, 2)} for n, a in
                      sorted(by_merchant.items(), key=lambda kv: -kv[1])[:8]],
        "months": [{"month": m, "spent": round(a, 2)} for m, a in sorted(by_month.items())],
        "largest": [{"date": r["date"].isoformat(), "text": r["text"], "amount": r["amount"],
                     "category": r["category"]} for r in largest],
        "uncategorized": uncategorized[:15],
    }
