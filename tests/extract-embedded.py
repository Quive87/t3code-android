"""Writes the scripts embedded in install.sh (quoted heredocs) to a directory for linting."""
import os
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
out = sys.argv[2]
os.makedirs(out, exist_ok=True)
pattern = re.compile(r"cat > \"?([^\s\"]+)\"? <<'(__T3A_[A-Z_]+__)'\n(.*?)\n\2\n", re.S)
for match in pattern.finditer(source):
    target, delimiter, body = match.groups()
    extension = ".js" if body.lstrip().startswith(("//", '"use strict"')) else ".sh"
    path = os.path.join(out, delimiter.strip("_").lower() + extension)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(body + "\n")
    print(f"{path} <- {target}")
