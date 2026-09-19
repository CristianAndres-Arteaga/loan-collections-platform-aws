# ADR-0007: Contenedor sin privilegios y base de imagen actualizada

## Estado
Aceptado

Fecha: 2026-09-18

Reemplaza a: ADR-0006

## Contexto
El ADR-0006 aceptó de forma temporal 6 vulnerabilidades CRITICAL (5 en `perl`,
1 en `glibc`) en la imagen `loan-collections-api:9668233`, construida sobre
`python:3.14-slim@sha256:cad9a2c8...`. Su condición de revisión exigía volver a
comparar el digest de la base y volver a escanear antes de desplegar.

Durante la revisión de cierre del Módulo 4 aparecieron dos hechos nuevos:

1. El `Dockerfile` no definía `USER`, por lo que la aplicación corría como root
   dentro del contenedor. Ante una vulnerabilidad explotable en la API, un
   atacante heredaría privilegios de root dentro del contenedor.
2. Al reconstruir la imagen para corregirlo, `python:3.14-slim` resolvió a un
   digest distinto (`sha256:ef30e8ee...`, antes `cad9a2c8...`). El tag de la
   base había avanzado a una versión más nueva.

La imagen nueva, `loan-collections-api:cae670a` (manifiesto
`sha256:9a7f61da...`), se escaneó con ECR y reportó únicamente 1 hallazgo HIGH
(en `zlib`): 0 CRITICAL, 0 MEDIUM, 0 LOW. La imagen anterior tenía 6 CRITICAL,
13 HIGH, 6 MEDIUM y 2 LOW. El `USER` agregado no explica la mejora: crear un
usuario no cambia paquetes del sistema. Atribuimos el cambio a la base
actualizada; no se contrastó el historial del tag, por lo que es una inferencia.

## Decisión
- La imagen de referencia pasa a ser `loan-collections-api:cae670a`. Se construyó
  sobre el commit `cae670a` con el árbol de trabajo limpio y corre como
  `appuser` (uid 1000), creado con `useradd` y activado con `USER` después de
  `pip install` y `COPY`, y antes de `CMD`. Se verificó que `id` devuelve
  `uid=1000(appuser)` y que `GET /health` responde con ese usuario. El puerto
  8080 no requiere privilegios.
- La imagen `9668233` (root, 6 CRITICAL) se elimina de ECR. Ninguna instancia la
  usa, y conservarla dejaba disponible por error una imagen con privilegios
  excesivos y vulnerabilidades críticas para un futuro launch template.
- El hallazgo HIGH residual en `zlib` se acepta de forma temporal, con la misma
  condición de revisión del ADR-0006: antes de que el launch template del
  Módulo 5 referencie la imagen, se consulta la ficha del CVE (corrección
  disponible, alcanzabilidad desde la aplicación), se reconstruye con
  `docker build --pull` y se vuelve a escanear.

## Alternativas consideradas
- Conservar `9668233` hasta que la lifecycle policy la retire: descartado —
  mantiene una imagen root y con hallazgos críticos disponible sin beneficio,
  porque nada depende de ella.
- Cambiar a Alpine o distroless para eliminar el hallazgo residual: no
  evaluada. No se justifica mientras la base actual reporte un solo hallazgo
  HIGH; se reevalúa si la revisión previa al Módulo 5 lo requiere.
- Fijar el digest de la base en el `FROM` para reproducibilidad: no decidida.
  Daría builds idénticos, pero dejaría de incorporar parches automáticamente y
  exigiría actualizar el digest a mano.

## Consecuencias
- El tag de una base flotante (`python:3.14-slim`) cambia con el tiempo: la misma
  línea `FROM` produjo resultados de seguridad muy distintos en pocas horas. Esto
  confirma la necesidad de reconstruir con regularidad y de escanear cada
  imagen; el pipeline del Módulo 10 debe hacerlo de forma automática.
- Como el escaneo reporta pero no bloquea, la compuerta que frena un despliegue
  con hallazgos CRITICAL sigue pendiente para el Módulo 10.
- Los tags inmutables funcionaron como se esperaba: la corrección de seguridad
  exigió un commit nuevo y un tag nuevo (`cae670a`), en lugar de sobrescribir
  `9668233`, y queda una relación directa entre cada imagen y su commit.
- Los números del escaneo original se conservan en el ADR-0006 y en este
  documento, porque la evidencia en ECR desaparece al borrar la imagen.
- Falta analizar la explotabilidad del CVE restante: no fue consultado todavía.
