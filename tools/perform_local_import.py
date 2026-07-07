from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List


ROOT = Path(__file__).resolve().parent.parent
API_DIR = ROOT / 'infinityfree' / 'htdocs' / 'api'
MIGRATION = API_DIR / 'migration-data.json'
LOCAL_STATE = API_DIR / 'local_cg_state.json'
REPORT = API_DIR / 'local_import_report.json'


def load_json(path: Path) -> Any:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding='utf-8'))


def default_state() -> Dict[str, Any]:
    return {
        'branches': [
            {'id': 'barberia-1', 'name': 'Barbería de Arriba', 'active': True},
            {'id': 'barberia-2', 'name': 'Barbería de Abajo', 'active': True},
        ],
        'barbers': [
            {'id': 'jose', 'name': 'Jose', 'active': True, 'branch_id': 'barberia-1', 'commission_rate': 0.5},
            {'id': 'luis', 'name': 'Luís', 'active': True, 'branch_id': 'barberia-1', 'commission_rate': 0.5},
            {'id': 'samuel', 'name': 'Samuel', 'active': True, 'branch_id': 'barberia-1', 'commission_rate': 0.5},
            {'id': 'omar', 'name': 'Omar', 'active': True, 'branch_id': 'barberia-2', 'commission_rate': 0.6},
            {'id': 'randy', 'name': 'Randy', 'active': True, 'branch_id': 'barberia-2', 'commission_rate': 0.5},
            {'id': 'juan', 'name': 'Juan', 'active': True, 'branch_id': 'barberia-2', 'commission_rate': 0.5},
        ],
        'services': [
            {'id': 'tijeras', 'name': 'Corte con tijeras', 'price': 30000, 'branch_id': 'barberia-1'},
            {'id': 'basico', 'name': 'Corte básico', 'price': 25000, 'branch_id': 'barberia-1'},
            {'id': 'barba', 'name': 'Barba', 'price': 15000, 'branch_id': 'barberia-1'},
            {'id': 'combo', 'name': 'Corte y barba', 'price': 40000, 'branch_id': 'barberia-1'},
            {'id': 'combo-tijeras', 'name': 'Corte con tijeras y barba', 'price': 40000, 'branch_id': 'barberia-1'},
            {'id': 'tijeras-b2', 'name': 'Corte con tijeras', 'price': 30000, 'branch_id': 'barberia-2'},
            {'id': 'basico-b2', 'name': 'Corte básico', 'price': 25000, 'branch_id': 'barberia-2'},
            {'id': 'barba-b2', 'name': 'Barba', 'price': 15000, 'branch_id': 'barberia-2'},
            {'id': 'combo-b2', 'name': 'Corte y barba', 'price': 40000, 'branch_id': 'barberia-2'},
            {'id': 'combo-tijeras-b2', 'name': 'Corte con tijeras y barba', 'price': 40000, 'branch_id': 'barberia-2'},
        ],
        'sales': [],
        'closures': [],
        'expenses': [],
        'settings': {
            'commission_rate': 0.5,
            'currency': 'COP',
            'business_whatsapp_country_code': '57',
            'catalog_version': 3,
        },
    }


def merge_by_id(current: List[Dict[str, Any]], incoming: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    merged = {str(item['id']): item for item in current if isinstance(item, dict) and 'id' in item}
    for item in incoming:
        if isinstance(item, dict) and 'id' in item:
            merged[str(item['id'])] = item
    return list(merged.values())


def normalize_state(state: Dict[str, Any]) -> Dict[str, Any]:
    defaults = default_state()
    for key in ['branches', 'barbers', 'services', 'sales', 'closures', 'expenses']:
        if not isinstance(state.get(key), list):
            state[key] = defaults[key]
    settings = state.get('settings') if isinstance(state.get('settings'), dict) else {}
    merged_settings = dict(defaults['settings'])
    merged_settings.update(settings)
    state['settings'] = merged_settings

    for sale in state['sales']:
        if sale.get('sale_kind') not in {'service', 'product'}:
            sale['sale_kind'] = 'product' if not sale.get('barber_id') else 'service'
        if sale['sale_kind'] == 'product':
            sale['barber_id'] = None
            sale['barber_name'] = sale.get('barber_name') or 'Barbería · Nevera'
            sale['service_id'] = sale.get('service_id') or 'nevera'
            sale['base_amount'] = int(sale.get('amount', 0) or 0)
            sale['listed_price'] = sale.get('listed_price') if sale.get('listed_price') is not None else None
            sale['tip_amount'] = int(sale.get('tip_amount', 0) or 0)

    return state


def main():
    incoming = load_json(MIGRATION)
    if incoming is None:
        print('No se encontró migration-data.json en', MIGRATION)
        return 1

    state = load_json(LOCAL_STATE) or default_state()

    for key in ['branches', 'barbers', 'services', 'sales', 'closures', 'expenses']:
        state[key] = merge_by_id(state.get(key, []), incoming.get(key, []))

    state['settings'] = dict(state.get('settings', {}))
    state['settings'].update(incoming.get('settings', {}))

    state = normalize_state(state)

    API_DIR.mkdir(parents=True, exist_ok=True)
    LOCAL_STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding='utf-8')

    report = {
        'ok': True,
        'counts': {
            'branches': len(state['branches']),
            'barbers': len(state['barbers']),
            'services': len(state['services']),
            'sales': len(state['sales']),
            'closures': len(state['closures']),
            'expenses': len(state['expenses']),
        }
    }
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
