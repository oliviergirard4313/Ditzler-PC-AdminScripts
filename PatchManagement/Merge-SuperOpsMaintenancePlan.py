import csv
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

EXCEL_PATH = Path(r'C:/Admin/Ditzler/PatchManagement/Historique/Ditzler_Maintenance_Planung_v2024.xlsx')
CSV_PATH = Path(r'C:/Admin/Ditzler/PatchManagement/SuperOps_PatchInventar_20260806_1017.csv')
OUTPUT_PATH = Path(r'C:/Admin/Ditzler/PatchManagement/Consolidated_SuperOps_Excel.csv')
UNMATCHED_EXCEL_PATH = Path(r'C:/Admin/Ditzler/PatchManagement/Unmatched_Excel_Names.txt')
UNMATCHED_SUPEROPS_PATH = Path(r'C:/Admin/Ditzler/PatchManagement/Unmatched_SuperOps_Names.txt')

NS = {'x': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}


def get_shared_strings(z):
    try:
        with z.open('xl/sharedStrings.xml') as f:
            tree = ET.parse(f)
    except KeyError:
        return []
    shared = []
    for si in tree.findall('.//x:si', NS):
        text = ''.join(t.text or '' for t in si.findall('.//x:t', NS))
        shared.append(text)
    return shared


def get_sheet_paths(z):
    with z.open('xl/workbook.xml') as f:
        tree = ET.parse(f)
    rels = {}
    with z.open('xl/_rels/workbook.xml.rels') as f:
        rel_tree = ET.parse(f)
    for rel in rel_tree.findall('.//rel:Relationship', {'rel': 'http://schemas.openxmlformats.org/package/2006/relationships'}):
        rels[rel.attrib['Id']] = rel.attrib['Target']
    sheets = []
    for sheet in tree.findall('.//x:sheet', NS):
        rid = sheet.attrib.get('{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id')
        target = rels.get(rid)
        if target:
            sheets.append((sheet.attrib['name'], Path('xl') / target))
    return sheets


def cell_value(cell, shared_strings):
    v = cell.find('x:v', NS)
    if v is None or v.text is None:
        return ''
    if cell.attrib.get('t') == 's':
        idx = int(v.text)
        return shared_strings[idx]
    return v.text


def col_index(col):
    index = 0
    for ch in col:
        if 'A' <= ch <= 'Z':
            index = index * 26 + (ord(ch) - ord('A') + 1)
    return index - 1


def parse_rows(sheet_xml, shared_strings):
    rows = []
    for row in sheet_xml.findall('.//x:sheetData/x:row', NS):
        line = []
        cells = sorted(row.findall('x:c', NS), key=lambda c: col_index(''.join(ch for ch in c.attrib['r'] if ch.isalpha())))
        current = 0
        for cell in cells:
            col = ''.join(ch for ch in cell.attrib['r'] if ch.isalpha())
            idx = col_index(col)
            while current < idx:
                line.append('')
                current += 1
            line.append(cell_value(cell, shared_strings).strip())
            current += 1
        rows.append(line)
    return rows


def read_excel_assets(path):
    with zipfile.ZipFile(path, 'r') as z:
        shared_strings = get_shared_strings(z)
        sheets = get_sheet_paths(z)
        assets = []
        for sheet_name, sheet_path in sheets:
            with z.open(sheet_path.as_posix()) as f:
                sheet_xml = ET.parse(f)
            rows = parse_rows(sheet_xml, shared_strings)
            header_row = None
            for idx, row in enumerate(rows):
                normalized = ' '.join(cell.replace('\n', ' ').strip() for cell in row if cell)
                if 'Name' in normalized and 'Server oder Gerät' in normalized:
                    header_row = idx
                    break
                if 'Intervall' in normalized and 'Wartungstyp' in normalized and 'Name' in normalized:
                    header_row = idx
                    break
            if header_row is None:
                continue
            for data_row in rows[header_row + 1:]:
                if len(data_row) < 5:
                    continue
                name = data_row[4].strip()
                if not name or name.lower() in ('name', 'server oder gerät'):
                    continue
                assets.append({
                    'Sheet': sheet_name,
                    'Name': name,
                    'UpdateGroup': data_row[5].strip() if len(data_row) > 5 else '',
                    'BusinessImpact': data_row[6].strip() if len(data_row) > 6 else '',
                    'IsGrundstoff': data_row[7].strip() if len(data_row) > 7 else '',
                    'OS': data_row[12].strip() if len(data_row) > 12 else '',
                    'IPAddress': data_row[13].strip() if len(data_row) > 13 else '',
                    'UpdateDetails': data_row[14].strip() if len(data_row) > 14 else '',
                })
        return assets


def read_superops_csv(path):
    with path.open(newline='', encoding='utf-8-sig') as f:
        reader = csv.reader(f, delimiter=';', quotechar='"')
        rows = list(reader)
    if not rows:
        return []
    header = rows[0]
    assets = []
    for row in rows[1:]:
        if len(row) < 2:
            continue
        fields = [field.strip() for field in row]
        assets.append({
            'AssetId': fields[0].strip('"\ufeff'),
            'Name': fields[1].strip('"'),
            'HostName': fields[2].strip('"') if len(fields) > 2 else '',
            'Platform': fields[3].strip('"') if len(fields) > 3 else '',
            'PlatformFamily': fields[4].strip('"') if len(fields) > 4 else '',
            'Status': fields[5].strip('"') if len(fields) > 5 else '',
            'PatchStatus': fields[6].strip('"') if len(fields) > 6 else '',
            'LastCommunicated': fields[7].strip('"') if len(fields) > 7 else '',
            'Category': fields[8].strip('"') if len(fields) > 8 else '',
        })
    return assets


def consolidate(excel_assets, superops_assets):
    lookup = {asset['Name'].upper(): asset for asset in superops_assets if asset['Name']}
    merged = []
    for asset in excel_assets:
        so = lookup.get(asset['Name'].upper())
        merged.append({
            'Sheet': asset['Sheet'],
            'Name': asset['Name'],
            'UpdateGroup': asset['UpdateGroup'],
            'OS': asset['OS'],
            'IPAddress': asset['IPAddress'],
            'UpdateDetails': asset['UpdateDetails'],
            'SuperOpsName': so['Name'] if so else '',
            'AssetId': so['AssetId'] if so else '',
            'HostName': so['HostName'] if so else '',
            'Platform': so['Platform'] if so else '',
            'PlatformFamily': so['PlatformFamily'] if so else '',
            'Status': so['Status'] if so else '',
            'PatchStatus': so['PatchStatus'] if so else '',
            'LastCommunicated': so['LastCommunicated'] if so else '',
            'Category': so['Category'] if so else '',
            'Matched': 'Yes' if so else 'No',
        })
    return merged


def main():
    excel_assets = read_excel_assets(EXCEL_PATH)
    superops_assets = read_superops_csv(CSV_PATH)
    merged = consolidate(excel_assets, superops_assets)
    with OUTPUT_PATH.open('w', newline='', encoding='utf-8') as f:
        fieldnames = ['Sheet', 'Name', 'UpdateGroup', 'OS', 'IPAddress', 'UpdateDetails', 'SuperOpsName', 'AssetId', 'HostName', 'Platform', 'PlatformFamily', 'Status', 'PatchStatus', 'LastCommunicated', 'Category', 'Matched']
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(merged)

    unmatched_excel = [row['Name'] for row in merged if row['Matched'] == 'No']
    unmatched_superops = [asset['Name'] for asset in superops_assets if asset['Name'].upper() not in {row['Name'].upper() for row in excel_assets}]
    with UNMATCHED_EXCEL_PATH.open('w', encoding='utf-8') as f:
        f.write('\n'.join(unmatched_excel))
    with UNMATCHED_SUPEROPS_PATH.open('w', encoding='utf-8') as f:
        f.write('\n'.join(sorted(set(unmatched_superops))))

    print(f'Excel assets: {len(excel_assets)}')
    print(f'SuperOps assets: {len(superops_assets)}')
    print(f'Matched: {sum(1 for row in merged if row["Matched"] == "Yes")}')
    print(f'Unmatched Excel rows: {len(unmatched_excel)}')
    print(f'Unmatched SuperOps assets: {len(unmatched_superops)}')
    print(f'Wrote {OUTPUT_PATH}')
    print(f'Wrote {UNMATCHED_EXCEL_PATH}')
    print(f'Wrote {UNMATCHED_SUPEROPS_PATH}')


if __name__ == '__main__':
    main()
