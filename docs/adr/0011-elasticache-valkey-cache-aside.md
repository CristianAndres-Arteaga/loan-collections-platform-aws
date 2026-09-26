# ADR-0011: ElastiCache Valkey (cache.t4g.micro) con patrón cache-aside y clave por fecha para las cuotas vencidas

## Estado
Aceptado

Fecha: 2026-09-24

## Contexto
El Módulo 7 incorpora una capa de caché en memoria delante de RDS
PostgreSQL. El candidato natural es `GET /installments/?overdue=true`: es la
consulta que más usan cobradores y supervisores, filtra por fecha y por estado
sobre la tabla de cuotas completa, y su resultado es el mismo para todos los
usuarios durante el día.

Siguiendo la lección de proceso del ADR-0010, el costo se verificó con datos
reales antes de diseñar nada, en lugar de asumir precios o coberturas del
Free Tier.

### Evidencia de precios (2026-09-24)
Obtenida con `aws pricing get-products` (endpoint `us-east-1`, filtro
`location = "US East (Ohio)"`), quedándonos solo con los términos
**On-Demand** (los precios Reserved requieren un compromiso de 1 o 3 años y
no aplican a un recurso que se enciende unas horas para pruebas):

| Nodo | Motor | USD/hora |
|---|---|---|
| cache.t4g.micro | **Valkey** | **0.0128** |
| cache.t3.micro | Valkey | 0.0136 |
| cache.t4g.micro | Redis OSS / Memcached | 0.016 |
| cache.t3.micro | Redis OSS / Memcached | 0.017 |

La consulta también devolvió filas de **Extended Support** solo para Redis
OSS (0.013 a 0.027 USD/h adicionales por nodo). Es un recargo que AWS aplica
automáticamente cuando la versión mayor del motor supera su soporte estándar,
y se suma al precio del nodo.

## Decisión

### 1. Motor y tamaño: Valkey en `cache.t4g.micro`, un solo nodo
- **Valkey sobre Redis OSS**: es un fork de Redis OSS 7.2 compatible a nivel
  de protocolo (el cliente `redis-py` funciona sin cambios) y cuesta un 20%
  menos por hora de nodo en el mismo tamaño.
- **Valkey/Redis sobre Memcached**: Memcached no tiene replicación, failover
  Multi-AZ ni persistencia. Si en el futuro se agrega una réplica, solo el
  primero lo permite.
- **Graviton (`t4g`) sobre Intel (`t3`)**: menor precio por el mismo rol.
- **Un solo nodo**, sin réplica, igual que la decisión de RDS single-AZ del
  ADR-0003. Con cache-aside, perder la caché no pierde datos porque la fuente
  de verdad es PostgreSQL. Lo que se pierde es rendimiento hasta que la caché
  se vuelve a llenar. Primario + réplica en otra AZ duplica las horas de nodo
  y queda documentado como la configuración de producción.

### 2. Costo y control de encendido
- ~0.04 USD por una prueba de 3 h con un nodo, y ~8.30 USD si quedara
  encendido 24/7 hasta el vencimiento del plan (2026-10-21), frente a
  122.82 USD de créditos.
- Se mantiene el patrón de interruptor: parámetro **`CreateCache`, por
  defecto `false`**, igual que `CreateNatGateways`, `CreateEcrEndpoints` y
  `CreateAlb`. El riesgo real no es el precio sino olvidarlo encendido.

### 3. Patrón de acceso: cache-aside + invalidación en escritura
| Aspecto | Decisión |
|---|---|
| Lectura | Cache-aside: `GET` en la caché; si falla (MISS), consultar PostgreSQL y guardar el resultado con `SET ... EX <TTL>` |
| Clave | `installments:overdue:v1:{YYYY-MM-DD}` |
| Valor | JSON serializado de `list[InstallmentRead]` |
| TTL | 300 segundos |
| Invalidación | `DELETE` de la clave del día en `registrar_pago`, **después** de `db.commit()` |
| Caché no disponible | Fallar abierto hacia PostgreSQL, con `socket_timeout` de ~0.3 s y un warning en el log |

Justificación de cada punto:

- **Fecha dentro de la clave.** La consulta filtra por
  `due_date < date.today()`, así que el resultado correcto cambia a
  medianoche aunque nadie modifique la base de datos. Con la fecha en la
  clave, el día nuevo busca una clave distinta y nunca reutiliza la respuesta
  del día anterior. La corrección no depende del TTL.
- **La fecha se calcula una sola vez por petición** (`hoy = date.today()`) y
  se usa tanto para la clave como para la consulta. Si se calculara dos
  veces y la medianoche cayera entre ambas llamadas, se guardarían datos de
  un día bajo la clave del otro.
- **El TTL cumple dos roles:**
  1. *Limpieza*: las claves de días anteriores expiran solas y no se
     acumulan en memoria.
  2. *Límite de datos viejos*: si el commit de un pago funciona pero el
     `DELETE` en la caché falla (red, caché caída), la clave del día queda
     desactualizada y lo único que acota el error es el TTL. Por eso es corto
     (5 min) y no de 24 h.
- **Invalidar después del commit y no antes.** Si se borrara antes y el
  commit fallara, otra petición podría volver a llenar la caché en el
  intervalo y la invalidación no serviría para nada. Borrar después garantiza
  que la próxima lectura vea el estado ya confirmado.
- **Por qué importa la invalidación en este dominio.** Sin ella, una cuota
  recién pagada seguiría apareciendo como vencida y otro cobrador podría
  llamar a un cliente que ya pagó. En cobranzas eso es una queja o un
  reclamo regulatorio, no solo un dato viejo.
- **Fallar abierto con timeout corto.** La caché es una optimización, no una
  dependencia. Si no responde (por ejemplo, con `CreateCache=false`), el
  endpoint debe seguir funcionando contra PostgreSQL. Sin un timeout corto,
  cada petición esperaría el timeout por defecto del cliente (varios
  segundos) antes de caer a la base de datos: técnicamente funcionaría, pero
  para el usuario estaría caído.

## Alternativas consideradas
- **Redis OSS**: descartado. Tiene la misma funcionalidad para este caso, es
  un 20% más caro y está expuesto a recargos de Extended Support en versiones
  viejas.
- **Memcached**: descartado. No tiene replicación ni failover.
- **ElastiCache Serverless**: no evaluado con datos en este módulo. Cobra
  almacenamiento mínimo y cómputo por petición, y encaja mejor con cargas
  impredecibles que con pruebas cortas y controladas.
- **Write-through** (escribir en la caché en cada escritura a la base de
  datos): descartado. La respuesta cacheada es una lista agregada que habría
  que recalcular completa en cada pago. Invalidar es más simple y el
  siguiente `GET` la reconstruye.
- **Clave sin fecha y TTL de 24 h**: descartado. Una entrada creada a las
  23:55 serviría la lista del día anterior durante casi todo el día
  siguiente. Un TTL corto reduce ese error, pero no lo elimina.
- **Réplica Multi-AZ desde el inicio**: descartado por costo en un entorno
  de pruebas. Queda como configuración de producción.

## Consecuencias
- La caché queda en la ruta de lectura del endpoint más usado, pero su
  ausencia no rompe la aplicación. Se puede desplegar y probar el código con
  `CreateCache=false`, que siempre usa PostgreSQL.
- Toda nueva escritura que cambie `status` o `due_date` de una cuota debe
  invalidar la clave del día. Hoy la única es `registrar_pago`; cualquier
  endpoint futuro que olvide hacerlo servirá datos viejos hasta por 5 min.
- Con un solo nodo, un reinicio o fallo del nodo vacía la caché y todas las
  peticiones van a PostgreSQL hasta que se vuelva a llenar.
- **Deuda detectada (no de la caché):** `date.today()` usa la zona horaria
  del contenedor, que es casi seguro UTC. Para clientes en UTC-5 las cuotas
  empiezan a figurar como vencidas a las 19:00 del día anterior en hora
  local. Es un error de negocio preexistente que la clave por fecha hizo
  visible. Se registra como deuda y no se resuelve en este módulo.
- La infraestructura concreta (red, seguridad, descubrimiento del endpoint)
  y las lecciones de la implementación se documentan en la adenda siguiente.

## Adenda: infraestructura e implementación (2026-09-25)

Implementado en `infrastructure/07-cache.yaml` (stack
`loan-collections-cache`), con cambios en `03-security.yaml` (IAM) y
`05-compute.yaml` (user-data). Validado end-to-end en AWS; la evidencia está
en `docs/evidence/module-07-cache-e2e.txt`.

### Red y seguridad
| Aspecto | Implementación | Motivo |
|---|---|---|
| Subredes | Subnet group en las **subredes de datos** 1a/1b (las mismas de RDS) | No tienen ruta a internet en su tabla de rutas. Una caché no necesita salir a internet ni ser alcanzable desde él. |
| Security Group | Entrada TCP 6379 **solo desde el SG de las EC2 de la app** (referencia a SG, no CIDR) | Si cambian las IPs de las instancias o el ASG escala, la regla sigue siendo correcta. Nada más en la VPC puede hablar con la caché. |
| Cifrado en reposo | `AtRestEncryptionEnabled: true` (clave administrada por AWS) | Sin costo adicional. |
| Cifrado en tránsito | `TransitEncryptionEnabled: true`; el cliente usa `ssl=True` (`CACHE_TLS`, por defecto `true`) | El tráfico entre la app y la caché va cifrado aunque esté dentro de la VPC. Con TLS activo, un cliente sin TLS no conecta. |
| Motor | Valkey 9.1, 1 nodo, sin failover automático ni Multi-AZ | Ver sección 1 de la Decisión. |
| Snapshots | `SnapshotRetentionLimit: 0` | La caché es descartable: PostgreSQL es la fuente de verdad. Respaldarla solo agrega costo de almacenamiento. |

### Descubrimiento del endpoint
- El endpoint se publica en el parámetro SSM
  **`/loan-collections/cache-endpoint`** (tipo `String`, no es un secreto).
  Con `CreateCache=true` vale la dirección del primario; con `false` vale
  `disabled`.
- **El parámetro es incondicional a propósito.** El user-data corre con
  `set -e` y lee el parámetro al arrancar: si no existiera, la instancia
  fallaría en el arranque y el ASG entraría en un ciclo de reemplazos. El
  comentario en la plantilla lo advierte para que nadie le agregue una
  `Condition`.
- Con `CACHE_HOST=disabled` la app no crea el cliente: cero conexiones y
  cero timeouts, directo a PostgreSQL.
- El rol de las EC2 recibe `ssm:GetParameter` solo sobre los ARN exactos de
  `db-password` y `cache-endpoint` (política `SsmParameterReadAppConfig`),
  sin comodines.
- El endpoint **no se exporta** con `Export`. Si `05-compute` importara un
  export de `07-cache`, CloudFormation bloquearía apagar la caché mientras el
  export esté en uso (el mismo candado que se vio con el target group en el
  ADR-0010). SSM desacopla ambos stacks.
- **Consecuencia operativa:** la instancia lee el endpoint **una sola vez,
  al arrancar**. Por eso el orden de encendido es
  endpoints de ECR → caché → ALB → ASG, y se apaga en orden inverso. Si se
  enciende la caché con instancias ya corriendo, estas siguen con `disabled`
  hasta ser reemplazadas. Si se apaga con instancias corriendo, estas fallan
  abierto hacia PostgreSQL.

### Lecciones de la implementación
- **Reintentos por defecto de `redis-py` 8.1.0.** Con la caché caída, el
  cliente reintenta 10 veces con backoff exponencial con jitter (~2.7 s por
  operación). La prueba local de "fallar abierto" tardó **9.8 s** por
  petición: funcionaba, pero para el usuario la app estaba caída. Se
  corrigió con `retry=Retry(NoBackoff(), 0)`. Medición en caliente con la
  caché caída: 0.415 s, frente a 0.407 s sin caché. Lección: un timeout
  corto no alcanza si la librería reintenta por su cuenta; hay que medir la
  ruta de fallo, no solo configurarla.
- **Error transitorio de ElastiCache.** El primer intento de crear la caché
  falló con `GeneralServiceException` (HTTP 408) y el stack quedó en
  `UPDATE_ROLLBACK_COMPLETE`. El reintento sin cambios funcionó. Con el
  patrón de interruptor, reintentar es un `deploy` más; siempre hay que leer
  los eventos del stack antes de cambiar la plantilla.
- **`cloudformation deploy` conserva los valores anteriores de los
  parámetros.** Cambiar el `Default` de `ImageTag` en la plantilla no cambia
  un stack existente (respondió *No changes to deploy*): el `Default` solo
  aplica al crear. Los valores (`ImageTag` y los interruptores) se pasan
  siempre con `--parameter-overrides` y se verifica el estado real después
  del deploy.

### Resultado de la prueba end-to-end (2026-09-25)
6/6 pasos correctos vía ALB: health 200 → `MISS` → `HIT` → `POST` de pago
201 → `MISS` (invalidación) → `HIT`. Limitaciones de la prueba:
- La lista de vencidas estaba vacía (`[]`): prueba el **mecanismo**
  (llenado, lectura e invalidación), no la mejora de rendimiento.
- Los tiempos (MISS 0.467 s, HIT 0.413 s) están dominados por la latencia
  de la red entre el cliente y Ohio, no por la consulta.
- La deuda de zona horaria se vio en vivo: la clave del contenedor era del
  día 25 mientras en hora local todavía era el 24.

### Deuda técnica registrada
- **Sin autenticación en Valkey** (ni `AuthToken` ni usuarios RBAC). Hoy la
  mitiga el Security Group, que solo admite a las EC2 de la app. Para
  producción, usar RBAC de ElastiCache con un usuario de permisos mínimos.
- **Un solo nodo:** ver Consecuencias.
- **Logging sin configurar:** los warnings de la caché salen sin nivel ni
  marca de tiempo (handler de último recurso de `logging`). Se resuelve en
  el módulo de observabilidad.
- **Zona horaria UTC en `date.today()`:** ver Consecuencias.
