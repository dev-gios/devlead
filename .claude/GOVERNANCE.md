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

#### Quién escribe el envelope — la escritura interactiva la dirige un humano

"DevLead lo LEE, nunca lo escribe" distingue **quién dirige la escritura**, no qué binario la ejecuta.

Un editor de configuración interactivo, donde cada escritura la elige un humano sentado en la terminal, ES el usuario configurando su propia máquina — con asistencia. Proponer un valor por defecto es asistencia; escribirlo sin que el humano lo haya elegido, no. Lo prohibido no se mueve: DevLead derivando y aplicando configuración por su cuenta se estaría auto-concediendo autoridad, y sigue prohibido sin excepción por modo, flag, ni instrucción inline.

**La condición es un requisito, no una recomendación.** Un editor de configuración que escriba el envelope DEBE:

1. **Negarse a correr sin TTY.** Sin humano del otro lado no hay quién dirija la escritura, y un editor que igual escribe dejó de ser asistencia: es DevLead escribiendo.
2. **Ser inalcanzable desde `sweep-execute`, `sweep-loop` y `sweep-discover`.** Los tres, nombrados. Ninguno puede invocarlo, ni directa ni indirectamente, ni a través de un wrapper.

Si alguna vía autónoma puede invocarlo alguna vez, A3 está **roto** — no flexibilizado, no matizado: roto. La condición no admite grados. O el editor es inalcanzable desde todo camino autónomo, o el absoluto se cayó.

**El precedente ya existe en este código; el mecanismo no es nuevo.** `_do_optin` en `.devlead/scripts/envelope.sh` gatea su única pregunta con `[[ ! -t 0 ]] → return 0`: sin TTY no pregunta, no escribe `~/.devlead/autonomous-repos` y no toca el timer. Y `envelope.sh init` (`_do_init`) ya escribe el scaffold del envelope — lo crea solo si no existe, nunca lo sobrescribe, y lo deja en `merge.mode: never`. Los caminos autónomos llaman `check` y `plan`, ambos de solo lectura. Esta cláusula nombra lo que el código ya hacía.

**Chequeo narrow-not-widen:** antes, un humano escribía YAML a mano en un editor de texto. Después, un humano contesta prompts y se escriben las elecciones de ese mismo humano. El conjunto de configuraciones alcanzables no crece — no hay valor que el editor pueda escribir que el humano no pudiera haber tipeado, y `default-branch` lo sigue rechazando `_do_show` igual que antes. Lo único que cambia es cuánto tiene que saber el humano para llegar a ellas. DevLead no gana nada: su autoridad de merge la sigue concediendo el envelope, y el envelope lo siguen decidiendo humanos.

### §A4 — PARK siempre con razón exacta

**A4 · PARK siempre con razón exacta. Cuando una issue es aparcada, la razón EXACTA del gate se registra verbatim, sin parafrasear. PARK ≠ pass.**

El dev que lee el reporte debe saber exactamente qué falló sin tener que reconstruir el contexto.

---

## §hard-limits — Los límites duros viven en código

DevLead trabaja por su cuenta. Lo que NO puede hacer no depende de una frase en un prompt: lo decide `guard.sh`, un hook que corre antes de cada herramienta y bloquea la llamada con una razón exacta.

| Límite | Qué bloquea |
|---|---|
| `production` | Deploys, cambios de infraestructura o de cluster, CLIs de nube, conexión a otra máquina, publicar paquetes o releases, push a la rama por defecto |
| `merge-door` | Mergear un PR por cualquier vía que no sea `merge.sh` (que lee el envelope — §A3) |
| `database` | Todo lo que apunte a una base de datos que no esté en esta máquina, incluida una dirección tomada de una variable |
| `secrets` | Leer o escribir un archivo de credenciales fuera de los lugares permitidos; volcar el entorno; `gh auth token` |
| `scope` | Escribir un archivo fuera del repositorio en el que se inició la sesión |
| `self-config` | Cambiar los archivos que configuran estos límites (`~/.devlead/`, los settings de Claude Code) |

**Quién concede una excepción.** Solo el usuario, y solo para credenciales: los lugares desde donde DevLead puede leer una clave se listan, un glob por línea, en `~/.devlead/secrets-allow`. Ningún script de DevLead escribe ese archivo y el guard bloquea a la sesión que lo intente. Los otros límites no tienen excepción.

**Cuándo está activo.** En toda sesión interactiva de DevLead y en toda corrida desatendida (los lanzadores fijan `DEVLEAD_GUARD=1` en el proceso de Claude Code, donde la sesión no puede quitarlo). Fuera de DevLead no hace nada.

**Un límite bloqueado no se rodea.** Si la tarea lo necesita, DevLead se detiene y le dice al usuario qué hace falta: manual → avisa y espera; autónomo → PARK con la razón exacta que imprimió el guard (§A4). Buscar otra vía para lograr el mismo efecto es una violación de esta sección.

**Qué no es.** No es un sandbox: un comando de Bash se evalúa como texto, así que frena los errores de un agente honesto y no contiene a uno hostil. La defensa estructural de producción es que sus credenciales no estén en esta máquina.

**La sesión nunca tiene el token de GitHub en la mano.** Para saber si hay auth usa `envelope-auth.sh auth`, que responde `available` o `unavailable`; los scripts que la necesitan la resuelven en su propio proceso.

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
| `sweep-discover` | usuario una vez (delegación permanente vía `discover.enabled: true` en el envelope) | DevLead (explora `discover.modules[].path` contra `discover.modules[].spec`) | run entero — sin autoridad de ejecución, solo `gh issue create` | PARK + continuar | PARK + silencioso + reporte en archivo | REPO ACTUAL únicamente | no mid-run — reporte en archivo |

**Merge (columna omitida de la tabla por ancho):** `manual` es `never` siempre — estrecha por debajo del techo. `batch`, `sweep-scoped`, `sweep-plan-driven` y `sweep-local-plan` heredan el techo de §A3: lo que conceda `merge.mode` del envelope del repo, y `never` si no hay envelope. `sweep-discover` no tiene columna de merge aplicable — no abre PRs, así que `merge.mode` nunca entra en juego.

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

### §sweep-discover-profile

- **Comando/trigger:** `/sweep-discover` (o el flag equivalente en `/sweep-execute` cuando `discover.enabled: true`)
- **Autorizador:** usuario una vez — delegación permanente pre-autorizada vía `discover.enabled: true` y la lista de `discover.modules[]` declarada en `.devlead/envelope.yml`
- **Autor del work-list:** DevLead explora cada `discover.modules[].path` contra su `discover.modules[].spec` declarado y deriva los gaps
- **Granularidad de autorización:** run entero — pero sin autoridad de ejecución. Este perfil no crea ramas, no abre PRs, no mergea. Su ÚNICO output es `gh issue create`. Es la propiedad que define el perfil, y lo vuelve ESTRICTAMENTE MÁS ESTRECHO que cualquier otro perfil de esta tabla: todos los demás terminan, en algún punto, en código tocando el repo o en un PR abierto; este termina en una issue.
- **Gate failure:** PARK + continuar (razón exacta verbatim) — si un módulo declarado no puede explorarse (path inexistente, spec inexistente, o falla de lectura), DevLead aparca ESE módulo y sigue con el próximo. No hay gate de código que correr porque no hay código que tocar; el "gate" acá es poder completar la comparación módulo-vs-spec.
- **Divergencia:** PARK + silencioso + reporte en archivo — si lo que encuentra en el módulo no coincide con lo que el spec describe, DevLead no decide por su cuenta qué hacer con la brecha: la registra como issue con `discover.label` y sigue. La decisión sobre esa brecha queda para el humano que la revise.
- **Catástrofe (scope):** REPO ACTUAL únicamente (igual que sweep-scoped y sweep-plan-driven) — `NOT_A_GIT_REPO` o `gh auth` perdido para SOLO el repo en curso; el run continúa con el siguiente.
- **Mid-run notify:** no mid-run — reporte en archivo al final. No hay nada que aprobar en vivo porque no hay ejecución en vivo: cada hallazgo se materializa como issue, no como acción.
- **Cómo satisface A1:** `discover.enabled: true` más la lista de `discover.modules[]` declarada en el envelope ES la delegación permanente pre-autorizada, exactamente como §inv6-governance ya establece para la envelope policy en general. El usuario decidió, al declarar esos módulos y sus specs, qué superficie puede explorar DevLead — no en el momento de correr, sino de antemano.
- **Por qué NO necesita el gate generate→show→approve** (a pesar de que a primera vista parece que debería): §inv6-governance y §generate-show-approve exigen ese gate cuando DevLead deriva un work-list AD-HOC — porque ese work-list se va a EJECUTAR (ramas, PRs, código tocando el repo) y la aprobación tiene que pasar antes de que eso ocurra. Discovery deriva un work-list también, pero ese work-list se materializa como ISSUES, no como ejecución. No se crea ninguna rama, no se abre ningún PR, no se toca código. La aprobación no se salteó — se RELOCALIZÓ al punto donde el trabajo realmente empieza: modo plan-driven decide, según policy, si esas issues se trabajan; y `discover.label`, sostenido por la regla de acoplamiento del schema (`discover.label` debe figurar en `select.exclude_labels`, ver `.devlead/scripts/envelope.sh`), las mantiene afuera del work-list de plan-driven hasta que un humano las revise y les saque la label o las reclasifique. El gate sigue existiendo; vive en el próximo perfil de la cadena, no en este.
- **El ciclo de dos noches:** esta es la forma que gobierna el perfil. Noche uno, `sweep-discover` corre, explora los módulos declarados contra sus specs, y archiva una issue por cada gap con `discover.label` puesto. Vos mirás esas issues. Noche dos, `sweep-plan-driven` (o el modo que corresponda) decide qué de lo que sobrevivió a tu revisión se trabaja — y solo lo hace si vos ya sacaste o cambiaste la label, porque mientras `discover.label` siga puesto y siga en `select.exclude_labels`, plan-driven las sigue ignorando. El label ES el mecanismo que mantiene el ciclo abierto entre las dos noches; sin él, discovery se archivaría trabajo a sí mismo y lo ejecutaría en la corrida siguiente, sin que nadie lo mire — que es exactamente el agujero que la regla de acoplamiento del schema existe para cerrar.
- **Corrida programada:** `devlead-discover.timer` (semanal, nunca habilitado por la instalación) dispara `discover-fleet.sh`, que entra SOLO a los repos de `~/.devlead/autonomous-repos` cuyo envelope dice `enabled: true` y `discover.enabled: true`, y ahí invoca este mismo comando — un intento por repo, sin reintentos. El lanzador no agrega autoridad: lee el envelope y dispara el comando; se niega a correr sin flags de permisos elegidos por el usuario o sobre artefactos que `doctor.sh` no verifica como el trunk revisado (mismo listón que `sweep-loop.sh`), y avisa por §escalation-channel (`discover-no-permissions`, `discover-drift`).
- **Chequeo narrow-not-widen:** este perfil no gana ninguna autoridad que los demás no tengan — la pierde. No puede crear ramas, no puede abrir PRs, no puede mergear; ninguno de los otros verbos de Layer 0 (A3, merge) aplica porque nunca llega a ese punto. Es un perfil de SOLO LECTURA sobre el repo y SOLO ESCRITURA sobre el issue tracker. Estrecha por debajo de todos los perfiles existentes, no los iguala ni los amplía.

---

## §escalation-channel — Avisar no es decidir

La columna "Mid-run notify" de la tabla de perfiles describe lo que hace **DevLead dentro de un run**: los perfiles autónomos no se detienen a preguntar por cada issue aparcada, y eso no cambia. PARK sigue siendo silencioso hacia adentro del run y visible en el reporte.

Lo que esta sección agrega es un canal de **escalada de nivel run**, implementado en código (`.devlead/scripts/notify.sh`), para el caso que la tabla no cubría: un run desatendido que **no puede seguir solo**. Hasta ahora ese caso terminaba en un archivo y una línea de journald que nadie leía.

**Tres niveles, y solo tres:**

| Nivel | Cuándo | A dónde va |
|-------|--------|------------|
| `need` | El run no puede continuar sin una decisión o una acción del usuario | Bandeja local + push al teléfono (prioridad alta) |
| `agenda` | La lista de lo que DevLead va a trabajar hoy; no pide nada (§daily-agenda). Un solo emisor: `sweep.sh`, una vez por corrida | Bandeja local + push al teléfono (prioridad normal) |
| `info` | Desenlace normal que conviene saber | Bandeja local únicamente |

**Disparadores de `need` (lista cerrada; agregar uno es una edición de esta sección):**

- el loop no tiene permisos configurados (`loop-no-permissions`)
- el kill-switch del envelope lo pausó (`loop-paused`)
- el drift guard se negó a correr con artefactos no verificados (`loop-drift`)
- no se pudo resolver el repo destino (`loop-no-repo`)
- el run convergió sin progreso: las mismas tareas aparcadas por las mismas razones (`loop-stuck`)
- se alcanzó el tope de iteraciones con tareas del plan sin terminar (`loop-cap`)
- el discover programado no tiene flags de permisos elegidos por el usuario (`discover-no-permissions`)
- el discover programado encontró artefactos instalados que no verifican como el trunk revisado (`discover-drift`)

Una issue aparcada por un gate rojo NO es un disparador: es el funcionamiento normal del perfil y va al reporte. Lo que escala es que el run entero dejó de avanzar.

**Lo que el canal no puede hacer:**

1. **No concede ni transfiere autoridad.** `notify.sh` no ejecuta pasos del pipeline, no lee ni escribe el envelope, y una entrada de la bandeja nunca es una orden: retomar lo que quedó frenado requiere la misma autorización que cualquier otro trabajo (A1).
2. **No cambia desenlaces.** `notify.sh send` siempre sale 0. Un canal caído no convierte un run fallido en exitoso ni al revés.
3. **No saca información de la máquina sin que el usuario lo haya configurado.** Sin `~/.devlead/notify.env` no hay push. Con él, el push lleva por defecto solo el código del aviso; el repo y el detalle quedan en la bandeja local salvo opt-in explícito (`DEVLEAD_NOTIFY_DETAIL=1`).

**Chequeo narrow-not-widen:** antes, un run frenado esperaba en silencio hasta que el usuario mirara. Después, espera igual — pero avisa. DevLead no hace nada que antes no pudiera; el usuario se entera antes.

---

## §learned-preferences — Aprender no es autorizar

DevLead aprende cómo trabaja el usuario leyendo lo que el usuario escribe en los PRs (`.devlead/scripts/learn.sh`). De ese feedback destila **preferencias**: una línea de estilo de trabajo cada una ("los tests primero", "un PR por cambio").

**Decisión del usuario (2026-11-13):** una preferencia deducida queda **activa al instante**; DevLead la muestra en el siguiente standup y el usuario quita la que no le sirve. No hay paso de aprobación previo. Esto es legal bajo A1 porque una preferencia no inicia trabajo: solo da forma a trabajo que ya fue autorizado por el camino de siempre.

**Lo que una preferencia es:** contexto de estilo que se entrega a las etapas de implementación (cómo nombrar, cómo testear, cómo partir un cambio, cómo redactar un PR).

**Lo que una preferencia no puede hacer:**

1. **No concede ni amplía autoridad (A3).** `open-pr.sh`, `merge.sh`, `envelope.sh`, los gates y `forbidden-check.sh` no leen preferencias ni el estado de `learn.sh`. Ninguna frase guardada ahí puede abrir un PR, mergear, ni mover un límite. Esto se verifica por test (`test/unit-learn.sh`, bloque A3), no por prosa.
2. **No gana ningún conflicto.** Orden de precedencia: Layer-0 › envelope › gates y zonas prohibidas › spec / plan de la issue › preferencia. Una preferencia que choca con cualquiera de los anteriores no se aplica, y se anota en el PR.
3. **No se registra si habla de autoridad.** Un comentario que pide mergear a otra rama, saltear un gate, tocar una zona prohibida o cambiar permisos no se convierte en preferencia: se le muestra al usuario como algo que configura él (envelope / `devlead config`).
4. **No vuelve una vez quitada.** `pref-remove` desactiva sin borrar, justamente para que el mismo feedback no la deduzca de nuevo.

**De quién se aprende:** solo de la cuenta autenticada en `gh`. El filtro por autor está en código, en `learn.sh capture`: el texto de cualquier otra cuenta se descarta antes de guardarse, así que el comentario de un tercero en un PR nunca llega a ser una instrucción para un run desatendido.

**Dónde se aprende:** la deducción (feedback → preferencia) corre en `/arranquemos`, con el usuario presente, que la ve en el standup. Los perfiles autónomos (batch, sweep-execute, loop) solo **leen** las preferencias activas.

**Límite conocido:** el filtro por autor no distingue lo que el usuario escribió a mano de lo que una herramienta publicó con su mismo token. Hoy el pipeline de DevLead no publica comentarios en PRs; si eso cambia, esos comentarios deben excluirse de la captura.

**Chequeo narrow-not-widen:** antes, DevLead implementaba sin memoria de las correcciones. Después, implementa con ellas. El conjunto de acciones que puede tomar es idéntico; lo que cambia es la forma del diff que produce.

---

## §trust-reading — Un buen historial no es una autorización

`learn.sh trust` lee los outcomes que mide `sweep.sh` y dice si el historial de PRs de DevLead en un repo está **estable** (`VERDICT: steady`): al menos 10 PRs mergeados y las últimas 5 mediciones sin ningún PR cerrado sin mergear ni con cambios pedidos.

**Lo único que hace ese veredicto:** permitir que `/arranquemos` le cuente al usuario el dato y le recuerde dónde se decide el margen de DevLead (`devlead config`).

**Lo que no hace, nunca:**

1. **No cambia `merge.mode` ni ningún otro límite (A3).** `learn.sh` no nombra el archivo del envelope, no llama a `envelope.sh`, `config.sh`, `merge.sh` ni `open-pr.sh`, y no ejecuta ningún verbo de PR. Verificado por test (`test/unit-learn.sh`), no por prosa.
2. **No es leído por nada que conceda o custodie autoridad.** Las puertas, el envelope, los gates y las zonas prohibidas no leen `learn.sh` ni su estado (mismo test A3 de §learned-preferences).
3. **No es un argumento.** DevLead no usa el veredicto para pedir más autoridad, ni lo repite en otros pasos, ni lo convierte en preferencia. El usuario decide si le sirve.

**Límites de la medición, que el propio comando declara:** un PR mergeado después de pedirle cambios cuenta como mergeado (el historial no guarda eso), y cada medición es una foto de lo que GitHub mostraba esa mañana.

**Chequeo narrow-not-widen:** el conjunto de acciones de DevLead es idéntico antes y después. Lo que se agrega es un dato en el standup.

---

## §daily-agenda — Avisar el plan no es pedir permiso; ajustarlo no es autorizar

En el perfil `sweep-plan-driven` la cola de trabajo sale de `envelope.sh plan`: la policy que escribió el usuario ya autorizó ese trabajo (§inv6-governance). La **agenda** (`.devlead/scripts/agenda.sh`) es cómo el usuario se entera de esa cola antes de que se ejecute, y cómo la ajusta.

**Decisión del usuario (2026-11-13):** DevLead manda la lista de lo que va a hacer hoy y arranca; no espera un OK. Si el usuario tiene otra prioridad, la cambia. Esto es legal bajo A1 porque la autorización no la da la agenda: ya la dio el envelope. La agenda no agrega un paso de aprobación y no quita ninguno.

**El circuito:**

1. El sweep de la mañana (`sweep.sh`) guarda la cola de cada repo incluido (`agenda.sh publish`) y manda UN aviso por corrida, nivel `agenda` (§escalation-channel: llega al teléfono con prioridad normal; no es un `need`).
2. El usuario, si quiere, ajusta: `devlead agenda first <N>`, `devlead agenda skip <N>`, `devlead agenda reset`.
3. El run (`/sweep-execute` plan-driven, E1.4 Paso 3) deriva su cola de nuevo — A2, nunca usa la cola guardada — y la pasa por `agenda.sh apply`.

**Lo que un ajuste de agenda puede hacer:** reordenar issues de la cola, o sacar issues de la cola por hoy.

**Lo que un ajuste de agenda no puede hacer:**

1. **No agrega trabajo (A1).** `agenda.sh apply` nunca emite un número que no recibió por stdin, sea cual sea el contenido de sus archivos de estado; una línea dañada se ignora. Una issue que la policy del envelope dejó afuera no entra por la agenda. Verificado por test (`test/unit-agenda.sh`), no por prosa, y repetido como regla en E1.4 Paso 3.
2. **No concede ni amplía autoridad (A3).** `open-pr.sh`, `merge.sh`, `envelope.sh`, los gates y `forbidden-check.sh` no leen la agenda.
3. **No sobrevive al día.** Los ajustes pertenecen a una agenda publicada; publicar la del día siguiente los descarta. Un cambio permanente de prioridad es policy, y la policy se cambia en el envelope o con labels (`select.exclude_labels`, `order.priority_labels`).
4. **No destraba un fallo.** Si `agenda.sh apply` falla o devuelve algo ilegible, el repo se aparca (`agenda-error`); DevLead no adivina qué quiso el usuario.

**Quién ajusta:** el usuario — en la terminal con `devlead agenda`, o pidiéndolo en una sesión de `/arranquemos`. Los perfiles autónomos solo corren `publish` (el sweep) y `apply` (el run); nunca `first`, `skip` ni `reset`.

**Issue salteada y dependencias:** una issue salteada queda como `skipped-by-agenda` y cuenta como bloqueada para sus dependientes: con `on_failure.skip_dependents: true` E2.2 los aparca en vez de construirlos sobre trabajo que hoy no se hace; con `false` rige el chequeo de siempre de `branch.sh`. Poner primero (`first`) una issue que depende de otra todavía no trabajada es decisión del usuario: la agenda no reordena dependencias por él, y el chequeo de `branch.sh` sigue aplicando.

**Privacidad del aviso:** el push viaja por un servicio de terceros. Por defecto lleva solo cantidades ("2 repo(s), 5 issue(s) today"); la lista con nombres de repo y títulos queda en la bandeja local, y sale de la máquina únicamente si el usuario puso `DEVLEAD_NOTIFY_DETAIL=1` en `notify.env`.

**Chequeo narrow-not-widen:** antes, el run plan-driven trabajaba toda la cola de la policy en el orden de la policy. Después, trabaja esa cola o un subconjunto de ella, en un orden que el usuario pudo cambiar. El conjunto de issues alcanzables no crece nunca.

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
| `.claude/commands/sweep-discover.md` | Espejo no-normativo de A1-A4 inline + referencia a §sweep-discover-profile | Ver §sweep-discover-profile |
| `.claude/commands/cerremos.md` | Espejo no-normativo de A1-A4 inline + referencia a §A1 | Ver §A1 |

**Regla de tie-breaker:** el único texto normativo es GOVERNANCE.md. Los bloques A1-A4 inline en comandos y en CLAUDE.md son ESPEJOS de §Layer-0 por presencia-en-contexto. Si divergen del texto de GOVERNANCE.md, GOVERNANCE.md gana y el espejo se corrige.
