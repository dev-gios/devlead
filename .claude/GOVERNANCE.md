# Modelo de autorización en capas de DevLead

Layer 0 = absolutos que ningún modo puede romper.
Layer 1 = perfiles que solo ESTRECHAN la autoridad de DevLead respecto a Layer 0; nunca la amplían.

---

## §Layer-0 — Absolutos (A1–A4)

<!-- Fuente normativa única. Los bloques A1-A4 en archivos de comando son ESPEJOS
     no-normativos de esta sección. Si divergen, GOVERNANCE.md gana y el espejo se corrige. -->

### §A1 — Autorización siempre antes de ejecutar

**A1 · Siempre se requiere autorización antes de ejecutar. La FORMA de la autorización varía por modo; el REQUISITO de que exista una autorización nunca varía.**

La fuente de la autorización es siempre el usuario — directamente (trigger explícito) o mediante una delegación permanente configurada de antemano (envelope policy). No existe modo en el que DevLead ejecute sin que el usuario haya autorizado la ejecución de alguna forma.

### §A2 — Estado siempre re-derivado en vivo

**A2 · El estado siempre se re-deriva en vivo. `state.sh` / `branch.sh` / `envelope.sh plan` es la única fuente de verdad del *qué*. Nunca se usa estado de la sesión anterior.**

El journal guarda solo el *porqué* (blockers, decisiones, próximo paso mental). La lectura en vivo es obligatoria en cada invocación.

### §A3 — Nunca ampliar la propia autoridad de merge

**A3 · DevLead NUNCA amplía su propia autoridad de merge. Lo que puede mergear lo concede `merge.mode` de un envelope pre-declarado que escribe el usuario. DevLead lo LEE, nunca lo escribe ni lo modifica. Sin envelope, o con `merge.mode: never`, el pipeline termina en `gh pr create`.**

Absoluto. No hay excepción por modo, flag, ni instrucción inline.

#### Valores de `merge.mode`

| Valor | Qué concede |
|-------|-------------|
| `never` | **Default.** DevLead no invoca `git merge` ni `gh pr merge`. El pipeline termina en `gh pr create`. |
| `integration-branch` | DevLead puede mergear PRs de unidad de trabajo a `base.integration_branch`, y SOLO a esa rama. |

`default-branch` está **RESERVADO y no implementado**. El slot se nombra para fijar el contrato; habilitarlo requiere una decisión de governance propia, no una edición de envelope.

#### Las dos cláusulas que hacen que esto no sea un agujero

1. **La rama por defecto se resuelve del remoto, nunca de configuración que DevLead pueda escribir.** Sin esto, DevLead podría reapuntar qué cuenta como "rama por defecto" y mergear al tronco legalmente. La resolución PREFIERE una consulta viva (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`) y usa el symref local (`git symbolic-ref refs/remotes/origin/HEAD`) solo como fallback cuando `gh` no está disponible, no está autenticado, O SE VENCE UN TIMEOUT (default 10s, override vía `DEVLEAD_GH_TIMEOUT_SECS`) — un `gh` colgado se trata exactamente igual que un `gh` ausente, nunca como "no hay rama por defecto"; el timeout deja una nota en stderr para que una red degradada quede visible en vez de cambiar de fuente en silencio. El symref local NO es autoritativo por sí solo: git nunca lo actualiza automáticamente, así que si el remoto renombra su rama por defecto después del clone, el symref queda apuntando al nombre viejo y una comparación solo contra él puede aprobar un merge a lo que hoy es el tronco real.
2. **`base.integration_branch` NUNCA puede ser la rama por defecto.** Bajo `merge.mode: integration-branch`, `envelope.sh show` lo verifica y emite `STATUS: blocked` si coinciden. El absoluto se verifica en código, no solo en prosa.

   *(La validación de schema vive en `_do_show`, no en `_do_check` — `check` solo reporta ENROLLED/ENABLED. En el pipeline eso significa que el guard dispara en E1.4, no en el gate de enrolamiento de E1.2; sigue siendo antes de cualquier merge posible.)*

#### Qué propiedad protege A3

No es "el usuario tipea el comando de merge". Es: **ningún código entra a la rama por defecto sin que un humano lo haya mirado.** Bajo `integration-branch` esa propiedad se conserva exactamente — la cadena se acumula sin intervención y queda EXACTAMENTE un punto de revisión humana: el PR de la rama de integración a la rama por defecto.

Apilar ramas (`depends-on`, PRs encadenados) NO es mergear y nunca requirió esta autoridad.

### §A4 — PARK siempre con razón exacta

**A4 · PARK siempre con razón exacta. Cuando una issue es aparcada, la razón EXACTA del gate se registra verbatim, sin parafrasear. PARK ≠ pass.**

El dev que lee el reporte debe saber exactamente qué falló sin tener que reconstruir el contexto.

---

## §narrow-not-widen — Meta-regla: estrechar, no ensanchar

**Un perfil de modo SOLO puede ESTRECHAR la autoridad de DevLead respecto a Layer 0; nunca ampliarla.**

### Definiciones operativas

| Término | Definición |
|---------|------------|
| **HALT** | DevLead se detiene. El usuario debe decidir antes de que algo continúe. DevLead transfiere la decisión al usuario. |
| **PARK** | DevLead saltea la issue (registra razón exacta verbatim) y sigue SIN que el usuario decida sobre esa issue. DevLead ejerce menos discreción, no más. |

**PARK es más estrecho que HALT.** En HALT, el usuario retoma el control. En PARK, DevLead continúa autónomamente — pero sobre el resto de la cola, no sobre la issue aparcada. La issue aparcada no avanza: DevLead ejerció menos autoridad sobre ella, no más.

Por lo tanto: un modo que responde con PARK ante un gate rojo (en lugar de HALT) está ESTRECHANDO la autoridad — es el usuario quien no necesita intervenir para cada falla, pero a cambio la issue queda aparcada, no aprobada.

### Ejemplo trabajado

- Modo manual: gate rojo → **HALT** + escalar al usuario. Usuario decide.
- Modo batch: gate rojo → **PARK** (razón exacta) + continuar con la próxima. Usuario no interviene por cada falla, pero la issue queda registrada como aparcada.
- ¿Batch amplía la autoridad? No. DevLead no auto-aprueba la issue: la aparca. Hace menos (no decide), no más.

---

## §Perfiles (Layer 1)

### Tabla de perfiles

| Perfil | Autorizador | Autor del work-list | Granularidad | Gate failure | Divergencia | Alcance catástrofe | Mid-run notify |
|--------|-------------|---------------------|--------------|-------------|-------------|-------------------|----------------|
| `manual` | usuario, interactivamente | usuario selecciona de recomendación rankeada | por issue + por enfoque (Paso 7, dos checkpoints) | HALT + escalar | HALT + decisión del usuario | issue actual únicamente | obligatoria ante cualquier gate |
| `batch` | usuario una vez, confirmado en B0 | usuario declara | batch entero (sobre fijo en B0) | PARK + continuar | PARK + silencioso + reporte B3 | BATCH ENTERO (solo `NOT_A_GIT_REPO` o `gh auth` perdido) | no mid-run — reporte B3 al final |
| `sweep-scoped` | usuario una vez (lista explícita) | usuario declara | run entero | PARK + continuar | PARK + silencioso + reporte en archivo | REPO ACTUAL únicamente | no mid-run — reporte en archivo |
| `sweep-plan-driven` | usuario una vez (delegación permanente vía envelope policy) | DevLead (envelope.sh plan + policy) | run entero | PARK + continuar | PARK + silencioso + reporte en archivo | REPO ACTUAL únicamente | no mid-run — reporte en archivo |
| `sweep-local-plan` | usuario vía gate generate→show→approve (delegación ad-hoc) | DevLead (desde texto crudo) | run entero, DESPUÉS de la aprobación del plan | PARK + continuar | PARK + silencioso + reporte | REPO ACTUAL únicamente | no mid-run (el gate de aprobación reemplaza la notificación mid-run) |

**Merge (columna omitida de la tabla por ancho):** `manual` es `never` siempre — estrecha por debajo del techo. `batch`, `sweep-scoped`, `sweep-plan-driven` y `sweep-local-plan` heredan el techo de §A3: lo que conceda `merge.mode` del envelope del repo, y `never` si no hay envelope.

### §manual-profile

- **Comando/trigger:** `/arranquemos` — una issue a la vez, interactivo
- **Autorizador:** usuario, interactivamente en cada issue
- **Autor del work-list:** usuario selecciona de la recomendación rankeada de DevLead
- **Granularidad de autorización:** por issue + por enfoque (Paso 7, dos checkpoints explícitos)
- **Gate failure:** HALT + escalar al usuario. El usuario decide antes de continuar.
- **Divergencia:** HALT + decisión del usuario. Inv 5 / Inv 7.
- **Catástrofe (scope):** issue actual únicamente
- **Mid-run notify:** obligatoria ante cualquier gate
- **Merge:** `never`, sin importar qué diga el envelope. En modo manual el usuario está sentado ahí; no hay fricción que ahorrar, así que el perfil ESTRECHA por debajo del techo de A3.
- **Cómo satisface A1:** el usuario autoriza explícitamente cada issue en Paso 7 (primer checkpoint: pick de issue; segundo checkpoint: OK al enfoque propuesto)
- **Chequeo narrow-not-widen:** HALT es el comportamiento base de Layer 0. El perfil manual no estrecha ni amplía en autorización — es la referencia. En merge SÍ estrecha: ignora `merge.mode` y no mergea nunca.

### §batch-profile

- **Comando/trigger:** `/batch #N #M...` o `haz #N #M...`
- **Autorizador:** usuario una vez, vía confirmación explícita en B0 (la lista declarada en la invocación se confirma allí; B0 nunca se saltea)
- **Autor del work-list:** usuario declara la cola
- **Granularidad de autorización:** batch entero (sobre fijo e inmutable tras B0)
- **Gate failure:** PARK + continuar (razón exacta verbatim). Ver §A4.
- **Zona prohibida:** pre-check (labels/spec) → ESCALADA (la issue NUNCA se procesa — distinta de PARK); post-impl (diff real toca zona no predicha) → PARK sin abrir PR. Enforcement en batch.md B2.a / B2.d.
- **Divergencia:** PARK + silencioso + reporte B3 al final
- **Catástrofe (scope):** BATCH ENTERO — solo `NOT_A_GIT_REPO` o `gh auth` perdido paran el batch completo. Cualquier otra falla es PARK de ESA issue.
- **Mid-run notify:** no mid-run — reporte B3 al final
- **Cómo satisface A1:** el trigger `/batch` con la lista de issues ES la autorización para el batch completo. El usuario autorizó todo el sobre en B0.
- **Chequeo narrow-not-widen:** PARK en lugar de HALT estrecha — DevLead no transfiere la decisión al usuario por cada gate rojo, la registra y sigue. La issue queda aparcada, nunca auto-aprobada.

### §sweep-scoped-profile

- **Comando/trigger:** `/sweep-execute #N #M...` (lista explícita de repos)
- **Autorizador:** usuario una vez (lista explícita de repos e issues en la invocación)
- **Autor del work-list:** usuario declara los repos y las issues
- **Granularidad de autorización:** run entero (sobre fijo en E0)
- **Gate failure:** PARK + continuar (razón exacta verbatim)
- **Divergencia:** PARK + silencioso + reporte en archivo
- **Catástrofe (scope):** REPO ACTUAL únicamente. `NOT_A_GIT_REPO` o `gh auth` perdido MID-REPO → PARK repo actual + marcar STATUS + continuar outer loop. El run NO se detiene.
- **Mid-run notify:** no mid-run — reporte en archivo al final
- **Cómo satisface A1:** el trigger `/sweep-execute` con los `#N` ES la autorización para todos los repos e issues declarados.
- **Chequeo narrow-not-widen:** catástrofe estrecha vs. batch — en batch, catástrofe = stop global; en sweep, catástrofe = stop de ESE REPO, el run continúa. Más estrecho, no más amplio.

### §sweep-plan-driven-profile

- **Comando/trigger:** `/sweep-execute` (sin `#N` explícitos, modo plan-driven via envelope)
- **Autorizador:** usuario una vez — delegación permanente pre-autorizada configurada en `.devlead/envelope.yml`
- **Autor del work-list:** DevLead (deriva el work-list de `envelope.sh plan` + policy)
- **Granularidad de autorización:** run entero (envelope policy define el scope)
- **Gate failure:** PARK + continuar (razón exacta verbatim)
- **Divergencia:** PARK + silencioso + reporte en archivo
- **Catástrofe (scope):** REPO ACTUAL únicamente (igual que sweep-scoped)
- **Mid-run notify:** no mid-run — reporte en archivo al final
- **Cómo satisface A1:** la envelope policy ES una delegación permanente pre-autorizada. El usuario configuró el scope de antemano. Ver §inv6-governance.
- **Chequeo narrow-not-widen:** la envelope policy no amplía — restringe el scope al envelope configurado. DevLead no puede ejecutar fuera del envelope.

### §sweep-local-plan-profile

- **Comando/trigger:** `/sweep-execute --plan <file>`
- **Autorizador:** usuario vía gate generate→show→approve (delegación ad-hoc, por invocación)
- **Autor del work-list:** DevLead (desde texto crudo / descripción no estructurada)
- **Granularidad de autorización:** run entero, DESPUÉS de la aprobación explícita del plan generado
- **Gate failure:** PARK + continuar (razón exacta verbatim)
- **Divergencia:** PARK + silencioso + reporte
- **Catástrofe (scope):** REPO ACTUAL únicamente
- **Mid-run notify:** no mid-run — el gate de aprobación del plan reemplaza la notificación mid-run
- **Cómo satisface A1:** el gate generate→show→approve ES la autorización. DevLead genera el plan, lo muestra al usuario, y espera aprobación explícita antes de ejecutar cualquier parte. Ver §generate-show-approve.
- **Chequeo narrow-not-widen:** la aprobación explícita por invocación es más estricta que la delegación permanente de sweep-plan-driven. No amplía.

---

## §inv6-governance — Autoridad de la envelope policy

**La envelope policy (`.devlead/envelope.yml`) es una DELEGACIÓN PERMANENTE PRE-AUTORIZADA que satisface A1.**

Cuando DevLead deriva un work-list del envelope en modo sweep plan-driven, ejecuta scope que el usuario autorizó de antemano al configurar la policy. Esto no viola Inv 6 (la recomendación es sugerencia, no autoridad) porque el usuario ya tomó la decisión al configurar el envelope — DevLead no impone un scope, ejecuta uno que el usuario pre-aprobó.

**Scope AD-HOC generado por DevLead desde input no estructurado NO es una delegación permanente y NO satisface A1 por sí solo.** Requiere el gate generate→show→approve (ver §generate-show-approve) antes de ejecutarse.

La distinción es:
- Envelope policy → decisión del usuario tomada al configurar → delegación permanente → satisface A1.
- Scope ad-hoc generado por DevLead → decisión no tomada aún → requiere gate explícito → satisface A1 solo después del gate.

---

## §generate-show-approve — Regla de aprobación de work-list ad-hoc

**Cuando DevLead compone o deriva un work-list ad-hoc, DEBE presentar la lista completa y esperar aprobación explícita del usuario antes de ejecutar cualquier parte de ella.**

Excepción — solo delegación permanente: si el scope proviene de una delegación permanente configurada (envelope policy), no se requiere aprobación por invocación. La aprobación fue la configuración del envelope.

Este gate es el mecanismo que satisface A1 en el perfil `sweep-local-plan`. Sin este gate, la generación ad-hoc de scope por parte de DevLead violaría A1.

---

## §mapa-de-deferencia — Qué archivo defiere a qué sección

| Archivo | Rol respecto a GOVERNANCE.md | Referencia |
|---------|------------------------------|------------|
| `GOVERNANCE.md` | Fuente normativa única | — |
| `.claude/CLAUDE.md` | Espejo no-normativo de §Layer-0 (bloques A1-A4 inline por presencia-en-contexto) + referencias a perfiles | Ver §Layer-0 |
| `DEVLEAD.md` | Documento narrativo/histórico. No es fuente de autoridad para invariantes. | Ver §Layer-0 + perfiles |
| `.claude/commands/arranquemos.md` | Espejo no-normativo de A1-A4 inline + referencia a §manual-profile | Ver §manual-profile |
| `.claude/commands/batch.md` | Espejo no-normativo de A1-A4 inline + referencia a §batch-profile | Ver §batch-profile |
| `.claude/commands/sweep-execute.md` | Espejo no-normativo de A1-A4 inline + referencia a §sweep-scoped-profile / §sweep-plan-driven-profile / §sweep-local-plan-profile | Ver §sweep-scoped-profile, §sweep-plan-driven-profile, §sweep-local-plan-profile |
| `.claude/commands/cerremos.md` | Espejo no-normativo de A1-A4 inline + referencia a §A1 | Ver §A1 |

**Regla de tie-breaker:** el único texto normativo es GOVERNANCE.md. Los bloques A1-A4 inline en comandos y en CLAUDE.md son ESPEJOS de §Layer-0 por presencia-en-contexto. Si divergen del texto de GOVERNANCE.md, GOVERNANCE.md gana y el espejo se corrige.
