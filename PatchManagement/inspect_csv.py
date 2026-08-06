import csv
from pathlib import Path
path = Path(r'C:/Admin/Ditzler/PatchManagement/SuperOps_PatchInventar_20260806_1017.csv')
print('exists', path.exists())
with path.open(newline='', encoding='utf-8') as f:
    reader = csv.reader(f)
    rows = [row for _, row in zip(range(20), reader)]
    for i, row in enumerate(rows):
        print(i, row)
