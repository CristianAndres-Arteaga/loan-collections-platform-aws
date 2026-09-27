# ADR-0013: HTTPS con CloudFront y certificado por defecto (sin dominio propio) delante del ALB

## Estado
Aceptado

Fecha: 2026-09-27

## Contexto
El ADR-0010 dejó el ALB con un listener HTTP:80 temporal restringido a la IP
del desarrollador y dos deudas explícitas para el Módulo 8:

1. **Sin HTTPS**: la API viajaba en texto plano entre el cliente y AWS.
2. **Regla 443 abierta a `0.0.0.0/0`** en `AlbSecurityGroup` desde el
   Módulo 3, sin ningún listener detrás (configuración muerta).

El plan original era Route 53 + dominio propio + certificado ACM en un
listener HTTPS:443 del ALB. ACM solo emite certificados públicos para
dominios que se controlan, así que ese plan depende de tener un dominio.

### Evidencia de la cuenta (2026-09-25)
`aws route53domains list-prices`:

```
AccessDeniedException: Free Tier accounts are not supported for this service
```

La cuenta está en el Free plan (ADR-0010) y no puede registrar dominios con
Route 53 Domains. El desarrollador tampoco tiene un dominio externo.

## Decisión

### 1. CloudFront como punto de entrada HTTPS
Se pone una distribución CloudFront delante del ALB usando el certificado
por defecto `*.cloudfront.net` (`CloudFrontDefaultCertificate: true`). Da
HTTPS válido sin dominio ni ACM.

| Tramo | Protocolo |
|---|---|
| Cliente → CloudFront | HTTPS (`ViewerProtocolPolicy: redirect-to-https`) |
| CloudFront → ALB | HTTP:80 (`OriginProtocolPolicy: http-only`) |
| ALB → EC2 | HTTP:8080 (red privada de la VPC) |

Configuración de la distribución:

- **`Managed-CachingDisabled`** (`4135ea2d-...`): es una API con datos que
  cambian; cachear en el borde podría servir datos obsoletos o de otro
  cliente. El caché de la aplicación sigue siendo Valkey (ADR-0011).
- **`Managed-AllViewerExceptHostHeader`** (`b689b0a8-...`): reenvía headers,
  query strings y cookies del cliente, pero no el `Host`, para que el ALB
  reciba su propio nombre.
- **`PriceClass_100`** (Norteamérica y Europa): suficiente para un único
  usuario en América y el más barato.
- **`IPV6Enabled: false`**: el filtro de IP es IPv4 `/32`. Con IPv6 activo,
  un navegador con doble pila podría entrar por IPv6 y quedar bloqueado.

### 2. Vive en `06-alb.yaml`, bajo el mismo interruptor `CreateAlb`
CloudFront no va en un stack `08-cdn.yaml` aparte. Si otro stack importara el
DNS del ALB desde un Export condicional, poner `CreateAlb=false` quedaría
bloqueado por CloudFormation ("export in use"), el mismo problema que llevó
a dejar el Target Group sin condición en el ADR-0010. Con ambos en el mismo
stack y la misma condición, se encienden y se apagan juntos.

### 3. Tres capas de control de acceso

| Capa | Control | Frena a |
|---|---|---|
| Red (SG del ALB) | Puerto 80 solo desde la prefix list administrada `com.amazonaws.global.cloudfront.origin-facing` (`pl-b6a144df` en us-east-2) | Todo internet que no sea CloudFront |
| ALB (listener) | Regla prioridad 1: header `X-Origin-Verify` == secreto → forward. Acción por defecto: `403` fixed-response | Distribuciones CloudFront **de otras cuentas** apuntando al DNS del ALB |
| Borde (CloudFront Function, viewer-request) | `event.viewer.ip` debe ser la IP del desarrollador; si no, `403` | Cualquier cliente que no sea el desarrollador (la API aún no tiene autenticación) |

- **El filtro de IP se mueve del SG a una CloudFront Function** porque, con
  CloudFront en medio, el ALB recibe conexiones de IPs de CloudFront: el SG
  ya no ve la IP real del cliente. El borde es el último punto donde se ve.
- La IP entra como parámetro `AllowedClientCidr` (igual que en el ADR-0010) y
  se inyecta en el código de la función con `!Sub` + `!Split`. No se
  commitea.
- **Peso de la prefix list**: una regla que referencia una prefix list cuenta
  como su `MaxEntries` (55 para la de CloudFront) contra la cuota por
  defecto de 60 reglas de entrada del SG. El `AlbSecurityGroup` queda con
  margen para ~5 reglas más.

### 4. Manejo del secreto `X-Origin-Verify`
- Parámetro `OriginVerifySecret` con `NoEcho: true`, **sin valor por
  defecto**, `MinLength: 32` y `AllowedPattern` hexadecimal. Un valor vacío
  o débil hace fallar el deploy.
- Se genera con `openssl rand -hex 32` y se guarda **fuera del repo** en
  `~/.loan-collections-origin-secret` (permisos `600`). Se pasa al deploy con
  `$(cat ...)`, así el valor no queda en el historial de la shell.
- **`NoEcho` solo oculta el valor en CloudFormation** (consola y
  `describe-stacks` muestran `****`). El valor sigue legible para quien tenga
  permisos de lectura sobre la configuración de CloudFront
  (`GetDistributionConfig`) o las reglas del ALB (`DescribeRules`). Es un
  riesgo aceptado para este proyecto.

### 5. Cierre de la regla 443 (deuda del Módulo 3)
Se eliminó la regla inline `443 ← 0.0.0.0/0` de `AlbSecurityGroup` en
`03-security.yaml`. El change set mostró `Modify / Replacement: False` y,
tras aplicarlo, el SG `sg-03221de2cf2abc964` quedó con `Ingress: []`. La
única regla de entrada ahora es la del puerto 80 desde CloudFront, creada por
`06-alb.yaml` solo cuando `CreateAlb=true`.

## Alternativas consideradas
- **Route 53 Domains + ACM en el ALB**: descartado. La cuenta no puede
  registrar dominios (evidencia arriba) y el desarrollador no tiene uno.
- **Dominio externo + ACM con validación DNS**: descartado. No hay dominio y
  comprarlo no aporta aprendizaje adicional frente al costo y al tiempo
  restante de la cuenta.
- **Certificado autofirmado importado a ACM en el ALB**: descartado. El
  navegador lo rechaza, así que no es un HTTPS real, y enseña una mala
  práctica.
- **Stack `08-cdn.yaml` independiente**: descartado (bloqueo del export
  condicional, ver Decisión 2).
- **Mantener el filtro de IP en el SG del ALB**: descartado. Con CloudFront
  en medio el SG ve IPs de CloudFront, no la del cliente.
- **Secrets Manager con rotación para `X-Origin-Verify`**: es la opción
  correcta en producción, pero se descartó aquí. Cuesta dinero, y rotar
  exige actualizar CloudFront y el ALB de forma coordinada sin cortar
  tráfico: demasiada complejidad para una cuenta que se cierra el
  2026-10-21.
- **AWS WAF con una IP set en CloudFront**: más completo (también permite
  rate limiting y reglas administradas), pero tiene costo fijo mensual. La
  CloudFront Function cubre el requisito sin ese costo (2M invocaciones/mes
  gratis).

## Consecuencias
- **HTTPS extremo a extremo desde el lado del cliente**, verificado en el
  E2E del 2026-09-27 (`docs/evidence/module-08-cloudfront-e2e.txt`, 7/7
  pruebas). El ALB ya no es accesible desde internet (timeout directo).
- **La deuda del 443 abierto queda cerrada.**
- **El tramo CloudFront → ALB sigue en HTTP.** Viaja por la red de AWS, pero
  no está cifrado. Cifrarlo requiere un listener HTTPS en el ALB con un
  certificado para un nombre que CloudFront valide, lo cual vuelve a
  requerir un dominio. Queda como deuda documentada.
- **Ciclos de prueba más lentos**: crear o borrar la distribución tarda
  varios minutos; en el E2E, el apagado de `06-alb` fue el paso más largo.
- **`GroupDescription` desactualizada**: el SG del ALB sigue diciendo
  "Allow HTTPS from Internet to the ALB". No se corrige a propósito:
  `GroupDescription` es inmutable y cambiarla reemplazaría el SG (ID nuevo,
  export `loan-collections-alb-sg-id` y regla de `Ec2AppSecurityGroup`
  afectados). Si algún día el stack se recrea desde cero, se corrige ahí.
- **`pl-b6a144df` depende de la región.** Por eso es un parámetro
  (`CloudFrontOriginPrefixListId`) y no un valor fijo en el template.
- **Si cambia la IP pública del desarrollador**, CloudFront responde `403`
  (ya no timeout como en el ADR-0010) hasta volver a desplegar con el nuevo
  `AllowedClientCidr`.
- **La API sigue sin autenticación.** El filtro de IP en el borde es una
  mitigación temporal, no un reemplazo.
- **Lección de proceso**: la cadena completa se probó antes de encender
  instancias. Un `503 awselb` a través de CloudFront, con el Target Group
  vacío, demostró que la IP, el header y la regla del listener funcionaban,
  sin gastar tiempo de EC2.
