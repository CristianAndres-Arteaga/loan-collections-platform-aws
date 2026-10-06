# ADR-0015: CI/CD con GitHub Actions, OIDC, scan gate y promoción manual

## Estado
Aceptado

Fecha: 2026-10-04

Relacionado con: ADR-0006/0008/0012/0016 (aceptación de CVE), ADR-0013 (CloudFront),
ADR-0014 (observabilidad)

## Contexto
Hasta el Módulo 9, cada imagen se construía y se subía a ECR **a mano desde la
laptop**: `docker login` dejaba el token de ECR en texto plano en
`~/.docker/config.json`, el escaneo se revisaba a mano consultando por digest, y nada
impedía mergear a `main` un template inválido o una imagen que no arrancara. Encender
y apagar el entorno para cada prueba requería entre 6 y 10 comandos manuales en un
orden fijo, y ya había causado errores (por ejemplo, `deploy` conserva el valor
anterior de los parámetros que no se pasan, lección del Módulo 7).

Restricciones:
- La cuenta está en el plan Free de AWS: los créditos vencen el 2026-10-21 y el
  entorno vive **apagado** por defecto (ASG en 0, sin ALB ni endpoints).
- El repositorio ECR es `IMMUTABLE` y usa el escaneo *basic*, que solo corre al hacer
  push.
- El repositorio de GitHub es público.

## Decisión

### 1. Identidad: OIDC, sin access keys
- El proveedor OIDC de GitHub (`token.actions.githubusercontent.com`) ya existía en la
  cuenta: se creó a mano en la consola para el proyecto TMS. Solo puede haber **uno
  por URL por cuenta**, así que no se crea otro: se **importó** a CloudFormation en un
  stack de nivel cuenta, `account-github-oidc` (`00-account-github-oidc.yaml`), con un
  change set de tipo `IMPORT`, `DeletionPolicy` y `UpdateReplacePolicy` en `Retain`, y
  el export `account-github-oidc-provider-arn`. Drift verificado: `IN_SYNC`.
- El rol `loan-collections-github-ci` (`09-cicd.yaml`, stack `loan-collections-cicd`)
  confía en ese proveedor con `StringEquals` sobre:
  - `aud` = `sts.amazonaws.com`
  - `sub` = `repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main`, con los
    **IDs numéricos inmutables** del dueño y del repositorio. Renombrar el usuario o el
    repo no habilita a un tercero que reutilice el nombre.
- Permisos mínimos: `ecr:GetAuthorizationToken` (no admite restricción por recurso) y,
  **solo sobre el ARN del repositorio**, las acciones de push más
  `DescribeImages`/`DescribeImageScanFindings`. Sin `BatchDeleteImage`, sin
  CloudFormation y sin permisos sobre otros servicios. `MaxSessionDuration` 3600.

### 2. Integración continua en cada PR (`pr-ci.yml`)
- `permissions: contents: read`, **sin `id-token: write`**: un PR, incluido uno desde
  un fork, no puede obtener credenciales de AWS.
- Jobs: `cfn-lint` (versión fija 1.57.1) sobre todos los templates, y
  `docker build --pull` + smoke test de `/health` con una base de datos ficticia y
  `CACHE_HOST=disabled`.
- El ruleset `protect-main` exige PR, prohíbe force push y borrado de `main`, y requiere
  que los dos checks pasen.

### 3. Release con scan gate (`release.yml`)
- Corre en push a `main` solo si cambian `app/**`, `Dockerfile`, `requirements.txt` o el
  propio workflow. Un merge que solo cambia docs o templates no genera una imagen nueva.
- `concurrency` sin cancelación: nunca se interrumpe un release a medio push.
- Build `linux/amd64` con `--pull` y `--provenance=false`: el push es **un solo
  manifest**, sin index ni atestación, y el escaneo se consulta directamente por tag.
- Tag = SHA corto del commit. Si el tag ya existe, el job omite el build y el push y va
  directo al gate, así que re-ejecutarlo es seguro (idempotente).
- Espera del escaneo con reintentos: `ScanNotFoundException` se reintenta, porque la API
  de lectura tiene **consistencia eventual** (visto en el Módulo 9 y otra vez en el
  primer run de CI). Cualquier otro error falla de inmediato. Timeout: 5 minutos.
- Gate: **todo `CRITICAL` bloquea**. Un `HIGH` bloquea salvo que su CVE exacto esté en
  `CVE_ALLOWLIST`, y cada entrada de la allowlist tiene un ADR de aceptación.
- El gate corre **después** del push, porque el escaneo de ECR lo exige. Una imagen que
  no pasa **no se borra** (eso requeriría `BatchDeleteImage` en el rol de CI) y su tag
  no se puede reutilizar (`IMMUTABLE`): queda en cuarentena, sin promover.

### 4. Publicar no es promover
- Que el release termine en verde significa "**apta** para promover", no "desplegada".
  Lo que corre en producción lo decide únicamente el parámetro `ImageTag` de
  `05-compute`, y lo cambia una persona.
- **Promover** = agregar el tag `prod-<sha>` a la imagen (un `put-image` con el mismo
  manifest: mismo digest, sin rebuild) y desplegar `05-compute` con `ImageTag=<sha>`.
  Se hace con el ASG en 0, para no dejar una flota con dos versiones distintas.
- El pipeline **nunca** agrega `prod-`: el tag tiene que significar "estuvo en
  producción". Si se agregara al pasar el gate, la regla de retención contaría imágenes
  que nunca se desplegaron.
- Lifecycle policy de ECR (`04-ecr.yaml`):
  1. Prioridad 1: conservar las últimas 5 imágenes `prod-*`.
  2. Prioridad 2: conservar las últimas 10 imágenes del resto.

  Una imagen retenida por una regla de mayor prioridad no puede expirar por una de
  menor. Un *lifecycle policy preview* confirmó que los hijos sin tag de un index
  protegido tampoco expiran. Sin la regla 1, con el pipeline subiendo una imagen por
  merge, la imagen de producción habría expirado y la siguiente instancia del ASG
  habría fallado en `docker pull`.
- Rollback: `./scripts/env.sh promote <sha anterior>`. El retag se omite porque
  `prod-<sha>` ya existe.

### 5. Operación del entorno con `scripts/env.sh`
- Comandos `status`, `promote <tag>`, `up` y `down`, con el orden fijo
  endpoints → ALB/CloudFront → ASG (y al revés para apagar). `up` espera a que `/health`
  devuelva 200.
- El script **solo cambia parámetros de encendido y apagado**. Usa
  `cloudformation deploy`, que ejecuta el change set sin revisión, y eso es aceptable
  porque los templates se leen siempre de `origin/main` con `git show`: lo desplegado es
  lo que ya se revisó en un PR. `down` funciona desde cualquier rama.
- `promote` muestra el resumen del escaneo (de la misma API que usa el gate) y pide una
  confirmación explícita.
- El secreto del header de CloudFront se lee de un archivo local y se enmascara en el
  log.

### 6. La infraestructura no tiene despliegue continuo
Los cambios de template se despliegan **a mano, con un change set revisado, en el
momento del merge**. No hay CD de infraestructura por tres razones: el entorno vive
apagado para cuidar los créditos, el rol de CI no tiene permisos de CloudFormation
(menor superficie de ataque en un repo público), y cada cambio de recurso con estado
merece una revisión de `Replacement`.

## Alternativas consideradas
- **Access keys de IAM guardadas como secrets de GitHub:** descartado. Son credenciales
  de larga duración, hay que rotarlas, y una filtración da acceso permanente. OIDC
  entrega credenciales temporales de una hora atadas a un repo y una rama.
- **Crear un segundo proveedor OIDC solo para este proyecto:** imposible, porque hay uno
  por URL por cuenta. Mantenerlo fuera de CloudFormation dejaba infraestructura sin
  versionar, así que se importó.
- **Despliegue continuo (el pipeline cambia `ImageTag` y despliega):** descartado. El
  entorno está apagado casi siempre, y promover es una decisión humana que incluye
  aceptar riesgos (ADR-0016).
- **Escanear antes del push con Trivy u otra herramienta en el runner:** válido, y
  evitaría subir imágenes que no pasan. Se prefirió una sola fuente de verdad (el
  escaneo de ECR, la misma que consulta `promote`). Queda como mejora.
- **Borrar automáticamente las imágenes que no pasan el gate:** descartado. Requiere un
  permiso destructivo en el rol de CI y elimina la evidencia. La lifecycle policy las
  limpia sola.
- **Amazon Inspector (escaneo *enhanced*):** re-evalúa las imágenes cada vez que se
  publica un CVE nuevo, así que resolvería el punto ciego del escaneo *basic* que
  documentan ADR-0012 y ADR-0016. Queda como mejora por costo y plazo.

## Consecuencias
**Deudas cerradas:**
- Escaneo dentro del pipeline con una compuerta que bloquea la promoción (ADR-0012).
- Script para encender y apagar el entorno (pendiente desde el Módulo 6).
- Los releases ya no dependen del token de ECR guardado en la laptop.
- La contraseña de RDS se resuelve desde `ssm-secure` (Módulo 10.3); la E2E confirmó el
  login de la app.

**Deudas abiertas y riesgos aceptados:**
- **Escaneo continuo de la imagen desplegada** (Inspector): hoy solo se ven los CVE
  nuevos cuando se reconstruye.
- **Tests automatizados:** el CI de PR solo hace lint, build y smoke test. No hay tests
  unitarios ni de integración.
- **Actions fijadas por tag mayor** (`@v4`, `@v2`), no por SHA de commit. Si una de esas
  actions se compromete, el workflow que tiene `id-token: write` podría verse afectado.
  Mitigación futura: fijar cada action por SHA y usar Dependabot para actualizarlas.
- **La allowlist vive en el workflow:** cambiarla requiere un commit, y por lo tanto una
  imagen nueva. Es intencional (cada cambio queda revisado en un PR), pero un re-run de
  un run fallido usa la allowlist anterior.
- **Riesgo residual del script:** si se mergea un cambio de template que fuerza un
  `Replacement` y no se despliega a mano con change set, el próximo `up` lo aplicaría
  sin revisión. Lo cubre la regla del punto 6.

**Evidencia:** `docs/evidence/module-10-cicd-release-e2e.txt` (primer run en rojo y
segundo en verde, preview de la lifecycle policy, promoción, `up`/`down` y pruebas
T1-T4).
