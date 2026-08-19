"""Calcula los sha256 de los <script> inline de un HTML para el CSP.

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

# El navegador hashea el texto del script tal y como quedó en el DOM, y el
# tokenizador HTML convierte todo \r\n y \r suelto en \n. Sin esta
# normalización, un archivo con finales CRLF (los exports de Windows, sin ir
# más lejos) da un hash que no coincide y el CSP bloquea el script.
html = html.replace("\r\n", "\n").replace("\r", "\n")

# Los <script src="..."> los cubre 'self'; aquí solo van los inline.
inline = re.finditer(r"<script(?![^>]*\ssrc=)[^>]*>(.*?)</script>", html, re.S)

sources = ["'self'"]
for match in inline:
    digest = hashlib.sha256(match.group(1).encode("utf-8")).digest()
    sources.append("'sha256-" + base64.b64encode(digest).decode() + "'")

print(" ".join(sources))
