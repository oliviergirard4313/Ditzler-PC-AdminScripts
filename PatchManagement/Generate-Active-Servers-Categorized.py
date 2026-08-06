import csv
from pathlib import Path

INPUT_CSV = Path(r'C:/Admin/Ditzler/PatchManagement/Consolidated_SuperOps_Excel.csv')
OUTPUT_CSV = Path(r'C:/Admin/Ditzler/PatchManagement/Active_Servers_Categorized.csv')

AUTO_CATEGORIES = {
    'GRUPPE 1': 'SV_SW-Std_Manual-Update-G1',
    'GRUPPE 2': 'SV_SW-Std_Manual-Update-G2',
    'GRUPPE 3': 'SV_SW-Std_Manual-Update-G3',
    'GRUPPE 4': 'SV_SW-Std_Manual-Update-G4',
}

NO_UPDATE_OS = ('2012 R2',)
NO_UPDATE_NAMES = ('SV-OS-DC', 'SV-PSG-DC')


def is_active_server(row):
    status = row.get('Status', '').strip().upper()
    platform = row.get('Platform', '').strip().upper()
    os_name = row.get('OS', '').strip().upper()
    if status != 'ONLINE':
        return False
    if 'SERVER' in platform or 'SERVER' in os_name:
        return True
    return False


def recommended_category(row):
    name = row.get('Name', '').strip().upper()
    os_name = row.get('OS', '').strip().upper()
    group = row.get('UpdateGroup', '').strip().upper()

    if any(name.startswith(prefix) for prefix in NO_UPDATE_NAMES) or any(token in os_name for token in NO_UPDATE_OS):
        return 'SV_SW-Std_NO-Update'
    if group in AUTO_CATEGORIES:
        return AUTO_CATEGORIES[group]
    if row.get('Category', '').strip():
        return row['Category'].strip()
    return 'REVIEW'


def main():
    if not INPUT_CSV.exists():
        raise FileNotFoundError(f'Missing input file: {INPUT_CSV}')

    with INPUT_CSV.open(newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        rows = [r for r in reader]

    active = [r for r in rows if is_active_server(r)]
    unique = {}
    for row in active:
        name = row.get('Name', '').strip()
        if not name:
            continue
        unique.setdefault(name, row)

    with OUTPUT_CSV.open('w', newline='', encoding='utf-8') as f:
        fieldnames = [
            'Name', 'OS', 'Platform', 'IPAddress', 'Status', 'UpdateGroup',
            'CurrentCategory', 'RecommendedCategory', 'PatchStatus', 'SuperOpsName', 'AssetId'
        ]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for name in sorted(unique):
            row = unique[name]
            writer.writerow({
                'Name': name,
                'OS': row.get('OS', '').strip(),
                'Platform': row.get('Platform', '').strip(),
                'IPAddress': row.get('IPAddress', '').strip(),
                'Status': row.get('Status', '').strip(),
                'UpdateGroup': row.get('UpdateGroup', '').strip(),
                'CurrentCategory': row.get('Category', '').strip(),
                'RecommendedCategory': recommended_category(row),
                'PatchStatus': row.get('PatchStatus', '').strip(),
                'SuperOpsName': row.get('SuperOpsName', '').strip(),
                'AssetId': row.get('AssetId', '').strip(),
            })

    print(f'Found {len(unique)} unique active server assets.')
    print(f'Wrote {OUTPUT_CSV}')


if __name__ == '__main__':
    main()
