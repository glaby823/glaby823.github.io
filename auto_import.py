import os

commit=input("Nom du commit: ")

os.system(f"git add .")
os.system(f"git commit -m {commit}")
os.system(f"git push origin main")

for i in range(10):
    print("")

print("Fini")
