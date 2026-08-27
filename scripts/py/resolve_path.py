# Resolve a possibly-relative path against a base directory (resolve_path_against).
# Invoked as: python3 resolve_path.py <base> <path>
import os
import sys

print(os.path.abspath(os.path.join(sys.argv[1], sys.argv[2])))
