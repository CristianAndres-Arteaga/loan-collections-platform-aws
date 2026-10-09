#!/usr/bin/env bash
# Enciende, apaga y promueve el entorno de pruebas de loan-collections.
#
#   ./scripts/env.sh status          estado actual (solo lectura)
#   ./scripts/env.sh promote <tag>   tag prod-<tag> + ImageTag en 05 (solo con ASG en 0)
#   ./scripts/env.sh up              endpoints -> ALB/CloudFront -> ASG, espera /api/installments/ 200 (cadena completa)
#   ./scripts/env.sh down            ASG -> ALB/CloudFront -> endpoints
#
# Solo cambia parametros de encendido/apagado. Los templates se leen SIEMPRE de
# origin/main (lo ya revisado en un PR), nunca del working tree. Los cambios de
# template se despliegan aparte, a mano, con un change set revisado.
set -euo pipefail

PROFILE="${AWS_PROFILE_NAME:-tms-admin}"
REGION="us-east-2"
TEMPLATE_REF="origin/main"
REPO="loan-collections-api"
ASG_NAME="loan-collections-app-asg"
SECRET_FILE="$HOME/.loan-collections-origin-secret"

VPC_STACK="loan-collections-vpc"
ALB_STACK="loan-collections-alb"
COMPUTE_STACK="loan-collections-compute"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }
log()  { printf '\n[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Copia infrastructure/<archivo> desde origin/main a un temporal y devuelve la ruta.
template() {
  local out="$TMP_DIR/$1"
  git show "$TEMPLATE_REF:infrastructure/$1" > "$out"
  echo "$out"
}

deploy() {
  local stack="$1" file="$2" tpl
  shift 2
  tpl="$(template "$file")"
  log "deploy $stack ($file @ $(git rev-parse --short "$TEMPLATE_REF")): $(printf '%s ' "$@" | sed -E 's/(OriginVerifySecret=)[^ ]+/\1****/')"
  aws_ cloudformation deploy --stack-name "$stack" --template-file "$tpl" \
    --no-fail-on-empty-changeset --parameter-overrides "$@"
}

stack_param() {
  aws_ cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Parameters[?ParameterKey=='$2'].ParameterValue | [0]" --output text
}

stack_output() {
  aws_ cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text
}

asg_desired() {
  aws_ autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].DesiredCapacity' --output text
}

cmd_status() {
  echo "Templates desde:      $TEMPLATE_REF ($(git rev-parse --short "$TEMPLATE_REF"))"
  echo "ImageTag (05):        $(stack_param "$COMPUTE_STACK" ImageTag)"
  echo "ASG min/desired/ok:   $(aws_ autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].[MinSize,DesiredCapacity,length(Instances[?LifecycleState==`InService`])]' --output text)"
  echo "CreateAlb (06):       $(stack_param "$ALB_STACK" CreateAlb)"
  echo "AllowedClientCidr:    $(stack_param "$ALB_STACK" AllowedClientCidr)"
  echo "CreateEcrEndpoints:   $(stack_param "$VPC_STACK" CreateEcrEndpoints)"
  echo "VPC endpoints:        $(aws_ ec2 describe-vpc-endpoints --query 'length(VpcEndpoints)' --output text)"
  echo "CdnUrl:               $(stack_output "$ALB_STACK" CdnUrl)"
}

cmd_promote() {
  local tag="${1:-}" ok manifest media
  [ -n "$tag" ] || die "uso: $0 promote <tag>"
  [ "$(asg_desired)" = "0" ] || die "promover solo con el ASG en 0 (corre '$0 down' primero)."

  log "Resumen del scan de $tag:"
  aws_ ecr describe-image-scan-findings --repository-name "$REPO" --image-id imageTag="$tag" \
    --query 'imageScanFindings.findingSeverityCounts' --output json
  read -r -p "¿El run 'release' de $tag está en VERDE en GitHub Actions? (y/N): " ok
  [ "$ok" = "y" ] || die "promoción cancelada."

  if aws_ ecr describe-images --repository-name "$REPO" --image-ids imageTag="prod-$tag" > /dev/null 2>&1; then
    log "prod-$tag ya existe: se omite el retag."
  else
    manifest="$(aws_ ecr batch-get-image --repository-name "$REPO" --image-ids imageTag="$tag" \
      --query 'images[0].imageManifest' --output text)"
    media="$(aws_ ecr batch-get-image --repository-name "$REPO" --image-ids imageTag="$tag" \
      --query 'images[0].imageManifestMediaType' --output text)"
    aws_ ecr put-image --repository-name "$REPO" --image-tag "prod-$tag" \
      --image-manifest "$manifest" --image-manifest-media-type "$media" \
      --query 'image.imageId' --output json
  fi

  deploy "$COMPUTE_STACK" 05-compute.yaml ImageTag="$tag"
  log "Promovida: $tag (protegida como prod-$tag)."
}

cmd_up() {
  local my_ip cdn code
  [ -r "$SECRET_FILE" ] || die "no encuentro $SECRET_FILE (secreto del header de CloudFront)."
  my_ip="$(curl -fsS https://checkip.amazonaws.com)/32"
  log "Tu IP pública: $my_ip"

  deploy "$VPC_STACK" 01-vpc.yaml CreateEcrEndpoints=true
  deploy "$ALB_STACK" 06-alb.yaml CreateAlb=true AllowedClientCidr="$my_ip" \
    OriginVerifySecret="$(cat "$SECRET_FILE")"
  deploy "$COMPUTE_STACK" 05-compute.yaml DesiredCapacity=1

  cdn="$(stack_output "$ALB_STACK" CdnUrl)"
  log "Esperando $cdn/api/installments/?overdue=true = 200 (máx. 10 min)..."
  for i in $(seq 1 40); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$cdn/api/installments/?overdue=true" || true)"
    echo "  intento $i/40: $code"
    if [ "$code" = "200" ]; then
      log "Entorno listo: $cdn"
      return 0
    fi
    sleep 15
  done
  die "/api/installments/ no llegó a 200 en 10 min. El entorno sigue ENCENDIDO: investiga o corre '$0 down'."
}

cmd_down() {
  deploy "$COMPUTE_STACK" 05-compute.yaml DesiredCapacity=0
  deploy "$ALB_STACK" 06-alb.yaml CreateAlb=false AllowedClientCidr=127.0.0.1/32
  deploy "$VPC_STACK" 01-vpc.yaml CreateEcrEndpoints=false
  log "Apagado. Estado final:"
  cmd_status
}

case "${1:-}" in
  status)  cmd_status ;;
  promote) cmd_promote "${2:-}" ;;
  up)      cmd_up ;;
  down)    cmd_down ;;
  *)       echo "uso: $0 {status|promote <tag>|up|down}" >&2; exit 2 ;;
esac
