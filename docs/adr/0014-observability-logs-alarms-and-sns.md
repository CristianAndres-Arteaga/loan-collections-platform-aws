# ADR-0014: Observabilidad con CloudWatch Logs, alarmas y alertas por email (SNS)

## Estado
Aceptado

Fecha: 2026-09-27

## Contexto
Hasta el Módulo 8, la única forma de saber si la API funcionaba era hacer `curl`
a mano. Había tres problemas concretos:

1. **Logs sin formato ni destino.** La app escribía warnings sin nivel ni fecha
   (deuda del Módulo 7). El contenedor usaba el driver por defecto de Docker
   (`json-file`), así que los logs vivían en el disco de la instancia y **se
   perdían** cuando el ASG la reemplazaba. El rol de EC2 tenía
   `logs:PutLogEvents` sobre `/loan-collections/*` desde el Módulo 3, pero nada
   lo usaba.
2. **Fecha de negocio en UTC.** `date.today()` usaba el reloj del contenedor
   (UTC). En Bolivia (UTC-4), entre las 20:00 y las 24:00 la app ya calculaba
   las cuotas vencidas con la fecha del día siguiente.
3. **Sin alertas.** Una caída de la app, de las instancias o de la base de
   datos solo se descubría probando.

## Decisión

### 1. Logs estructurados en la app
- `app/core/logging_config.py`: una línea **JSON** por evento hacia **stdout**,
  con `timestamp` (UTC, milisegundos), `level`, `logger` y `message`. Los
  loggers de uvicorn se redirigen al mismo formato.
- stdout y no un archivo: la app no decide el destino de sus logs (factor XI de
  Twelve-Factor). Lo decide el runtime.
- Los logs van en **UTC**, que es el estándar para correlacionar eventos. La
  fecha de negocio va en la zona del negocio (punto 2).
- uvicorn usa el logger `uvicorn.error` también para mensajes INFO. Las
  consultas y alarmas filtran por `level`, nunca por el nombre del logger.

### 2. Fecha de negocio configurable
- `business_timezone` (por defecto `America/La_Paz`, UTC-4 sin horario de
  verano) y `_hoy()` con `ZoneInfo`. Se agrega `tzdata` a `requirements.txt`
  para no depender de los archivos de zona de la imagen `slim`.
- En AWS entra como variable `BUSINESS_TIMEZONE` desde el parámetro
  `BusinessTimezone` de `05-compute.yaml`, sin reconstruir la imagen.

### 3. Envío de logs a CloudWatch Logs
- `docker run --log-driver awslogs`, con el stream igual al **instance ID**
  (leído con IMDSv2).
- **`mode=non-blocking`, `max-buffer-size=4m`**: si CloudWatch no responde, la
  app no se traba al escribir; en el peor caso se pierden líneas. Es el mismo
  criterio *fail-open* de la caché (ADR-0011).
- **Log group creado en IaC** (`/loan-collections/app`, `RetentionInDays: 7`).
  Si Docker lo creara, quedaría con retención infinita.
- **Interface endpoint `logs`** en `01-vpc.yaml`, bajo `CreateEcrEndpoints`.
  Sin NAT, un permiso IAM no alcanza: hace falta un camino de red (igual que
  COMP-07 y ECR-06).

### 4. Alertas: SNS + alarmas

| Alarma | Métrica | Umbral | Dónde vive |
|---|---|---|---|
| `app-errors` | Metric filter `{ ($.level = "ERROR") \|\| ($.level = "CRITICAL") }` → `LoanCollections/App AppErrorCount` | > 0 en 1 min | `08-monitoring.yaml` |
| `rds-cpu-high` | `AWS/RDS CPUUtilization` | > 80% durante 15 min | `08-monitoring.yaml` |
| `alb-unhealthy-hosts` | `UnHealthyHostCount` | > 0 durante 5 min | `06-alb.yaml` |
| `alb-no-healthy-hosts` | `HealthyHostCount` | < 1 durante 5 min, **sin datos = alarma** | `06-alb.yaml` |
| `alb-target-5xx` | `HTTPCode_Target_5XX_Count` | > 5 en 5 min | `06-alb.yaml` |
| `alb-elb-5xx` | `HTTPCode_ELB_5XX_Count` | > 5 en 5 min | `06-alb.yaml` |

- Un stack nuevo, `08-monitoring.yaml`, contiene el topic `loan-collections-alerts`,
  la suscripción de email, el metric filter y las alarmas que no dependen del
  ALB. Exporta el ARN del topic.
- **Las alarmas del ALB viven en `06-alb.yaml` bajo `AlbEnabled`.** El nombre
  que usa CloudWatch para el ALB (`app/loan-collections-alb/<sufijo>`) cambia
  cada vez que se recrea. Una alarma con el nombre fijo quedaría mirando un ALB
  inexistente, en `INSUFFICIENT_DATA`, sin sonar nunca. Además se evita el
  bloqueo de exports condicionales (ALB-05, ADR-0013).
- **`alb-unhealthy-hosts` exige 5 minutos seguidos**, alineados a
  `HealthCheckGracePeriod: 300`. Con 1 minuto, cada arranque de instancia
  (hasta ~4 min unhealthy) generaría un email falso (fatiga de alarmas).
- Todas notifican en `ALARM` y también en `OK`.
- El email se pasa como parámetro `AlertEmail` al desplegar; no está en el repo.

### 5. Topic de SNS sin cifrar, a propósito
Con la clave administrada `aws/sns`, CloudWatch no puede publicar en el topic,
porque la key policy no le da permiso, y las alarmas fallarían sin avisar. La
alternativa correcta es una CMK propia (~1 USD/mes) con permiso para
`cloudwatch.amazonaws.com`. Los mensajes solo dicen qué alarma cambió de
estado, sin datos de clientes, así que se acepta el topic sin cifrar.

### 6. Suscripción de email con baja autenticada
La suscripción se confirmó con
`aws sns confirm-subscription --authenticate-on-unsubscribe true`
(`ConfirmationWasAuthenticated: true`). Así, el link "unsubscribe" de los
emails ya no puede borrarla; darla de baja exige credenciales de AWS.

### 7. `MinSize` igual a `DesiredCapacity`
`05-compute.yaml` pasa de `MinSize: "0"` a `MinSize: !Ref DesiredCapacity`.
Encendido significa al menos 1 instancia (el target tracking puede subir a 2 y
volver a 1); apagado sigue siendo 0/0.

## Incidentes encontrados durante el módulo
Detalle en `docs/evidence/module-09-observability-e2e.txt`.

- **El ASG se quedó en 0 instancias (bug desde el Módulo 5).** La política de
  target tracking por CPU (60%) crea una alarma `AlarmLow`. Con la API sin carga,
  a los ~15 minutos esa alarma bajó la capacidad deseada de 1 a 0, y
  `MinSize: 0` lo permitió. Habría pasado en cualquier prueba de más de ~15
  minutos; los E2E anteriores fueron más cortos. Corregido con la decisión 7.
- **OK falso con el servicio caído.** Con cero instancias, `UnHealthyHostCount`
  es 0 y la alarma pasó a `OK` mientras CloudFront devolvía 503. Se agregó
  `alb-no-healthy-hosts` con `TreatMissingData: breaching`.
- **Punto ciego de los 5xx.** Con la app detenida, el ALB devolvió 502 (fail-open
  hacia un puerto cerrado). Ese 502 cuenta en `HTTPCode_ELB_5XX_Count`, no en
  `HTTPCode_Target_5XX_Count`. Se agregó `alb-elb-5xx`.
- **La suscripción de email se borró dos veces sin intervención del usuario.**
  El email de OK llegó a las 21:52:51 UTC y a las 21:53:40 la suscripción ya
  figuraba como `Deleted`; volvió a pasar tras una confirmación con clic
  normal. Causa muy probable: un escáner automático de links que abre el
  "unsubscribe". No se pudo comprobar. Corregido con la decisión 6.
- **Timestamp mal generado en la prueba sintética.** `date +%s%3N` imprime 19
  dígitos en este Ubuntu y CloudWatch rechazó el evento
  (`tooNewLogEventStartIndex`). Se usa `$(date +%s)000`.
- **Escaneo de ECR "inexistente".** `imageScanStatus` apareció como `None`
  justo después del push; un `start-image-scan` manual devolvió
  `LimitExceededException`, es decir, el escaneo on push sí existía
  (consistencia eventual). Resultado: los 2 HIGH ya aceptados (ADR-0008,
  ADR-0012), 0 MEDIUM y 0 LOW con la base nueva.

## Medidas obtenidas
- **Ventana ciega:** ~30–45 s de 502 antes de que el ALB marque el target
  unhealthy (3 checks × 15 s).
- **Tiempo de detección (MTTD):** ~8 min desde la caída hasta el email de ALARM.
- **Auto-reparación:** el ASG reemplazó la instancia 7 s después de reactivar
  `ReplaceUnhealthy`; la nueva estuvo healthy en ~1.5–2 min.

## Alternativas consideradas
- **CloudWatch Agent** (memoria y disco, que EC2 no publica por defecto):
  pospuesto. Suma configuración en el `user-data` y la app aún no tiene
  problemas de memoria que medir.
- **AWS X-Ray / OpenTelemetry** (trazas): fuera de alcance para un único
  servicio sin llamadas entre servicios.
- **Métricas de grupo del ASG** (`GroupInServiceInstances`): válidas para
  detectar cero instancias, pero hay que activarlas. `HealthyHostCount` del ALB
  ya está disponible y mide lo que importa: instancias que responden.
- **CMK propia para cifrar SNS**: descartada por costo (decisión 5).
- **Rotar logs a S3 para archivo largo**: innecesario; los logs no son un
  archivo histórico en este proyecto.

## Consecuencias
- Los logs sobreviven al reemplazo de instancias y se consultan con Logs
  Insights sin configurar campos, porque vienen en JSON.
- Seis alarmas; las cuatro del ALB se crean y se borran con él.
- **Ruido esperado en cada encendido de prueba:** el ALB existe varios minutos
  antes que la instancia (mientras se crea CloudFront), así que
  `alb-no-healthy-hosts` envía ALARM y luego OK. También puede enviar ALARM
  durante el apagado. En producción el ALB siempre tiene instancias.
- `alb-target-5xx`, `alb-elb-5xx` y `rds-cpu-high` no se vieron en ALARM
  durante las pruebas.
- **Drift en CloudFormation:** la suscripción se confirmó con la CLI, fuera de
  la plantilla; el atributo de baja autenticada no está declarado en IaC.
- La imagen `1de2957` tiene `America/Bogota` como valor por defecto en el
  código. En AWS no importa, porque la variable de entorno manda; el valor
  correcto entra en la próxima imagen.
- El único canal de alerta es el email; en un equipo real se sumaría un canal
  de chat o una herramienta de guardias.
