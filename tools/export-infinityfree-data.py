from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import sys
import zipfile
from collections import Counter
from pathlib import Path


def load_server(app_root: Path):
    server_path = app_root / "server.py"
    if not server_path.is_file():
        raise RuntimeError(f"No se encontró {server_path}")
    sys.path.insert(0, str(app_root))
    spec = importlib.util.spec_from_file_location("capitan_gold_export_server", server_path)
    if not spec or not spec.loader:
        raise RuntimeError("No se pudo cargar server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def unique_by_id(items: list[dict]) -> list[dict]:
    merged: dict[str, dict] = {}
    without_id: list[dict] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        item_id = str(item.get("id") or "")
        if item_id:
            merged[item_id] = item
        else:
            without_id.append(item)
    return list(merged.values()) + without_id


def copy_proofs(app_root: Path, state: dict, uploads_output: Path) -> tuple[int, list[str]]:
    uploads_output.mkdir(parents=True, exist_ok=True)
    source_uploads = app_root / "data" / "uploads"
    archive_directory = app_root / "data" / "history-archives"
    required = {
        Path(str(sale.get("proof_url"))).name
        for sale in state["sales"]
        if str(sale.get("proof_url") or "").startswith("/uploads/")
    }
    copied = 0
    missing = set(required)
    for filename in sorted(required):
        source = source_uploads / filename
        if source.is_file():
            shutil.copy2(source, uploads_output / filename)
            copied += 1
            missing.discard(filename)

    if missing and archive_directory.is_dir():
        for archive_path in sorted(archive_directory.glob("*.zip"), reverse=True):
            if not missing:
                break
            try:
                with zipfile.ZipFile(archive_path) as archive:
                    names = set(archive.namelist())
                    for filename in list(missing):
                        member = f"uploads/{filename}"
                        if member not in names:
                            continue
                        target = uploads_output / filename
                        target.write_bytes(archive.read(member))
                        copied += 1
                        missing.discard(filename)
            except (OSError, zipfile.BadZipFile):
                continue
    return copied, sorted(missing)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Exporta Capitan Gold a un JSON importable en InfinityFree."
    )
    parser.add_argument("--app-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--uploads-output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()

    app_root = args.app_root.resolve()
    server = load_server(app_root)
    database = server.read_db()
    sales, closures, expenses = server.combined_history(database)
    state = {
        "version": 1,
        "branches": database.get("branches", []),
        "barbers": database.get("barbers", []),
        "services": database.get("services", []),
        "sales": unique_by_id(list(sales)),
        "closures": unique_by_id(list(closures)),
        "expenses": unique_by_id(list(expenses)),
        "settings": database.get("settings", {}),
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(state, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    copied_proofs, missing_proofs = copy_proofs(
        app_root, state, args.uploads_output.resolve()
    )

    branch_sales = Counter(str(item.get("branch_id") or "") for item in state["sales"])
    branch_totals = Counter()
    for sale in state["sales"]:
        if sale.get("status") == "confirmed":
            branch_totals[str(sale.get("branch_id") or "")] += int(
                sale.get("amount", 0) or 0
            )
    report = {
        "source": str(app_root),
        "output": str(args.output.resolve()),
        "counts": {
            "branches": len(state["branches"]),
            "barbers": len(state["barbers"]),
            "services": len(state["services"]),
            "sales": len(state["sales"]),
            "closures": len(state["closures"]),
            "expenses": len(state["expenses"]),
            "proofs_copied": copied_proofs,
            "proofs_missing": len(missing_proofs),
        },
        "sales_by_branch": dict(branch_sales),
        "confirmed_totals_by_branch": dict(branch_totals),
        "missing_proofs": missing_proofs,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False))
    return 0 if not missing_proofs else 2


if __name__ == "__main__":
    raise SystemExit(main())
