#!/usr/bin/env bash
# =============================================================================
# Despliegue de los demos de `Poryectosdemo/` en el VPS `canalimena`.
#
#   ./deploy/deploy-demo.sh agave           despliega y recarga nginx
#   ./deploy/deploy-demo.sh agave --setup   además crea el conf y emite el cert
#
# Cada demo vive en Poryectosdemo/<nombre>/ y se publica en
# <nombre>.andproducciones.com desde /var/www/<nombre>. El HTML de la carpeta
# se sube como index.html, se llame como se llame en el repo.
#
# Idempotente. El --setup detecta si el certificado ya existe y no vuelve a
# pedirlo (Let's Encrypt: 5 emisiones por dominio a la semana).
# =============================================================================
set -euo pipefail

SSH_HOST="${SSH_HOST:-canalimena}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEMO="${1:-}"
if [[ -z "$DEMO" || "$DEMO" == --* ]]; then
  echo "uso: $0 <demo> [--setup]     demos: $(ls "$REPO/Poryectosdemo" | tr '\n' ' ')" >&2
  exit 1
fi

SRC="$REPO/Poryectosdemo/$DEMO"
[[ -d "$SRC" ]] || { echo "no existe $SRC" >&2; exit 1; }

DOMAIN="$DEMO.andproducciones.com"
WEBROOT="/var/www/$DEMO"
CONF="$DEMO.conf"

SETUP=false
[[ "${2:-}" == "--setup" ]] && SETUP=true

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

# --- Qué HTML es la portada --------------------------------------------------
# Si hay index.html se usa ese; si no, el único .html de la carpeta. Con varios
# candidatos no se adivina: el demo de agave, por ejemplo, es index_4.html.
if [[ -f "$SRC/index.html" ]]; then
  HTML="$SRC/index.html"
else
  mapfile -t CANDIDATES < <(find "$SRC" -maxdepth 1 -name '*.html' | sort)
  if [[ ${#CANDIDATES[@]} -ne 1 ]]; then
    echo "en $SRC hay ${#CANDIDATES[@]} .html y ninguno se llama index.html:" >&2
    printf '    %s\n' "${CANDIDATES[@]}" >&2
    echo "renombra el bueno a index.html" >&2
    exit 1
  fi
  HTML="${CANDIDATES[0]}"
fi
say "Demo '$DEMO' -> https://$DOMAIN   (portada: $(basename "$HTML"))"

# --- CSP: el hash de cada <script> inline ------------------------------------
say "Calculando hashes CSP de los scripts inline"
HASHES=$(python "$REPO/deploy/csp-hashes.py" < "$HTML")
echo "    $HASHES"

# --- Archivos ----------------------------------------------------------------
# Se monta una copia con el HTML ya renombrado a index.html y el resto de la
# carpeta (imágenes, css, lo que haya) tal cual.
say "Empaquetando el demo"
STAGE="$(mktemp -d -t demo-XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -r "$SRC/." "$STAGE/"
find "$STAGE" -maxdepth 1 -name '*.html' -delete
cp "$HTML" "$STAGE/index.html"
# Que no salga en buscadores lo resuelve la cabecera X-Robots-Tag del conf, no
# un Disallow: bloquear el rastreo dejaría sin vista previa los enlaces que se
# mandan por WhatsApp, Slack o LinkedIn, que es justo para lo que existe el demo.
printf 'User-agent: *\nAllow: /\n' > "$STAGE/robots.txt"

TAR="$(mktemp -t demo-XXXXXX).tar.gz"
tar -czf "$TAR" -C "$STAGE" .
echo "    $(du -h "$TAR" | cut -f1)"

say "Subiendo a $SSH_HOST:$WEBROOT"
scp -q "$TAR" "$SSH_HOST:/tmp/demo-$DEMO.tar.gz"
rm -f "$TAR"

ssh "$SSH_HOST" bash -s <<REMOTE
set -euo pipefail
sudo mkdir -p "$WEBROOT"
# Se vacía primero para que no queden huérfanos archivos que ya no están en el
# repo. Es un estático, no hay nada generado en el servidor que perder.
sudo find "$WEBROOT" -mindepth 1 -delete
sudo tar -xzf /tmp/demo-$DEMO.tar.gz -C "$WEBROOT"
rm -f /tmp/demo-$DEMO.tar.gz
sudo chown -R www-data:www-data "$WEBROOT"
sudo find "$WEBROOT" -type d -exec chmod 755 {} +
sudo find "$WEBROOT" -type f -exec chmod 644 {} +
echo "    \$(sudo find "$WEBROOT" -type f | wc -l) archivos en $WEBROOT"
REMOTE

# --- nginx + TLS -------------------------------------------------------------
# El conf se instala SIEMPRE: lleva dentro los hashes CSP del JavaScript y si se
# queda atrás el navegador bloquea los scripts sin avisar.
say "Sincronizando el conf de nginx (incluye los hashes CSP)"
sed -e "s|__CSP_SCRIPT_HASHES__|$HASHES|g" \
    -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__WEBROOT__|$WEBROOT|g" \
    "$REPO/deploy/demo.conf" > "$STAGE/$CONF"
scp -q "$STAGE/$CONF" "$SSH_HOST:/tmp/$CONF"

if $SETUP; then
  ssh "$SSH_HOST" bash -s <<REMOTE
set -euo pipefail
CERT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem

# Con sudo: /etc/letsencrypt/live es solo-root y sin él el test siempre daría
# "no existe", llamando a certbot en cada despliegue.
if ! sudo test -f "\$CERT"; then
  echo "    Sin certificado todavía: se publica solo el bloque :80 para el reto ACME"
  sudo tee /etc/nginx/sites-available/$CONF >/dev/null <<'HTTPONLY'
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
    }
    location / { return 404; }
}
HTTPONLY
  sudo ln -sfn /etc/nginx/sites-available/$CONF /etc/nginx/sites-enabled/$CONF
  sudo nginx -t && sudo systemctl reload nginx

  echo "    Emitiendo certificado para $DOMAIN"
  sudo certbot certonly --webroot -w /var/www/letsencrypt \
       -d $DOMAIN \
       --non-interactive --agree-tos --email andproducciones@gmail.com \
       --keep-until-expiring
else
  echo "    Certificado ya presente, no se vuelve a emitir"
fi

sudo cp /tmp/$CONF /etc/nginx/sites-available/$CONF
rm -f /tmp/$CONF
sudo ln -sfn /etc/nginx/sites-available/$CONF /etc/nginx/sites-enabled/$CONF
sudo nginx -t
sudo systemctl reload nginx
echo "    nginx recargado"
REMOTE
else
  ssh "$SSH_HOST" bash -s <<REMOTE
set -euo pipefail
sudo cp /tmp/$CONF /etc/nginx/sites-available/$CONF
rm -f /tmp/$CONF
sudo ln -sfn /etc/nginx/sites-available/$CONF /etc/nginx/sites-enabled/$CONF
sudo nginx -t
sudo systemctl reload nginx
echo "    nginx recargado con el CSP al día"
REMOTE
fi

say "Listo — https://$DOMAIN"
