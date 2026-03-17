import os

def tree(dir_path, indent=""):
    for item in sorted(os.listdir(dir_path)):
        full_path = os.path.join(dir_path, item)
        if os.path.isdir(full_path):
            print(f"{indent}📁 {item}/")
            tree(full_path, indent + "    ")
        else:
            print(f"{indent}📄 {item}")

tree(".")