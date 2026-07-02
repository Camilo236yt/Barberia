from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import base64
import datetime as dt
import gzip
import json
import mimetypes
import os
import re
import subprocess
import socket
import threading
import time
import uuid
import zipfile
import ipaddress
import hmac
import secrets


ROOT = Path(__file__).resolve().parent
ANGULAR_PUBLIC_DIR = ROOT / "frontend" / "dist" / "frontend" / "browser"
DATA_DIR = ROOT / "data"
UPLOAD_DIR = DATA_DIR / "uploads"
DB_PATH = DATA_DIR / "db.json"
HISTORY_ARCHIVE_DIR = DATA_DIR / "history-archives"
HISTORY_BACKUP_STATUS_PATH = DATA_DIR / "history-backup-status.json"
HISTORY_UPLOAD_INDEX_PATH = DATA_DIR / "history-upload-index.json"
HISTORY_BACKUP_SCRIPT = ROOT / "tools" / "backup-history.ps1"
MAX_IMAGE_BYTES = 8 * 1024 * 1024

LOCK = threading.Lock()
EVENT_CONDITION = threading.Condition()
DATA_VERSION = 0
ADMIN_ASSIGNMENTS = {}
ADMIN_DEVICE_SESSIONS = {}
ADMIN_ASSIGNMENT_LOCK = threading.Lock()
MAX_ADMIN_DEVICES = 2
ADMIN_DEVICE_TIMEOUT_SECONDS = 90
LOCAL_UI_SESSIONS = {}
LOCAL_UI_SESSION_LOCK = threading.Lock()
LOCAL_UI_MONITOR_ARMED = False
LOCAL_UI_CLOSE_GRACE_SECONDS = 6
LOCAL_UI_HEARTBEAT_TIMEOUT_SECONDS = 90
HISTORY_BACKUP_LOCK = threading.Lock()
HISTORY_ARCHIVE_CACHE_KEY = None
HISTORY_ARCHIVE_CACHE = ([], [])

DEFAULT_DB = {
    "branches": [
        {"id": "barberia-1", "name": "Barbería de Arriba", "active": True},
        {"id": "barberia-2", "name": "Barbería de Abajo", "active": True},
    ],
    "barbers": [
        {"id": "jose", "name": "Jose", "active": True, "branch_id": "barberia-1", "commission_rate": 0.5},
        {"id": "luis", "name": "Luís", "active": True, "branch_id": "barberia-1", "commission_rate": 0.5},
        {"id": "samuel", "name": "Samuel", "active": True, "branch_id": "barberia-1", "commission_rate": 0.5},
        {"id": "omar", "name": "Omar", "active": True, "branch_id": "barberia-2", "commission_rate": 0.6},
        {"id": "randy", "name": "Randy", "active": True, "branch_id": "barberia-2", "commission_rate": 0.5},
        {"id": "juan", "name": "Juan", "active": True, "branch_id": "barberia-2", "commission_rate": 0.5},
    ],
    "services": [
        {"id": "tijeras", "name": "Corte con tijeras", "price": 30000, "branch_id": "barberia-1"},
        {"id": "basico", "name": "Corte básico", "price": 25000, "branch_id": "barberia-1"},
        {"id": "barba", "name": "Barba", "price": 15000, "branch_id": "barberia-1"},
        {"id": "combo", "name": "Corte y barba", "price": 40000, "branch_id": "barberia-1"},
        {
            "id": "combo-tijeras",
            "name": "Corte con tijeras y barba",
            "price": 40000,
            "branch_id": "barberia-1",
        },
        {"id": "tijeras-b2", "name": "Corte con tijeras", "price": 30000, "branch_id": "barberia-2"},
        {"id": "basico-b2", "name": "Corte básico", "price": 25000, "branch_id": "barberia-2"},
        {"id": "barba-b2", "name": "Barba", "price": 15000, "branch_id": "barberia-2"},
        {"id": "combo-b2", "name": "Corte y barba", "price": 40000, "branch_id": "barberia-2"},
        {
            "id": "combo-tijeras-b2",
            "name": "Corte con tijeras y barba",
            "price": 40000,
            "branch_id": "barberia-2",
        },
    ],
    "sales": [],
    "closures": [],
    "settings": {
        "commission_rate": 0.5,
        "currency": "COP",
        "business_whatsapp_country_code": "57",
        "catalog_version": 3,
    },
}


def infer_closure_events(closure):
    events = []
    closed_at = closure.get("closed_at")
    if closed_at:
        events.append(
            {
                "type": "closed",
                "at": closed_at,
                "counted_cash": closure.get("counted_cash", 0),
                "expected_cash": closure.get("expected_cash", 0),
                "cash_difference": closure.get("cash_difference", 0),
                "total_confirmed": closure.get("total_confirmed", 0),
                "cash_total": closure.get("cash_total", 0),
                "nequi_confirmed": closure.get("nequi_confirmed", 0),
                "sales_count": closure.get("sales_count", 0),
            }
        )
    reopened_at = closure.get("reopened_at")
    if reopened_at:
        events.append({"type": "reopened", "at": reopened_at})
    return events


def closure_event_from_snapshot(snapshot):
    return {
        "type": "closed",
        "at": snapshot["closed_at"],
        "counted_cash": snapshot["counted_cash"],
        "expected_cash": snapshot["expected_cash"],
        "cash_difference": snapshot["cash_difference"],
        "total_confirmed": snapshot["total_confirmed"],
        "cash_total": snapshot["cash_total"],
        "nequi_confirmed": snapshot["nequi_confirmed"],
        "sales_count": snapshot["sales_count"],
    }


def ensure_storage():
    DATA_DIR.mkdir(exist_ok=True)
    UPLOAD_DIR.mkdir(exist_ok=True)
    HISTORY_ARCHIVE_DIR.mkdir(exist_ok=True)
    token_path = DATA_DIR / "admin-online-token.txt"
    if not token_path.exists():
        token_path.write_text(secrets.token_urlsafe(32), encoding="utf-8")
    if not DB_PATH.exists():
        write_db(DEFAULT_DB)


def admin_online_token():
    ensure_storage()
    return (DATA_DIR / "admin-online-token.txt").read_text(encoding="utf-8").strip()


def read_db():
    ensure_storage()
    with DB_PATH.open("r", encoding="utf-8") as db_file:
        data = json.load(db_file)

    changed = False
    for key in ["branches", "barbers", "services", "sales", "closures"]:
        if key not in data:
            data[key] = DEFAULT_DB[key]
            changed = True
    previous_catalog_version = int(data.get("settings", {}).get("catalog_version", 0) or 0)
    if "settings" not in data:
        data["settings"] = DEFAULT_DB["settings"]
        changed = True
    else:
        for key, value in DEFAULT_DB["settings"].items():
            if key not in data["settings"]:
                data["settings"][key] = value
                changed = True

    if previous_catalog_version < 2:
        data["branches"] = [dict(branch) for branch in DEFAULT_DB["branches"]]
        data["barbers"] = [dict(barber) for barber in DEFAULT_DB["barbers"]]
        data["services"] = [dict(service) for service in DEFAULT_DB["services"]]
        data["settings"]["catalog_version"] = 2
        changed = True

    if previous_catalog_version < 3:
        updated_prices = {
            "tijeras": 30000,
            "basico": 25000,
            "barba": 15000,
            "combo": 40000,
            "combo-tijeras": 40000,
            "tijeras-b2": 30000,
            "basico-b2": 25000,
            "barba-b2": 15000,
            "combo-b2": 40000,
            "combo-tijeras-b2": 40000,
        }
        for service in data["services"]:
            if service.get("id") in updated_prices:
                service["price"] = updated_prices[service["id"]]
        data["settings"]["catalog_version"] = 3
        changed = True

    for collection_name in ["barbers", "services"]:
        unassigned = [item for item in data[collection_name] if not item.get("branch_id")]
        if unassigned:
            existing_ids = {item.get("id") for item in data[collection_name]}
            clones = []
            for item in unassigned:
                item["branch_id"] = "barberia-1"
                clone = dict(item)
                clone_id = f"{item['id']}-b2"
                while clone_id in existing_ids:
                    clone_id = f"{item['id']}-b2-{uuid.uuid4().hex[:4]}"
                clone["id"] = clone_id
                clone["branch_id"] = "barberia-2"
                existing_ids.add(clone_id)
                clones.append(clone)
            data[collection_name].extend(clones)
            changed = True

    for barber in data["barbers"]:
        default_rate = 0.6 if (
            barber.get("id") == "omar" or barber.get("name", "").strip().casefold() == "omar"
        ) else 0.5
        try:
            commission_rate = float(barber.get("commission_rate", default_rate))
        except (TypeError, ValueError):
            commission_rate = default_rate
        if commission_rate <= 0 or commission_rate > 1:
            commission_rate = default_rate
        if barber.get("commission_rate") != commission_rate:
            barber["commission_rate"] = commission_rate
            changed = True

    for closure in data["closures"]:
        if not closure.get("branch_id"):
            closure["branch_id"] = "barberia-1"
            closure["branch_name"] = "Barbería 1"
            changed = True
        if "events" not in closure or not isinstance(closure.get("events"), list):
            closure["events"] = infer_closure_events(closure)
            changed = True

    for sale in data["sales"]:
        if not sale.get("branch_id"):
            sale["branch_id"] = "barberia-1"
            sale["branch_name"] = "Barbería 1"
            changed = True

    if changed:
        write_db(data)
    return data


def write_db(data):
    DATA_DIR.mkdir(exist_ok=True)
    temp_path = DB_PATH.with_suffix(".tmp")
    with temp_path.open("w", encoding="utf-8") as db_file:
        json.dump(data, db_file, ensure_ascii=False, indent=2)
    temp_path.replace(DB_PATH)


def publish_data_change():
    global DATA_VERSION
    with EVENT_CONDITION:
        DATA_VERSION += 1
        EVENT_CONDITION.notify_all()


def now_iso():
    return dt.datetime.now().isoformat(timespec="seconds")


def today_key():
    return dt.date.today().isoformat()


def item_day(item):
    return str(item.get("created_at") or "")[:10]


def money_to_int(value):
    try:
        amount = int(round(float(value)))
    except (TypeError, ValueError):
        return None
    return amount if amount > 0 else None


def validated_name(value, item_label):
    name = str(value or "").strip()
    if len(name) < 2:
        raise ValueError(f"El nombre del {item_label} debe tener al menos 2 caracteres.")
    if len(name) > 60:
        raise ValueError(f"El nombre del {item_label} no puede superar 60 caracteres.")
    return name


def find_by_id(items, item_id):
    return next((item for item in items if item.get("id") == item_id), None)


def find_closure(db, date_key, branch_id):
    return next(
        (
            closure
            for closure in db["closures"]
            if closure.get("date") == date_key and closure.get("branch_id") == branch_id
        ),
        None,
    )


def materialize_archived_sale(db, sale_id):
    sale = find_by_id(db["sales"], sale_id)
    if sale:
        return sale

    for archive_path in sorted(HISTORY_ARCHIVE_DIR.glob("*.zip"), reverse=True):
        archived = read_history_archive(archive_path)
        if not archived or not find_by_id(archived.get("sales", []), sale_id):
            continue

        known_sale_ids = {item.get("id") for item in db["sales"]}
        for archived_sale in archived.get("sales", []):
            if archived_sale.get("id") not in known_sale_ids:
                db["sales"].append(archived_sale)
                known_sale_ids.add(archived_sale.get("id"))

        known_closure_ids = {item.get("id") for item in db["closures"]}
        for archived_closure in archived.get("closures", []):
            if archived_closure.get("id") not in known_closure_ids:
                db["closures"].append(archived_closure)
                known_closure_ids.add(archived_closure.get("id"))

        return find_by_id(db["sales"], sale_id)
    return None


def is_day_closed(db, branch_id, date_key=None):
    closure = find_closure(db, date_key or today_key(), branch_id)
    return bool(closure and closure.get("status") == "closed")


def parse_counted_cash(value):
    try:
        amount = int(round(float(value or 0)))
    except (TypeError, ValueError):
        raise ValueError("El efectivo contado debe ser un numero valido.")
    if amount < 0:
        raise ValueError("El efectivo contado no puede ser negativo.")
    return amount


def barber_commission_rate(barber):
    default_rate = 0.6 if (
        barber.get("id") == "omar" or barber.get("name", "").strip().casefold() == "omar"
    ) else 0.5
    try:
        rate = float(barber.get("commission_rate", default_rate))
    except (TypeError, ValueError):
        rate = default_rate
    return rate if 0 < rate <= 1 else default_rate


def sale_tip_amount(sale):
    try:
        amount = int(sale.get("amount", 0) or 0)
        tip = int(sale.get("tip_amount", 0) or 0)
    except (TypeError, ValueError):
        return 0
    return tip if 0 <= tip <= amount else 0


def sale_base_amount(sale):
    return int(sale.get("amount", 0) or 0) - sale_tip_amount(sale)


def closure_snapshot(db, date_key, counted_cash, branch):
    sales = [
        sale
        for sale in db["sales"]
        if item_day(sale) == date_key
        and sale.get("branch_id") == branch["id"]
        and sale.get("status") not in {"annulled", "rejected"}
    ]
    confirmed = [sale for sale in sales if sale.get("status") == "confirmed"]
    pending = [sale for sale in sales if sale.get("status") == "pending_review"]
    cash_total = sum(sale["amount"] for sale in confirmed if sale.get("payment_method") == "cash")
    nequi_confirmed = sum(sale["amount"] for sale in confirmed if sale.get("payment_method") == "nequi")
    nequi_pending = sum(sale["amount"] for sale in pending if sale.get("payment_method") == "nequi")
    commission_rate = float(db["settings"].get("commission_rate", 0.5))

    barber_totals = []
    for barber in db["barbers"]:
        if barber.get("branch_id") != branch["id"]:
            continue
        barber_sales = [sale for sale in confirmed if sale.get("barber_id") == barber["id"]]
        total = sum(sale["amount"] for sale in barber_sales)
        tip_total = sum(sale_tip_amount(sale) for sale in barber_sales)
        base_total = sum(sale_base_amount(sale) for sale in barber_sales)
        nequi_total = sum(
            sale["amount"] for sale in barber_sales if sale.get("payment_method") == "nequi"
        )
        nequi_base_total = sum(
            sale_base_amount(sale)
            for sale in barber_sales
            if sale.get("payment_method") == "nequi"
        )
        barber_rate = barber_commission_rate(barber)
        base_commission = int(round(base_total * barber_rate))
        commission = base_commission + tip_total
        nequi_shop_share = nequi_base_total - int(round(nequi_base_total * barber_rate))
        barber_totals.append(
            {
                "barber_id": barber["id"],
                "barber_name": barber["name"],
                "sales_count": len(barber_sales),
                "total": total,
                "base_total": base_total,
                "tip_total": tip_total,
                "nequi_total": nequi_total,
                "nequi_base_total": nequi_base_total,
                "nequi_shop_share": nequi_shop_share,
                "commission_rate": barber_rate,
                "commission": commission,
                "shop_share": base_total - base_commission,
            }
        )

    return {
        "date": date_key,
        "branch_id": branch["id"],
        "branch_name": branch["name"],
        "closed_at": now_iso(),
        "status": "closed",
        "counted_cash": counted_cash,
        "expected_cash": cash_total,
        "cash_difference": counted_cash - cash_total,
        "total_confirmed": sum(sale["amount"] for sale in confirmed),
        "cash_total": cash_total,
        "nequi_confirmed": nequi_confirmed,
        "nequi_pending": nequi_pending,
        "sales_count": len(confirmed),
        "pending_nequi_count": len(pending),
        "commission_rate": commission_rate,
        "barbers": barber_totals,
    }


def refresh_closure_summary(db, date_key, branch):
    closure = find_closure(db, date_key, branch["id"])
    if not closure:
        return None

    sales = [
        sale
        for sale in db["sales"]
        if item_day(sale) == date_key
        and sale.get("branch_id") == branch["id"]
        and sale.get("status") not in {"annulled", "rejected"}
    ]
    confirmed = [sale for sale in sales if sale.get("status") == "confirmed"]
    pending = [sale for sale in sales if sale.get("status") == "pending_review"]
    cash_total = sum(sale["amount"] for sale in confirmed if sale.get("payment_method") == "cash")
    nequi_confirmed = sum(
        sale["amount"] for sale in confirmed if sale.get("payment_method") == "nequi"
    )
    nequi_pending = sum(
        sale["amount"] for sale in pending if sale.get("payment_method") == "nequi"
    )

    current_barbers = {
        barber["id"]: barber
        for barber in db["barbers"]
        if barber.get("branch_id") == branch["id"]
    }
    previous_barbers = {
        barber.get("barber_id"): barber
        for barber in closure.get("barbers", [])
        if barber.get("barber_id")
    }
    barber_ids = list(current_barbers)
    for barber_id in previous_barbers:
        if barber_id not in barber_ids:
            barber_ids.append(barber_id)
    for sale in confirmed:
        if sale.get("barber_id") not in barber_ids:
            barber_ids.append(sale.get("barber_id"))

    barber_totals = []
    for barber_id in barber_ids:
        barber_sales = [sale for sale in confirmed if sale.get("barber_id") == barber_id]
        current = current_barbers.get(barber_id)
        previous = previous_barbers.get(barber_id, {})
        if current:
            rate = barber_commission_rate(current)
            name = current["name"]
        else:
            try:
                rate = float(previous.get("commission_rate", 0.5))
            except (TypeError, ValueError):
                rate = 0.5
            if rate <= 0 or rate > 1:
                rate = 0.5
            name = previous.get("barber_name") or (
                barber_sales[0].get("barber_name") if barber_sales else "Barbero"
            )
        total = sum(sale["amount"] for sale in barber_sales)
        tip_total = sum(sale_tip_amount(sale) for sale in barber_sales)
        base_total = sum(sale_base_amount(sale) for sale in barber_sales)
        nequi_total = sum(
            sale["amount"] for sale in barber_sales if sale.get("payment_method") == "nequi"
        )
        nequi_base_total = sum(
            sale_base_amount(sale)
            for sale in barber_sales
            if sale.get("payment_method") == "nequi"
        )
        base_commission = int(round(base_total * rate))
        commission = base_commission + tip_total
        nequi_shop_share = nequi_base_total - int(round(nequi_base_total * rate))
        barber_totals.append(
            {
                "barber_id": barber_id,
                "barber_name": name,
                "sales_count": len(barber_sales),
                "total": total,
                "base_total": base_total,
                "tip_total": tip_total,
                "nequi_total": nequi_total,
                "nequi_base_total": nequi_base_total,
                "nequi_shop_share": nequi_shop_share,
                "commission_rate": rate,
                "commission": commission,
                "shop_share": base_total - base_commission,
            }
        )

    counted_cash = int(closure.get("counted_cash", 0) or 0)
    closure.update(
        {
            "expected_cash": cash_total,
            "cash_difference": counted_cash - cash_total,
            "total_confirmed": sum(sale["amount"] for sale in confirmed),
            "cash_total": cash_total,
            "nequi_confirmed": nequi_confirmed,
            "nequi_pending": nequi_pending,
            "sales_count": len(confirmed),
            "pending_nequi_count": len(pending),
            "barbers": barber_totals,
            "modified_at": now_iso(),
        }
    )
    return closure


def save_proof_image(data_url, sale_id):
    if not data_url:
        return None

    match = re.match(r"^data:(image/[a-zA-Z0-9.+-]+);base64,(.+)$", data_url, re.DOTALL)
    if not match:
        raise ValueError("El comprobante debe ser una imagen valida.")

    mime_type, encoded = match.groups()
    raw = base64.b64decode(encoded, validate=True)
    if len(raw) > MAX_IMAGE_BYTES:
        raise ValueError("La imagen supera el limite de 8 MB.")

    extension = mimetypes.guess_extension(mime_type) or ".jpg"
    if extension == ".jpe":
        extension = ".jpg"

    filename = f"{sale_id}{extension}"
    target = UPLOAD_DIR / filename
    target.write_bytes(raw)
    return f"/uploads/{filename}"


def local_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def active_public_dir():
    return ANGULAR_PUBLIC_DIR


def history_day_payload(db, date_key):
    return {
        "version": 1,
        "month": date_key[:7],
        "date": date_key,
        "generated_at": now_iso(),
        "branches": db["branches"],
        "barbers": db["barbers"],
        "services": db["services"],
        "settings": db["settings"],
        "sales": [
            sale for sale in db["sales"] if item_day(sale) == date_key
        ],
        "closures": [
            closure for closure in db["closures"] if closure.get("date") == date_key
        ],
    }


def write_history_archive(db, date_key):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_key):
        raise ValueError("Fecha de historial no valida.")
    HISTORY_ARCHIVE_DIR.mkdir(exist_ok=True)
    payload = history_day_payload(db, date_key)
    target = HISTORY_ARCHIVE_DIR / f"{date_key}.zip"
    temp_target = HISTORY_ARCHIVE_DIR / f"{date_key}.tmp"
    with zipfile.ZipFile(
        temp_target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
    ) as archive:
        archive.writestr(
            "history.json",
            json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8"),
        )
        included = set()
        for sale in payload["sales"]:
            proof_url = str(sale.get("proof_url") or "")
            if not proof_url.startswith("/uploads/"):
                continue
            filename = Path(proof_url).name
            source = UPLOAD_DIR / filename
            if source.is_file() and filename not in included:
                archive.write(source, f"uploads/{filename}")
                included.add(filename)
    temp_target.replace(target)
    mark_history_archive_pending(date_key)
    return target


def read_history_upload_index():
    if not HISTORY_UPLOAD_INDEX_PATH.exists():
        return {}
    try:
        value = json.loads(HISTORY_UPLOAD_INDEX_PATH.read_text(encoding="utf-8-sig"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def mark_history_archive_pending(date_key):
    uploaded = read_history_upload_index()
    if date_key not in uploaded:
        return
    uploaded.pop(date_key, None)
    temp_path = HISTORY_UPLOAD_INDEX_PATH.with_suffix(".tmp")
    temp_path.write_text(
        json.dumps(uploaded, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    temp_path.replace(HISTORY_UPLOAD_INDEX_PATH)


def read_history_archive(path):
    try:
        with zipfile.ZipFile(path, "r") as archive:
            return json.loads(archive.read("history.json").decode("utf-8"))
    except (OSError, KeyError, ValueError, zipfile.BadZipFile, json.JSONDecodeError):
        return None


def restore_history_proofs(month_key):
    UPLOAD_DIR.mkdir(exist_ok=True)
    for archive_path in HISTORY_ARCHIVE_DIR.glob(f"{month_key}-??.zip"):
        with zipfile.ZipFile(archive_path, "r") as archive:
            for member in archive.infolist():
                member_path = Path(member.filename)
                if (
                    member.is_dir()
                    or len(member_path.parts) != 2
                    or member_path.parts[0] != "uploads"
                ):
                    continue
                filename = member_path.name
                target = UPLOAD_DIR / filename
                if not target.exists():
                    target.write_bytes(archive.read(member))


def combined_history(db):
    global HISTORY_ARCHIVE_CACHE_KEY, HISTORY_ARCHIVE_CACHE
    sales = list(db["sales"])
    closures = list(db["closures"])
    sale_ids = {sale.get("id") for sale in sales}
    closure_ids = {closure.get("id") for closure in closures}
    archive_paths = sorted(HISTORY_ARCHIVE_DIR.glob("*.zip"))
    cache_key = tuple(
        (str(path), path.stat().st_mtime_ns, path.stat().st_size) for path in archive_paths
    )
    if cache_key != HISTORY_ARCHIVE_CACHE_KEY:
        archived_sales = []
        archived_closures = []
        for archive_path in archive_paths:
            archived = read_history_archive(archive_path)
            if not archived:
                continue
            archived_sales.extend(archived.get("sales", []))
            archived_closures.extend(archived.get("closures", []))
        HISTORY_ARCHIVE_CACHE = (archived_sales, archived_closures)
        HISTORY_ARCHIVE_CACHE_KEY = cache_key

    for sale in HISTORY_ARCHIVE_CACHE[0]:
        if sale.get("id") not in sale_ids:
            sales.append(sale)
            sale_ids.add(sale.get("id"))
    for closure in HISTORY_ARCHIVE_CACHE[1]:
        if closure.get("id") not in closure_ids:
            closures.append(closure)
            closure_ids.add(closure.get("id"))
    return sales, closures


def prepare_existing_history_archives(db):
    created_dates = []
    closure_dates = sorted(
        {
            str(closure.get("date") or "")
            for closure in db["closures"]
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(closure.get("date") or ""))
        }
    )
    for date_key in closure_dates:
        if not (HISTORY_ARCHIVE_DIR / f"{date_key}.zip").exists():
            write_history_archive(db, date_key)
            created_dates.append(date_key)
    return created_dates


def pending_history_uploads():
    uploaded = read_history_upload_index()
    return sorted(
        path.stem
        for path in HISTORY_ARCHIVE_DIR.glob("????-??-??.zip")
        if path.stem not in uploaded
    )


def run_history_backup(action, history_key="", timeout=120):
    if action not in {"Upload", "List", "Download"}:
        raise ValueError("Accion de respaldo no valida.")
    if action == "Upload" and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", history_key):
        raise ValueError("Fecha de historial no valida.")
    if action == "Download" and not re.fullmatch(r"\d{4}-\d{2}", history_key):
        raise ValueError("Mes de historial no valido.")
    if not HISTORY_BACKUP_SCRIPT.exists():
        raise RuntimeError("No se encontro el modulo de respaldo de historial.")
    powershell = (
        Path(os.environ.get("SystemRoot", r"C:\Windows"))
        / "System32"
        / "WindowsPowerShell"
        / "v1.0"
        / "powershell.exe"
    )
    command = [
        str(powershell),
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(HISTORY_BACKUP_SCRIPT),
        "-Action",
        action,
        "-AppRoot",
        str(ROOT),
    ]
    if action == "Upload":
        command.extend(["-Date", history_key])
    elif action == "Download":
        command.extend(["-Month", history_key])
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    with HISTORY_BACKUP_LOCK:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            creationflags=creation_flags,
            check=False,
        )
    output = completed.stdout.strip()
    if completed.returncode != 0:
        detail = completed.stderr.strip() or output or "Git no pudo completar el respaldo."
        raise RuntimeError(detail)
    if not output:
        return {}
    try:
        return json.loads(output.splitlines()[-1])
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Respuesta de respaldo no valida: {output}") from exc


def write_history_backup_status(state, date_key, message):
    DATA_DIR.mkdir(exist_ok=True)
    payload = {
        "state": state,
        "date": date_key,
        "month": date_key[:7] if date_key else "",
        "message": message,
        "at": now_iso(),
    }
    temp_path = HISTORY_BACKUP_STATUS_PATH.with_suffix(".tmp")
    temp_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    temp_path.replace(HISTORY_BACKUP_STATUS_PATH)


def read_history_backup_status():
    if not HISTORY_BACKUP_STATUS_PATH.exists():
        return {"state": "idle", "message": "Todavia no se ha ejecutado un respaldo."}
    try:
        status = json.loads(
            HISTORY_BACKUP_STATUS_PATH.read_text(encoding="utf-8-sig")
        )
        return status if isinstance(status, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {"state": "error", "message": "No se pudo leer el estado del respaldo."}


def queue_history_backup(date_key):
    write_history_backup_status(
        "queued", date_key, "Respaldo preparado. Esperando el envio a GitHub."
    )

    def upload():
        try:
            run_history_backup("Upload", date_key)
        except Exception as exc:
            print(f"No se pudo subir el historial {date_key}: {exc}")

    threading.Thread(target=upload, daemon=True).start()


def history_backup_summary():
    local_months = sorted(
        {path.stem[:7] for path in HISTORY_ARCHIVE_DIR.glob("????-??-??.zip")}, reverse=True
    )
    remote_months = []
    remote_error = ""
    try:
        remote_months = run_history_backup("List").get("months", [])
    except Exception as exc:
        remote_error = str(exc)
    return {
        "local_months": local_months,
        "remote_months": remote_months,
        "status": read_history_backup_status(),
        "remote_error": remote_error,
    }


def update_local_ui_session(session_id, closing=False):
    global LOCAL_UI_MONITOR_ARMED
    now = time.monotonic()
    with LOCAL_UI_SESSION_LOCK:
        LOCAL_UI_MONITOR_ARMED = True
        LOCAL_UI_SESSIONS[session_id] = {
            "last_seen": now,
            "close_after": now + LOCAL_UI_CLOSE_GRACE_SECONDS if closing else None,
        }


def monitor_local_ui(server):
    while True:
        time.sleep(0.5)
        now = time.monotonic()
        with LOCAL_UI_SESSION_LOCK:
            if not LOCAL_UI_MONITOR_ARMED:
                continue
            expired = [
                session_id
                for session_id, session in LOCAL_UI_SESSIONS.items()
                if (
                    session.get("close_after") is not None
                    and now >= session["close_after"]
                )
                or now - session.get("last_seen", now) >= LOCAL_UI_HEARTBEAT_TIMEOUT_SECONDS
            ]
            for session_id in expired:
                LOCAL_UI_SESSIONS.pop(session_id, None)
            should_stop = not LOCAL_UI_SESSIONS
        if should_stop:
            print("La pestaña local se cerro. Apagando Barberia Control.")
            server.shutdown()
            return


class BarberiaHandler(BaseHTTPRequestHandler):
    server_version = "BarberiaDemo/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        print(f"{self.address_string()} - {format % args}")

    def send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        use_gzip = "gzip" in (self.headers.get("Accept-Encoding") or "").lower() and len(body) >= 1024
        if use_gzip:
            body = gzip.compress(body, compresslevel=5)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Vary", "Accept-Encoding")
        if use_gzip:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length == 0:
            return {}
        raw = self.rfile.read(length).decode("utf-8")
        return json.loads(raw)

    def is_local_host_request(self):
        host = (self.headers.get("Host") or "").split(":")[0].strip("[]").lower()
        if host in {"localhost", "127.0.0.1", "::1"}:
            return True
        try:
            ip = ipaddress.ip_address(host)
            return ip.is_private or ip.is_loopback
        except ValueError:
            return False

    def is_local_ui_request(self):
        host = (self.headers.get("Host") or "").split(":")[0].strip("[]").lower()
        return host in {"localhost", "127.0.0.1", "::1"}

    def local_ui_session(self, closing=False):
        if not self.is_local_ui_request():
            self.send_json({"error": "Esta accion solo esta disponible en la computadora principal."}, 403)
            return
        payload = self.read_json_body()
        session_id = str(payload.get("session_id") or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9-]{8,80}", session_id):
            self.send_json({"error": "Sesion local no valida."}, 400)
            return
        update_local_ui_session(session_id, closing=closing)
        self.send_json({"ok": True})

    def send_redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def request_admin_role(self):
        if self.is_local_host_request():
            return "local"
        parsed = urlparse(self.path)
        query_token = (parse_qs(parsed.query).get("token") or [""])[0]
        provided_token = (self.headers.get("X-Admin-Token") or query_token).strip()
        expected_token = admin_online_token()
        if provided_token and hmac.compare_digest(provided_token, expected_token):
            return "online"
        return None

    def admin_device_id(self):
        parsed = urlparse(self.path)
        query_device_id = (parse_qs(parsed.query).get("device_id") or [""])[0]
        return (self.headers.get("X-Device-Id") or query_device_id).strip()

    def authorize_admin_device(self, role):
        device_id = self.admin_device_id()
        if not re.fullmatch(r"[A-Za-z0-9-]{8,80}", device_id):
            self.send_json({"error": "Este dispositivo no tiene una identificacion valida."}, 403)
            return None

        now = time.monotonic()
        with ADMIN_ASSIGNMENT_LOCK:
            expired = [
                saved_id
                for saved_id, session in ADMIN_DEVICE_SESSIONS.items()
                if now - session.get("last_seen", now) >= ADMIN_DEVICE_TIMEOUT_SECONDS
            ]
            for expired_id in expired:
                ADMIN_DEVICE_SESSIONS.pop(expired_id, None)
                ADMIN_ASSIGNMENTS.pop(expired_id, None)

            if device_id not in ADMIN_DEVICE_SESSIONS and len(ADMIN_DEVICE_SESSIONS) >= MAX_ADMIN_DEVICES:
                self.send_json(
                    {
                        "error": (
                            "Ya hay dos dispositivos administrativos conectados. "
                            "Cierra uno o espera un momento para ingresar."
                        )
                    },
                    403,
                )
                return None
            ADMIN_DEVICE_SESSIONS[device_id] = {"role": role, "last_seen": now}
        return device_id

    def require_admin_role(self):
        role = self.request_admin_role()
        if not role:
            self.send_json({"error": "El enlace administrativo online no es valido."}, 403)
            self.close_connection = True
            return None
        if not self.authorize_admin_device(role):
            return None
        return role

    def branch_scope(self, role):
        branch_id = (self.headers.get("X-Branch-Id") or "").strip()
        if branch_id not in {"barberia-1", "barberia-2"}:
            self.send_json({"error": "El acceso administrativo no tiene una barberia asignada."}, 403)
            return None
        device_id = self.admin_device_id()
        with ADMIN_ASSIGNMENT_LOCK:
            assigned_branch = ADMIN_ASSIGNMENTS.get(device_id)
        if assigned_branch != branch_id:
            self.send_json({"error": "Esta sesion no tiene asignada esa barberia."}, 403)
            return None
        return branch_id

    def admin_options(self, role):
        with LOCK:
            db = read_db()
        device_id = self.admin_device_id()
        with ADMIN_ASSIGNMENT_LOCK:
            selected = ADMIN_ASSIGNMENTS.get(device_id)
            connected_devices = len(ADMIN_DEVICE_SESSIONS)
        branches = [
            branch
            for branch in db["branches"]
            if branch.get("active", True)
        ]
        self.send_json(
            {
                "role": role,
                "selected_branch_id": selected,
                "occupied_branch_id": None,
                "connected_devices": connected_devices,
                "max_devices": MAX_ADMIN_DEVICES,
                "branches": branches,
            }
        )

    def select_admin_branch(self, role):
        payload = self.read_json_body()
        branch_id = (payload.get("branch_id") or "").strip()
        with LOCK:
            db = read_db()
            branch = find_by_id(db["branches"], branch_id)
        if not branch or not branch.get("active", True):
            raise ValueError("Selecciona una barberia valida.")

        device_id = self.admin_device_id()
        with ADMIN_ASSIGNMENT_LOCK:
            ADMIN_ASSIGNMENTS[device_id] = branch_id
        publish_data_change()
        self.send_json({"role": role, "branch": branch})

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/admin/options":
            role = self.require_admin_role()
            if role:
                self.admin_options(role)
            return

        if path == "/api/bootstrap":
            role = self.require_admin_role()
            if not role:
                return
            branch_id = self.branch_scope(role)
            if not branch_id:
                return
            with LOCK:
                db = read_db()
                history_sales, history_closures = combined_history(db)
                branch = find_by_id(db["branches"], branch_id)
                if not branch:
                    self.send_json({"error": "Barberia no encontrada."}, 404)
                    return
                self.send_json(
                    {
                        "branches": [branch],
                        "barbers": [
                            barber for barber in db["barbers"] if barber.get("branch_id") == branch_id
                        ],
                        "services": [
                            service for service in db["services"] if service.get("branch_id") == branch_id
                        ],
                        "sales": [
                            sale for sale in history_sales if sale.get("branch_id") == branch_id
                        ],
                        "closures": [
                            closure
                            for closure in history_closures
                            if closure.get("branch_id") == branch_id
                        ],
                        "settings": db["settings"],
                        "capabilities": {
                            "historical_sales": True,
                            "strict_date_filtering": True,
                        },
                    }
                )
            return

        if path == "/api/history-backups":
            role = self.require_admin_role()
            if not role or not self.branch_scope(role):
                return
            self.send_json(history_backup_summary())
            return

        if path == "/api/history-backup-status":
            role = self.require_admin_role()
            if not role or not self.branch_scope(role):
                return
            self.send_json({"status": read_history_backup_status()})
            return

        if path == "/api/events":
            role = self.require_admin_role()
            if role:
                self.serve_events()
            return

        if path.startswith("/uploads/"):
            self.serve_upload(path)
            return

        if path.startswith("/admin") and not self.request_admin_role():
            self.send_json({"error": "El enlace administrativo online no es valido."}, 403)
            return

        if path.startswith("/barbero"):
            self.send_redirect("/admin/barberia-1")
            return

        if path.startswith(("/cita", "/agenda", "/agendar")):
            self.send_redirect("/admin/barberia-1")
            return

        self.serve_public(path)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        try:
            if path == "/api/local-ui/heartbeat":
                self.local_ui_session()
                return
            if path == "/api/local-ui/close":
                self.local_ui_session(closing=True)
                return
            if path == "/api/admin/select-branch":
                role = self.require_admin_role()
                if role:
                    self.select_admin_branch(role)
                return
            if path == "/api/barbers":
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                self.create_barber()
                return
            if re.match(r"^/api/barbers/[^/]+$", path):
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                self.update_barber(path.split("/")[3])
                return
            if re.match(r"^/api/barbers/[^/]+/delete$", path):
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                self.delete_barber(path.split("/")[3])
                return
            if path == "/api/services":
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                self.create_service()
                return
            if re.match(r"^/api/services/[^/]+$", path):
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                self.update_service(path.split("/")[3])
                return
            if re.match(r"^/api/services/[^/]+/delete$", path):
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                self.delete_service(path.split("/")[3])
                return
            if path == "/api/sales":
                role = self.require_admin_role()
                if not role:
                    return
                if not self.branch_scope(role):
                    return
                self.create_sale()
                return
            if re.match(r"^/api/sales/[^/]+$", path):
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                self.update_sale(path.split("/")[3])
                return
            if re.match(r"^/api/sales/[^/]+/delete$", path):
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                self.delete_sale(path.split("/")[3])
                return
            if re.match(r"^/api/sales/[^/]+/status$", path):
                role = self.require_admin_role()
                if not role:
                    return
                if not self.branch_scope(role):
                    return
                sale_id = path.split("/")[3]
                self.update_sale_status(sale_id)
                return
            if path == "/api/day/close":
                role = self.require_admin_role()
                if not role:
                    return
                if not self.branch_scope(role):
                    return
                self.close_day()
                return
            if path == "/api/day/reopen":
                role = self.require_admin_role()
                if not role:
                    return
                if not self.branch_scope(role):
                    return
                self.reopen_day()
                return
            if path == "/api/history-backups/download":
                role = self.require_admin_role()
                if not role or not self.branch_scope(role):
                    return
                payload = self.read_json_body()
                month_key = str(payload.get("month") or "").strip()
                result = run_history_backup("Download", month_key)
                restore_history_proofs(month_key)
                publish_data_change()
                self.send_json(result)
                return
        except json.JSONDecodeError:
            self.send_json({"error": "JSON invalido."}, 400)
            return
        except ValueError as exc:
            self.send_json({"error": str(exc)}, 400)
            return

        self.send_json({"error": "Ruta no encontrada."}, 404)
        self.close_connection = True

    def serve_public(self, request_path):
        public_dir = active_public_dir()
        if not (public_dir / "index.html").exists():
            self.send_frontend_missing()
            return

        safe_path = request_path.lstrip("/") or "index.html"
        target = (public_dir / safe_path).resolve()
        if not str(target).startswith(str(public_dir.resolve())) or not target.exists() or target.is_dir():
            target = public_dir / "index.html"
        self.serve_file(target)

    def send_frontend_missing(self):
        body = (
            "<!doctype html><html lang='es'><meta charset='utf-8'>"
            "<title>Frontend no compilado</title>"
            "<body style='font-family:system-ui;padding:32px'>"
            "<h1>Frontend Angular no compilado</h1>"
            "<p>Ejecuta <strong>Iniciar Barberia.cmd</strong> para instalar dependencias y compilar Angular automaticamente.</p>"
            "</body></html>"
        ).encode("utf-8")
        self.send_response(503)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.close_connection = False

        last_seen = -1
        try:
            while True:
                with EVENT_CONDITION:
                    if last_seen == DATA_VERSION:
                        EVENT_CONDITION.wait(timeout=20)
                    current_version = DATA_VERSION

                if current_version != last_seen:
                    last_seen = current_version
                    payload = json.dumps({"version": current_version, "at": now_iso()})
                    self.wfile.write(f"event: db-changed\ndata: {payload}\n\n".encode("utf-8"))
                else:
                    self.wfile.write(b": heartbeat\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def serve_upload(self, request_path):
        safe_path = request_path.replace("/uploads/", "", 1)
        target = (UPLOAD_DIR / safe_path).resolve()
        if not str(target).startswith(str(UPLOAD_DIR.resolve())) or not target.exists():
            self.send_json({"error": "Archivo no encontrado."}, 404)
            return
        self.serve_file(target)

    def serve_file(self, target):
        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        body = target.read_bytes()
        try:
            target.resolve().relative_to(active_public_dir().resolve())
            is_public_asset = True
        except ValueError:
            is_public_asset = False

        if is_public_asset and re.search(r"-[A-Z0-9]{8,}\.(?:js|css)$", target.name):
            cache_control = "public, max-age=31536000, immutable"
        elif is_public_asset and target.name not in {"index.html", "sw.js"}:
            cache_control = "public, max-age=86400"
        else:
            cache_control = "no-cache" if is_public_asset else "no-store"

        compressible = (
            content_type.startswith("text/")
            or content_type
            in {
                "application/javascript",
                "application/json",
                "application/manifest+json",
                "image/svg+xml",
            }
        )
        use_gzip = (
            compressible
            and len(body) >= 1024
            and "gzip" in (self.headers.get("Accept-Encoding") or "").lower()
        )
        if use_gzip:
            body = gzip.compress(body, compresslevel=6)

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", cache_control)
        self.send_header("Vary", "Accept-Encoding")
        if use_gzip:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def create_barber(self):
        payload = self.read_json_body()
        name = validated_name(payload.get("name"), "barbero")
        branch_id = self.headers.get("X-Branch-Id")
        with LOCK:
            db = read_db()
            if any(
                item.get("branch_id") == branch_id
                and item.get("name", "").casefold() == name.casefold()
                for item in db["barbers"]
            ):
                raise ValueError("Ya existe un barbero con ese nombre.")
            barber = {
                "id": f"barbero-{uuid.uuid4().hex[:8]}",
                "name": name,
                "active": True,
                "branch_id": branch_id,
                "commission_rate": 0.6 if name.casefold() == "omar" else 0.5,
            }
            db["barbers"].append(barber)
            write_db(db)
        publish_data_change()
        self.send_json({"barber": barber}, 201)

    def update_barber(self, barber_id):
        payload = self.read_json_body()
        name = validated_name(payload.get("name"), "barbero")
        with LOCK:
            db = read_db()
            barber = find_by_id(db["barbers"], barber_id)
            branch_id = self.headers.get("X-Branch-Id")
            if not barber or barber.get("branch_id") != branch_id:
                self.send_json({"error": "Barbero no encontrado."}, 404)
                return
            if any(
                item.get("id") != barber_id
                and item.get("branch_id") == branch_id
                and item.get("name", "").casefold() == name.casefold()
                for item in db["barbers"]
            ):
                raise ValueError("Ya existe un barbero con ese nombre.")
            barber["name"] = name
            if name.casefold() == "omar":
                barber["commission_rate"] = 0.6
            write_db(db)
        publish_data_change()
        self.send_json({"barber": barber})

    def delete_barber(self, barber_id):
        self.read_json_body()
        with LOCK:
            db = read_db()
            barber = find_by_id(db["barbers"], barber_id)
            branch_id = self.headers.get("X-Branch-Id")
            if not barber or barber.get("branch_id") != branch_id:
                self.send_json({"error": "Barbero no encontrado."}, 404)
                return
            branch_barbers = [item for item in db["barbers"] if item.get("branch_id") == branch_id]
            if len(branch_barbers) <= 1:
                raise ValueError("Debe quedar al menos un barbero.")
            db["barbers"] = [item for item in db["barbers"] if item.get("id") != barber_id]
            write_db(db)
        publish_data_change()
        self.send_json({"deleted": barber_id})

    def create_service(self):
        payload = self.read_json_body()
        name = validated_name(payload.get("name"), "servicio")
        price = money_to_int(payload.get("price"))
        branch_id = self.headers.get("X-Branch-Id")
        if not price:
            raise ValueError("El precio debe ser mayor a cero.")
        with LOCK:
            db = read_db()
            if any(
                item.get("branch_id") == branch_id
                and item.get("name", "").casefold() == name.casefold()
                for item in db["services"]
            ):
                raise ValueError("Ya existe un servicio con ese nombre.")
            service = {
                "id": f"servicio-{uuid.uuid4().hex[:8]}",
                "name": name,
                "price": price,
                "branch_id": branch_id,
            }
            db["services"].append(service)
            write_db(db)
        publish_data_change()
        self.send_json({"service": service}, 201)

    def update_service(self, service_id):
        payload = self.read_json_body()
        name = validated_name(payload.get("name"), "servicio")
        price = money_to_int(payload.get("price"))
        if not price:
            raise ValueError("El precio debe ser mayor a cero.")
        with LOCK:
            db = read_db()
            service = find_by_id(db["services"], service_id)
            branch_id = self.headers.get("X-Branch-Id")
            if not service or service.get("branch_id") != branch_id:
                self.send_json({"error": "Servicio no encontrado."}, 404)
                return
            if any(
                item.get("id") != service_id
                and item.get("branch_id") == branch_id
                and item.get("name", "").casefold() == name.casefold()
                for item in db["services"]
            ):
                raise ValueError("Ya existe un servicio con ese nombre.")
            service["name"] = name
            service["price"] = price
            write_db(db)
        publish_data_change()
        self.send_json({"service": service})

    def delete_service(self, service_id):
        self.read_json_body()
        with LOCK:
            db = read_db()
            service = find_by_id(db["services"], service_id)
            branch_id = self.headers.get("X-Branch-Id")
            if not service or service.get("branch_id") != branch_id:
                self.send_json({"error": "Servicio no encontrado."}, 404)
                return
            branch_services = [item for item in db["services"] if item.get("branch_id") == branch_id]
            if len(branch_services) <= 1:
                raise ValueError("Debe quedar al menos un servicio.")
            db["services"] = [item for item in db["services"] if item.get("id") != service_id]
            write_db(db)
        publish_data_change()
        self.send_json({"deleted": service_id})

    def create_sale(self):
        payload = self.read_json_body()
        payment_method = payload.get("payment_method")
        if payment_method not in {"cash", "nequi"}:
            raise ValueError("Selecciona efectivo o Nequi.")

        amount = money_to_int(payload.get("amount"))
        if not amount:
            raise ValueError("El valor cobrado debe ser mayor a cero.")

        sale_date = str(payload.get("sale_date") or today_key()).strip()
        try:
            parsed_sale_date = dt.date.fromisoformat(sale_date)
        except ValueError:
            raise ValueError("Selecciona una fecha valida para la venta.")
        if parsed_sale_date > dt.date.today():
            raise ValueError("No puedes facturar una fecha futura.")
        sale_time = str(payload.get("sale_time") or dt.datetime.now().strftime("%H:%M")).strip()
        if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", sale_time):
            raise ValueError("Selecciona una hora valida para la venta.")

        with LOCK:
            db = read_db()
            branch = find_by_id(db["branches"], payload.get("branch_id"))
            if not branch or not branch.get("active", True):
                raise ValueError("Selecciona una barberia valida.")
            if branch["id"] != self.headers.get("X-Branch-Id"):
                raise ValueError("No puedes facturar en una barberia diferente a la de este acceso.")
            if sale_date == today_key() and is_day_closed(db, branch["id"], sale_date):
                raise ValueError("La caja de esta barberia ya esta cerrada.")

            barber = find_by_id(db["barbers"], payload.get("barber_id"))
            if not barber or barber.get("branch_id") != branch["id"]:
                raise ValueError("Barbero no encontrado.")

            custom_service_name = str(payload.get("custom_service_name") or "").strip()
            if custom_service_name:
                service_id = "especial"
                service_name = validated_name(custom_service_name, "servicio especial")
                listed_price = None
                base_amount = amount
                tip_amount = 0
            else:
                service = find_by_id(db["services"], payload.get("service_id"))
                if not service or service.get("branch_id") != branch["id"]:
                    raise ValueError("Servicio no encontrado.")
                service_id = service["id"]
                service_name = service["name"]
                listed_price = int(service["price"])
                tip_amount = max(0, amount - listed_price)
                base_amount = amount - tip_amount

            sale_id = uuid.uuid4().hex[:12]
            proof_url = None
            if payment_method == "nequi":
                proof_url = save_proof_image(payload.get("proof_image"), sale_id)
                if not proof_url:
                    raise ValueError("El comprobante de Nequi es obligatorio.")

            sale = {
                "id": sale_id,
                "created_at": f"{sale_date}T{sale_time}:00",
                "branch_id": branch["id"],
                "branch_name": branch["name"],
                "barber_id": barber["id"],
                "barber_name": barber["name"],
                "service_id": service_id,
                "service_name": service_name,
                "amount": amount,
                "base_amount": base_amount,
                "listed_price": listed_price,
                "tip_amount": tip_amount,
                "payment_method": payment_method,
                "proof_url": proof_url,
                "proof_note": (payload.get("proof_note") or "").strip(),
                "client_name": (payload.get("client_name") or "").strip(),
                "status": "confirmed" if payment_method == "cash" else "pending_review",
            }
            db["sales"].insert(0, sale)
            refresh_closure_summary(db, sale_date, branch)
            write_db(db)
            if find_closure(db, sale_date, branch["id"]) or (
                HISTORY_ARCHIVE_DIR / f"{sale_date}.zip"
            ).exists():
                write_history_archive(db, sale_date)
                queue_history_backup(sale_date)
            publish_data_change()
            self.send_json({"sale": sale}, 201)

    def update_sale(self, sale_id):
        payload = self.read_json_body()
        service_name = validated_name(payload.get("service_name"), "servicio")
        amount = money_to_int(payload.get("amount"))
        if not amount:
            raise ValueError("El valor cobrado debe ser mayor a cero.")
        payment_method = payload.get("payment_method")
        if payment_method not in {"cash", "nequi"}:
            raise ValueError("Selecciona efectivo o Nequi.")

        with LOCK:
            db = read_db()
            sale = materialize_archived_sale(db, sale_id)
            if not sale:
                self.send_json({"error": "Venta no encontrada."}, 404)
                return
            branch_id = self.headers.get("X-Branch-Id")
            if sale.get("branch_id") != branch_id:
                self.send_json({"error": "Esta venta pertenece a otra barberia."}, 403)
                return

            barber = find_by_id(db["barbers"], payload.get("barber_id"))
            if barber and barber.get("branch_id") != branch_id:
                raise ValueError("Selecciona un barbero valido.")
            if not barber and payload.get("barber_id") != sale.get("barber_id"):
                raise ValueError("Selecciona un barbero valido.")
            if payment_method == "nequi" and not sale.get("proof_url"):
                raise ValueError("No puedes cambiar a Nequi una venta que no tiene comprobante.")

            listed_price = sale.get("listed_price")
            if listed_price is None and sale.get("service_id") != "especial":
                service = find_by_id(db["services"], sale.get("service_id"))
                if service and service.get("branch_id") == branch_id:
                    listed_price = int(service["price"])
            try:
                listed_price = int(listed_price) if listed_price is not None else None
            except (TypeError, ValueError):
                listed_price = None
            tip_amount = max(0, amount - listed_price) if listed_price else 0

            sale.update(
                {
                    "barber_id": barber["id"] if barber else sale["barber_id"],
                    "barber_name": barber["name"] if barber else sale["barber_name"],
                    "service_name": service_name,
                    "amount": amount,
                    "base_amount": amount - tip_amount,
                    "listed_price": listed_price,
                    "tip_amount": tip_amount,
                    "payment_method": payment_method,
                    "client_name": str(payload.get("client_name") or "").strip()[:80],
                    "proof_note": str(payload.get("proof_note") or "").strip()[:120],
                    "updated_at": now_iso(),
                }
            )
            if payment_method == "cash" and sale.get("status") == "pending_review":
                sale["status"] = "confirmed"

            date_key = item_day(sale)
            branch = find_by_id(db["branches"], branch_id)
            refresh_closure_summary(db, date_key, branch)
            write_db(db)
            if find_closure(db, date_key, branch_id) or (
                HISTORY_ARCHIVE_DIR / f"{date_key}.zip"
            ).exists():
                write_history_archive(db, date_key)
                queue_history_backup(date_key)
            publish_data_change()
            self.send_json({"sale": sale})

    def delete_sale(self, sale_id):
        with LOCK:
            db = read_db()
            sale = materialize_archived_sale(db, sale_id)
            if not sale:
                self.send_json({"error": "Venta no encontrada."}, 404)
                return
            branch_id = self.headers.get("X-Branch-Id")
            if sale.get("branch_id") != branch_id:
                self.send_json({"error": "Esta venta pertenece a otra barberia."}, 403)
                return

            date_key = item_day(sale)
            db["sales"] = [item for item in db["sales"] if item.get("id") != sale_id]
            branch = find_by_id(db["branches"], branch_id)
            refresh_closure_summary(db, date_key, branch)
            write_db(db)
            if find_closure(db, date_key, branch_id) or (
                HISTORY_ARCHIVE_DIR / f"{date_key}.zip"
            ).exists():
                write_history_archive(db, date_key)
                queue_history_backup(date_key)
            publish_data_change()
            self.send_json({"deleted": sale_id})

    def update_sale_status(self, sale_id):
        payload = self.read_json_body()
        status = payload.get("status")
        if status not in {"confirmed", "pending_review", "rejected", "annulled"}:
            raise ValueError("Estado de venta no permitido.")

        with LOCK:
            db = read_db()
            sale = materialize_archived_sale(db, sale_id)
            if not sale:
                self.send_json({"error": "Venta no encontrada."}, 404)
                return
            branch_id = self.headers.get("X-Branch-Id")
            if sale.get("branch_id") != branch_id:
                self.send_json({"error": "Esta venta pertenece a otra barberia."}, 403)
                return
            sale["status"] = status
            sale["reviewed_at"] = now_iso()
            date_key = item_day(sale)
            branch = find_by_id(db["branches"], branch_id)
            refresh_closure_summary(db, date_key, branch)
            write_db(db)
            if find_closure(db, date_key, branch_id) or (
                HISTORY_ARCHIVE_DIR / f"{date_key}.zip"
            ).exists():
                write_history_archive(db, date_key)
                queue_history_backup(date_key)
            publish_data_change()
            self.send_json({"sale": sale})

    def close_day(self):
        payload = self.read_json_body()
        date_key = today_key()
        counted_cash = parse_counted_cash(payload.get("counted_cash"))

        with LOCK:
            db = read_db()
            branch = find_by_id(db["branches"], payload.get("branch_id"))
            if not branch or not branch.get("active", True):
                raise ValueError("Selecciona una barberia valida.")
            if branch["id"] != self.headers.get("X-Branch-Id"):
                raise ValueError("No puedes cerrar la caja de otra barberia.")
            if is_day_closed(db, branch["id"], date_key):
                raise ValueError("El dia ya se encuentra cerrado.")

            pending = [
                sale
                for sale in db["sales"]
                if item_day(sale) == date_key
                and sale.get("branch_id") == branch["id"]
                and sale.get("status") == "pending_review"
            ]
            if pending:
                raise ValueError("Hay pagos Nequi pendientes. Confirma o rechaza esos comprobantes antes de cerrar.")

            snapshot = closure_snapshot(db, date_key, counted_cash, branch)
            existing = find_closure(db, date_key, branch["id"])
            if existing:
                events = existing.get("events") or infer_closure_events(existing)
                existing.update(snapshot)
                existing.pop("reopened_at", None)
                existing["events"] = events + [closure_event_from_snapshot(snapshot)]
                closure = existing
            else:
                closure = {
                    "id": uuid.uuid4().hex[:12],
                    **snapshot,
                    "events": [closure_event_from_snapshot(snapshot)],
                }
                db["closures"].insert(0, closure)
            write_db(db)
            write_history_archive(db, date_key)
            publish_data_change()
            queue_history_backup(date_key)
            self.send_json({"closure": closure, "backup_date": date_key})

    def reopen_day(self):
        payload = self.read_json_body()
        date_key = today_key()

        with LOCK:
            db = read_db()
            branch = find_by_id(db["branches"], payload.get("branch_id"))
            if not branch or not branch.get("active", True):
                raise ValueError("Selecciona una barberia valida.")
            if branch["id"] != self.headers.get("X-Branch-Id"):
                raise ValueError("No puedes reabrir la caja de otra barberia.")
            closure = find_closure(db, date_key, branch["id"])
            if not closure or closure.get("status") != "closed":
                raise ValueError("El dia de hoy no esta cerrado.")
            events = closure.get("events") or infer_closure_events(closure)
            closure["status"] = "reopened"
            closure["reopened_at"] = now_iso()
            closure["events"] = events + [{"type": "reopened", "at": closure["reopened_at"]}]
            write_db(db)
            write_history_archive(db, date_key)
            publish_data_change()
            queue_history_backup(date_key)
            self.send_json({"closure": closure, "backup_date": date_key})


def main():
    ensure_storage()
    with LOCK:
        existing_db = read_db()
        prepare_existing_history_archives(existing_db)
        pending_history_dates = pending_history_uploads()
    for history_date in pending_history_dates:
        queue_history_backup(history_date)
    port = 8000
    server = ThreadingHTTPServer(("127.0.0.1", port), BarberiaHandler)
    monitor_thread = threading.Thread(target=monitor_local_ui, args=(server,), daemon=True)
    monitor_thread.start()
    print("Barberia Control corriendo.")
    print(f"Administrador local: http://localhost:{port}/admin")
    print("El enlace online se crea con Iniciar Barberia Internet.cmd")
    print("Usa Ctrl+C para detener el servidor.")
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
