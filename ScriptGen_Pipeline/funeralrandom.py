import random, shutil
from pathlib import Path

src = Path("Funeral Pics")              # your input folder
dst = Path("images_randomized")   # output folder
dst.mkdir(exist_ok=True)

exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".tif", ".tiff", ".bmp", ".heic"}
files = [p for p in src.iterdir() if p.is_file() and p.suffix.lower() in exts]

random.shuffle(files)  # new order each run

# If you want the SAME order every time, uncomment:
# random.seed(12345); random.shuffle(files)

for i, p in enumerate(files, 1):
    new_name = f"{i:04d}_{p.name}"   # 0001_filename.jpg, 0002_...
    shutil.copy2(p, dst / new_name)

print(f"Copied {len(files)} files to {dst}")
