from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import base64
import datetime as dt
import json
import mimetypes
import re
import socket
import threading
import uuid
import ipaddress
import hmac
import secrets


ROOT = Path(__file__).resolve().parent
ANGULAR_PUBLIC_DIR = ROOT / "frontend" / "dist" / "frontend" / "browser"
DATA_DIR = ROOT / "data"
UPLOAD_DIR = DATA_DIR / "uploads"
DB_PATH = DATA_DIR / "db.json"
MAX_IMAGE_BYTES = 8 * 1024 * 1024

LOCK = threading.Lock()
EVENT_CONDITION = threading.Condition()
DATA_VERSION = 0
ADMIN_ASSIGNMENTS = {"local": None, "online": None}
ADMIN_ASSIGNMENT_LOCK = threading.Lock()

DEFAULT_DB = {
    "branches": [
        {"id": "barberia-1", "name": "Barbería 1", "active": True},
        {"id": "barberia-2", "name": "Barbería 2", "active": True},
    ],
    "barbers": [
        {"id": "carlos", "name": "Carlos", "active": True},
        {"id": "andres", "name": "Andres", "active": True},
        {"id": "miguel", "name": "Miguel", "active": True},
    ],
    "services": [
        {"id": "corte", "name": "Corte", "price": 20000},
        {"id": "barba", "name": "Barba", "price": 12000},
        {"id": "combo", "name": "Corte + barba", "price": 30000},
        {"id": "cejas", "name": "Cejas", "price": 7000},
    ],
    "sales": [],
    "closures": [],
    "settings": {
        "commission_rate": 0.5,
        "currency": "COP",
        "business_whatsapp_country_code": "57",
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
    if "settings" not in data:
        data["settings"] = DEFAULT_DB["settings"]
        changed = True
    else:
        for key, value in DEFAULT_DB["settings"].items():
            if key not in data["settings"]:
                data["settings"][key] = value
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
        barber_totals.append(
            {
                "barber_id": barber["id"],
                "barber_name": barber["name"],
                "sales_count": len(barber_sales),
                "total": total,
                "commission": int(round(total * commission_rate)),
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


class BarberiaHandler(BaseHTTPRequestHandler):
    server_version = "BarberiaDemo/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        print(f"{self.address_string()} - {format % args}")

    def send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
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

    def require_admin_role(self):
        role = self.request_admin_role()
        if role:
            return role
        self.send_json({"error": "El enlace administrativo online no es valido."}, 403)
        self.close_connection = True
        return None

    def branch_scope(self, role):
        branch_id = (self.headers.get("X-Branch-Id") or "").strip()
        if branch_id not in {"barberia-1", "barberia-2"}:
            self.send_json({"error": "El acceso administrativo no tiene una barberia asignada."}, 403)
            return None
        with ADMIN_ASSIGNMENT_LOCK:
            assigned_branch = ADMIN_ASSIGNMENTS.get(role)
        if assigned_branch != branch_id:
            self.send_json({"error": "Esta sesion no tiene asignada esa barberia."}, 403)
            return None
        return branch_id

    def admin_options(self, role):
        with LOCK:
            db = read_db()
        other_role = "online" if role == "local" else "local"
        with ADMIN_ASSIGNMENT_LOCK:
            selected = ADMIN_ASSIGNMENTS.get(role)
            occupied = ADMIN_ASSIGNMENTS.get(other_role)
        branches = [
            branch
            for branch in db["branches"]
            if branch.get("active", True) and branch.get("id") != occupied
        ]
        self.send_json(
            {
                "role": role,
                "selected_branch_id": selected,
                "occupied_branch_id": occupied,
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

        other_role = "online" if role == "local" else "local"
        with ADMIN_ASSIGNMENT_LOCK:
            if ADMIN_ASSIGNMENTS.get(other_role) == branch_id:
                raise ValueError("La otra administracion ya esta usando esa barberia.")
            ADMIN_ASSIGNMENTS[role] = branch_id
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
                        "sales": [sale for sale in db["sales"] if sale.get("branch_id") == branch_id],
                        "closures": [
                            closure for closure in db["closures"] if closure.get("branch_id") == branch_id
                        ],
                        "settings": db["settings"],
                    }
                )
            return

        if path == "/api/events":
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
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
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

        with LOCK:
            db = read_db()
            branch = find_by_id(db["branches"], payload.get("branch_id"))
            if not branch or not branch.get("active", True):
                raise ValueError("Selecciona una barberia valida.")
            if branch["id"] != self.headers.get("X-Branch-Id"):
                raise ValueError("No puedes facturar en una barberia diferente a la de este acceso.")
            if is_day_closed(db, branch["id"]):
                raise ValueError("La caja de esta barberia ya esta cerrada.")

            barber = find_by_id(db["barbers"], payload.get("barber_id"))
            if not barber or barber.get("branch_id") != branch["id"]:
                raise ValueError("Barbero no encontrado.")

            custom_service_name = str(payload.get("custom_service_name") or "").strip()
            if custom_service_name:
                service_id = "especial"
                service_name = validated_name(custom_service_name, "servicio especial")
            else:
                service = find_by_id(db["services"], payload.get("service_id"))
                if not service or service.get("branch_id") != branch["id"]:
                    raise ValueError("Servicio no encontrado.")
                service_id = service["id"]
                service_name = service["name"]

            sale_id = uuid.uuid4().hex[:12]
            proof_url = None
            if payment_method == "nequi":
                proof_url = save_proof_image(payload.get("proof_image"), sale_id)
                if not proof_url:
                    raise ValueError("El comprobante de Nequi es obligatorio.")

            sale = {
                "id": sale_id,
                "created_at": now_iso(),
                "branch_id": branch["id"],
                "branch_name": branch["name"],
                "barber_id": barber["id"],
                "barber_name": barber["name"],
                "service_id": service_id,
                "service_name": service_name,
                "amount": amount,
                "payment_method": payment_method,
                "proof_url": proof_url,
                "proof_note": (payload.get("proof_note") or "").strip(),
                "client_name": (payload.get("client_name") or "").strip(),
                "status": "confirmed" if payment_method == "cash" else "pending_review",
            }
            db["sales"].insert(0, sale)
            write_db(db)
            publish_data_change()
            self.send_json({"sale": sale}, 201)

    def update_sale_status(self, sale_id):
        payload = self.read_json_body()
        status = payload.get("status")
        if status not in {"confirmed", "pending_review", "rejected", "annulled"}:
            raise ValueError("Estado de venta no permitido.")

        with LOCK:
            db = read_db()
            sale = find_by_id(db["sales"], sale_id)
            if not sale:
                self.send_json({"error": "Venta no encontrada."}, 404)
                return
            if sale.get("branch_id") != self.headers.get("X-Branch-Id"):
                self.send_json({"error": "Esta venta pertenece a otra barberia."}, 403)
                return
            sale["status"] = status
            sale["reviewed_at"] = now_iso()
            write_db(db)
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
            publish_data_change()
            self.send_json({"closure": closure})

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
            publish_data_change()
            self.send_json({"closure": closure})


def main():
    ensure_storage()
    port = 8000
    server = ThreadingHTTPServer(("127.0.0.1", port), BarberiaHandler)
    print("Barberia Control corriendo.")
    print(f"Administrador local: http://localhost:{port}/admin")
    print("El enlace online se crea con Iniciar Barberia Internet.cmd")
    print("Usa Ctrl+C para detener el servidor.")
    server.serve_forever()


if __name__ == "__main__":
    main()
