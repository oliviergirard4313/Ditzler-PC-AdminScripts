import csv
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

def read_excel_names(path):
    path = Path(path)
    with zipfile.ZipFile(path, 'r') as z:
        wb = ET.fromstring(z.read('xl/workbook.xml'))
        ns = {'x':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
        sheets = [(s.attrib['name'], s.attrib.get('{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id')) for s in wb.findall('x:sheets/x:sheet', ns)]
        rels = ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))
        relmap = {r.attrib['Id']: r.attrib['Target'] for r in rels.findall('{http://schemas.openxmlformats.org/package/2006/relationships}Relationship')}
        shared = []
        if 'xl/sharedStrings.xml' in z.namelist():
            sroot = ET.fromstring(z.read('xl/sharedStrings.xml'))
            for si in sroot.findall('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}si'):
                shared.append(''.join([t.text or '' for t in si.findall('.//{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t')]))
        assets = []
        for name, rid in sheets:
            sheet = ET.fromstring(z.read('xl/' + relmap[rid]))
            header = None
            for row in sheet.findall('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}sheetData/{http://schemas.openxmlformats.org/spreadsheetml/2006/main}row'):
                cols = {}
                for c in row.findall('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}c'):
                    col = ''.join([ch for ch in c.attrib['r'] if ch.isalpha()])
                    idx = 0
                    for ch in col:
                        idx = idx * 26 + (ord(ch) - ord('A') + 1)
                    v = c.find('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}v')
                    if v is None:
                        cols[idx] = ''
                    elif c.attrib.get('t') == 's':
                        cols[idx] = shared[int(v.text)]
                    else:
                        cols[idx] = v.text
                if not header and cols:
                    header = [cols.get(i, '') for i in range(1, max(cols.keys())+1)]
                    continue
                if not header:
                    continue
                values = [cols.get(i, '') for i in range(1, max(cols.keys())+1)]
                if len(values) >= 5 and values[4]:
                    assets.append({'sheet': name, 'row': row.attrib.get('r'), 'name': values[4].strip(), 'group': values[5].strip() if len(values) >= 6 else '', 'os': values[12].strip() if len(values) >= 13 else '', 'note': values[10].strip() if len(values) >= 11 else ''})
        return assets

def read_superops_csv(path):
    path = Path(path)
    with path.open(newline='', encoding='utf-8') as f:
        reader = csv.reader(f, delimiter=';')
        header = next(reader)
        rows = []
        for row in reader:
            if not row:
                continue
            rows.append({
                'AssetId': row[0].strip('"\ufeff'),
                'Name': row[1].strip('"'),
                'HostName': row[2].strip('"'),
                'Platform': row[3].strip('"'),
                'PlatformFamily': row[4].strip('"'),
                'Status': row[5].strip('"'),
                'PatchStatus': row[6].strip('"'),
                'LastCommunicated': row[7].strip('"'),
                'Categorie_SWPatch': row[8].strip('"') if len(row) > 8 else ''
            })
        return rows

excel = read_excel_names(r'C:/Admin/Ditzler/PatchManagement/Historique/Ditzler_Maintenance_Planung_v2024.xlsx')
superops = read_superops_csv(r'C:/Admin/Ditzler/PatchManagement/SuperOps_PatchInventar_20260806_1017.csv')
so_names = {a['Name']: a for a in superops}
excel_names = [a['name'] for a in excel if a['name']]
unique_excel = sorted(set(excel_names))
print('excel rows', len(excel), 'unique names', len(unique_excel))
print('superops rows', len(superops))

matched = []
unmatched = []
for name in unique_excel:
    if name in so_names:
        matched.append(name)
    else:
        unmatched.append(name)
print('matched', len(matched), 'unmatched', len(unmatched))
print('sample unmatched')
for name in sorted(unmatched)[:50]:
    print(name)
print('sample matched')
for name in sorted(matched)[:50]:
    print(name)
