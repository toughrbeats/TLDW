with open("yml.txt", "r") as infile:
    lines = infile.readlines()

with open("yml.txt", "w") as outfile:
    for line in lines:
        clean_line = line.strip()
        if clean_line:  # skip blank lines
            outfile.write(f"      - {clean_line}\n")
