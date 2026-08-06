import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
path = Path(r'C:/Admin/Ditzler/PatchManagement/Historique/Ditzler_Maintenance_Planung_v2024.xlsx')
print('exists', path.exists())
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
            for c in row.findall('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}c'):
                v = c.find('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}v')
                if v is None:
                    values.append('')
                else:
                    if c.attrib.get('t') == 's':
                        values.append(shared[int(v.text)])
                    else:
                        values.append(v.text)
            rows.append(values)
        print('\nSheet:', name)
        for r in rows[:10]:
            print(r)
