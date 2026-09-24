# ADR-0010: ALB con listener HTTP:80 temporal restringido por IP + corrección del modelo de costos (Free plan con créditos)

## Estado
Aceptado

Fecha: 2026-09-23

## Contexto
El Módulo 6 introduce el Application Load Balancer delante del Auto Scaling
Group del Módulo 5. Desde el 2026-09-11 el ALB figuraba como "problema de
costo sin resolver", bajo la premisa de que la cuenta no tenía cobertura
gratuita para él y que cualquier gasto sería un cobro real con presupuesto
cero. Antes de diseñar el ALB se verificó esa premisa contra la cuenta real,
en vez de seguir asumiéndola.

### Evidencia de la cuenta (2026-09-23)
`aws freetier get-account-plan-state`:

- `accountPlanType`: `FREE`, `accountPlanStatus`: `ACTIVE`
- `accountPlanRemainingCredits`: **122.82 USD**
- `accountPlanExpirationDate`: **2026-10-21T02:07 UTC**

La consola de Billing confirma: *"Your free plan account does not get
charged. Credits cover your free plan costs."* y advierte que la cuenta se
cierra al vencer el plan.

Uso bruto del 2026-09-01 al 2026-09-23 (Cost Explorer, excluyendo
`RECORD_TYPE = Credit`; el `UnblendedCost` sin filtro da ~0 porque los
créditos se netean contra el consumo):

| Servicio | USD |
|---|---|
| Amazon RDS | 12.74 |
| EC2 - Compute | 1.27 |
| EC2 - Other | 1.03 |
| Amazon VPC | 0.65 |
| ECR, S3 y resto | ~0.00 |
| **Total** | **~15.70** |

## Decisión

### 1. Modelo de costos corregido
- **No existe riesgo de cobro real** mientras la cuenta esté en el Free
  plan: todo el consumo se descuenta de créditos. El recurso escaso no es
  dinero sino **créditos (122.82 USD) y tiempo (hasta el 2026-10-21)**.
- **La premisa "RDS y bastion son gratis dentro de las 750 h/mes del Free
  Tier"**, usada para la política de no-teardown del 2026-09-15 (y como
  premisa de costo al diseñar RDS, ver ADR-0003), **era incorrecta para esta
  cuenta**: RDS consume ~0.55 USD/día de créditos. La política de mantener
  los stacks base encendidos se conserva porque el crédito alcanza hasta el
  vencimiento, pero ahora con su costo real conocido.
- **Se permanece en el Free plan** y el proyecto se termina antes del
  vencimiento (objetivo interno: 2026-10-18). No se migra a un plan pago.

### 2. ALB con listener HTTP:80 temporal
- Costo estimado del ALB en `us-east-2`: ~0.0225 USD/h + LCU mínimo
  (~0.008 USD/h) + 2 IPv4 públicas (~0.005 USD/h c/u) ≈ **0.04 USD/h**.
  Encendido 24/7 hasta el vencimiento serían ~27 USD, dentro del crédito
  disponible. Aun así se mantiene el patrón de interruptor (`CreateAlb`,
  por defecto `false`), igual que `CreateNatGateways` y `CreateEcrEndpoints`.
- **Listener HTTP:80, no HTTPS:443**, porque ACM solo emite certificados
  para dominios que se controlan, y el DNS del ALB
  (`*.elb.amazonaws.com`) no lo es. HTTPS queda para el Módulo 8
  (Route 53 + dominio propio).

### 3. Regla de entrada del puerto 80
- Origen: **una sola IP `/32`** (la del desarrollador), no `0.0.0.0/0`.
  La API todavía no tiene autenticación y expone datos de préstamos y
  cuotas; restringir en la capa de red compensa temporalmente la falta de
  control en la capa de aplicación (defensa en profundidad).
- La IP **no se escribe en el template ni en el repositorio**: entra como
  parámetro `AllowedClientCidr` al desplegar. Evita publicar un dato
  personal en un repo público y soporta IPs domésticas dinámicas.
- La regla vive en **`06-alb.yaml`** como `AWS::EC2::SecurityGroupIngress`
  independiente sobre el `AlbSecurityGroup` importado
  (`loan-collections-alb-sg-id`), no en `03-security.yaml`. Así su ciclo de
  vida queda atado al del ALB: con `CreateAlb=false` desaparecen juntos el
  listener y el puerto 80 abierto.
- **No se modifica el SG de las EC2**: la regla `8080 ← AlbSecurityGroup`
  ya existe desde el Módulo 3 (verificado con `describe-security-groups`:
  `Ec2AppSecurityGroup` tiene una única regla de entrada, 8080 desde
  `sg-03221de2cf2abc964`).

## Alternativas consideradas
- **Pasar a un plan pago** para conservar la cuenta después del
  2026-10-21: descartado. Introduce riesgo de cobro real sin necesidad
  para completar el proyecto.
- **No desplegar el ALB y documentarlo solo con teoría y diagramas**:
  descartado. El costo real es mínimo y el ALB es central para el examen
  SAA-C03 y para cerrar el punto ciego de `HealthCheckType: EC2` del
  ADR-0009.
- **Puerto 80 abierto a `0.0.0.0/0`**: descartado mientras la API no tenga
  autenticación.
- **Postergar todo el listener al Módulo 8**: descartado. Bloquearía la
  validación del target group, los health checks y el cambio a
  `HealthCheckType: ELB` en este módulo.

## Consecuencias
- **Cierre de la cuenta el 2026-10-21**: todos los recursos del proyecto (y
  los de TMS, que comparte la cuenta) dejarán de existir. El cierre de
  portafolio (Módulo 12) pasa de "demo en vivo" a **evidencia persistente en
  GitHub**: capturas, salidas de `curl`, diagramas y ADRs. Las capturas de
  TMS deben tomarse antes del 2026-10-18.
- **Calendario comprimido**: siete módulos (6 a 12) en ~25 días.
- **Deuda de seguridad documentada**: el `AlbSecurityGroup` mantiene desde
  el Módulo 3 una regla 443 abierta a `0.0.0.0/0` sin ningún listener
  asociado. No es explotable hoy (nada responde en ese puerto), pero es
  configuración muerta que una auditoría marcaría. Se resuelve en el
  Módulo 8 junto con el listener HTTPS.
- **Deuda de aplicación**: la API sigue sin autenticación; la restricción
  `/32` es una mitigación temporal, no un reemplazo.
- **Si cambia la IP pública del desarrollador**, el ALB responde con
  *timeout* hasta volver a desplegar con el nuevo `AllowedClientCidr`.
- **Lección de proceso**: dos premisas de costo repetidas durante semanas
  ("el ALB no tiene cobertura", "RDS es gratis") resultaron falsas al
  compararlas con Cost Explorer y la API de Free Tier. Toda decisión de
  costo futura en este proyecto se basa en datos de la cuenta, no en
  supuestos generales.
- En una cuenta con créditos, el `UnblendedCost` de Cost Explorer sale
  neteado (~0); para ver el consumo real hay que filtrar
  `RECORD_TYPE != Credit`.
