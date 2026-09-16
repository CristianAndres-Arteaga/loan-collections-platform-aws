# ADR-0003: RDS Single-AZ y credenciales sin Secrets Manager (Free Tier)

## Estado
Aceptado

## Contexto
El diseño original contemplaba RDS Multi-AZ, una clave KMS administrada por el
cliente (CMK) y credenciales gestionadas automáticamente vía Secrets Manager
(`ManageMasterUserPassword`). Al avanzar en el Módulo 2 se confirmó que el
proyecto tiene presupuesto real de $0 — sin créditos gratuitos de AWS más allá
del Free Tier estándar de 12 meses. Multi-AZ, una CMK propia y Secrets Manager no
tienen cobertura de Free Tier: generan costo continuo desde el primer minuto.

## Decisión
- RDS se despliega en **Single-AZ**, `db.t3.micro`, dentro del Free Tier
  (750 horas/mes de instancia).
- Se usa la clave **administrada por AWS** (`aws/rds`) para cifrado en reposo,
  en vez de una CMK propia.
- Las credenciales se pasan como parámetro CloudFormation `DBMasterPassword`
  (`NoEcho: true`, sin default), provisto vía variable de shell (`read -s`) en el
  momento del deploy, en vez de `ManageMasterUserPassword`/Secrets Manager.
- `BackupRetentionPeriod` se fijó en `1` (el máximo permitido por Free Tier en
  esta cuenta — un valor mayor es rechazado por AWS con error explícito).

## Alternativas consideradas
- Multi-AZ real: descartado por costo continuo (~duplica el costo de cómputo de
  RDS). La teoría de Multi-AZ (replicación síncrona, standby pasivo, failover vía
  actualización del endpoint DNS) ya fue enseñada y evaluada en el proyecto —
  queda como conocimiento adquirido aunque no desplegado permanentemente. Un test
  real de failover Multi-AZ queda abierto como posible excepción corta y
  deliberada al llegar al Módulo 9 (HA/DR).
- CMK propia: descartada — cuesta $1/mes fijo sin Free Tier, por una ganancia de
  control de política de clave que no es crítica para un proyecto de estudio sin
  cifras reales de PII.
- Secrets Manager con rotación automática: descartado — ~$0.40/mes por secreto,
  sin tier gratuito continuo.

## Consecuencias
- Costo de RDS $0 dentro de la ventana de Free Tier de la cuenta.
- Se pierde failover automático real y rotación automática de credenciales — un
  trade-off consciente y documentado, no un descuido. Sirve como punto de
  conversación en entrevista: "elegí Single-AZ por restricción de presupuesto,
  entendiendo y pudiendo explicar el trade-off frente a Multi-AZ".
- El manejo de credenciales pasa a ser manual (compartir/rotar la contraseña
  fuera de banda) en vez de automático — riesgo operativo aceptado
  deliberadamente para este contexto de proyecto personal de estudio.