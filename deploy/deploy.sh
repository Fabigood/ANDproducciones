#!/usr/bin/env bash
# =============================================================================
# Despliegue de andproducciones.com en el VPS `canalimena`.
#
#   ./deploy/deploy.sh          despliega los archivos y recarga nginx
#   ./deploy/deploy.sh --setup  además crea el conf de nginx y emite el cert
#
# Idempotente: se puede correr las veces que haga falta. El --setup detecta si
# el certificado ya existe y no vuelve a pedirlo (Let's Encrypt tiene límite de
# 5 emisiones por dominio a la semana).
# =============================================================================
set -euo pipefail

SSH_HOST="${SSH_HOST:-canalimena}"
DOMAIN="andproducciones.com"
WEBROOT="/var/www/andproducciones"
CONF="andproducciones.conf"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SETUP=false
[[ "${1:-}" == "--setup" ]] && SETUP=true

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

# --- CSP: el hash de cada <script> inline -----------------------------------
# El CSP prohíbe JS inline salvo que su sha256 esté declarado. Se calcula aquí
# en cada despliegue para que editar el JS de la página no rompa el sitio.
say "Calculando hashes CSP de los scripts inline"
HASHES=$(python "$REPO/deploy/csp-hashes.py" < "$REPO/index.html")
echo "    $HASHES"

# --- Archivos ----------------------------------------------------------------
say "Empaquetando el sitio"
TAR="$(mktemp -t andprod-XXXXXX).tar.gz"
tar -czf "$TAR" -C "$REPO" index.html robots.txt sitemap.xml site.webmanifest assets fonts
echo "    $(du -h "$TAR" | cut -f1)"

say "Subiendo a $SSH_HOST:$WEBROOT"
scp -q "$TAR" "$SSH_HOST:/tmp/andprod.tar.gz"
rm -f "$TAR"

ssh "$SSH_HOST" bash -s <<REMOTE
set -euo pipefail
sudo mkdir -p "$WEBROOT"
# --recursive sobre un tar limpio: los archivos que ya no existan en el repo se
# quedarían huérfanos, así que se vacía primero. Es una landing estática, no hay
# nada generado en el servidor que perder.
sudo find "$WEBROOT" -mindepth 1 -delete
sudo tar -xzf /tmp/andprod.tar.gz -C "$WEBROOT"
rm -f /tmp/andprod.tar.gz
sudo chown -R www-data:www-data "$WEBROOT"
sudo find "$WEBROOT" -type d -exec chmod 755 {} +
sudo find "$WEBROOT" -type f -exec chmod 644 {} +
echo "    \$(sudo find "$WEBROOT" -type f | wc -l) archivos en $WEBROOT"
REMOTE

# --- nginx + TLS -------------------------------------------------------------
# El conf se instala SIEMPRE, no solo con --setup: lleva dentro los hashes CSP
# del JavaScript, y si se queda atrás el navegador bloquea los scripts de la
# página sin avisar. --setup solo añade la emisión del certificado.
say "Sincronizando el conf de nginx (incluye los hashes CSP)"
sed "s|__CSP_SCRIPT_HASHES__|$HASHES|g" "$REPO/deploy/$CONF" > /tmp/$CONF
scp -q /tmp/$CONF "$SSH_HOST:/tmp/$CONF"
rm -f /tmp/$CONF

if $SETUP; then
  ssh "$SSH_HOST" bash -s <<REMOTE
set -euo pipefail
CERT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem

# Con sudo: /etc/letsencrypt/live es solo-root y sin él el test siempre
# daba "no existe", llamando a certbot en cada despliegue.
if ! sudo test -f "\$CERT"; then
  echo "    Sin certificado todavía: se publica solo el bloque :80 para el reto ACME"
  sudo tee /etc/nginx/sites-available/$CONF >/dev/null <<'HTTPONLY'
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
    }
    location / { return 404; }
}
HTTPONLY
  sudo ln -sfn /etc/nginx/sites-available/$CONF /etc/nginx/sites-enabled/$CONF
  sudo nginx -t && sudo systemctl reload nginx

  echo "    Emitiendo certificado para $DOMAIN y www.$DOMAIN"
  sudo certbot certonly --webroot -w /var/www/letsencrypt \
       -d $DOMAIN -d www.$DOMAIN \
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
