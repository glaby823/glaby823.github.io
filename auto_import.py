import os
os.system(f"git add .")
os.system(f"git commit -m {input("Nom du commit: ")}")
os.system(f"git push origin main")
