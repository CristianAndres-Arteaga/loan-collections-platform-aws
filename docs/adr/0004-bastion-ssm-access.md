# ADR-0004: Acceso administrativo a RDS vía bastion + SSM Session Manager

## Estado
Aceptado

## Contexto
Por diseño (ver ADR-0001), la subnet de base de datos no tiene ruta a
`0.0.0.0/0` — ni siquiera con `PubliclyAccessible=true` en RDS es posible
alcanzarla desde Internet. Sin embargo, se necesita poder conectarse
administrativamente a la base (cargar el schema inicial, verificar datos,
debugging) durante el desarrollo, sin exponer la base ni abrir puertos de
entrada innecesarios.

## Decisión
Se despliega una instancia EC2 `t3.micro` (Free Tier) como bastion en la subnet
pública, con un IAM Role/Instance Profile con la política administrada
`AmazonSSMManagedInstanceCore`, y un Security Group **sin ninguna regla de
entrada** (SSM no la necesita — toda la comunicación es saliente, iniciada por
el agente SSM hacia el servicio de AWS). El Security Group de RDS referencia el
Security Group del bastion como origen autorizado (`SourceSecurityGroupId`), no
un CIDR. El acceso se realiza vía
`aws ssm start-session --document-name AWS-StartPortForwardingSessionToRemoteHost`,
que crea un túnel `localhost:15432` → bastion → RDS `:5432`, permitiendo correr
`psql` localmente contra la base como si estuviera en la misma red.

## Alternativas consideradas
- Bastion con SSH y par de claves: descartado — requiere gestionar y rotar
  claves privadas, y abrir el puerto 22 de entrada al bastion (aunque sea
  restringido por IP), lo cual es una superficie de ataque que SSM evita por
  completo.
- RDS con acceso público directo (`PubliclyAccessible=true` + SG restringido por
  IP): descartado — además de ser mala práctica para una base con datos
  financieros, es técnicamente inviable con el diseño de subnets del ADR-0001
  (sin ruta a Internet desde la subnet DB).

## Consecuencias
- Cero superficie de ataque de entrada: ningún puerto abierto a Internet, ni en
  el bastion ni en RDS.
- El acceso queda auditado vía CloudTrail (cada sesión SSM queda registrada por
  usuario IAM), a diferencia de SSH donde solo se sabe qué clave se usó.
- Se agrega un recurso más para gestionar (bastion) y un orden de dependencia
  entre stacks a recordar: RDS importa el SG del bastion, por lo que el
  despliegue/destrucción debe respetar el orden VPC → bastion → RDS (y a la
  inversa al destruir).
- Se descubrió en la práctica que pegar bloques SQL multilínea directamente en
  una sesión SSM interactiva corrompe el contenido (caracteres perdidos/
  reordenados) — la solución adoptada fue tunelizar el puerto y ejecutar
  `psql -f archivo.sql` localmente, nunca pegar contenido largo directo en la
  sesión interactiva.