# ADR-0001: Diseño de VPC three-tier

## Estado
Aceptado

## Contexto
El sistema financiero maneja información sensible de préstamos y cobranzas, por lo
que era necesario diseñar una red que separara claramente las capas web, aplicación
y datos, evitando concentrar todos los recursos en una sola subnet. Además, la
arquitectura debía ser tolerante a la caída de una Availability Zone, distribuyendo
los recursos entre múltiples AZ para mantener la disponibilidad del sistema.
Finalmente, la capa de base de datos debía estar aislada a nivel de red de la capa
de aplicación, de modo que no tuviera exposición directa a Internet y solo pudiera
recibir conexiones desde los recursos autorizados de la aplicación.

## Decisión
Se implementó una VPC con CIDR 10.0.0.0/16, dividida en 6 subnets distribuidas
2 Availability Zones: 2 públicas, 2 privadas de aplicación y 2 privadas de base de
datos. Las subnets públicas utilizan un Internet Gateway (IGW), las privadas-app
utilizan NAT Gateway para salida controlada a Internet, y las privadas-DB no tienen
ruta hacia el NAT Gateway ni salida directa a Internet.

## Alternativas consideradas
Se descartó utilizar una sola Availability Zone por el riesgo de que una falla
afectara simultáneamente a toda la arquitectura; también se descartó una tercera AZ
por el costo y complejidad adicionales que no eran necesarios para el nivel de
resiliencia requerido. Se descartó compartir una única subnet privada entre la capa
de aplicación y la base de datos, ya que, aunque los Security Groups permiten
controlar las comunicaciones, separar las subnets proporciona un aislamiento de red
adicional y permite aplicar diferentes rutas y políticas de salida para cada capa.

## Consecuencias
El diseño proporciona mayor disponibilidad al distribuir los recursos entre dos
Availability Zones y mayor aislamiento de seguridad al mantener la base de datos en
subnets sin salida directa a Internet; además, refuerza conceptos relevantes p
el examen SAA-C03, como Multi-AZ, route tables, Internet Gateway y NAT Gateway.
Como consecuencia, administrar la infraestructura es más compleja al tener seis
subnets, diferentes tablas de rutas y distintos patrones de conectividad, y el
acceso administrativo a RDS requirió implementar el patrón **bastion/SSM**, en
lugar de conectarse directamente desde Internet. Como deuda conocida, queda
pendiente definir y endurecer los **Security Groups** específicos entre las capas
para complementar el aislamiento proporcionado por las subnets.
