# ADR-0017: Estrategia de HA/DR: RDS Single-AZ con PITR, protección contra borrado y Backup & Restore regional sin ensayar

## Estado
Aceptado

Fecha: 2026-10-07

Relacionado con: ADR-0003 (RDS Single-AZ; este ADR cierra su punto abierto
sobre la prueba real de failover), ADR-0001 (VPC en 2 AZ), ADR-0013
(CloudFront delante del ALB), ADR-0014 (observabilidad y alarmas)

## Contexto
El Módulo 11 evaluó la disponibilidad (HA) y la recuperación ante desastres
(DR) de la plataforma con pruebas reales, no solo con teoría. En el paso 11.1
se fijaron objetivos de negocio para la cobranza de préstamos:

- **RPO 5 min:** perder como máximo 5 minutos de pagos registrados.
- **RTO 1 h:** volver a atender en menos de una hora.

Antes del módulo, la plataforma tenía tres debilidades conocidas: RDS en una
sola AZ, `DeletionPolicy: Delete` en la instancia (borrar el stack `02-rds`
borraba también los backups automáticos) y ninguna copia fuera de la región.

### Resultados medidos
| Escenario | Medición | Evidencia |
|---|---|---|
| Corrupción de datos → restore PITR a una instancia nueva | RPO 4 min 26 s · RTO 28 min 40 s (solo la base, sin reconectar la app) | `module-11-pitr-drill.txt` |
| Convertir a Multi-AZ / volver a Single-AZ | 11 min 22 s / 5 min 10 s, **sin corte** en ninguno de los dos | `module-11-multiaz-e2e.txt` |
| Muerte de la única instancia EC2 (Desired 1) | **RTO 2 min 50 s** visto por el cliente = 81 s de detección del ASG + 94 s de arranque hasta el primer 200 | `module-11-multiaz-e2e.txt` |
| Failover forzado de RDS Multi-AZ | **≤ 15 s** de errores visibles, 2 peticiones fallidas; RDS registró ~49 s; la app se recuperó sola | `module-11-multiaz-e2e.txt` |
| Copia de snapshot a us-west-2 | Snapshot 3 min 34 s + copia 1 min 37 s; cifrada con la clave `aws/rds` de la región destino | `module-11-cross-region-snapshot.txt` |

Además se verificó que el plan Free de la cuenta **permite** Multi-AZ y la
copia de snapshots entre regiones. Las dos eran dudas abiertas.

## Decisión
1. **RDS sigue en Single-AZ de forma permanente.** Multi-AZ queda disponible
   con el parámetro `EnableMultiAz` de `02-rds.yaml` (default `"false"`), y
   solo se activa para pruebas, con un change set revisado. Activarlo de forma
   permanente duplica el costo de la instancia (0.018 → 0.036 USD/h en Ohio
   para `db.t3.micro`, unos +13 USD/mes).
2. **Protección contra borrado en capas:** `DeletionProtection: true`,
   `DeletionPolicy: Snapshot` y `UpdateReplacePolicy: Snapshot` en la
   instancia. `DBInstanceIdentifier` fijo, que además hace que CloudFormation
   rechace cualquier reemplazo. `BackupRetentionPeriod: 1`, el máximo que
   acepta el plan.
3. **La recuperación ante corrupción de datos es el PITR** a una instancia
   nueva (ensayado en 11.2). El restore nunca sobrescribe la original.
4. **El cómputo sigue en `DesiredCapacity: 1`** por costo, con el RTO medido
   de unos 3 minutos ante la muerte de la instancia. La configuración
   recomendada para producción es `Desired 2`, una instancia por AZ.
5. **`/health` es superficial a propósito:** no consulta la base. El ASG usa
   `HealthCheckType: ELB`. Un health check que dependiera de RDS haría que
   una caída de la base marcara **todas** las instancias como unhealthy, y
   el ASG las reemplazaría en cascada. Además, con `UnhealthyThreshold 3 × 15 s`
   (45 s), el ALB ni siquiera alcanzaría a reaccionar ante un failover de
   unos 15 s. Las dependencias se vigilan con alarmas (ADR-0014), no con el
   health check.
6. **El DR regional es Backup & Restore con copia manual de snapshot,
   sin ensayar.** Se demostró que la copia funciona. El restore en la región
   de DR **no** se ensayó, y la copia **no** está programada.

## Alternativas consideradas
- **Multi-AZ permanente:** descartado por costo. Es la mejora de mayor valor
  para producción: llevó la caída de la base de minutos (restore) a segundos
  (failover).
- **`Desired 2` en el ASG:** descartado por costo (el doble en EC2). Con
  Multi-AZ, el cómputo pasa a ser el eslabón débil: 2 min 50 s frente a
  unos 15 s de la base.
- **Replicación automática de backups entre regiones:** daría PITR en la región
  de DR (RPO de minutos). Queda como mejora futura; no se verificó si el plan
  la permite.
- **Read replica en otra región (Pilot Light):** RPO de segundos y RTO de
  decenas de minutos, pero con una segunda instancia siempre encendida.
  Desproporcionado para el presupuesto.
- **AWS Backup con regla de copia entre regiones:** automatizaría la decisión 6
  con una política y retención declaradas. Mejora futura.
- **Health check profundo (`/health` consultando RDS):** descartado por el
  riesgo de cascada descrito en la decisión 5.

## Consecuencias
### Objetivos frente a la realidad
| Fallo | ¿Cumple RPO 5 min / RTO 1 h? |
|---|---|
| Muerte de una instancia EC2 | Sí: RTO ~3 min, sin pérdida de datos |
| Corrupción de datos | RPO en el límite (4-8 min de atraso observado en el PITR). RTO probable dentro de 1 h, pero **no medido de punta a punta**: falta reconectar la app al endpoint nuevo (`DB_HOST` + Instance Refresh) |
| Caída de la AZ de la base | Igual que la fila anterior (restore PITR en la otra AZ). Con Multi-AZ activado: segundos |
| Caída de la región | **No cumple.** RPO = antigüedad de la última copia manual (sin límite si no se programa). RTO estimado en **horas**: en us-west-2 no existen la red, la imagen de ECR, los parámetros de SSM, los exports ni los IDs regionales (AMI, prefix list de CloudFront) |

Se acepta conscientemente que el DR regional no cumpla los objetivos: es un
proyecto de estudio con presupuesto de Free plan. Documentarlo así es
preferible a declarar un Pilot Light que no existe.

### Otros efectos
- Se cierra el punto abierto de ADR-0003: el failover Multi-AZ se probó de
  verdad, como una excepción corta y deliberada (~77 min, unos 0.02 USD).
- Al revertir Multi-AZ después del failover, la base pasó de `us-east-2b` a
  `us-east-2a` (RDS conserva la primaria activa). La plantilla no fija
  `AvailabilityZone`, así que no hubo conflicto. El bastión también está en 2a.
- Los cambios de `MultiAZ` producen `Replacement: Conditional` en el change
  set. Regla establecida: ejecutarlos solo después de revisar las redes de
  seguridad de la decisión 2.
- El RTO se mide desde el cliente con una sonda externa. Los eventos del
  proveedor (RDS) no reflejan lo que vio el usuario: 49 s registrados frente a
  ~15 s de errores reales.

### Deuda registrada
- Ensayar el restore en us-west-2 y medir el RTO regional real.
- Programar la copia entre regiones (AWS Backup) o activar la replicación
  automática de backups.
- Replicar la imagen de ECR y los parámetros de SSM a la región de DR, y
  parametrizar los IDs regionales en las plantillas.
- Medir de punta a punta el RTO del PITR, incluida la reconexión de la app.
- Reducir el hueco de detección del ASG (81 s) y probar `Desired 2`.
