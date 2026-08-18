"""Calcula los sha256 de los <script> inline de index.html para el CSP.

El HTML llega por stdin a propósito: en Git Bash sobre Windows el intérprete de
Python es nativo y no entiende las rutas estilo /c/... que produce el shell.

    python deploy/csp-hashes.py < index.html
    -> 'self' 'sha256-...' 'sha256-...'
"""
import base64
import hashlib
import re
import sys

html = sys.stdin.buffer.read().decode("utf-8")

# Los <script src="..."> los cubre 'self'; aquí solo van los inline.
inline = re.finditer(r"<script(?![^>]*\ssrc=)[^>]*>(.*?)</script>", html, re.S)

sources = ["'self'"]
for match in inline:
    digest = hashlib.sha256(match.group(1).encode("utf-8")).digest()
    sources.append("'sha256-" + base64.b64encode(digest).decode() + "'")

print(" ".join(sources))
