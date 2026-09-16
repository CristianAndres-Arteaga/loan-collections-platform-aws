# ADR-0005: IAM least-privilege para EC2 de aplicación y Security Groups en capas (ALB → EC2 → RDS)

## Estado
Aceptado

## Contexto
Las futuras instancias EC2 de la capa de aplicación (Módulo 5) van a necesitar
credenciales de AWS para hacer `docker pull` desde ECR y escribir logs, pero sin
exponer credenciales permanentes ni otorgar permisos más allá de lo estrictamente
necesario. Además, la arquitectura de red requiere que el tráfico fluya en cadena
estricta desde Internet hasta la base de datos — ninguna capa debe poder saltearse
a la anterior, incluso si una capa intermedia es comprometida.

## Decisión
- Se creó un **IAM Role** (`loan-collections-ec2-app-role`) con Instance Profile,
  para ser asumido por las futuras instancias EC2 de aplicación, con permisos
  acotados a: `AmazonEC2ContainerRegistryReadOnly` (pull de imágenes desde ECR),
  `AmazonSSMManagedInstanceCore` (gestión vía Session Manager, sin SSH), y una
  policy inline de CloudWatch Logs restringida al prefijo
  `/loan-collections/*` (no acceso global a logs de la cuenta).
- Se crearon dos nuevos Security Groups como recursos independientes, antes de
  que existan las instancias/ALB que los van a usar: `SG-ALB` (ingreso 443 desde
  `0.0.0.0/0`) y `SG-EC2-App` (ingreso solo desde `SG-ALB`, no desde Internet).
- Se actualizó `DBSecurityGroup` (RDS) para aceptar también tráfico desde
  `SG-EC2-App`, completando la cadena `ALB → EC2 → RDS` en una sola unidad
  coherente, aunque ALB y EC2 todavía no estén desplegados.

## Alternativas consideradas
- Usar una policy administrada amplia (ej: `AmazonEC2ContainerRegistryFullAcce
  o similar) para simplificar: descartado por violar least privilege — la app
  solo necesita *leer* imágenes, nunca administrar el repositorio ECR.
- Conectar los Security Groups recién en el Módulo 5, cuando existan las
  instancias reales: descartado — un Security Group es un recurso válido de AWS
  independientemente de si algo lo usa todavía, y definir la cadena completa
  ahora deja el Módulo 5 más simple (solo adjuntar SGs ya existentes) en vez d
  tener que volver a tocar `02-rds.yaml` de nuevo.
- Dar acceso SSH directo a las futuras instancias de app: descartado por la
  misma razón que en ADR-0004 — SSM evita abrir cualquier puerto de entrada y
  mantiene auditoría centralizada vía CloudTrail.

## Consecuencias
- Las futuras instancias EC2 de aplicación nacen con permisos mínimos desde el
  primer despliegue, sin necesidad de acotar permisos "después" (que rara vez
  pasa en la práctica una vez que algo ya funciona).
- La cadena de Security Groups queda completamente definida y documentada antes
  de que exista tráfico real — el Módulo 5 no requiere ninguna decisión de
  seguridad nueva, solo adjuntar recursos ya diseñados.
- Costo $0: los Security Groups y el IAM Role no tienen costo por existir vacíos,
  a diferencia de NAT Gateway o ALB.
- Deuda pendiente: el puerto de la app (`AppPort`, default `8080`) es un
  supuesto — deberá confirmarse o ajustarse cuando se defina el stack real de
  aplicación en el Módulo 4.