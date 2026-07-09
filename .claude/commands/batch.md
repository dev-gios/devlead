Sos DevLead en modo batch. El trigger de esta invocación ES la autorización explícita — no confirmás por tarea. Seguí estos pasos en orden exacto.

---

## Paso B0 — Leer el sobre UNA vez

<!-- Inv Fase 2: el sobre se lee y confirma UNA vez. Es inmutable durante el loop.
     El trigger "/batch" o "haz #N #M..." ya es la autorización (Inv 1 forma batch).
     No se repite la confirmación por issue — Paso 7 de arranquemos.md NO corre en batch. -->

### Parsear la cola

Extraé los números de issue de la invocación en el orden de aparición. El orden declarado ES el contrato de dependencias para v1.

Formatos aceptados:
- `/batch #12 #15 #18`
- `haz #12, #15, #18`
- `haz #12, #15 y #18 hasta 4`
- Cualquier variante en español con números de issue precedidos de `#`

Extraé también el presupuesto opcional ("hasta N"). Si no se especifica, presupuesto = cantidad de issues en la cola.

### Mostrar el sobre

Presentá exactamente este bloque antes de arrancar:

```
## Batch — sobre confirmado

Cola (en orden de procesamiento):
  1. #[N] — [título si disponible, o "sin título"]
  2. #[N] — ...
  ...

Presupuesto: [n] issues
Política: APARCA Y SIGUE — un gate rojo no para el batch, aparca esa issue y sigo con la siguiente
Zonas prohibidas (4):
  🚫 db-migrations    → migraciones de base de datos, archivos .sql, schema.prisma
  🚫 prod-config      → configuración de producción, .env.production, terraform, k8s
  🚫 auth-security    → auth/, security/, .pem, .key, secretos, rbac, oauth
  🚫 ci-cd            → .github/workflows/, .gitlab-ci.yml, Jenkinsfile, .circleci/

¿Dale para arrancar?
```

Esperá una confirmación explícita ("dale", "sí", "ok", o cualquier afirmativo) antes de continuar al Paso B1. Después de esta confirmación, los parámetros son fijos.

---

## Paso B1 — Inicializar tracking en-memoria

<!-- ADR-4: tracking en-memoria únicamente. CERO archivo de estado en disco.
     El estado real del *qué* vive en GitHub; state.sh es la fuente de verdad. -->

Mantené en la conversación el siguiente tally. Actualizalo al cerrar cada iteración B2:

```
COLA BATCH:
  #[N]  → pending
  #[M]  → pending
  ...
PRESUPUESTO: [n] restantes
BLOQUEADAS: {} ← set vacío; se va llenando con #s de issues aparcadas/bloqueadas
```

Estados posibles por issue: `pending` → `pr_listo` | `aparcada` | `escalada` | `no_alcanzada`

El set `BLOQUEADAS` acumula números de issue que fueron aparcados o bloqueados (por gate, dep, o zona). Se consulta al inicio de cada iteración para detectar dependencias transitivas: si la issue actual declara `DEPENDS-ON: A` y A ∈ BLOQUEADAS → PARK sin empezar, agregar a BLOQUEADAS, seguir.

Regla: NUNCA escribas un archivo `.devlead/batch-state.json` ni ningún otro archivo de tracking de estado del batch.

---

## Paso B2 — Loop por issue

Procesá cada issue `pending` en orden, mientras presupuesto > 0.

Para cada issue, ejecutá en orden los sub-pasos B2.a → B2.e.

---

### B2.a — Pre-check de zona prohibida

<!-- ADR-2, capa 1: pre-check best-effort sobre paths derivados.
     Si BLOCKED → la issue se ESCALA (semánticamente distinta de aparcada: nunca se tocó).
     Inv 5: no procesar issues en zona prohibida bajo ninguna circunstancia. -->

Derivá los paths candidatos para esta issue EN ESTE ORDEN de confianza:
1. **Labels de la issue** — `area:auth`, `area:db`, `ci`, `infra`, `security`, `migration` mapean directo a zona.
2. **Paths mencionados en el body de la issue.**
3. **Paths mencionados en el Spec o Design doc** resuelto en B2.b (si ya disponible del run anterior).

Ejecutá con el Bash tool:

```
bash ~/.devlead/scripts/forbidden-check.sh <paths-candidatos>
```

Si `STATUS: blocked`:
- Marcá la issue `escalada` con `ZONE: {zona}` y `PATH: {path}` registrado.
- NO proceses la issue. Continuá al siguiente issue.

Si `STATUS: clear` → procedé a B2.b.

Si los paths candidatos no se pueden derivar con certeza (issue sin labels ni referencias) → anotá "pre-check sin paths confiables — delegando a capa 2 (B2.d)" y procedé a B2.b.

---

### B2.b — Cuerpo del pipeline (inner loop)

<!-- ADR-1: batch.md NO re-prosa Pasos 8-10. Los referencia como cuerpo con 2 deltas.
     Fuente de verdad del cuerpo: arranquemos.md. Si necesitás el detalle exacto de
     cualquier sub-paso, leelo con Read tool desde ~/.claude/commands/arranquemos.md. -->

Ejecutá los siguientes pasos de `arranquemos.md` para ESTA issue, en este orden exacto:

- **Paso 8.1** — Resolver spec de la issue (`ref-resolver.sh {issue_num}`) — capturá `DEPENDS-ON:` si aparece
- **Paso 8.2** — Crear la rama (`branch.sh {issue_num} "{issue_title}" {type} [{dep_num}]`) — pasá `dep_num` como 4to arg solo si Paso 8.1 emitió `DEPENDS-ON:`
- **Paso 8.3** — Pipeline principal (con spec si encontrado, directo si no)
- **Paso 8.4** — QA gates (`gate-check.sh`)
- **Paso 9** — Gate visual de frontend (SOLO si Paso 8.1 encontró `DESIGN: {path}`)

Cada sub-paso es un gate. Si alguno retorna blocked/error → interceptá la señal en B2.c (no en Paso 8 se escala al usuario — en batch se aparca).

**Deltas que batch aplica al cuerpo** (y NADA más):
1. **Skip Paso 7** — la autorización ya se dio en B0. No preguntes confirmación por issue.
2. **HALT → PARK** — toda señal que en single-task dice "HALT y escalá al usuario" acá dice "PARK esta issue con la razón, seguí con la próxima" (ver tabla B2.c).
3. **Dep-check antes de Paso 8.1** — si la issue ya tiene `DEPENDS-ON` conocido (de un run anterior del resolver) y ese número ∈ BLOQUEADAS → PARK sin empezar (no corras el resolver). Si no hay info previa, dejá que Paso 8.1 corra y aplicá B2.c tras obtener `DEPENDS-ON:`.

Paso 8.5 (abrir el PR) NO se ejecuta acá — se ejecuta en B2.d después del post-check.

Ningún paso de merge ni cierre de issue se ejecuta NUNCA en batch ni en sweep — el pipeline termina en `gh pr create` (B2.d). Si al leer `arranquemos.md` encontrás un paso de merge o `gh issue close`, IGNORALO: el merge es del usuario, siempre (Inv 3).

---

### B2.c — Interceptar señales HALT → PARK

<!-- ADR-3: traducción completa de señales. El gate en sí no cambia — solo cambia
     qué hace el orquestador con la señal. -->

Cuando cualquier sub-paso de B2.b retorna blocked o error, aplicá esta tabla:

| Señal | Acción en batch | Sección del reporte |
|---|---|---|
| `branch.sh STATUS: blocked` (dirty repo, detached HEAD, no dev) | **PARK** con razón exacta del GAP | 🅿️ Aparcadas |
| `branch.sh STATUS: blocked` GAP `predecesor #N no encontrado y no mergeado` | **PARK** con razón exacta + agregar issue a BLOQUEADAS | 🅿️ Aparcadas |
| `ref-resolver GAP: file not found` (spec no existe en esa ruta) | **PARK** "spec referenciado no encontrado: {path}" | 🅿️ Aparcadas |
| `ref-resolver GAP: multi-predecesor no soportado en v1` | **PARK** "multi-predecesor declarado — resolución manual requerida" | 🅿️ Aparcadas |
| `DEPENDS-ON: A` y A ∈ BLOQUEADAS | **PARK** "dep-blocked: predecesor #A aparcado", agregar issue a BLOQUEADAS | 🅿️ Aparcadas |
| `ref-resolver SPEC: none` (sin spec) | **Continuar** sin spec (igual que single-task) | — |
| `DEP-CHECK: unavailable` (del resolver) | **Continuar** — nunca PARK; anotá `"⚠️ deps sin verificar (gh ausente)"` junto al PR en B3 | ⚠️ Junto al PR |
| Spec choca con código real (divergencia, Inv 5/7) | **PARK** "divergencia spec/código: {detalle}" | 🅿️ Aparcadas |
| `gate-check.sh` falla | **PARK** con la razón exacta del gate | 🅿️ Aparcadas |
| Gate visual > 3 iteraciones (Paso 9) | **PARK** "visual diff sin resolver tras 3 iteraciones" | 🅿️ Aparcadas |
| Chrome MCP no disponible (gate visual) | **PARK** "gate visual no completable sin Chrome MCP" | 🅿️ Aparcadas |
| `NOT_A_GIT_REPO` o `gh auth` perdido | **STOP BATCH ENTERO** — emitir reporte parcial con lo hecho hasta acá | (ver B3 catástrofe) |

Regla de PARK: siempre registrá la razón EXACTA del gate (sin parafrasear). Es lo que el dev necesita para entender qué pasó.

Regla de STOP: solo las dos señales catastróficas de entorno paran el batch. Cualquier otra falla es PARK de ESA issue, nunca del batch.

---

### B2.d — Post-check de zona prohibida + abrir PR

<!-- ADR-2, capa 2: verificación dura sobre diff real. Esta es la red de seguridad
     real porque los paths son los que la implementación REALMENTE tocó.
     Inv 5 forma post-impl: si tocó zona → PARK sin abrir PR (nunca silencioso). -->

Antes de abrir el PR, ejecutá con el Bash tool:

```
git diff --name-only origin/dev...HEAD | bash ~/.devlead/scripts/forbidden-check.sh
```

Si la salida es EXACTAMENTE `STATUS: clear`:
- Ejecutá **Paso 8.5** de `arranquemos.md` para esta issue (`gh pr create ...`).
- Capturá la URL del PR.
- Marcá la issue `pr_listo` con la URL.

Cualquier otra salida (`STATUS: blocked`, `STATUS: empty-diff`, o ausencia de `STATUS: clear`):
- **PARK** la issue. Razón exacta:
  - `STATUS: blocked` → `"tocó zona prohibida no predicha: {zona} — {path}"`
  - cualquier otro caso → `"post-check sin cambios / STATUS ausente"`
- **NO** abras el PR.
- Continuá al siguiente issue.

---

### B2.e — Actualizar tracking y presupuesto

Actualizá el tally en-memoria con el nuevo estado de la issue.

Decrementá el presupuesto en 1.

Si el presupuesto llegó a 0 y quedan issues `pending`:
- Marcá las restantes `no_alcanzada`.
- Salí del loop B2 → procedé a B3.

---

## Paso B3 — Reporte de entrega final

<!-- ADR-6: el reporte es la ÚNICA superficie de salida del batch.
     Inv 3 heredado: merge es del usuario, siempre.
     Inv Fase 2: cada issue tiene una sola razón de estado — sin ambigüedad. -->

Emití el reporte final. Usá exactamente este formato:

**Batch completado normal:**

```
## Batch completado — [N] issues procesadas

✅ PRs listos para review ([n])
- #[num] — [título] → [PR url]
- ...

🅿️ Aparcadas ([m])
- #[num] — [razón exacta del gate que falló]
- #[num] — tocó zona prohibida no predicha (auth-security): src/auth/guard.ts — no abrí PR
- ...

🚫 Escaladas — zona prohibida ([k])
- #[num] — caería en [zona]: [path/razón]. No la procesé.
- ...

⏸️ No alcanzadas (presupuesto agotado) ([j])
- #[num] — [título si disponible]
- ...

El merge de los PRs es tuyo — DevLead se detiene acá.
```

Omití las secciones con 0 ítems (salvo ✅ PRs, que siempre aparece aunque sea vacía).

**Si el batch fue interrumpido por catástrofe de entorno** (`NOT_A_GIT_REPO` o `gh auth` perdido):

```
## Batch interrumpido — [razón] tras [N] issues procesadas

[Incluí las secciones completadas hasta el momento del stop]

⏸️ No alcanzadas (batch interrumpido) ([j])
- #[num] — [título]
- ...

DevLead se detuvo por falla de entorno. Resolvé [razón] y volvé a lanzar.
```

---

<!-- Inv 3 absoluto heredado: el reporte cierra con PR abiertos, nunca mergeados.
     Inv Fase 2: la cola es fija desde B0 — el reporte refleja exactamente las issues
     del sobre original, sin extensiones. -->
