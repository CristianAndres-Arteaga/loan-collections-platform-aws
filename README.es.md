# Loan Collections Platform (AWS)

**Español** · [English](README.md)

**Sistema de gestión de préstamos y cobranza sobre una arquitectura three-tier en AWS**: VPC propia en 2 AZs, EC2 en Auto Scaling detrás de un ALB, RDS PostgreSQL, ElastiCache, CloudFront con frontend en S3, CI/CD con GitHub Actions y toda la infraestructura como código en CloudFormation.

Lo construí como estudio práctico para **AWS Certified Solutions Architect – Associate (SAA-C03)**. Cada decisión está documentada en un ADR y cada prueba de resiliencia está **medida y registrada como evidencia**.

![CloudFormation](https://img.shields.io/badge/IaC-CloudFormation-FF4F8B?logo=amazonaws&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.14-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-0.141-009688?logo=fastapi&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-ECR-2496ED?logo=docker&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/CI%2FCD-GitHub_Actions_%2B_OIDC-2088FF?logo=githubactions&logoColor=white)

![Dashboard de cobranza: cuotas vencidas y registro de pagos](docs/screenshots/01-dashboard-overdue.png)

---

## Resultados medidos

Todas las cifras salen de pruebas reales sobre la infraestructura desplegada. Las salidas completas están en [`docs/evidence/`](docs/evidence/).

| Prueba | Resultado | Evidencia |
|---|---|---|
| Failover forzado de RDS Multi-AZ | El cliente vio **≤ 15 s de errores** (2 peticiones); RDS reportó ~49 s. La app se recuperó sola, sin reinicios | [multiaz-e2e](docs/evidence/module-11-multiaz-e2e.txt) |
| Terminar la única instancia EC2 | **RTO para el cliente: 2 min 50 s**. Detección del ASG: 81 s. Lanzamiento → 200: 94 s | [multiaz-e2e](docs/evidence/module-11-multiaz-e2e.txt) |
| Restore PITR de RDS | **RPO 4 min 26 s · RTO 28 min 40 s** (solo la capa de datos) | [pitr-drill](docs/evidence/module-11-pitr-drill.txt) |
| Copia de snapshot entre regiones (us-east-2 → us-west-2) | 1 min 37 s, cifrada con la clave KMS de la región destino | [cross-region](docs/evidence/module-11-cross-region-snapshot.txt) |
| Falla inyectada (contenedor detenido) | MTTD de la alarma ~8 min. Se encontró un **OK falso** (MinSize 0 + target tracking) y se corrigió | [observability](docs/evidence/module-09-observability-e2e.txt) |
| Pagos sobre una cuota ya pagada o por encima del saldo | **409** en ambos casos; `SELECT … FOR UPDATE` serializa los pagos concurrentes | [frontend-e2e](docs/evidence/module-12a-frontend-e2e.txt) |
| Encender / apagar el entorno completo | `up` ≈ 10–13 min (CloudFront ocupa 6–9) · `down` ≈ 8 min | [cicd-release](docs/evidence/module-10-cicd-release-e2e.txt) |

**Conclusión principal:** con Multi-AZ la base de datos se recupera en segundos, así que el punto débil de disponibilidad es el **cómputo con una sola instancia**, no RDS. El siguiente paso sería pasar a `Desired 2` (una instancia por AZ).

---

## Arquitectura

![Diagrama de arquitectura: CloudFront, S3, ALB, EC2 Auto Scaling, RDS y ElastiCache en una VPC con 2 AZs](docs/diagram/architecture.png)

<sub>Diagrama generado como código desde [`docs/diagram/architecture.py`](docs/diagram/architecture.py) con los íconos oficiales de AWS.</sub>

**Flujo de una petición:** el navegador entra a una única URL de CloudFront. La función de CloudFront filtra por IP. El behavior `*` sirve la UI desde un bucket S3 **privado** mediante OAC, y `/api/*` va al ALB con un header secreto que el listener valida. El Security Group del ALB solo admite la *prefix list* de CloudFront. Las instancias EC2 están en subnets privadas **sin NAT Gateway**: bajan la imagen de ECR y envían logs a través de VPC Endpoints. RDS y ElastiCache solo aceptan tráfico desde el Security Group de la app.

UI y API comparten el mismo origen, así que **no hace falta CORS** ([ADR-0018](docs/adr/0018-static-frontend-s3-oac-same-cloudfront-distribution.md)).

---

## Servicios de AWS y por qué

| Capa | Servicio | Decisión clave | ADR |
|---|---|---|---|
| Red | VPC, 6 subnets en 2 AZs, Security Groups en capas | Three-tier: público / app / datos | [0001](docs/adr/0001-vpc-design.md), [0005](docs/adr/0005-iam-least-privilege-and-layered-security-groups.md) |
| Red | VPC Endpoints (7) en lugar de NAT Gateway | Más barato y sin salida a internet desde las subnets privadas | [0002](docs/adr/0002-conditional-nat-gateway.md), [0009](docs/adr/0009-vpc-endpoints-and-ssm-parameter-store.md) |
| Cómputo | EC2 + Auto Scaling + Launch Template | Docker en EC2 (no ECS) para cubrir EC2/ASG del examen | [0005](docs/adr/0005-iam-least-privilege-and-layered-security-groups.md) |
| Balanceo | Application Load Balancer | Health check superficial a propósito (evita reemplazos en cascada si cae RDS) | [0010](docs/adr/0010-alb-http-temporary-and-free-plan-cost-model.md) |
| Datos | RDS PostgreSQL 16 | Single-AZ por costo, Multi-AZ como parámetro (probado), PITR y DeletionProtection | [0003](docs/adr/0003-rds-single-az-free-tier.md), [0017](docs/adr/0017-ha-dr-strategy-single-az-pitr-and-regional-backup-restore.md) |
| Caché | ElastiCache Valkey | Cache-aside con clave por fecha y fail-open | [0011](docs/adr/0011-elasticache-valkey-cache-aside.md) |
| Edge | CloudFront + CloudFront Functions | HTTPS sin dominio propio; filtro de IP en el edge | [0013](docs/adr/0013-https-via-cloudfront-without-custom-domain.md) |
| Frontend | S3 privado + OAC | Misma distribución, behaviors por path | [0018](docs/adr/0018-static-frontend-s3-oac-same-cloudfront-distribution.md) |
| Acceso admin | Bastion + SSM Session Manager | Sin SSH abierto ni claves; túnel por SSM a RDS | [0004](docs/adr/0004-bastion-ssm-access.md) |
| Observabilidad | CloudWatch Logs (JSON), metric filters, 6 alarmas, SNS | Alarmas sobre `ELB_5XX` y `HealthyHostCount`, no solo sobre la app | [0014](docs/adr/0014-observability-logs-alarms-and-sns.md) |
| CI/CD | GitHub Actions, OIDC, ECR scan | Publicar ≠ promover: promoción manual a producción | [0015](docs/adr/0015-cicd-github-actions-oidc-scan-gate-and-manual-promotion.md) |

---

## Seguridad

- **Sin credenciales de larga duración:** GitHub Actions asume un rol vía **OIDC**; las instancias usan un instance profile con mínimo privilegio.
- **Secretos:** la contraseña de RDS vive en **SSM Parameter Store (SecureString)** y CloudFormation la resuelve con `ssm-secure`. Nunca está en el repo ni en parámetros.
- **Red:** ALB → EC2 → RDS encadenados por Security Groups; RDS y EC2 sin IP pública; el ALB solo es alcanzable desde CloudFront (prefix list + header secreto).
- **Datos:** RDS cifrado (KMS), bucket con Block Public Access ×4, SSE-S3 y política que exige TLS y `AWS:SourceArn` de la distribución.
- **Contenedor:** usuario no-root e imagen escaneada en ECR. Un *scan gate* bloquea la promoción ante hallazgos HIGH/CRITICAL sin aceptar. Las aceptaciones de riesgo están documentadas: [0006](docs/adr/0006-ecr-image-vulnerability-risk-acceptance.md), [0008](docs/adr/0008-zlib-residual-risk-final-acceptance.md), [0012](docs/adr/0012-perl-pod-text-cve-risk-acceptance.md), [0016](docs/adr/0016-libstdcxx-pcre2-cve-risk-acceptance-and-gate-allowlist.md).

---

## Costos

La cuenta usa el **Free plan con créditos**. Para gastar lo mínimo, la infraestructura se divide en dos grupos:

- **Siempre encendido:** VPC, RDS `db.t3.micro` Single-AZ, bastion, ECR, bucket del frontend. Cuesta unos **USD 1,4 por día**.
- **Encendido bajo demanda** con `scripts/env.sh`: VPC Endpoints, ALB, CloudFront y el ASG. Se crean para cada sesión de pruebas y se destruyen al terminar.

Ejemplo: activar Multi-AZ durante ~77 min para la prueba de failover costó ~USD 0,02 ([ADR-0010](docs/adr/0010-alb-http-temporary-and-free-plan-cost-model.md)).

---

## Cómo desplegarlo

**Requisitos:** AWS CLI v2 con un perfil con permisos, `cfn-lint` y Docker.

1. Desplegar los stacks base en orden, con change sets revisados: `00` (OIDC) → `01-vpc` → `bastion` → `02-rds` → `03-security` → `04-ecr` → `05-compute` → `06-alb` → `07-cache` → `08-monitoring` → `09-cicd` → `10-frontend`.
2. Subir el frontend:
   ```bash
   aws s3 sync frontend/ s3://<bucket-frontend> --delete --cache-control no-cache
   ```
3. Operar el entorno con el script:
   ```bash
   ./scripts/env.sh status          # estado actual (solo lectura)
   ./scripts/env.sh promote <tag>   # marca prod-<tag> y actualiza ImageTag (solo con el ASG en 0)
   ./scripts/env.sh up              # endpoints → ALB/CloudFront → ASG; espera /api 200
   ./scripts/env.sh down            # orden inverso
   ```

`env.sh` lee los templates **siempre de `origin/main`**, nunca del working tree: solo se despliega lo que ya pasó por un PR.

**Pipeline:** `pr-ci` (cfn-lint + build + smoke test) en cada PR → merge → `release` construye, sube a ECR y espera el escaneo → **promoción manual** con `env.sh promote`.

---

## Estructura del repositorio

```
├── app/                 API FastAPI (routers, models SQLAlchemy, schemas Pydantic, caché)
├── frontend/            UI estática (HTML/CSS/JS sin framework)
├── database/            schema.sql, seed.sql, demo-data.sql
├── infrastructure/      plantillas CloudFormation 00–10 + bastion
├── scripts/env.sh       encendido / apagado / promoción
├── docs/adr/            18 Architecture Decision Records
├── docs/evidence/       salidas de las pruebas E2E y de resiliencia
├── docs/screenshots/    capturas de la UI
├── .github/workflows/   pr-ci.yml, release.yml
└── Dockerfile
```

---

## Deuda técnica y mejoras futuras

Las dejo visibles a propósito: conozco los límites del diseño y sé cuál sería el siguiente paso en cada caso.

**Disponibilidad**
- `Desired 2` (una instancia por AZ) y **Instance Refresh** (`MinHealthyPercentage 100`) para desplegar sin downtime.
- Restore real en la región de DR: hoy solo se copió el snapshot; faltan la VPC, la imagen y los parámetros allí.

**Testing**
- Tests automatizados de los caminos de escritura (POST de pagos) en `pr-ci`. Hoy el smoke test solo cubre `/health`.
- Concurrencia real de dos pagos simultáneos: el `FOR UPDATE` se razonó, pero no se ejecutó en paralelo.

**Aplicación**
- "Monto adeudado" no descuenta los pagos parciales (la API debería devolver el saldo).
- El estado `late` no se usa: o lo asigna un job de EventBridge Scheduler o se elimina.
- `amount_paid` acepta valores ≤ 0 (falta `Field(gt=0)`) y no hay `Idempotency-Key`.

**Operación y seguridad**
- Automatizar el `s3 sync` del frontend y sumar el stack de caché a `env.sh up`.
- Dominio propio + ACM para tener HTTPS también entre CloudFront y el ALB.
- Rotación automática de la contraseña de RDS (Secrets Manager), descartada por costo.
- Mínimo privilegio también en el rol administrativo que uso para desplegar.

---

## Estado del proyecto

Proyecto **terminado** (octubre de 2026). Toda la infraestructura se dio de baja al vencer los créditos de la cuenta (21-10-2026), así que **no hay ninguna URL activa**: la evidencia de que todo funcionó está en [`docs/evidence/`](docs/evidence/) y [`docs/screenshots/`](docs/screenshots/).

| Antes del pago | Después del pago | Validación de pagos (409) |
|---|---|---|
| ![](docs/screenshots/01-dashboard-overdue.png) | ![](docs/screenshots/02-after-payment.png) | ![](docs/screenshots/03-payment-guard.png) |

---

**Autor:** Cristian Andrés Rueda Arteaga · [GitHub](https://github.com/CristianAndres-Arteaga) · Licencia [MIT](LICENSE)
