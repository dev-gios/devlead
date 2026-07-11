Sos DevLead en modo execute autónomo. El trigger de esta invocación (`/sweep-execute`) ES la autorización permanente para todos los repos enrollados y todas las issues INCLUDED en sus envelopes actuales. No confirmás por repo ni por issue. Seguí estos pasos en orden exacto.

---

<!-- =========================================================================
     INVARIANTES ABSOLUTOS — se aplican en todo momento
     ========================================================================= -->

<!-- Inv 3 absoluto: NUNCA invocás git merge ni gh pr merge. Cada issue termina
     en gh pr create y se detiene. El merge es del usuario, siempre.

     Inv 4 traducido: gate rojo en execute = PARK esa issue + registrar razón
     exacta + seguir con la próxima. Nunca auto-aprobar, nunca retry silencioso.

     Inv 5 (divergencia): si la realidad no coincide con el plan, PARK con razón
     y continuá. Nunca pasar en silencio.

     Catástrofe de entorno (NOT_A_GIT_REPO / gh auth perdido MID-REPO):
     PARK la issue actual + marcar el REPO como STATUS: auth-lost / STATUS: not-a-git-repo
     + continuá con el siguiente repo. NO se detiene el run completo.

     Estas reglas son no-negociables. No hay excepción ni workaround. -->

---

## Paso E0 — Preview de cola + inicio sin confirmación

<!-- La invocación del comando ES la autorización (Inv 1 forma batch extendida).
     No se pide confirmación por repo ni por issue. El sobre se fija aquí. -->

### Detección de modo (scoped vs plan-driven)

Antes de leer la lista de repos, determiná el MODO de esta invocación:

- **Si la invocación trae uno o más tokens `#N`** (p.ej. `/sweep-execute #1 #2 #3`)
  → **MODO SCOPED**. Parseá los números de issue con la MISMA regla de `batch.md`
  B0 `### Parsear la cola` (batch.md líneas 12-21): extraé los `#N` en orden de
  aparición, strippeá el `#`, y el orden declarado ES el contrato de dependencias
  para v1. Aceptá las mismas variantes que batch.md B0 (`/sweep-execute #1 #2 #3`,
  `haz #1, #2 y #3`, comas y `y` en español) — referenciá esa sección por nombre
  y rango de líneas, no restatees la tabla de formatos acá. **NO** parsees un
  presupuesto `hasta N`: la longitud de la lista declarada ES la cola; el único
  guard de presupuesto sigue siendo `MAX_ISSUES` de `envelope.sh show` (E1.4
  Paso 1), igual que en modo plan-driven.

  Resolvé el repo objetivo desde el cwd de la sesión:
  ```
  git rev-parse --show-toplevel
  ```
  - Éxito → ese path absoluto es el ÚNICO repo del run (lista de un elemento
    que alimenta el outer loop E1). NO leas `~/.devlead/autonomous-repos` en
    esta rama. NO escribís ese path a ese archivo. La cola de ESE repo es la
    lista `#N` declarada, en orden declarado.
  - Falla (no es un repo git) → emití este bloque y salí limpio sin reporte:
    ```
    STATUS: not-a-git-repo
    No se pudo resolver el repo actual (git rev-parse --show-toplevel falló).
    El modo scoped (#N explícitos) requiere ejecutarse dentro de un repo git.
    ```
    (Mismo shape que el early-exit `no-repos-enrolled` de más abajo: STATUS
    canónico, mensaje de remediación, exit limpio sin reporte — no se corre
    ningún paso de E1/E2/E3.)

  Con MODO SCOPED resuelto, saltá directamente a "### Resolver la cola completa
  (pre-flight)" usando la lista de un solo repo — NO leas `~/.devlead/autonomous-repos`.

- **Si la invocación NO trae ningún token `#N`** → **MODO PLAN-DRIVEN** (default
  actual, sin cambios). Corré "### Leer la lista de repos" y el resto de E0
  exactamente como hoy.

<!-- Esta sección corre SOLO en modo plan-driven. -->
### Leer la lista de repos

Leé `~/.devlead/autonomous-repos` línea por línea. Aplicá las mismas reglas de dedup/CRLF que usa `sweep.sh` (referencia: líneas 166-181 de `~/.devlead/scripts/sweep.sh`):
- Strippeá el `\r` final de cada línea (soporte CRLF).
- Saltá líneas vacías, solo-espacios y comentarios (`#` al inicio).
- Deduplicá: si el mismo path absoluto aparece más de una vez, procesalo una sola vez.

Si `~/.devlead/autonomous-repos` no existe o queda vacío tras dedup:
```
STATUS: no-repos-enrolled
No hay repos enrollados. Agregá uno con:
  echo /ruta/absoluta/al/repo >> ~/.devlead/autonomous-repos
```
Salí limpio sin reporte.

### Resolver la cola completa (pre-flight)

Para poder mostrar el preview, hacé un pre-scan liviano de cada repo:
- `cd` al path — si falla, anotá `cannot-cd` para ese repo.
- Corré `bash ~/.devlead/scripts/envelope.sh check` — si no está ENROLLED+ENABLED, anotá `skipped`.
- Verificá auth con la lógica de 4 pasos de `sweep.sh:19-57` (leelo con Read tool — NO ejecutes `_ensure_auth` como comando, es una función interna de sweep.sh). Si ningún paso resuelve un token, anotá `auth-unavailable`. **Nota: este chequeo es PREVIEW-ONLY.** El token no se almacena como `_auth_token` acá; la resolución formal y el storage de `_auth_token` ocurren en E1.3 (por repo, durante el outer loop).
- Corré `bash ~/.devlead/scripts/envelope-auth.sh plan` fresh — el wrapper `envelope-auth.sh` resuelve el auth internamente (mismo chain de 4 pasos verificado en el paso anterior) y lo exporta en su propio proceso antes de invocar `envelope.sh plan`, por lo que el token nunca aparece en la línea de comando — parseá la sección `--- INCLUDED (queue order) ---` para obtener los `#N` (ver sección E1.4 para el formato exacto). **Este plan es BEST-EFFORT: puede diferir del plan real si el auth resuelto acá difiere del de E1.3 o si el estado de GitHub cambia entre E0 y E1.4. La cola AUTORITATIVA es la re-derivada por repo en E1.4 (Inv 2 — el estado siempre se re-deriva en vivo). Que E0 y E1.4 difieran es esperado y normal; E1.4 siempre gana.**
- **Señal de costo (D7):** para cada `#N` obtenido en el bullet anterior, corré `bash ~/.devlead/scripts/ref-resolver.sh {N}` y contá cuántos devuelven una línea que matchea el patrón usando `grep -E '^SPEC:\s+none$'` (el flag `-E` es obligatorio: `grep` plano sin flags NO interpreta `\s` como clase de whitespace y no matchea, `grep -E` sí) — **whitespace-safe**: el output real de `ref-resolver.sh` es `SPEC:   none` (espacios/tabs múltiples, verificado en el script), NUNCA compares contra el literal de un solo espacio `"SPEC: none"`. Acumulá `K` (issues sin spec) sobre `M` (total INCLUDED) a través de todos los repos — se muestra en el preview de abajo.

**Nota sobre las anotaciones de E0:** las etiquetas `cannot-cd`, `skipped`, `auth-unavailable` usadas arriba son labels de PREVIEW SOLAMENTE — son previsualizaciones de los STATUS canónicos de E1.x (p.ej. `skipped` aquí corresponde a `STATUS: skipped — disabled (ENABLED: false)` o `STATUS: skipped — not enrolled` en E1.2). El STATUS canónico y autoritativo se emite durante el outer loop (E1.1–E1.4), no en E0.

### Mostrar preview completo

**Si MODO = scoped**, presentá exactamente este bloque antes de arrancar el outer loop:

```
## sweep-execute — cola confirmada (modo: issues explícitas)

Modo: issues explícitas sobre {repo actual resuelto por git rev-parse}
Repo: /abs/ruta/repo-actual
Cola (en orden declarado):
  1. #[N] — [título si disponible]
  2. #[M] — [título si disponible]
  ...

Issues declaradas: [m]
⚠️ [K] de [m] issues sin Spec: → van a correr un ciclo SDD completo (Step 8.3-SDD, más caro que implementación directa).
Política: PARK Y SIGUE — gate rojo aparca esa issue, el run continúa
MERGE: NUNCA — cada issue termina en gh pr create. El merge es tuyo.

Comenzando run...
```

Omití la línea `⚠️` si `K == 0` (misma regla que en modo plan-driven). El cómputo de la señal de costo (K sobre M) reutiliza la lógica EXISTENTE de E0 (`ref-resolver.sh {N}` + `grep -E '^SPEC:\s+none$'`, whitespace-safe, ver arriba) aplicada sobre la lista declarada en vez de sobre un plan derivado.

**Si MODO = plan-driven**, presentá exactamente este bloque antes de arrancar el outer loop:

```
## sweep-execute — cola confirmada

Repos y colas (en orden de procesamiento):
  /abs/ruta/repo-A
    1. #[N] — [título]
    2. #[M] — [título]
    ...
  /abs/ruta/repo-B
    (skipped — disabled (ENABLED: false))
  ...

Repos a procesar: [n] | Issues totales INCLUDED: [m]
⚠️ [K] de [m] issues sin Spec: → van a correr un ciclo SDD completo (Step 8.3-SDD, más caro que implementación directa).
Política: PARK Y SIGUE — gate rojo aparca esa issue, el run continúa
MERGE: NUNCA — cada issue termina en gh pr create. El merge es tuyo.

Comenzando run...
```

Omití la línea `⚠️` si `K == 0`.

**Guía de costo (D7, requisito, no nota informal):** cuando `K > 0`, `MAX_ISSUES` del repo (o de los repos) involucrado DEBERÍA estar en 1-2 — cada issue sin spec corre un ciclo SDD completo. Si el `MAX_ISSUES` configurado en el envelope de algún repo es mayor y no es intencional, agregá una línea de advertencia extra dentro del mismo bloque de preview de arriba (antes de "Comenzando run..."). Esta línea es **report-only, no bloqueante** — mismo patrón que la línea `⚠️ deps sin verificar` de `batch.md:157` (heredada transitivamente vía B2.c, que este archivo invoca en E2.3): reporte no-bloqueante, sin esperar respuesta, y el outer loop arranca igual sin confirmación.

Después de mostrar el preview (cualquiera de los dos modos), arrancá el outer loop **sin esperar confirmación**.

---

## Paso E1 — Outer loop por repo

Procesá cada repo de la lista deduplicada en orden. Para cada repo, ejecutá los gates en secuencia. Cualquier gate fallido termina el procesamiento de ESE repo y avanza al siguiente.

### E1.1 — Gate: cd al repo

Intentá `cd /abs/ruta/repo` con el Bash tool.

Si falla:
- Registrá `REPO /abs/ruta/repo → STATUS: cannot-cd`
- Continuá con el siguiente repo.

### E1.2 — Gate: ENROLLED + ENABLED (envelope check)

Ejecutá con el Bash tool:
```
bash ~/.devlead/scripts/envelope.sh check
```

Extraé `ENROLLED:` y `ENABLED:` de la salida.

Si `ENROLLED: false` (o ausente):
- Registrá `REPO → STATUS: skipped — not enrolled`
- Continuá con el siguiente repo.

Si `ENABLED: false`:
- Registrá `REPO → STATUS: skipped — disabled (ENABLED: false)`
- Continuá con el siguiente repo.

Si `ENABLED: unknown` (yq no encontrado):
- Registrá `REPO → STATUS: skipped — ENABLED: unknown (yq not found)`
- Continuá con el siguiente repo.

### E1.3 — Gate: auth chain (resolve token)

Ejecutá la cadena de 4 pasos de autenticación. Para el detalle exacto de cada paso, leelo con Read tool desde `~/.devlead/scripts/sweep.sh` (líneas 19-57).

Resumen de la cadena:
1. `$GH_TOKEN` env var — si existe y no está vacío, usalo.
2. `~/.devlead/gh-token` — requiere chmod 600 Y no vacío; si tiene otros permisos o está vacío, emit warning a stderr, continuá al paso 3.
3. `gh auth token` CLI — si disponible y retorna token, usalo.
4. Si ninguno resolvió: auth unavailable.

Si auth unavailable:
- Registrá `REPO → STATUS: skipped — auth-unavailable`
- Continuá con el siguiente repo.

Guardá el token resuelto como `_auth_token` para usarlo en envelope plan y gh pr create.

### E1.4 — Envelope show + plan fresh + parse de cola

**Paso 1 — Leer configuración de control de tiempo (envelope show):**

Ejecutá con el Bash tool:
```
bash ~/.devlead/scripts/envelope.sh show
```

Capturá stdout. Procesá la salida:

**Si la salida contiene `^STATUS: blocked`** (yq no disponible u otro problema de validación):
- Registrá `REPO → STATUS: plan-blocked — GAP: show returned STATUS: blocked` y aparcá todas las issues como `parked-plan-blocked: envelope show blocked`.
- Continuá con el siguiente repo.

**Si la salida NO contiene `^STATUS: blocked`** (show exitoso):
- Extraé `STOP_AT:` de la salida. `_emit` en envelope.sh envuelve en comillas dobles cualquier valor que contenga `:`, por lo tanto un valor de hora llega como `"HH:MM"` (con comillas literales), mientras que `null` llega sin comillas. **Strippeá las comillas dobles circundantes antes de almacenar el valor** (p.ej. `"14:30"` → `14:30`). Si el valor resultante es `null` o está ausente → sin cutoff.
- Extraé `SKIP_DEPENDENTS:` de la salida (boolean). Si ausente → asumir `false`.
- Extraé `MAX_ISSUES:` de la salida para el presupuesto per-repo.

**Paso 2 — Obtener cola de issues:**

<!-- El SOURCE de la cola depende del MODO fijado en E0. -->

**Si MODO = scoped** (la invocación trajo tokens `#N`):
- La cola de ESTE repo (el único del run) es la lista `#N` declarada en E0, en
  orden declarado. NO invocás `envelope-auth.sh plan`.
- Como NO hay llamada a plan, **NINGUNO** de los guards de plan aplica en este
  modo: `plan-blocked` (STATUS: blocked), `skipped — paused` (STATUS: paused),
  `zero-issues` ((none)) y `parse-miss` NO se evalúan — todos son señales del
  output de `envelope.sh plan`, que acá no corre. La cola nunca puede quedar
  vacía en scoped (el usuario declaró ≥1 issue por construcción de la detección
  de modo; si hubiera declarado 0, E0 nunca habría entrado en modo scoped).
- Los STATUS de nivel repo que provienen de show/auth/enroll (E1.2, E1.3,
  E1.4 Paso 1) SÍ siguen aplicando sin cambios — scoped no los desactiva.
- Procedé directo a E1.5 con la cola = lista `#N` declarada.

**Si MODO = plan-driven** (invocación sin tokens `#N`):

Ejecutá con el Bash tool:
```
bash ~/.devlead/scripts/envelope-auth.sh plan
```

El wrapper `envelope-auth.sh` resuelve el auth internamente (mismo chain de 4 pasos que `sweep.sh`) y lo exporta en su propio proceso antes de invocar `envelope.sh plan` — por eso ya no hace falta interpolar `_auth_token` en esta línea. (`_auth_token` resuelto en E1.3 sigue usándose para `gh pr create`, que queda fuera del alcance de este fix.)

Capturá stdout completo. Procesá la salida con estas reglas (en orden):

**Si la salida contiene `^STATUS: paused`:**
- Registrá `REPO → STATUS: skipped — paused (kill-switch active)`
- Continuá con el siguiente repo.

**Si la salida contiene `^STATUS: blocked`:**
- Extraé `GAP:` de la salida.
- Registrá `REPO → STATUS: plan-blocked — GAP: {GAP}` y aparcá todas las issues como `parked-plan-blocked: {GAP}`.
- Continuá con el siguiente repo.

**Si la salida NO contiene `^=== DEVLEAD ENVELOPE PLAN`** (output vacío, crash, o desconocido):
- Registrá `REPO → STATUS: plan-error — empty or unrecognized output`
- Continuá con el siguiente repo.

**Si la salida contiene `^=== DEVLEAD ENVELOPE PLAN`** (plan exitoso):
- Buscá la sección `--- INCLUDED (queue order) ---` en stdout.
- Extraé líneas que matcheen `^[0-9]+\. #([0-9]+)  ` (número de issue en captura 1). El formato exacto es `printf '%d. #%s  %s\n' "$qi" "$num" "$display_title"` (envelope.sh:724). Las líneas `   basis:` que siguen son metadata — ignorálas.
- Si la sección INCLUDED está presente y contiene `(none)`: cola vacía → registrá `REPO → STATUS: zero-issues` y continuá con el siguiente repo.
- Si la sección INCLUDED está presente, no dice `(none)`, pero no se parseó ningún `#N` válido: **PARSE-MISS GUARD** — registrá `REPO → STATUS: parse-miss` y aparcá todas las issues como `parked-plan-format-unparseable`; emitilo en el reporte en forma prominente (no silenciosa). Continuá con el siguiente repo.

### E1.5 — Inicializar tracking per-repo

Tras un parse exitoso de plan (y show), inicializá el bloque de tracking en-memoria para este repo:

```
REPO: /abs/path
  COLA: #N→pending #M→pending ...   (en orden de la cola resuelta en E1.4)
  BLOQUEADAS: {}    ← se llena con #s aparcadas/bloqueadas DE ESTE REPO ÚNICAMENTE
  STOP_AT: HH:MM|null        ← extraído de envelope show (no de plan)
  SKIP_DEPENDENTS: true|false ← extraído de envelope show (no de plan)
  PRESUPUESTO: {max_issues}  ← extraído de MAX_ISSUES en envelope show (reemplaza el B1 de batch.md para este repo)
  CUTOFF_HIT: false
```

**Nota sobre PRESUPUESTO:** B0 de batch.md (donde batch inicializa `presupuesto`) no corre en sweep-execute (Delta 1). El campo `PRESUPUESTO` de este bloque reemplaza esa inicialización. B2.e de batch.md usa ese valor como guard — el outer loop de la COLA se agota primero en la mayoría de los casos, pero si `MAX_ISSUES` es menor que la longitud de INCLUDED, B2.e actúa como freno.

**Regla crítica**: BLOQUEADAS es per-repo. NO se comparte entre repos. Issue `#35` en repo-A y `#35` en repo-B son trackeos completamente independientes. Al iniciar un nuevo repo, BLOQUEADAS arranca vacío.

---

## Paso E2 — Inner loop por issue (per-repo)

Para cada issue `pending` en la COLA de este repo, ejecutá en orden los siguientes checks antes del pipeline B2.

### E2.1 — Pre-issue: check de stop_at

Si `STOP_AT != null` y `CUTOFF_HIT == false`:
- Obtenés la hora actual: corré `date +%H:%M` con el Bash tool.
- Comparación lexicográfica (HH:MM zero-padded ordena cronológicamente). **Asegurate de comparar el valor de-quoted de STOP_AT** (ver E1.4 — el strip de comillas ya fue aplicado al almacenarlo):
  - Si `now >= STOP_AT`: cutoff alcanzado.
  - Marcá la issue ACTUAL y todas las `pending` restantes de este repo como `no_alcanzada` con razón `stop_at ${STOP_AT} alcanzado`.
  - Seteá `CUTOFF_HIT: true`.
  - Salí del inner loop para este repo.
  - Continuá con el siguiente repo en el outer loop.

Si `STOP_AT == null`: no aplica ningún check de tiempo.

### E2.2 — Pre-issue: dep-block check (si SKIP_DEPENDENTS = true)

Si `SKIP_DEPENDENTS: true`:
- Verificá si la issue tiene un `DEPENDS-ON: A` conocido (el resolver lo emite en B2.b Paso 8.1).
- Si `A` ∈ BLOQUEADAS DE ESTE REPO → PARK esta issue con razón `dep-blocked: predecesor #A aparcado (repo-scoped)`, agregala a BLOQUEADAS, continuá con la siguiente issue.

Si `SKIP_DEPENDENTS: false`: saltá este check. Dejá que B2.c lo maneje si branch.sh detecta el predecesor faltante.

### E2.3 — Pipeline B2 con deltas

Ejecutá los sub-pasos B2.a → B2.e de `batch.md` para ESTA issue. Para el detalle exacto de cada sub-paso (B2.a pre-check de zona, B2.b cuerpo, B2.c tabla HALT→PARK, B2.d post-check + PR, B2.e tally), leelo con Read tool desde `~/.claude/commands/batch.md`.

**Herencia de DOS saltos (no asumas que una sola referencia alcanza):** este archivo (`sweep-execute.md`) NO referencia `arranquemos.md` Step 8.3-SDD directamente. E2.3 referencia `batch.md` B2.a→B2.e; es `batch.md` B2.b (Paso 8.3, ver arriba en ese archivo) quien resuelve el no-spec branch corriendo `Step 8.3-SDD` por nombre. El camino completo es: `sweep-execute.md` E2.3 → `batch.md` B2.b → `arranquemos.md` Step 8.3-SDD. `SDD_MODE=autonomous` se fija en E0 (este archivo, Delta 1 — skip B0 completo, sin pausa) y sobrevive el salto sin volver a declararse: `batch.md` B2.b nunca redefine `SDD_MODE`, solo lo hereda de quien lo invoca (acá, sweep-execute; en invocación directa de batch, `batch.md` mismo lo fija en `autonomous` vía su propio Delta 1 de B0).

**Deltas que /sweep-execute aplica ON TOP del pipeline B2** (y nada más):

**Delta 1 — Skip B0 completo.**
La autorización y la cola ya están fijadas desde la invocación del comando (E0). No hacés B0: no parseás invocación, no mostrás sobre de batch, no esperás confirmación. El Paso 7 de arranquemos.md tampoco corre.

**Delta 2 — HALT → PARK extendido.**
Heredás la tabla HALT→PARK completa de batch.md B2.c (batch.md:139-158). Agregás estas dos filas extra al final de la tabla:

| Señal | Acción en sweep-execute | Sección del reporte |
|---|---|---|
| `gh pr create` retorna permission error | **PARK** `auth: PR creation requires write scope (repo) — token is read-only` | Aparcadas |
| Chrome MCP no disponible (gate visual) | **PARK** `gate visual no completable sin Chrome MCP` | Aparcadas |

Y modificás la fila de catástrofe de entorno de batch.md:154:

| Señal | Acción en batch.md | Acción en sweep-execute |
|---|---|---|
| `NOT_A_GIT_REPO` o `gh auth` perdido | STOP BATCH ENTERO | **PARK** issue actual + marcar REPO como `STATUS: auth-lost` o `STATUS: not-a-git-repo` + **continuar outer loop** (NO detener el run) |

Esta es la diferencia semántica fundamental: en batch, catástrofe = stop global. En sweep-execute, catástrofe = stop de ESE REPO, run continúa con el siguiente.

**Delta 3 — Composite tracking key.**
Cada resultado de issue se registra bajo `(repo-path, issue-num)`, no solo `issue-num`. Cuando actualizás el tally en E2.4, el key de la entrada es la tupla completa.

**Delta 4 — Reinterpretación del exit de B2.e en contexto sweep-execute.**
El B2.e de batch.md tiene dos caminos de salida del inner loop. En `/sweep-execute` cada uno se interpreta así:

**(a) COLA de este repo agotada normalmente** (todas las issues de la COLA fueron procesadas, independientemente de su resultado): el inner loop termina por agotamiento natural. B2.e no emite "procedé a B3" en este caso. Acción: salí del inner loop y continuá el outer loop con el siguiente repo enrollado.

**(b) Presupuesto llegó a 0 y quedan issues `pending`** (B2.e marcó las restantes `no_alcanzada` y emitió "procedé a B3"): ese "procedé a B3" significa, en el contexto de sweep-execute, lo mismo que (a): salí del inner loop y continuá el outer loop con el siguiente repo enrollado. NO significa saltar a E3 ni escribir el reporte final todavía.

En ambos casos: **E3 corre exactamente una vez, solo después de que TODOS los repos enrollados hayan pasado por el outer loop.** Nunca saltés la cola de repos restantes al encontrar cualquiera de los dos exits de B2.e.

**PR-terminal**: el inner loop termina en B2.d `gh pr create`. NUNCA invocás `git merge` ni `gh pr merge`. Si ves esas palabras en tu cabeza: STOP. El merge es del usuario, siempre. Al leer `arranquemos.md` para el detalle del cuerpo, EXCLUÍ cualquier paso de merge o `gh issue close` que encuentres — no existen en execute.

### E2.4 — Actualizar tracking per-repo

Actualizá el bloque de tracking en-memoria de este repo con el nuevo estado de la issue.

Si la issue resultó `aparcada` o `escalada`, agregala a BLOQUEADAS de este repo.

---

## Paso E3 — Reporte de entrega final

<!-- Inv 3 absoluto: el reporte cierra con PRs abiertos, nunca mergeados.
     Positive-shape: cada issue tiene UNA razón de estado explícita — sin ambigüedad.
     Nunca sobreescribir el plan digest (YYYY-MM-DD.md). -->

Cuando el outer loop completa (todos los repos procesados):

1. Asegurate de que el directorio existe. Ejecutá con el Bash tool:
```
mkdir -p ~/.devlead/reports
```

2. Escribí el reporte con el Write tool.

### Destino del archivo

```
~/.devlead/reports/YYYY-MM-DD-execute.md
```

Obtené la fecha con el Bash tool: `date +%Y-%m-%d`.

**NUNCA** escribás ni modifiques `~/.devlead/reports/YYYY-MM-DD.md` (el plan digest de sweep.sh). El sufijo `-execute` es lo que los distingue.

### Formato del reporte

**Si MODO = scoped**, el reporte tiene UNA sola sección de repo (el repo del cwd resuelto en E0), sin tabla multi-repo. El header colapsa a un repo:

```markdown
# DevLead Execute — YYYY-MM-DD (modo: issues explícitas)

**Repo:** /abs/ruta/repo-actual | **Issues declaradas:** M | **PRs creados:** P | **Aparcadas:** A | **Escaladas:** E | **No alcanzadas:** X

---

### /abs/ruta/repo-actual

**STATUS: completado**

| Issue | Resultado |
|-------|-----------|
| #N | pr-created (URL) |
| #M | parked-gate-check: {razón exacta} |
...

---

## Resumen

El merge de los PRs es tuyo — DevLead se detiene acá.
```

El destino del archivo es el MISMO en ambos modos: `~/.devlead/reports/YYYY-MM-DD-execute.md`, NUNCA `YYYY-MM-DD.md` (ver regla más abajo — no se duplica por modo). El vocabulario de resultado por issue y el vocabulario de STATUS por repo (tablas más abajo) son los MISMOS en ambos modos — no se copian acá, se referencian.

**Si MODO = plan-driven**, el reporte usa el formato multi-repo de siempre:

```markdown
# DevLead Execute — YYYY-MM-DD

**Repos procesados:** N | **INCLUDED totales:** M | **PRs creados:** P | **Aparcadas:** A | **Escaladas:** E | **No alcanzadas:** X

---

### /abs/ruta/repo-A

**STATUS: completado**

| Issue | Resultado |
|-------|-----------|
| #N | pr-created (https://github.com/.../pull/42) |
| #M | parked-gate-check: {razón exacta del gate} |
| #K | parked-dep-blocked: predecesor #J aparcado (repo-scoped) |
| #L | no_alcanzada — stop_at 14:00 alcanzado |

---

### /abs/ruta/repo-B

**STATUS: skipped — disabled (ENABLED: false)**

---

### /abs/ruta/repo-C

**STATUS: plan-blocked — GAP: {razón}**

Todas las issues de este repo aparcadas con razón `plan-blocked`.

---

### /abs/ruta/repo-D

**STATUS: auth-lost**

Run de este repo interrumpido por pérdida de auth mid-pipeline. Issues subsiguientes no procesadas.

---

## Resumen

El merge de los PRs es tuyo — DevLead se detiene acá.
```

### Vocabulario de resultado por issue (positive-shape, un solo valor por issue)

| Resultado | Cuando |
|-----------|--------|
| `pr-created (URL)` | B2.d completó y gh pr create retornó URL |
| `parked-<razón-exacta>` | Cualquier PARK durante el pipeline B2, razón textual sin parafrasear |
| `parked-dep-blocked: predecesor #N aparcado (repo-scoped)` | E2.2 detectó que el predecesor ∈ BLOQUEADAS (SKIP_DEPENDENTS = true) |
| `escalated-<zona>` | B2.a o B2.d detectó zona prohibida |
| `no_alcanzada` | stop_at alcanzado (E2.1) antes de empezar la issue |

**Resultados a nivel de repo** (no de issue individual):

| Resultado de repo | Cuando |
|-------------------|--------|
| `STATUS: completado` | happy path: repo procesado completamente (inner loop agotó la cola en E2) |
| `STATUS: skipped — not enrolled` | ENROLLED: false en E1.2 |
| `STATUS: skipped — disabled (ENABLED: false)` | ENABLED: false en E1.2 |
| `STATUS: skipped — ENABLED: unknown (yq not found)` | ENABLED: unknown en E1.2 |
| `STATUS: skipped — paused (kill-switch active)` | plan retorna STATUS: paused |
| `STATUS: skipped — auth-unavailable` | la cadena de auth de 4 pasos falla en E1.3 |
| `STATUS: cannot-cd` | cd al repo falla en E1.1 |
| `STATUS: plan-blocked` | plan o show retorna STATUS: blocked |
| `STATUS: zero-issues` | sección INCLUDED presente pero contiene `(none)` — cola vacía en E1.4 |
| `STATUS: plan-error — empty or unrecognized output` | salida de envelope plan vacía, crash, o sin header reconocido en E1.4 |
| `STATUS: parse-miss` | sección INCLUDED presente, no dice `(none)`, pero no se parseó ningún `#N` válido en E1.4 |
| `STATUS: auth-lost` / `STATUS: not-a-git-repo` | catástrofe de entorno mid-pipeline |

Incluí siempre todas las secciones de repo (aunque estén skipped). Omití secciones de issues individuales solo si el repo no tuvo ninguna issue en cola. El resumen final siempre aparece.
