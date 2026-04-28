
import sys

def check_braces(file_path):
    with open(file_path, 'r') as f:
        lines = f.readlines()
    
    depth = 0
    for i, line in enumerate(lines):
        for char in line:
            if char == '{':
                depth += 1
            elif char == '}':
                depth -= 1
        print(f"{i+1:3}: (Depth {depth}) {line.strip()}")
    
    if depth != 0:
        print(f"ERROR: Final depth is {depth}")
    else:
        print("Braces are balanced.")

check_braces(sys.argv[1])
