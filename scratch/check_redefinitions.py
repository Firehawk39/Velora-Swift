
import os
import re

def check_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    struct_name = None
    properties = {}
    errors = []

    for i, line in enumerate(lines):
        # Match struct/class/enum name
        struct_match = re.search(r'(struct|class|enum|actor)\s+(\w+)', line)
        if struct_match:
            new_struct = struct_match.group(2)
            # Reset properties when entering a new struct
            properties = {}
            struct_name = new_struct
            continue

        # Match @State, @AppStorage, @Binding, @EnvironmentObject, @Environment, @ObservedObject, @StateObject
        # Also match plain var/let
        prop_match = re.search(r'@(\w+).*?(var|let)\s+(\w+)', line)
        if not prop_match:
            prop_match = re.search(r'^\s*(var|let)\s+(\w+)', line)
        
        if prop_match:
            prop_name = prop_match.group(prop_match.lastindex)
            if prop_name in properties:
                errors.append(f"L{i+1}: Redefinition of '{prop_name}' in {struct_name}")
            else:
                properties[prop_name] = i + 1

    return errors

def main():
    root_dir = r"c:\Users\Jolly\OneDrive\Desktop\Velora AI Studio + Antigravity\Sources"
    all_errors = []
    for root, dirs, files in os.walk(root_dir):
        for file in files:
            if file.endswith(".swift"):
                path = os.path.join(root, file)
                file_errors = check_file(path)
                if file_errors:
                    all_errors.append(f"File: {path}\n" + "\n".join(file_errors))

    if all_errors:
        print("\n\n".join(all_errors))
    else:
        print("No redefinitions found.")

if __name__ == "__main__":
    main()
