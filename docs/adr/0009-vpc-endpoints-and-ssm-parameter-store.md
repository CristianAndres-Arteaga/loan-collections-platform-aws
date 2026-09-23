# ADR-0009: VPC Endpoints en vez de NAT Gateway + SSM Parameter Store para credenciales del Launch Template

## Estado
Aceptado

Fecha: 2026-09-22

## Contexto
El Módulo 5 necesitaba que las instancias EC2 del Auto Scaling Group,
ubicadas en subred privada, pudieran (1) hacer `docker pull` desde ECR y
(2) obtener la contraseña maestra de RDS sin exponerla en texto plano.
Dos decisiones de diseño, bajo la misma restricción de presupuesto cero de
todo el proyecto:

1. **Cómo alcanzar ECR/S3 (y luego SSM) desde subred privada**: NAT Gateway
   (ya usado en el Módulo 1) vs VPC Endpoints. Ninguna opción es gratis de
   dejar corriendo continuamente — un Interface Endpoint cobra por hora por
   AZ igual que un NAT Gateway, sin Free Tier en ningún caso.
2. **Cómo entregar la contraseña de RDS al contenedor**: el `user-data` de
   una instancia EC2 no es secreto — cualquier entidad IAM con
   `ec2:DescribeInstanceAttribute`, o el propio proceso dentro de la
   instancia vía IMDS sin autenticación adicional, puede leerlo completo.

## Decisión
- **VPC Endpoints sobre NAT Gateway**, agregados de forma condicional a
  `01-vpc.yaml` (parámetro `CreateEcrEndpoints`, mismo patrón de interruptor
  que `CreateNatGateways`): tres Interface Endpoints para ECR
  (`ecr.api`, `ecr.dkr`) y tres más para SSM Session Manager
  (`ssm`, `ssmmessages`, `ec2messages`), más un Gateway Endpoint gratuito
  para S3 (donde viven las capas de las imágenes). Elegido sobre NAT porque
  la instancia solo necesita alcanzar servicios de AWS puntuales, nunca
  internet en general — ruta de red más estrecha posible, mismo principio de
  menor privilegio aplicado a red en vez de IAM.
- **SSM Parameter Store `SecureString`** (clave `aws/ssm` administrada, sin
  costo en el tier estándar) sobre Secrets Manager (~$0.40/mes por secreto)
  para la contraseña de RDS. Se agregó una política IAM `ssm:GetParameter`
  al `EC2AppRole` de `03-security.yaml`, con el `Resource` acotado a la ARN
  exacta del parámetro `/loan-collections/db-password`, no a todo el árbol
  de parámetros de la cuenta.

## Incidente durante la implementación
La primera instancia de prueba del ASG terminó con `docker ps` completamente
vacío, ni un contenedor detenido. Diagnóstico vía
`/var/log/cloud-init-output.log`: el `user-data` instaló Docker
correctamente (`Complete!`, symlink de `docker.service` creado sin errores),
pero el siguiente comando del script — `aws ssm get-parameter` para leer la
contraseña, el primero en llamar a un servicio AWS antes incluso del login a
ECR — falló con `Connect timeout on endpoint URL:
"https://ssm.us-east-2.amazonaws.com/"`. Causa raíz: los Interface Endpoints
de SSM se crearon en una **segunda** actualización de `01-vpc.yaml`,
*después* de que esta instancia ya estuviera corriendo con la primera
versión (que solo tenía `ecr.api`/`ecr.dkr`/`s3`). `set -e` abortó el script
ahí mismo, así que nunca llegó a `docker login`/`pull`/`run`.

Solución: `aws autoscaling terminate-instance-in-auto-scaling-group
--no-should-decrement-desired-capacity` sobre la instancia afectada — el ASG
lanzó una instancia nueva, esta vez con los endpoints de SSM ya disponibles
desde el arranque. Verificado end-to-end: `docker ps` mostró el contenedor
corriendo, `curl localhost:8080/health` respondió `{"status":"ok"}`, y una
consulta real contra RDS (`/installments/?overdue=true`) devolvió `[]` sin
error, confirmando que la contraseña leída desde Parameter Store era
correcta.

**Nota lateral útil**: `dnf install -y docker` sí funcionó desde el primer
momento, sin NAT y sin endpoint de ECR/SSM todavía disponible en ese punto
del arranque. Los repositorios de Amazon Linux 2023 están respaldados por
mirrors alojados en S3, alcanzables a través del Gateway Endpoint de S3 que
ya existía desde la primera actualización de `01-vpc.yaml` (creado
originalmente para las capas de imágenes de ECR). Es decir, el Gateway
Endpoint de S3 por sí solo ya cubre `dnf`/`yum` en AL2023, sin necesitar NAT.

## Alternativas consideradas
- **Mantener NAT Gateway** para este flujo: descartado como decisión
  permanente — da salida general a internet cuando solo se necesitan
  servicios de AWS puntuales, con un costo por hora comparable al de los
  endpoints.
- **Secrets Manager** para la contraseña: ya descartado por costo en el
  ADR-0003 (rediseño Free Tier de RDS); se reafirma aquí para este nuevo
  caso de uso (EC2 leyendo el secreto) en vez de reabrir la discusión.
- **Contraseña como parámetro de CloudFormation inyectado directamente en
  `user-data`** en texto plano: descartado por la exposición vía IMDS y
  `ec2:DescribeInstanceAttribute` sin autenticación adicional.

## Consecuencias
- El orden de despliegue ahora importa de una forma que CloudFormation no
  fuerza automáticamente: los VPC Endpoints deben existir *antes* de que se
  lance cualquier instancia que dependa de ellos, pero `01-vpc.yaml`
  (endpoints) y `05-compute.yaml` (ASG) son stacks independientes sin
  relación de importación entre sí. Si se despliegan o se activan fuera de
  orden, una instancia puede lanzarse antes de que los endpoints estén
  disponibles y fallar en silencio, como ocurrió. **Mitigación documentada,
  no automatizada todavía**: siempre confirmar `CreateEcrEndpoints=true` en
  `01-vpc.yaml` antes de subir `DesiredCapacity` en `05-compute.yaml`.
  Automatizar esto (dependencia real entre stacks, o reintentos con backoff
  dentro del propio `user-data`) queda pendiente para el Módulo 10
  (pipeline CI/CD).
- Se repite en este módulo el mismo patrón de interruptor + apagado
  deliberado post-prueba que el Módulo 1 estableció para NAT — disciplina
  de costo consistente en todo el proyecto.
- El script de `user-data` no tiene manejo de errores más allá de `set -e`:
  una falla parcial deja una instancia "sana" a nivel de EC2/ASG
  (`InService`, `HealthCheckType: EC2`) pero sin la aplicación corriendo de
  verdad. Este punto ciego se cierra en el Módulo 6, cuando el ALB con
  chequeo de salud real (`HealthCheckType: ELB`) detecte este tipo de falla
  automáticamente y reemplace la instancia sin intervención manual.
