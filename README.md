# andproducciones.com

Landing de AND Producciones. Una sola página estática, sin build ni dependencias:
el HTML lleva dentro sus estilos y su JavaScript.

## Estructura

```
index.html            la página entera (marcado + CSS + JS)
fonts/                Sora y Manrope en woff2, servidas desde el propio dominio
assets/               favicons, iconos de app e imagen de Open Graph
robots.txt
sitemap.xml
site.webmanifest
deploy/
  deploy.sh           despliegue al VPS
  andproducciones.conf  copia versionada del conf de nginx
  csp-hashes.py       calcula los sha256 de los <script> inline para el CSP
  deploy-demo.sh      despliegue de los demos de Poryectosdemo/
  demo.conf           plantilla de nginx para los demos
Poryectosdemo/        demos de cliente, uno por carpeta
```

## Despliegue

El sitio vive en el VPS `canalimena` (definido en `~/.ssh/config`), junto a
canalimena.com y vibegoec.com, servido por nginx desde `/var/www/andproducciones`.

```bash
./deploy/deploy.sh
```

Sube los archivos y recarga nginx. Para cambios de contenido, es todo lo que hace falta.

```bash
./deploy/deploy.sh --setup
```

Hace lo de arriba y además se asegura de que exista el certificado. Solo hace falta
la primera vez o si se cambia de dominio. Es idempotente: si el certificado ya existe
no lo vuelve a pedir, así que no gasta el límite de emisiones de Let's Encrypt.

## Demos de cliente

Cada demo vive en `Poryectosdemo/<nombre>/` y se publica en
`<nombre>.andproducciones.com` desde `/var/www/<nombre>`:

```bash
./deploy/deploy-demo.sh agave           # despliega y recarga nginx
./deploy/deploy-demo.sh agave --setup   # además crea el conf y emite el certificado
```

El HTML de la carpeta se sube como `index.html` se llame como se llame en el repo
(el de agave es `index_4.html`). `deploy/demo.conf` es la plantilla de nginx: mismo
CSP por hash que la landing, más lo que necesitan los demos de Google (fuentes y el
mapa embebido). Los demos van con `noindex` y su propio `robots.txt`, para que no
compitan en buscadores con andproducciones.com.

## Detalles que conviene conocer antes de tocar nada

**El CSP va por hash.** `script-src` no permite `'unsafe-inline'`: declara el sha256
de cada `<script>` inline. `deploy.sh` los recalcula y reinstala el conf de nginx en
**cada** despliegue, así que editar el JS de la página es seguro mientras se despliegue
con el script. Editar el HTML a mano en el servidor deja la página sin JavaScript: el
navegador bloquea los scripts en silencio y se pierden el efecto del hero y el menú.

**Las fuentes son locales.** No hay peticiones a Google Fonts. Si se añade un peso nuevo
hay que descargar su woff2 a `fonts/` y declararlo en `fonts/fonts.css`.

**Las fuentes se cachean un año** (`immutable`). Llevan el subset en el nombre; si alguna
cambia de contenido, hay que cambiarle el nombre para invalidar la caché.

**El HTML nunca se cachea** (`no-cache`): un cambio de copy o de teléfono se ve al recargar.

**Colores de texto.** `--cobalto` (#1557FF) da 3.4:1 sobre el fondo oscuro: sirve para
superficies y titulares grandes, pero no llega al mínimo de WCAG AA en texto pequeño.
Para eso está `--cobalto-txt` (#8FB4FF), que da 9:1. Los rótulos de 11-13px usan esa.
