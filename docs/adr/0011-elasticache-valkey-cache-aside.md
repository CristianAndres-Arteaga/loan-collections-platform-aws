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
- **Pendiente para el paso de infraestructura (Paso 7.3):** ubicación en
  subredes privadas, Security Group con entrada 6379 solo desde el SG de las
  EC2, y cifrado en tránsito y en reposo. Se documentarán al implementarlos.
