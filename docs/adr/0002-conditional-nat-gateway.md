# ADR-0002: NAT Gateway condicional en la VPC

## Estado
Aceptado

## Contexto
NAT Gateway no tiene Free Tier — cuesta ~$32/mes + transferencia de datos solo por
existir, sin importar el uso. El proyecto tiene presupuesto real de $0. Crearlo de
forma permanente generaría costo continuo sin necesidad, ya que solo se usa cuando
una instancia en subnet privada necesita salida a internet (ej: EC2 haciendo
`docker pull` desde ECR en el Módulo 5).

## Decisión
El NAT Gateway se crea de forma condicional vía un parámetro CloudFormation
`CreateNatGateways` (default `"false"`), controlado por una Condition
`ShouldCreateNat`. Se activa solo en la sesión/módulo que realmente lo necesita,
y se destruye apenas deja de ser necesario.

## Alternativas consideradas
- NAT Gateway siempre activo: descartado por costo continuo innecesario.
- NAT Instance (EC2 en vez de NAT Gateway): más barato pero requiere gestión manual
  (parcheo, HA, escalado) — no vale la pena el ahorro para este proyecto de estudio.

## Consecuencias
- Costo $0 para la capa de VPC en el estado por defecto.
- Cada vez que se necesita salida a internet desde subnet privada, hay que
  recordar activar el parámetro y desactivarlo después — riesgo de olvido si no
  se sigue la rutina de cierre de sesión establecida.