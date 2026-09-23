# ADR-0008: Aceptación definitiva del hallazgo residual en zlib (CVE-2026-85091)

## Estado
Aceptado

Fecha: 2026-09-22

Relacionado con: ADR-0007 (cierra su condición de revisión pendiente)

## Contexto
El ADR-0007 aceptó de forma temporal el único hallazgo HIGH reportado en la
imagen `loan-collections-api:cae670a` (manifiesto `sha256:9a7f61da...`), con
una condición explícita de revisión antes de que el launch template del
Módulo 5 referenciara esa imagen: consultar la ficha del CVE, evaluar si es
alcanzable desde la aplicación, reconstruir con `docker build --pull` y volver
a escanear.

Esa revisión se realizó hoy:

- **Ficha del CVE**: CVE-2026-85091. Desbordamiento de heap en la función
  `gz_vacate()` de zlib (versiones 1.3.1.2 a 1.3.2), al llamar a `gzprintf()`
  o `gzvprintf()` sobre un descriptor abierto con `gzopen()` en modo no
  bloqueante, tras un "write stall". CVSS4 8.3 (HIGH). Paquete instalado en la
  imagen: `zlib 1.3.dfsg+really1.3.1-1` (paquete de Debian).
- **Alcanzabilidad**: FastAPI, Uvicorn, SQLAlchemy y psycopg2 no invocan en
  ningún punto la interfaz de archivos gzip de zlib (`gzopen`/`gzwrite`/
  `gzprintf`). Cuando Python usa `zlib`, lo hace a través de la interfaz de
  compresión en memoria (`zlib.compress`/`decompress`, deflate/inflate), que
  no pasa por la ruta vulnerable. El paquete está presente en el sistema
  operativo de la imagen, pero ningún proceso en ejecución llega a ese código.
- **Disponibilidad de parche**: se reconstruyó la imagen con
  `docker build --pull`. La base `python:3.14-slim` resolvió a un digest
  distinto al registrado en el ADR-0007 (`sha256:caaf356f...`, antes
  `sha256:ef30e8ee...`), pero el manifiesto de imagen resultante fue
  exactamente el mismo ya escaneado (`sha256:9a7f61da...`, idéntico byte a
  byte). Debian todavía no publicó un paquete `zlib` corregido; el cambio de
  digest de la base es metadata del manifiesto multi-arquitectura, no
  contenido nuevo.

## Decisión
Se acepta el hallazgo de forma permanente (ya no temporal, sujeta a un evento
puntual), reemplazada por una revisión periódica, por la combinación de:

1. Inalcanzable desde la ruta de ejecución real de la aplicación.
2. Sin parche disponible en la base actual, verificado en esta fecha.
3. Controles compensatorios ya presentes: el contenedor corre como `appuser`
   sin privilegios (ADR-0007); la instancia EC2 que lo ejecute en el Módulo 5
   vivirá en subred privada sin exposición directa a internet, y a partir del
   Módulo 6 quedará además detrás de un Application Load Balancer.

**Revisión periódica establecida**: reconstruir con `--pull` y volver a
escanear cada vez que la imagen se reconstruya por otro motivo (nueva
funcionalidad, actualización de dependencias), y como mínimo una vez antes
del cierre del proyecto (Módulo 12), para confirmar si ya existe parche.

La imagen `cae670a` (manifiesto `sha256:9a7f61da...`) queda confirmada como
la imagen de referencia para el launch template del Módulo 5. No se requiere
una nueva imagen ni un nuevo tag por este hallazgo.

## Alternativas consideradas
- **Migrar a Alpine o distroless** para eliminar el hallazgo: seguía sin
  evaluarse desde el ADR-0007. Se descarta abrir esa evaluación ahora porque
  el hallazgo no es explotable en este contexto — el costo de migrar de base
  (reconstruir la resolución de dependencias, validar compatibilidad de las
  librerías C que usa `psycopg2`, etc.) no se justifica por un hallazgo
  inalcanzable.
- **Fijar el digest de la base** (`FROM python:3.14-slim@sha256:...`) para
  que un futuro rebuild no introduzca hallazgos nuevos sin aviso: no
  decidida, se traslada como tema abierto para el Módulo 10 (pipeline
  CI/CD), donde el escaneo se automatiza y tendría sentido fijar también el
  digest base como parte del mismo control.

## Consecuencias
- Cierra formalmente el punto pendiente que dejó abierto el ADR-0007
  ("Falta analizar la explotabilidad del CVE restante").
- El launch template del Módulo 5 puede referenciar `cae670a` sin bloqueo de
  seguridad pendiente.
- Queda documentado un patrón repetible para futuras aceptaciones de riesgo
  en este proyecto: CVE exacto + alcanzabilidad real + disponibilidad de
  parche + controles compensatorios, no solo un conteo de severidad.
- El compromiso de revisión periódica depende de disciplina manual hasta que
  el Módulo 10 automatice el escaneo dentro del pipeline; sigue siendo una
  brecha de proceso real hasta entonces.
