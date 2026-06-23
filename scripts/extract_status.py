import re
import csv
from pathlib import Path

def main():
    md_file = Path('docs/ideal_001.md')
    csv_file = Path('put_temp_files_here/ideal_001_status.csv')
    
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

    with open(csv_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=['Name', 'index', 'status'])
        writer.writeheader()
        writer.writerows(rows)
        
    print(f"Successfully extracted {len(rows)} headers to {csv_file}")

if __name__ == '__main__':
    main()
