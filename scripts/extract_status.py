# python .\scripts\extract_status.py

import re
import csv
from pathlib import Path

def main():
    md_file = Path('docs/ideal_001.md')
    csv_file = Path('docs/ideal_001_status.csv')
    
    with open(md_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    rows = []
    # Match markdown headers ending with the specified emojis
    header_pattern = re.compile(r'^#+\s+(.*?)\s*(📝|⚠️|✅)\s*$')
    
    emoji_map = {
        '📝': 'not implemented',
        '⚠️': 'partially implemented',
        '✅': 'implemented'
    }

    index = 1
    for line in lines:
        match = header_pattern.match(line)
        if match:
            name = match.group(1).strip()
            emoji = match.group(2)
            status = emoji_map[emoji]
            rows.append({'Name': name, 'index': index, 'status': status})
            index += 1

    total = len(rows)
    implemented = sum(1 for r in rows if r['status'] == 'implemented')
    not_implemented = sum(1 for r in rows if r['status'] == 'not implemented')
    partially = sum(1 for r in rows if r['status'] == 'partially implemented')

    if total > 0:
        impl_pct = (implemented / total) * 100
        not_impl_pct = (not_implemented / total) * 100
        part_pct = (partially / total) * 100
    else:
        impl_pct = not_impl_pct = part_pct = 0.0

    summary_row = {
        'Name': f'SUMMARY (Total: {total})',
        'index': f'Impl: {implemented} ({impl_pct:.1f}%)',
        'status': f'Not Impl: {not_implemented} ({not_impl_pct:.1f}%) | Part: {partially} ({part_pct:.1f}%)'
    }
    rows.append(summary_row)

    with open(csv_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=['Name', 'index', 'status'])
        writer.writeheader()
        writer.writerows(rows)
        
    print(f"Successfully extracted {total} headers to {csv_file}")
    print(f"Summary: Implemented {impl_pct:.1f}%, Not Implemented {not_impl_pct:.1f}%, Partially Implemented {part_pct:.1f}%")

if __name__ == '__main__':
    main()
