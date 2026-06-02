import os
import re
import shutil

# Configuration
INPUT_FILE = "docs/ideal_001.md"  # Your big spec file
OUTPUT_DIR = "docs/chapters"      # Where the chunks go
INDEX_FILE = "docs/index.md"      # The new master index

def clean_filename(text):
    """Turns 'Higher Order Functions' into 'higher_order_functions'"""
    s = text.strip().lower()
    s = re.sub(r'[^a-z0-9\s_-]', '', s)
    return re.sub(r'[\s_-]+', '_', s)

def main():
    if not os.path.exists(INPUT_FILE):
        print(f"Error: Could not find {INPUT_FILE}")
        return

    # Clean output directory
    if os.path.exists(OUTPUT_DIR):
        shutil.rmtree(OUTPUT_DIR)
    os.makedirs(OUTPUT_DIR)

    with open(INPUT_FILE, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    # State machine variables
    chapter_num = 0
    section_num = 0
    nav_chapters = []
    
    current_chapter_dir = None
    current_chapter_title = "Preamble"
    current_section_file = None
    
    # We maintain a buffer of lines to write to the current section
    current_buffer = []
    
    # The Master Index content
    index_content = ["# Crisp Language Specification\n\n"]

    # Pre-create the 00_Preamble folder for text before the first Chapter
    current_chapter_dir = os.path.join(OUTPUT_DIR, "00_preamble")
    os.makedirs(current_chapter_dir, exist_ok=True)
    
    # Logic: Setext headers consist of a Text Line followed by a Underline Line
    # We iterate and look ahead.
    
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        next_line = lines[i+1].rstrip() if i + 1 < len(lines) else ""
        
        # Check for Chapter Header (======)
        if len(next_line) > 2 and set(next_line) == {'='}:
            # Flush previous section
            if current_section_file and current_buffer:
                with open(current_section_file, 'w', encoding='utf-8') as f:
                    f.writelines(current_buffer)
                current_buffer = []

            # Start New Chapter
            chapter_num += 1
            section_num = 0
            title = line.strip()
            slug = clean_filename(title)
            
            dirname = f"{chapter_num:02d}_{slug}"
            current_chapter_dir = os.path.join(OUTPUT_DIR, dirname)
            os.makedirs(current_chapter_dir, exist_ok=True)
            
            # Update Index
            index_content.append(f"\n## {title}\n")
            
            # Reset current file (Text between Chapter Header and First Section goes here?)
            # Let's create an intro file for the chapter just in case
            current_section_file = os.path.join(current_chapter_dir, "00_intro.md")
            current_buffer = [f"# {title}\n\n"]
            
            # Add to nav structure
            nav_chapters.append({
                "title": title,
                "sections": [("Introduction", f"chapters/{dirname}/00_intro.md")]
            })
            
            i += 2 # Skip title and underline
            continue

        # Check for Section Header (------)
        elif len(next_line) > 2 and set(next_line) == {'-'}:
            # Flush previous section
            if current_section_file and current_buffer:
                with open(current_section_file, 'w', encoding='utf-8') as f:
                    f.writelines(current_buffer)
                current_buffer = []

            # Start New Section
            section_num += 1
            title = line.strip()
            slug = clean_filename(title)
            
            filename = f"{section_num:02d}_{slug}.md"
            current_section_file = os.path.join(current_chapter_dir, filename)
            
            # Add Link to Master Index
            # Relative path for GitHub Pages/Markdown
            chapter_dirname = os.path.basename(current_chapter_dir)
            rel_path = f"chapters/{chapter_dirname}/{filename}"
            index_content.append(f"- [{title}]({rel_path})\n")
            
            # Add to nav structure
            nav_chapters[-1]["sections"].append((title, rel_path))
            
            # Start buffer with the header (H1 to prevent redundant sidebar nesting)
            current_buffer = [f"# {title}\n\n"]
            
            i += 2 # Skip title and underline
            continue
            
        # Normal Text
        else:
            # If we are in the "Master Index" connecting text mode (between ==== and ----)
            # You mentioned you wanted connecting text in the Master Index.
            # But we also need to put it somewhere in the files if people browse individually.
            # For now, I'll put it in the '00_intro.md' of the chapter AND the buffer.
            
            # Actually, to keep it simple: Everything goes into the current active .md file.
            # If you want text in the Index, you'd have to duplicate it. 
            # For this script, I will generate the files purely.
            
            current_buffer.append(lines[i])
            i += 1

    # Flush final buffer
    if current_section_file and current_buffer:
        with open(current_section_file, 'w', encoding='utf-8') as f:
            f.writelines(current_buffer)

    # Write Master Index
    with open(INDEX_FILE, 'w', encoding='utf-8') as f:
        f.writelines(index_content)

    # Generate mkdocs.yml with navigation
    base_content = ""
    if os.path.exists("mkdocs-base.yml"):
        with open("mkdocs-base.yml", "r", encoding="utf-8") as f:
            base_content = f.read()

    with open("mkdocs.yml", "w", encoding="utf-8") as f:
        f.write(base_content)
        f.write("\nnav:\n")
        f.write('  - "Welcome": "index.md"\n')
        f.write('  - "The Blueprint Philosophy": "crisp-curios.md"\n')
        f.write('  - "Crisp Codebase Reference": "reference.md"\n')
        f.write('  - "Crisp Testing Guide": "tests.md"\n')
        f.write('  - "Call Graph": "call_graph.md"\n')
        f.write('  - "Defmacro Utilities": "defmacro-utils.md"\n')
        f.write('  - "Benchmarks": "benchmarks.md"\n')
        f.write('  - "Criticisms": "criticsms.md"\n')
        f.write('  - "Elevator Pitches": "elevator_pitches.md"\n')
        f.write('  - "Chapters":\n')
        for ch in nav_chapters:
            ch_title = ch["title"].replace('"', '')
            f.write(f'      - "{ch_title}":\n')
            for sec_title, sec_path in ch["sections"]:
                clean_title = sec_title.replace('"', '')
                clean_path = sec_path.replace("\\", "/")
                f.write(f'          - "{clean_title}": "{clean_path}"\n')

    print(f"Done! Split {chapter_num} chapters into {OUTPUT_DIR}")
    print(f"Generated Master Index at {INDEX_FILE}")
    print("Generated mkdocs.yml navigation")

if __name__ == "__main__":
    main()