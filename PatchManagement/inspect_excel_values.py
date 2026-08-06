import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import Counter
path = Path(r'C:/Admin/Ditzler/PatchManagement/Historique/Ditzler_Maintenance_Planung_v2024.xlsx')
assert path.exists(), path
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
    for name, rid in sheets:
        sheet_path = 'xl/' + relmap[rid]
        sheet = ET.fromstring(z.read(sheet_path))
        rows = []
        for row in sheet.findall('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}sheetData/{http://schemas.openxmlformats.org/spreadsheetml/2006/main}row'):
            values = []
            cells = row.findall('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}c')
            last_col = 0
            for c in cells:
                col_ref = c.attrib['r']
                col = ''.join(ch for ch in col_ref if ch.isalpha())
                # convert col letters to index
                idx = 0
                for ch in col:
                    idx = idx * 26 + (ord(ch) - ord('A') + 1)
                while len(values) < idx - 1:
                    values.append('')
                v = c.find('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}v')
                if v is None:
                    values.append('')
                else:
                    if c.attrib.get('t') == 's':
                        values.append(shared[int(v.text)])
                    else:
                        values.append(v.text)
            rows.append(values)
        print('---', name, 'rows', len(rows))
        found = []
        for i, row in enumerate(rows):
            line = '|'.join(str(x) for x in row)
            if any(term in line for term in ['SV-', 'CLT-', 'DC', 'OS-', 'PSG-', 'PB-', 'OS.']):
                found.append((i+1, row))
        print('found asset-like rows', len(found))
        for i, row in found[:30]:
            print(i, row)
        print()
