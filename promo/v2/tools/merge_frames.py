"""Crop freshly rendered sequences and merge them into assets/frames (replacing same-named sequences)."""
import json, os, shutil, subprocess, sys, tempfile
src, dst, scale = sys.argv[1], sys.argv[2], sys.argv[3]
tmp = tempfile.mkdtemp()
subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "crop_frames.py"), src, tmp, scale], check=True, stdout=subprocess.DEVNULL)
new = json.load(open(os.path.join(tmp, "manifest.json")))
man = json.load(open(os.path.join(dst, "manifest.json")))
for name, m in new.items():
    shutil.rmtree(os.path.join(dst, name), ignore_errors=True)
    shutil.copytree(os.path.join(tmp, name), os.path.join(dst, name))
    man[name] = m
    print("merged", name, m)
json.dump(man, open(os.path.join(dst, "manifest.json"), "w"), indent=1)
shutil.rmtree(tmp)
