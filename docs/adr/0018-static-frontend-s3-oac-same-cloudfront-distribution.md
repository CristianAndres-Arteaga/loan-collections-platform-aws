# ADR-0018: Frontend estático en S3 privado servido por la misma distribución de CloudFront (OAC) y API bajo /api

## Estado
Aceptado

Fecha: 2026-10-11

Relacionado con: ADR-0013 (HTTPS vía CloudFront sin dominio propio),
ADR-0010 (ALB y modelo de costo del Free plan), ADR-0011 (caché cache-aside),
ADR-0015 (CI/CD y promoción manual), ADR-0017 (HA/DR)

## Contexto
Hasta el Módulo 11 la plataforma solo exponía una API REST. Para el
portafolio hacía falta una interfaz que mostrara el flujo de cobranza:
ver las cuotas vencidas y registrar un pago. Restricciones:

- **Presupuesto de Free plan** (créditos que vencen el 2026-10-21). Nada de
  cómputo extra siempre encendido.
- **HTTPS ya resuelto con CloudFront** (ADR-0013), con filtro de IP en una
  CloudFront Function y el ALB cerrado a CloudFront.
- **El entorno se enciende y apaga** con `scripts/env.sh`. La distribución
  y el ALB solo existen mientras está encendido (`AlbEnabled`).
- Cuando la cuenta se cierre, nada quedará en línea: el valor de la UI
  persistirá solo en las capturas del README.

## Decisión
1. **HTML, CSS y JS sin framework ni build** (`frontend/`, 3 archivos,
   unas 400 líneas). El alcance es un panel y un formulario. Un framework
   agregaría una toolchain sin beneficio para este alcance.
2. **Bucket S3 privado** (Block Public Access ×4, `BucketOwnerEnforced`,
   SSE-S3) en un stack propio, `10-frontend.yaml`, **siempre encendido**
   (costo prácticamente cero).
3. **La misma distribución de CloudFront sirve la UI y la API**, con dos
   behaviors:
   - `*` (default) → S3 a través de **OAC**, solo GET/HEAD, `CachingOptimized`,
     sin origin request policy.
   - `/api/*` → ALB, todos los métodos, `CachingDisabled`,
     `AllViewerExceptHostHeader`.

   Al ser el mismo origen, **no hace falta CORS**.
4. **La API pasa a `/api`** (`include_router(prefix="/api")`, cambio
   incompatible: `feat!`). `/health` sigue en la raíz porque lo usa el health
   check del target group, que va directo al ALB.
5. **OAC, bucket policy y behaviors viven en `06-alb.yaml` bajo `AlbEnabled`**,
   no en el stack del bucket. Nacen y mueren con la distribución, y así se
   evita el *export lock*: si la policy estuviera en `10` importando el ARN
   de la distribución, `env.sh down` no podría borrar la distribución.
6. **La bucket policy autoriza solo a CloudFront**, con
   `AWS:SourceArn` = esta distribución, y niega el transporte sin TLS
   (`aws:SecureTransport=false`).
7. **El filtro de IP (CloudFront Function, viewer-request) se asocia a
   ambos behaviors.** Si quedara solo en el default, `/api/*` estaría abierto.
8. **El frontend se publica con `aws s3 sync --delete --cache-control no-cache`.**
   Es un camino de deploy distinto al de la imagen (release + promote).
9. **Los headers propios de la app no reutilizan nombres que inyecta el CDN.**
   `X-Cache` pasa a `X-App-Cache`, porque CloudFront sobrescribía el valor.
10. **El servidor valida los pagos** (se encontró en el E2E de este módulo):
    `SELECT ... FOR UPDATE` sobre la cuota, 409 si ya está pagada y 409 si el
    monto supera el saldo. La UI limpia el formulario tras un 201, pero esa
    es una defensa de experiencia de usuario, no de integridad.

## Alternativas consideradas
- **S3 static website hosting público:** descartado. Exige un bucket público
  y el endpoint de website no soporta HTTPS, lo que contradice ADR-0013 y el
  Block Public Access.
- **Una segunda distribución solo para la UI:** descartado. Duplica el tiempo
  de `up` (8-9 min por distribución), obliga a configurar CORS en la API y
  necesita su propio filtro de IP.
- **OAI (Origin Access Identity):** mecanismo heredado. OAC es el reemplazo
  recomendado por AWS (soporta SSE-KMS y todas las regiones, y firma con SigV4).
- **Servir la UI desde FastAPI (`StaticFiles`):** descartado. Mezcla
  responsabilidades, cada cambio de CSS exigiría release + promote, y los
  estáticos no aprovecharían la caché del edge.
- **AWS Amplify Hosting:** más simple de operar, pero oculta justamente la
  pieza que se quería practicar (S3 + OAC + behaviors) y queda fuera del
  modelo IaC con CloudFormation del proyecto.
- **SSE-KMS con la clave `aws/s3`:** descartado. Con una clave administrada
  por AWS no se puede editar la key policy para permitir a CloudFront
  descifrar. Haría falta una CMK, con su costo mensual.

## Consecuencias
### Positivas
- Una sola URL HTTPS para UI y API, sin CORS, y con un único filtro de IP
  aplicado a todo.
- Ningún objeto del bucket es accesible sin pasar por esta distribución
  (verificado: acceso directo al bucket → 403).
- Costo adicional prácticamente nulo: el bucket guarda unos 16 KB y la
  distribución ya existía.

### Negativas y matices
- `<cdn>/health` y `<cdn>/docs` caen en el behavior `*` y devuelven **403**
  de S3. `env.sh up` espera ahora `/api/installments/?overdue=true`.
- Un change set de `06` con `CreateAlb=false` **falla** con
  "didn't contain changes": todos los recursos nuevos son condicionales.
  El primer `env.sh up` es el deploy real.
- La `CdnUrl` cambia en cada `up` (distribución nueva), igual que antes.
- El deploy del frontend (`s3 sync`) es **manual** y no está en `env.sh` ni
  en CI.
- `promote` exige el ASG en 0 y `05` no tiene `UpdatePolicy`: publicar una
  imagen nueva implica `down` → `promote` → `up` (unos 21 min).

### Hallazgos del E2E (corregidos)
- `X-Cache` sobrescrito por CloudFront → `X-App-Cache` (PR #12).
- `POST .../payments` devolvía **500 después del commit** por
  `payment.id` (la PK es `payment_id`) en un log del Módulo 9. Pasó
  3 módulos sin detectarse porque el smoke de CI solo prueba `/health`
  (PR #13, con la validación de la decisión 10).

### Deuda registrada
- Tests automatizados de los caminos de escritura (POST de pagos) en `pr-ci`.
- Automatizar el `s3 sync` del frontend (en `env.sh up` o en un workflow
  con filtro de paths `frontend/**`).
- `promote` con el entorno encendido mediante Instance Refresh
  (`MinHealthyPercentage 100`, `MaxHealthyPercentage 200`): sin downtime con
  una sola instancia.
- "Monto adeudado" suma `amount_due` y no descuenta los pagos parciales: la
  API debería devolver el saldo.
- El estado `late` del CHECK no se usa: o un job programado (EventBridge
  Scheduler) lo asigna y el filtro de vencidas lo incluye, o se elimina.
- `amount_paid` acepta valores ≤ 0: falta `Field(gt=0)` en `PaymentCreate`.
- Idempotency-Key en el POST de pagos para reintentos de red.
