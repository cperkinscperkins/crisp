import os
import re
import shutil

# Configuration
INPUT_FILE = "docs/ideal_001.md"  # Your big spec file
OUTPUT_DIR = "docs/chapters"      # Where the chunks go
INDEX_FILE = "docs/chapters/index.md"      # The new master index

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
    
    in_code_block = False
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        
        # Track code blocks
        if stripped.startswith("```"):
            in_code_block = not in_code_block
            current_buffer.append(line)
            i += 1
            continue
            
        if in_code_block:
            current_buffer.append(line)
            i += 1
            continue
            
        # Check for Chapter Header (starts with "# " or "## ")
        is_chapter = False
        prefix_len = 0
        if stripped.startswith("# ") and not stripped.startswith("##"):
            is_chapter = True
            prefix_len = 2
        elif stripped.startswith("## "):
            is_chapter = True
            prefix_len = 3
            
        if is_chapter:
            # Flush previous section
            if current_section_file and current_buffer:
                with open(current_section_file, 'w', encoding='utf-8') as f:
                    f.writelines(current_buffer)
                current_buffer = []

            # Start New Chapter
            chapter_num += 1
            section_num = 0
            title = stripped[prefix_len:].strip()
            slug = clean_filename(title)
            
            dirname = f"{chapter_num:02d}_{slug}"
            current_chapter_dir = os.path.join(OUTPUT_DIR, dirname)
            os.makedirs(current_chapter_dir, exist_ok=True)
            
            # Update Index
            index_content.append(f"\n## {title}\n")
            
            # Reset current file
            current_section_file = os.path.join(current_chapter_dir, "00_intro.md")
            current_buffer = [f"# {title}\n\n"]
            
            # Add to nav structure
            nav_chapters.append({
                "title": title,
                "sections": [("Introduction", f"chapters/{dirname}/00_intro.md")]
            })
            
            i += 1
            continue

        # Check for Section Header (starts with "### ")
        elif stripped.startswith("### "):
            # Flush previous section
            if current_section_file and current_buffer:
                with open(current_section_file, 'w', encoding='utf-8') as f:
                    f.writelines(current_buffer)
                current_buffer = []

            # Start New Section
            section_num += 1
            title = stripped[4:].strip()
            slug = clean_filename(title)
            
            filename = f"{section_num:02d}_{slug}.md"
            current_section_file = os.path.join(current_chapter_dir, filename)
            
            # Add Link to Master Index
            # Relative path from docs/chapters/index.md: 01_intro/01_file.md
            chapter_dirname = os.path.basename(current_chapter_dir)
            rel_path = f"{chapter_dirname}/{filename}"
            index_content.append(f"- [{title}]({rel_path})\n")
            
            # Add to nav structure
            nav_chapters[-1]["sections"].append((title, rel_path))
            
            # Start buffer with the header (H1 to prevent redundant sidebar nesting)
            current_buffer = [f"# {title}\n\n"]
            
            i += 1
            continue
            
        # Normal Text
        else:
            current_buffer.append(lines[i])
            i += 1

    # Flush final buffer
    if current_section_file and current_buffer:
        with open(current_section_file, 'w', encoding='utf-8') as f:
            f.writelines(current_buffer)

    # Write Master Index
    with open(INDEX_FILE, 'w', encoding='utf-8') as f:
        f.writelines(index_content)

    print(f"Done! Split {chapter_num} chapters into {OUTPUT_DIR}")
    print(f"Generated Master Index at {INDEX_FILE}")

if __name__ == "__main__":
    main()