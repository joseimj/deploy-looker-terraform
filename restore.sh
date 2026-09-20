#!/usr/bin/env bash
#
# restore.sh — Restaura una instancia de Looker (Google Cloud core)
#              a partir de un backup nativo seleccionado.
#
# El backup solo puede restaurarse SOBRE LA MISMA INSTANCIA de la que se tomó.
# La restauración SOBRESCRIBE los datos actuales: todo lo creado después del
# backup se pierde. La operación no se puede cancelar una vez iniciada.
#
# Uso:
#   ./restore.sh -i mi-looker -r us-central1                 # menú interactivo
#   ./restore.sh -i mi-looker -r us-central1 --latest -y     # último backup, sin preguntar
#   ./restore.sh -i mi-looker -r us-central1 -b BACKUP_ID -y # backup concreto
#   ./restore.sh -i mi-looker -r us-central1 --list          # solo listar
#
set -euo pipefail

INSTANCE=""
REGION=""
PROJECT=""
BACKUP_ID=""
USE_LATEST=false
ASSUME_YES=false
LIST_ONLY=false
WAIT=true

usage() {
  cat <<'EOF'
restore.sh — Restaura una instancia de Looker (Google Cloud core)
             a partir de un backup nativo seleccionado.

El backup solo puede restaurarse SOBRE LA MISMA INSTANCIA de la que se tomó.
La restauración SOBRESCRIBE los datos actuales: todo lo creado después del
backup se pierde. La operación no se puede cancelar una vez iniciada.

Uso:
  ./restore.sh -i mi-looker -r us-central1                 # menú interactivo
  ./restore.sh -i mi-looker -r us-central1 --latest -y     # último backup, sin preguntar
  ./restore.sh -i mi-looker -r us-central1 -b BACKUP_ID -y # backup concreto
  ./restore.sh -i mi-looker -r us-central1 --list          # solo listar

Opciones:
  -i, --instance NAME   Nombre de la instancia de Looker (obligatorio)
  -r, --region REGION   Región de la instancia (obligatorio)
  -p, --project ID      Proyecto de GCP (por defecto: el configurado en gcloud)
  -b, --backup ID       ID del backup a restaurar (omitir para elegir del menú)
      --latest          Usa el backup ACTIVE más reciente
      --list            Solo lista los backups y termina
      --no-wait         Lanza el restore y no espera a que termine
  -y, --yes             No pide confirmación
  -h, --help            Muestra esta ayuda
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--instance) INSTANCE="$2"; shift 2 ;;
    -r|--region)   REGION="$2";   shift 2 ;;
    -p|--project)  PROJECT="$2";  shift 2 ;;
    -b|--backup)   BACKUP_ID="$2"; shift 2 ;;
    --latest)      USE_LATEST=true; shift ;;
    --list)        LIST_ONLY=true;  shift ;;
    --no-wait)     WAIT=false;      shift ;;
    -y|--yes)      ASSUME_YES=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) die "Opción desconocida: $1 (usa --help)" ;;
  esac
done

command -v gcloud >/dev/null || die "gcloud no está instalado o no está en el PATH."
[[ -n "$INSTANCE" ]] || { usage; die "Falta --instance."; }
[[ -n "$REGION"   ]] || { usage; die "Falta --region."; }

if [[ -z "$PROJECT" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null)"
  [[ -n "$PROJECT" && "$PROJECT" != "(unset)" ]] \
    || die "No hay proyecto configurado. Usa --project."
fi

GC=(gcloud --project="$PROJECT")

# --- Comprobar que la instancia existe -------------------------------------
"${GC[@]}" looker instances describe "$INSTANCE" --region="$REGION" >/dev/null 2>&1 \
  || die "No se encontró la instancia '$INSTANCE' en $REGION (proyecto $PROJECT)."

# --- Listar backups ---------------------------------------------------------
echo "Backups de '$INSTANCE' ($REGION, proyecto $PROJECT):"
echo

mapfile -t ROWS < <(
  "${GC[@]}" looker backups list \
    --instance="$INSTANCE" --region="$REGION" \
    --sort-by="~createTime" \
    --format="value(name.basename(),state,createTime,expireTime)"
)

[[ ${#ROWS[@]} -gt 0 ]] || die "No hay backups para esta instancia."

printf "%-4s %-28s %-10s %-26s %s\n" "#" "BACKUP_ID" "ESTADO" "CREADO" "EXPIRA"
i=1
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r id state created expires <<<"$row"
  printf "%-4s %-28s %-10s %-26s %s\n" "$i" "$id" "$state" "$created" "$expires"
  ((i++))
done
echo

$LIST_ONLY && exit 0

# --- Seleccionar backup -----------------------------------------------------
BACKUP_STATE=""

if [[ -z "$BACKUP_ID" ]]; then
  if $USE_LATEST; then
    # Primer backup ACTIVE de la lista (ya viene ordenada de más nuevo a más viejo)
    for row in "${ROWS[@]}"; do
      IFS=$'\t' read -r id state _ _ <<<"$row"
      if [[ "$state" == "ACTIVE" ]]; then
        BACKUP_ID="$id"; BACKUP_STATE="$state"; break
      fi
    done
    [[ -n "$BACKUP_ID" ]] || die "No hay ningún backup ACTIVE para restaurar."
    echo "Backup más reciente: $BACKUP_ID"
  else
    read -rp "Número del backup a restaurar [1-${#ROWS[@]}]: " CHOICE
    [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#ROWS[@]} )) \
      || die "Selección inválida."
    IFS=$'\t' read -r BACKUP_ID BACKUP_STATE _ _ <<<"${ROWS[$((CHOICE-1))]}"
  fi
else
  # Validar que el ID indicado esté en la lista
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r id state _ _ <<<"$row"
    if [[ "$id" == "$BACKUP_ID" ]]; then BACKUP_STATE="$state"; break; fi
  done
  [[ -n "$BACKUP_STATE" ]] \
    || die "El backup '$BACKUP_ID' no existe para esta instancia."
fi

[[ "$BACKUP_STATE" == "ACTIVE" ]] \
  || die "El backup '$BACKUP_ID' está en estado '$BACKUP_STATE'; solo se restauran los ACTIVE."

# --- Confirmar --------------------------------------------------------------
cat <<EOF

  Instancia : $INSTANCE ($REGION, proyecto $PROJECT)
  Backup    : $BACKUP_ID

  Esto SOBRESCRIBE el contenido actual de la instancia.
  Todo lo creado después de ese backup se pierde y no se puede cancelar.

EOF

if ! $ASSUME_YES; then
  read -rp "Escribe el nombre de la instancia para confirmar: " CONFIRM
  [[ "$CONFIRM" == "$INSTANCE" ]] || die "Confirmación no coincide. Cancelado."
fi

# --- Restaurar --------------------------------------------------------------
echo "Lanzando restauración..."

# --async es obligatorio en 'instances restore'; devuelve el nombre de la operación.
OPERATION="$(
  "${GC[@]}" looker instances restore "$INSTANCE" \
    --backup="$BACKUP_ID" \
    --region="$REGION" \
    --async \
    --format="value(name)"
)"

OP_ID="${OPERATION##*/}"
echo "Operación: $OP_ID"

if ! $WAIT; then
  echo
  echo "Seguimiento:"
  echo "  gcloud --project=$PROJECT looker operations describe $OP_ID --region=$REGION"
  exit 0
fi

# 'gcloud looker operations' no tiene subcomando 'wait': se consulta en bucle.
echo "Esperando a que termine (puede tardar de minutos a horas)..."
while true; do
  DONE="$("${GC[@]}" looker operations describe "$OP_ID" --region="$REGION" \
            --format='value(done)' 2>/dev/null || echo "")"
  [[ "$DONE" == "True" || "$DONE" == "true" ]] && break
  printf '.'
  sleep 30
done
echo

OP_ERROR="$("${GC[@]}" looker operations describe "$OP_ID" --region="$REGION" \
              --format='value(error.message)')"
[[ -z "$OP_ERROR" ]] || die "La restauración falló: $OP_ERROR"

STATE="$("${GC[@]}" looker instances describe "$INSTANCE" --region="$REGION" --format='value(state)')"
echo "Restauración terminada. Estado de la instancia: $STATE"
