# DevLead — Agente de entrada (front door) para el día de trabajo

> Spec de diseño para construir con Claude Code.
> Estado: **diseño cerrado, listo para scaffolding.** Se construye primero el modo *single-task*; el *batch* se monta encima.

---

## 1. Qué es DevLead (en una frase)

DevLead es el **front door** del día: un orquestador con el que arrancas la jornada, que te dice qué tienes, qué quedó en camino y qué te conviene abordar, y que **despacha** el trabajo al pipeline que ya usas a diario (rama → SDD → implementación → tests → Chrome → qa gates → PR). No pica código él mismo: delega.

La interacción objetivo: dices *"arranquemos el día"*, te da el standup + recomendación; eliges; él ejecuta.

---

## 2. Decisiones de arquitectura ya tomadas

Estas son las que NO se redecidan al construir. Cada una tiene su porqué para que no se deshagan por inercia.

1. **DevLead NO es un subagente.** Es un **slash command** (`/arranquemos`) + su **persona en CLAUDE.md**, corriendo en la **sesión principal**. Razón: el front door tiene que vivir todo el día y conversar contigo; los subagentes son aislados, efímeros y devuelven-resumen-y-mueren. Desde la sesión principal, DevLead delega el trabajo pesado a los subagentes que ya tienes (SDD agent, implementador, auditores).

2. **Determinista donde se pueda, agéntico solo donde haga falta criterio.** El LLM no razona sobre git puro (branching, tags) — eso son scripts.

3. **Tres buckets de información, separados a propósito:**
   - *El qué* (issues, ramas, PRs, estado de CI) → **nunca se guarda**, se re-deriva en vivo cada mañana. Así nunca está stale ni alucinado.
   - *El por qué* (por qué paraste ayer, qué decidiste, blockers, próximo paso mental) → **sí se guarda** en un journal local. Ese contexto no vive en ningún otro lado.
   - *La referencia / intención* (FRD, DDT, criterios de aceptación, bundles de Claude Design) → estable; se carga **por-issue y on-demand**, nunca precargada. Detalle en la sección 5.

4. **Un solo checkpoint humano:** DevLead arma el plan y te lo presenta; tú confirmas *dónde arrancar*; de ahí es hands-off hasta que vuelven los PRs. El control está al inicio (apruebas el plan) y al final (revisas PRs), no por tarea.

5. **El merge siempre es tuyo.** DevLead nunca hace auto-merge a `dev`. Cada issue cierra en un PR.

6. **DevLead escala de vuelta cuando la realidad diverge del plan**, aunque hayas dado "arranca". Autorizas un plan, no un cheque en blanco contra sorpresas.

7. **DevLead es un modo acotado y opt-in, no un demonio siempre activo.** Se enciende con `/arranquemos` y se apaga con "cerremos el día"; esos dos comandos *son* la frontera que define cuándo el agente está al mando. Fuera de ellos usas Claude Code normal. La frontera es por convención (la persona vive siempre en `CLAUDE.md`, pero el workflow del día solo corre al invocarlo); se puede endurecer más adelante si hace falta.

---

## 3. Cómo funciona — ciclo del día (modo single-task)

### Al arrancar (`/arranquemos`)
1. Re-deriva el estado en vivo: ramas activas, PRs abiertos, estado de CI, issues asignadas.
2. Lee el journal local para recuperar el *porqué* de lo que quedó a medias.
3. Arma un **standup corto**: en camino / listo para review / nuevo entrante.
4. Te pregunta cuántas horas tienes hoy (para calibrar la recomendación).
5. **Recomienda** qué abordar — sugerencia rankeada, sin auto-arrancar nada.

### Al elegir tarea
6. Esperas tu OK. DevLead confirma el plan en una línea ("voy con SDD porque toca 3 módulos, ¿ok?") para que vetes el *enfoque*, no solo el resultado.
7. Despacha el pipeline: **rama desde el tag más cercano de dev → SDD si aplica (consume la referencia de la issue) → implementación → tests (hook) → Chrome MCP (E2E; diff visual contra el diseño si es front) → qa gates → PR.**

### Durante
8. Mantiene un *"dónde voy"* consultable: vuelves de una reunión, preguntas "¿en qué estábamos?", te resume sin re-leer todo.

### Al cerrar
9. **Write-back al journal**: qué avanzó, qué quedó a medias y *por qué*, próximos pasos.
10. El cierre lo disparas tú con *"cerremos el día"* — el journal lo escribe y gestiona el agente al 100%; tú nunca lo editas a mano.

> **Plantilla del journal (default, ajustable):** por entrada del día — qué se avanzó · qué quedó a medias y *por qué se paró* (lo más valioso) · próximo paso concreto · blockers / decisiones tomadas.
> *Opt-in para después:* que el agente anote una línea cada vez que cierra un PR, y "cerremos el día" solo consolide — red de seguridad por si cierras la terminal sin disparar el cierre.

---

## 4. Modo batch (se monta encima del single-task)

Disparador: le dices *"haz todo esto hoy"*. Eso **es** autorización explícita. El checkpoint se mueve de "antes de cada tarea" a "revisas N PRs al final". DevLead itera issue por issue de forma autónoma dentro de un **sobre** que defines una sola vez al arrancar:

- **Cola y orden** — la lista de issues y sus dependencias (si #M depende de #X, no se paralelizan).
- **Presupuesto** — tope de tiempo o de issues ("hasta 4, o hasta las 5pm, lo que llegue primero").
- **Política de fallo** — si una issue falla sus gates: ¿para todo / la aparca y sigue / reintenta una vez? *(default propuesto: aparca y sigue, la reporta).*
- **Zonas prohibidas** — paths que NO toca sin ti (migraciones, config de prod, auth). Ahí siempre escala.
- **Nunca auto-merge** — cada issue termina en PR.

Entrega final del batch: *"5 PRs listos para review, 1 aparcada (#M, te explico), 1 falló CI (#K, log adjunto)."*

> ⚠️ En batch, los **gates deterministas son la única red** hasta que vuelves. Por eso: (a) un gate que falla **detiene esa issue**, nunca se auto-aprueba; (b) los gates atrapan *correctitud*, no *"esto no era lo que quería"* — de ahí que la escalada por divergencia (decisión #6) sea obligatoria.

---

## 5. Capa de conocimiento (referencia / intención) y front-end

Tercer bucket (decisión #3): el **conocimiento de referencia** — FRD, DDT, criterios de aceptación y los **bundles de diseño de Claude Design**. Es estable y describe *intención*; no es estado ni notas-de-ayer.

**Regla de oro: por-issue y on-demand, nunca precargado.** La issue *referencia* su spec (un path, un link o un doc-id); cuando DevLead la toma, sigue esa referencia y carga *solo ese doc* para *esa* tarea. Precargar toda la documentación al arrancar el día quema contexto y baja calidad. Punto natural de consumo: el **paso del SDD** (ahí el FRD/DDT alimenta el spec).

**Dónde vive el doc → DECIDIDO: `/docs` en el repo** (privado, versionado, atado a la rama; lo mejor para ISO 27001). *Solo el bucket de referencia vive aquí* — el journal sigue en `.devlead/` y el estado no se guarda. Convención para que el resolver sea determinista:

```
/docs
  /<modulo>/            # p.ej. facturacion/
    FRD-*.md
    DDT-*.md
  /design/<feature>/    # bundle Handoff-to-Claude-Code de Claude Design
```

La issue **apunta a su spec por path relativo** (línea `Spec: docs/facturacion/DDT-011.md` en el cuerpo, o un campo/label). El resolver lee ese path y carga *solo ese doc* en el SDD.

*(Alternativas descartadas para este proyecto: skill que envuelve los docs — útil para reuso entre repos; MCP externo tipo Confluence/Drive/Jira — solo si los docs ya vivieran afuera, con la bandera de privacidad activa.)*

**Trátalo como intención, no como verdad.** Los FRD/DDT envejecen contra el código. El SDD reconcilia intención (doc) vs realidad (código); si chocan, eso *es* una divergencia → DevLead para y avisa (invariante 5).

### Front-end con Claude Design

- **Input:** el export *Handoff to Claude Code* de Claude Design empaca diseño + tokens del design system + estructura de componentes + intención en un bundle → DevLead lo consume como input del pipeline de front (cae en este bucket de referencia; es un "FRD de UI"). Claude Design también puede **extraer el design system del repo de CRM V3** → UI consistente con lo que ya existe, no desde cero.
- **Ingestión precisa:** PDFs con la skill `pdf-reading` (rasteriza a 150 DPI + extrae texto/layout); imágenes/mockups con visión nativa de Claude; build con la skill `frontend-design` para que no salga genérico.
- **Gate de precisión del front:** la fidelidad NO la da leer el mockup — un read estático nunca es pixel-perfect. La da cerrar el loop → implementa → screenshot con **Chrome MCP** → diff visual contra el bundle/mockup → corrige → repite. Mismo patrón verify→fix→verify.
- **Caveat honesto:** el código que sale de Claude Design no es production-ready as-is; lo endurecen tus qa gates (Security, A11y, React Patterns). Design da el borrador visual + intención; DevLead lo lleva a producción.
- **Privacidad:** en Max (personal) y Team (Ivolution), Claude Design no entrena con tus datos → ok para specs sensibles.

---

## 6. Qué hay que desarrollar (componentes)

| Componente | Tipo | Ubicación | Qué hace |
|---|---|---|---|
| `/arranquemos` | Slash command | `.claude/commands/` | Entry point del día: orquesta estado → journal → standup → recomendación |
| Persona DevLead | CLAUDE.md | `.claude/CLAUDE.md` | Define tono, reglas; espejos A1-A4 inline. Invariantes normativos: ver `.claude/GOVERNANCE.md` |
| Script de ensamblado de estado | Script (bash/py) | `.devlead/scripts/` | Re-deriva el *qué* en vivo: git + GitHub |
| Script de branching | Script | `.devlead/scripts/` | Rama desde el tag más cercano de dev (`git describe --tags`), determinista |
| Journal | Estado per-repo | `~/.devlead/journals/<repo-key>.md` (per-repo, clave = git root) | Guarda solo el *porqué* y notas |
| Resolver de referencia por-issue | Lógica en el command + script | `.devlead/scripts/` | Sigue el path/link/doc-id de la issue y carga *solo ese doc* en el paso del SDD |
| Ingesta de bundle Claude Design | Handoff / lógica | `.claude/` | Consume el bundle *Handoff to Claude Code* como input del pipeline de front |
| Gate de diff visual (front) | Hook / paso de pipeline | `.claude/hooks/` | Chrome MCP screenshot → compara contra el diseño → bloquea/itera si diverge |
| Hook de tests/lint | Hook `PostToolUse` | `.claude/hooks/` | Corre tests/lint tras cada edición (obligatorio, no por prompt) |
| Hook de gate de cierre | Hook `Stop` / `SubagentStop` | `.claude/hooks/` | Bloquea el cierre hasta que pasen los gates |
| Loop de batch + sobre | Lógica en el command | `.claude/commands/` | Itera la cola dentro del envelope (fase 2) |
| Write-back de cierre | Slash command | `.claude/commands/` | "cerremos el día" → el agente escribe el journal (gestionado 100% por él, disparo manual) |

**Skills built-in que se reutilizan:** `pdf-reading` (ingesta de specs en PDF), `frontend-design` (calidad de UI). No hay que construirlas.

### Integraciones (fuentes del "qué tengo")
- **GitHub** (issues + PRs) — base, obligatorio.
- **Claude Design** (handoff bundle) — input de front, vía export a Claude Code.
- **Calendario** — para no recomendar un P0 si tienes 4h de reuniones. *(pendiente tu sí/no)*
- **Slack / correo** — captar blockers o "urge esto" que no están en una issue. *(pendiente tu sí/no)*

---

## 7. Orden de construcción (fases)

**Fase 0 — Esqueleto single-task**
- `/arranquemos` + script de ensamblado de estado → ver el **standup corriendo con datos reales** antes de cablear nada más.
- Plantilla del journal.

**Fase 1 — Pipeline single-task completo**
- Script de branching desde tag.
- Hooks (`PostToolUse` tests/lint, `Stop` gate de cierre).
- Conexión a los subagentes existentes (SDD, implementador, auditores) + Chrome MCP.
- Capa de referencia (resolver por-issue) + ingesta de bundle Claude Design + gate de diff visual.
- Write-back de cierre.

**Fase 2 — Modo batch encima**
- Loop de cola + config del sobre.
- Política de fallo + zonas prohibidas + escalada por divergencia.

> El batch es literalmente "loopear el single-task dentro del sobre". Si la base no es sólida, el batch multiplica los errores → por eso va al final.

---

## 8. Decisiones pendientes (faltan tu sí/no)

- [ ] ¿Incluir **calendario** como fuente? (item 8 de la lista)
- [ ] ¿Incluir **Slack/correo** como fuente? (item 9)
- [ ] ¿Quieres **estimados S/M/L** por issue? *(ojo: los estimados de LLM son ruidosos)*
- [ ] **Defaults del sobre**: presupuesto típico, política de fallo, lista inicial de zonas prohibidas.
- [x] **Journal** → lo gestiona 100% el agente, cierre **manual** con "cerremos el día"; formato `.md` legible con la plantilla default (sección 3). *(json estructurado queda como alternativa si luego quieres más estructura.)*
- [x] **Dónde viven los docs de referencia** → `/docs` en el repo, con la convención de la sección 5.
- [x] **Cómo referencia la issue su spec** → path relativo (`Spec: docs/.../*.md`); el resolver lo lee.

---

## Nivel 2 — Autonomous Sweep (plan-only)

### Qué es

Un sweep autónomo programado que responde «¿qué haría DevLead hoy en cada repo enrolled?» sin ejecutar nada. Lee el estado, construye el plan y escribe un digest diario bajo `~/.devlead/reports/YYYY-MM-DD.md`. Cero ramas, cero PRs, cero commits, cero pushes.

### Setup automático (`devlead init`)

`devlead init` bootstrapea la máquina de forma automática: crea los symlinks,
instala las unidades systemd (service + timer) y siembra el `gh-token` headless.
Al final hace **una sola pregunta** de opt-in: si respondés que sí, `devlead init`
es el **único** camino init-driven que agrega este repo a `~/.devlead/autonomous-repos`
y corre `systemctl --user enable --now devlead-sweep.timer`. Si respondés que no,
no se enrola ni se activa el timer (decisión normal, no error).

Los pasos manuales de abajo siguen siendo válidos como ruta explícita/avanzada
(o para re-enrollar sin re-correr `init`).

### PAT (GitHub token) — alcance mínimo

Creá un Personal Access Token con los permisos **mínimos** necesarios:
- `repo` → lectura (para listar issues/PRs)
- `issues` → lectura

**Nunca otorgues permisos de escritura.** El sweep es read-only por diseño.

### Almacenar el PAT

```bash
echo 'ghp_TuTokenAqui' > ~/.devlead/gh-token
chmod 600 ~/.devlead/gh-token
```

El sweep rechaza el archivo si los permisos no son exactamente `600` (aviso en stderr, sin usar el token).

### Enrollar un repo

```bash
echo /ruta/absoluta/al/repo >> ~/.devlead/autonomous-repos
```

Además, el repo necesita `enabled: true` en su `envelope.yml`. El scaffold por defecto es `enabled: false` (kill-switch de seguridad): un repo debe habilitarse **explícitamente** para ser barrido.

### Activar el timer

```bash
systemctl --user enable --now devlead-sweep.timer
```

El installer **nunca** activa el timer. La activación es tuya y es explícita.

### Cambiar la cadencia

Editá `OnCalendar=` en `~/.config/systemd/user/devlead-sweep.timer`:

```
OnCalendar=*-*-* 07:00:00   # diario a las 07:00 (default)
```

Luego: `systemctl --user daemon-reload && systemctl --user restart devlead-sweep.timer`

### Sesiones headless (linger)

En servidores o sesiones sin login gráfico, el timer de usuario necesita linger habilitado para ejecutarse sin sesión activa:

```bash
loginctl enable-linger $USER
```

Esto permite que los servicios `--user` de systemd arranquen al boot sin login.

### Reportes

Los digests se escriben en `~/.devlead/reports/YYYY-MM-DD.md`. Cada ejecución **sobreescribe** el digest del día (no se acumula).

### Por qué no se usa `devlead` en PATH bajo systemd

Los units de usuario de systemd no heredan el PATH interactivo. El sweep invoca `envelope.sh` por ruta absoluta instalada (`~/.devlead/scripts/envelope.sh`) para garantizar resolución sin importar el entorno.

---

## Nivel 3 — Autonomous Execute (`/sweep-execute`)

### Qué es

`/sweep-execute` es el paso de ejecución autónoma sobre los repos enrollados: lee la cola de issues INCLUDED desde el envelope de cada repo, corre el pipeline B2 completo (branch → spec → impl → gates → PR) y entrega PRs listos para review. Nunca hace merge. Nunca escribe código sin autorización (la invocación del comando ES la autorización).

La diferencia con Nivel 2 (`sweep.sh`): Nivel 2 solo planifica (read-only). Nivel 3 ejecuta: crea ramas, implementa, corre gates, abre PRs.

### Cómo funciona

1. Lee `~/.devlead/autonomous-repos` (mismo dedup/CRLF que `sweep.sh`).
2. Por cada repo: corre `envelope.sh check` (ENROLLED + ENABLED), la cadena de auth de 4 pasos (`sweep.sh:19-57`), y `envelope.sh plan` fresh.
3. Parsea la sección `--- INCLUDED (queue order) ---` para obtener la cola de `#N`.
4. Por cada issue INCLUDED: corre B2.a → B2.e de `batch.md` con los deltas de execute (ver `.claude/commands/sweep-execute.md`).
5. Escribe el reporte en `~/.devlead/reports/YYYY-MM-DD-execute.md` al finalizar.

### Prerrequisitos operacionales

**PAT (GitHub token) — alcance WRITE requerido:**
A diferencia de Nivel 2 (read-only), `/sweep-execute` llama `gh pr create`. Tu PAT DEBE tener el scope `repo` (escritura) para crear PRs.

- **Token read-only → todas las issues se aparcan** con razón explícita `auth: PR creation requires write scope (repo) — token is read-only`. El error se detecta al momento de `gh pr create`, después de que la rama y los commits ya existen. Cada issue afectada queda PARK con esa razón — el reporte lo documenta — pero deja una rama local con commits sin PR (no es un no-op limpio). Revisá las ramas locales antes del próximo run si vas a corregir el token.
- Almacenamiento idéntico a Nivel 2: `echo 'ghp_TuToken' > ~/.devlead/gh-token && chmod 600 ~/.devlead/gh-token`

**Repo enrollado:** el repo debe estar en `~/.devlead/autonomous-repos`.

**Envelope habilitado:** `enabled: true` en `.devlead/envelope.yml` del repo.

### Invariantes aplicadas

Detalle normativo: ver `.claude/GOVERNANCE.md §sweep-scoped-profile / §sweep-plan-driven-profile`.

Resumen narrativo: `/sweep-execute` aplica A3 (nunca auto-merge), A4 (PARK con razón exacta), y catástrofe de entorno scoped al REPO ACTUAL (no al run completo — diferencia clave vs. `/batch` donde catástrofe = stop global). Ver GOVERNANCE.md §sweep-scoped-profile para el detalle completo.

### Reporte de run

Destino: `~/.devlead/reports/YYYY-MM-DD-execute.md`

**NUNCA** sobreescribe ni modifica `~/.devlead/reports/YYYY-MM-DD.md` (el plan digest de Nivel 2). El sufijo `-execute` los distingue.

Vocabulario de resultado por issue: `pr-created (URL)` / `parked-<razón>` / `escalated-<zona>` / `no_alcanzada`.

### Qué `/sweep-execute` NO hace

- **No mergea.** Absolutamente nunca.
- **No reintenta gates fallidos.** PARK es final para esa issue en ese run.
- **No procesa repos sin token write** sin avisarte. PARK explícito con razón de auth.
- **No detiene el run completo por fallo de una issue.** Fallo de issue = PARK de esa issue.
- **No para el run si un repo falla.** Catástrofe de repo = PARK de ese repo, run continúa.
- **No usa estado cacheado.** Cada `envelope.sh plan` se corre fresh (Inv 2).

---

## 9. Invariantes (lo que NUNCA se rompe)

Los invariantes normativos viven en `.claude/GOVERNANCE.md`. Esta sección es histórica/narrativa — no es la fuente de autoridad.

Para el modelo de autorización en capas, los absolutos A1-A4, los perfiles por modo, y las meta-reglas (narrow-not-widen, generate→show→approve), ver `.claude/GOVERNANCE.md`.
