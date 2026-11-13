# DevLead — Agente de entrada (front door) para el día de trabajo

> Spec de diseño para construir con Claude Code.
> Estado: **diseño cerrado, listo para scaffolding.** Se construye primero el modo *single-task*; el *batch* se monta encima.

---

## 1. Qué es DevLead (en una frase)

DevLead es el **front door** del día: un asistente con el que arrancas la jornada, que ve qué tienes y qué quedó en camino, decide qué abordar, te lo dice y **despacha** el trabajo al pipeline que ya usas a diario (rama → SDD → implementación → tests → Chrome → qa gates → PR). No pica código él mismo: delega.

La interacción objetivo: dices *"arranquemos el día"*, te da el standup y el plan, y empieza; si tienes otra prioridad se lo dices y cambia.

---

## 2. Decisiones de arquitectura ya tomadas

Estas son las que NO se redecidan al construir. Cada una tiene su porqué para que no se deshagan por inercia.

1. **DevLead NO es un subagente.** Es un **slash command** (`/arranquemos`) + su **persona en CLAUDE.md**, corriendo en la **sesión principal**. Razón: el front door tiene que vivir todo el día y conversar contigo; los subagentes son aislados, efímeros y devuelven-resumen-y-mueren. Desde la sesión principal, DevLead delega el trabajo pesado a los subagentes que ya tienes (SDD agent, implementador, auditores).

2. **Determinista donde se pueda, agéntico solo donde haga falta criterio.** El LLM no razona sobre git puro (branching, tags) — eso son scripts.

3. **Tres buckets de información, separados a propósito:**
   - *El qué* (issues, ramas, PRs, estado de CI) → **nunca se guarda**, se re-deriva en vivo cada mañana. Así nunca está stale ni alucinado.
   - *El por qué* (por qué paraste ayer, qué decidiste, blockers, próximo paso mental) → **sí se guarda** en un journal local. Ese contexto no vive en ningún otro lado.
   - *La referencia / intención* (FRD, DDT, criterios de aceptación, bundles de Claude Design) → estable; se carga **por-issue y on-demand**, nunca precargada. Detalle en la sección 5.

4. **Sin checkpoint de arranque** (revisada el 2026-11-13; antes: "un solo checkpoint humano"): DevLead arma el plan, te lo dice y empieza. El control está en los límites duros (`guard.sh`), en el envelope y en la revisión de los PRs, no en una confirmación previa.

5. **El merge lo concedes tú.** DevLead mergea solo lo que permita `merge.mode` de tu envelope, por `merge.sh`, y nunca a la rama por defecto. Con el valor por defecto (`never`) cada issue cierra en un PR abierto.

6. **DevLead escala de vuelta cuando la realidad diverge del plan**, aunque hayas dado "arranca". Autorizas un plan, no un cheque en blanco contra sorpresas.

7. **DevLead es un modo acotado y opt-in, no un demonio siempre activo.** Se enciende con `/arranquemos` y se apaga con "cerremos el día"; esos dos comandos *son* la frontera que define cuándo el agente está al mando. Fuera de ellos usas Claude Code normal. La frontera es por convención (la persona vive siempre en `CLAUDE.md`, pero el workflow del día solo corre al invocarlo); se puede endurecer más adelante si hace falta.

---

## 3. Cómo funciona — ciclo del día (modo single-task)

### Al empezar (`/devlead`)

Un solo comando para todo. Después le hablas en lenguaje natural y él entiende la intención: empezar el día, continuar lo de ayer, hacer una tarea concreta, decir cómo va, cambiar de rumbo o cerrar. `/arranquemos` y `/cerremos` siguen existiendo como alias.

1. Re-deriva el estado en vivo: ramas activas, PRs abiertos, estado de CI, issues asignadas.
2. Lee el journal local para recuperar el *porqué* de lo que quedó a medias.
3. Arma un **standup corto**: en camino / listo para review / nuevo entrante.
4. Estima la capacidad del día con el calendario y con lo que le hayas dicho; no te lo pregunta.
5. **Dice qué va a hacer** — el plan de hoy, con su porqué y su enfoque — **y empieza**.

### Al trabajar
6. No espera un OK por issue ni por enfoque. Si tienes otra prioridad se lo dices y cambia de rumbo. Solo te pregunta ante una decisión de producto que no puede predecir, un límite duro que bloquea algo necesario, o una acción irreversible que nadie pidió (`.claude/GOVERNANCE.md §A1`).
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
| `/arranquemos` | Slash command | `.claude/commands/` | Entry point del día: orquesta estado → journal → standup → plan → ejecución |
| Persona DevLead | CLAUDE.md | `.claude/CLAUDE.md` | Define tono, reglas; espejos A1-A4 inline. Invariantes normativos: ver `.claude/GOVERNANCE.md` |
| Script de ensamblado de estado | Script (bash/py) | `.devlead/scripts/` | Re-deriva el *qué* en vivo: git + GitHub |
| Script de branching | Script | `.devlead/scripts/` | Rama desde el tag más cercano de dev (`git describe --tags`), determinista |
| Journal | Estado per-repo | `~/.devlead/journals/<repo-key>.md` (entrada vigente) + `<repo-key>.history.md` (días anteriores); lo escribe `journal.sh save` | Guarda solo el *porqué* y notas. Acumulativo: cerrar el día archiva la entrada anterior, no la pisa |
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

## Loop nocturno (`devlead-loop.timer`) — qué necesita para correr

`sweep-loop.sh` re-invoca `claude -p "/sweep-execute --plan ..."` sin humano presente. Por eso exige tres cosas y se niega (o se pausa) si falta alguna:

- **`DEVLEAD_LOOP_REPO`** en `~/.devlead/loop.env`: el repo destino.
- **`DEVLEAD_LOOP_CLAUDE_ARGS`** en `~/.devlead/loop.env`: los flags de permisos de la sesión headless, separados por espacios. Sin esta variable el loop **no invoca `claude`** y sale con error: una sesión desatendida corre con permisos que alguien eligió, nunca con los que la máquina tenga por defecto. Ejemplo:
  ```
  DEVLEAD_LOOP_CLAUDE_ARGS=--permission-mode acceptEdits --allowedTools Bash,Read,Edit,Write,Glob,Grep,Agent
  ```
  `DEVLEAD_LOOP_DRYRUN=1` imprime el comando exacto, flags incluidos, sin ejecutar nada.
- **`enabled: true`** en el `.devlead/envelope.yml` de ese repo. Es el kill-switch: sin envelope, o con `enabled: false`, el loop imprime `STATUS: paused` y sale 0 sin invocar nada. Se consulta antes de cada iteración, así que apagarlo detiene un run en curso al terminar la iteración actual. (El LOCAL-PLAN interactivo no lo exige: ahí acabás de aprobar el plan vos.)

---

## Run multi-repo (`devlead-fleet.timer`) — el que ejecuta la agenda

El loop nocturno de arriba trabaja UN repo con UN plan local. Este timer hace la otra mitad del ciclo: una pasada desatendida de `/sweep-execute --fleet` sobre **todos** los repos de `~/.devlead/autonomous-repos` cuyo envelope diga `enabled: true`, trabajando la cola que arma la policy de cada uno — la misma lista que el sweep de las 07:00 te mandó como agenda, con tus ajustes aplicados.

| Hora | Qué corre | Qué hace |
|---|---|---|
| 07:00 | `devlead-sweep.timer` | Arma la agenda de cada repo y te avisa. No toca ningún repo |
| durante el día | vos | `devlead agenda first <N>` / `skip <N>` si querés otro orden |
| 22:00 | `devlead-loop.timer` | El plan local, si hay uno |
| 22:30 | `devlead-fleet.timer` | La agenda de cada repo enrolado: ramas, commits y PRs |

- **No viene activado.** Publicarlo no lo enciende: se activa en `devlead config` → Machine setup → Timers → fleet timer.
- **Necesita `DEVLEAD_LOOP_CLAUDE_ARGS`** en `~/.devlead/loop.env`, igual que el loop nocturno.
- **Una sola pasada por noche.** Un run de plan sabe cuándo terminó; uno de flota no, así que cada pasada extra pagaría una sesión entera para encontrar la cola ya trabajada. Se cambia en `ExecStart=` de la unidad (`--max-iterations`).
- **No corre a la par del loop nocturno.** Si a las 22:30 el loop sigue trabajando, este arranque espera a que termine (`After=devlead-loop.service`). Si movés los horarios, dejá este como el más tardío.
- **No recupera noches perdidas** (`Persistent=false`): no arranca a crear ramas cuando abrís la laptop.
- Lo que puede mergear sigue siendo lo que diga `merge.mode` de cada envelope; el timer no cambia eso.

## Discover programado (`devlead-discover.timer`)

`/sweep-discover` compara los módulos que declaraste en `discover.modules[]` contra su spec y archiva una issue por cada brecha. Este timer lo corre solo, una vez por semana (lunes 05:00), en cada repo enrolado cuyo envelope diga `enabled: true` **y** `discover.enabled: true` (`discover-fleet.sh`). Un repo que no lo pidió no se toca.

- **Solo archiva issues.** No crea ramas ni abre PRs. Cada issue lleva `discover.label`, que la mantiene fuera de toda agenda hasta que la revises y le saques la label (el ciclo de dos noches, `GOVERNANCE.md §sweep-discover-profile`).
- **No viene activado.** Se enciende en `devlead config` → Machine setup → Timers → discover timer.
- **Permisos propios y más chicos.** Lee `DEVLEAD_DISCOVER_CLAUDE_ARGS` de `~/.devlead/loop.env`; si no está, usa `DEVLEAD_LOOP_CLAUDE_ARGS`. Discover solo lee el repo y archiva issues, así que alcanza con algo como `--permission-mode default --allowedTools Bash,Read,Glob,Grep`. Sin ninguna de las dos, no arranca y te avisa.
- **Un intento por repo, sin reintentos** (un segundo intento podría archivar la misma brecha dos veces). Espera a que terminen el loop nocturno y el run multi-repo si siguen corriendo.
- `DEVLEAD_LOOP_DRYRUN=1 bash ~/.devlead/scripts/discover-fleet.sh` muestra qué correría, sin invocar nada.

## Aprendizaje — DevLead aprende de tus reviews (`learn.sh`)

DevLead aprende cómo trabajás leyendo lo que escribís en los PRs:

1. Comentás un PR como siempre (inline, en la conversación, o en el resumen de una review).
2. En el siguiente `/arranquemos`, `learn.sh capture` guarda tus comentarios nuevos — solo los de tu cuenta — y DevLead destila de ellos preferencias de una línea.
3. Las preferencias quedan **activas al instante** y aparecen en el standup ("Aprendí de tus reviews"). Si una no va: "quitá p3".
4. Todo run posterior — `/arranquemos`, `/batch`, `/sweep-execute`, el loop nocturno — las aplica al implementar.

| Comando | Qué hace |
|---|---|
| `learn.sh pref-list` | Preferencias activas y quitadas |
| `learn.sh pref-add user "..."` | Agregar una a mano |
| `learn.sh pref-remove p3` | Quitar una (no se vuelve a deducir) |
| `learn.sh outcomes` | Resumen de cómo terminaron los PRs de DevLead |

Todo vive en `~/.devlead/learn/<repo-key>/`, local y por repo. Una preferencia es estilo, nunca autoridad: no puede mergear, saltear un gate ni mover un límite (`GOVERNANCE.md §learned-preferences`).

El journal también es acumulativo: `/cerremos` archiva la entrada anterior en vez de pisarla (`journal.sh`), y `/arranquemos` lee los últimos días para detectar lo que se repite.

## Registro de decisiones — qué decidió solo y por qué (`decisions.sh`)

DevLead no te pide permiso para elegir una tarea o un enfoque. A cambio, nada de lo que decide por ti queda sin decir: cada decisión se registra con su razón, por repositorio.

- La ves en la conversación cuando la toma, y en el siguiente `/devlead` si la tomó en una corrida desatendida ("Decidí por vos").
- Si no era lo que querías, se lo dices ("así no, yo habría hecho un solo PR") y queda registrada la corrección.
- Las correcciones son lo que más le enseña: de ahí salen las entradas de "cómo decides" de tu perfil.

```
bash ~/.devlead/scripts/decisions.sh list
```

Es solo un registro: no autoriza ni frena nada.

---

## Perfil — DevLead aprende cómo escribes y decides (`profile.sh`)

Además de tus reviews, DevLead aprende de lo que TÚ escribes en tus conversaciones de Claude Code, de todos tus proyectos, y de lo que ya está guardado en Engram.

- **Qué lee:** solo lo que tecleaste. Descarta en código las respuestas del modelo, los resultados de herramientas, la salida de hooks, las notificaciones y todo lo que pegaste.
- **Qué guarda:** un perfil corto con dos clases de entradas — cómo escribes y cómo decides. Tiene un tope de tamaño (3000 caracteres por defecto) y cada entrada vence a los 90 días si no se confirma.
- **Qué no guarda:** nada de un proyecto concreto (nombres, clientes, rutas). Eso queda por repositorio, en `learn.sh`, y nunca pasa a otro.
- **Qué no puede decir:** nada sobre lo que DevLead puede hacer. Una entrada que hable de merge, límites, claves o producción se rechaza en código.
- **Dónde vive:** `~/.devlead/profile/`. Nada sale de tu máquina.

Para verlo o corregirlo:

```
bash ~/.devlead/scripts/profile.sh list
bash ~/.devlead/scripts/profile.sh remove p3
```

O simplemente díselo: "esa no me representa, quítala".

---

## Agenda del día — qué va a hacer DevLead hoy (`agenda.sh`)

Cada mañana el sweep arma la cola de cada repo enrolado con la policy de su envelope, la guarda como **agenda del día** y te manda un aviso al teléfono. DevLead no espera tu OK: a la hora del run arranca con esa cola. Si tenés otra prioridad, la cambiás antes:

| Comando (dentro del repo) | Qué hace |
|---|---|
| `devlead agenda` | Muestra la agenda de hoy, con tus ajustes aplicados |
| `devlead agenda first 15` | La #15 se trabaja primero |
| `devlead agenda skip 12` | La #12 no se trabaja hoy |
| `devlead agenda reset` | Descarta los ajustes |

En una sesión de `/arranquemos` alcanza con decirlo ("hoy primero la 15", "la 12 dejala").

Un ajuste solo **reordena o saltea** issues de la cola que tu policy ya incluyó; nunca agrega una. Vale por el día: la agenda de mañana arranca limpia. Para un cambio permanente — o para cambiar prioridades desde el teléfono, donde no hay terminal — usá labels en GitHub: las de `select.exclude_labels` sacan una issue de la cola y las de `order.priority_labels` la suben.

El push lleva por defecto solo cantidades ("2 repo(s), 5 issue(s) today"); para recibir la lista con repos y títulos en el teléfono agregá `DEVLEAD_NOTIFY_DETAIL=1` a `~/.devlead/notify.env`. La lista completa siempre queda en la bandeja local. Reglas en `GOVERNANCE.md §daily-agenda`.

## Avisos — bandeja local y push al teléfono (`notify.sh`)

Un run desatendido que no puede seguir solo avisa por `~/.devlead/scripts/notify.sh`. Todo queda en la bandeja local `~/.devlead/inbox.tsv`, que `/arranquemos` muestra a la mañana ("Mientras no estabas") y archiva. Los avisos de nivel `need` van además al teléfono con prioridad alta; el de nivel `agenda` (la lista del día) va con prioridad normal. La lista de qué dispara un `need` está en `.claude/GOVERNANCE.md §escalation-channel`.

**Activar el push** (sin esto, solo se escribe la bandeja y nada sale de la máquina):

1. Instalá la app de ntfy en el teléfono y suscribite a un topic con un nombre largo e imposible de adivinar (el nombre del topic es lo único que protege el canal), en `ntfy.sh` o en un servidor ntfy propio.
2. Creá la configuración:
   ```bash
   printf 'DEVLEAD_NTFY_URL=https://ntfy.sh/tu-topic-largo-y-secreto\n' > ~/.devlead/notify.env
   chmod 600 ~/.devlead/notify.env
   ```
   `notify.sh` ignora el archivo si los permisos no son exactamente `600` o si la URL no es `https`.
3. Probalo: `bash ~/.devlead/scripts/notify.sh send need prueba "hola"` y después `bash ~/.devlead/scripts/notify.sh list` — la entrada debe decir `push=sent`.

**Privacidad:** el push pasa por un servicio externo. Por defecto lleva solo el código del aviso (`DevLead needs you: loop-paused`), sin nombre de repo ni detalle. Agregá `DEVLEAD_NOTIFY_DETAIL=1` al archivo si querés que incluya el nombre del repo y el mensaje. Opcional: `DEVLEAD_NTFY_TOKEN=...` para un servidor con autenticación.

---

## Límites duros — lo que DevLead no puede hacer (`guard.sh`)

DevLead decide y ejecuta solo, pero hay seis cosas que un hook bloquea antes de que ocurran: tocar producción, mergear fuera de `merge.sh`, tocar una base de datos que no sea local, leer claves fuera de los lugares que permitiste, escribir fuera del repo en el que lo iniciaste, y cambiar su propia configuración. El detalle normativo está en `.claude/GOVERNANCE.md §hard-limits`.

Para permitirle leer una clave, agregá su ruta (un glob por línea) a `~/.devlead/secrets-allow`:

```
# lugares desde donde DevLead puede leer claves
~/Work/mi-proyecto/.env.local
```

Ese archivo lo escribís solo vos. No hay un archivo equivalente para producción ni para bases de datos: esos límites no tienen excepción.

El guard queda registrado por `install.sh` como hook `PreToolUse`. Está activo en las sesiones de DevLead y en todas las corridas desatendidas; en cualquier otra sesión de Claude Code no hace nada.

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

### Modo LOCAL-PLAN (`--plan <file>`)

Además de los modos ya documentados (issues explícitas y plan-driven), `/sweep-execute` soporta un tercer modo: **LOCAL-PLAN**. Se activa con `/sweep-execute --plan <file>` donde `<file>` es un plan YAML local (`.devlead/plan.local.yml`) previamente aprobado por el usuario.

A diferencia del modo plan-driven (que deriva la cola de GitHub issues vía `envelope.sh plan`), LOCAL-PLAN lee la cola directamente del archivo de plan — sin llamar a `gh issue list`, sin política de envelope. La autorización viene del gate `generate→show→approve`: DevLead genera el plan desde input del usuario, lo muestra completo, y espera aprobación explícita antes de ejecutar.

El contrato normativo completo está en `.claude/GOVERNANCE.md §sweep-local-plan-profile`. Este párrafo es histórico/narrativo.

### Invariantes aplicadas

Detalle normativo: ver `.claude/GOVERNANCE.md §sweep-scoped-profile / §sweep-plan-driven-profile / §sweep-local-plan-profile`.

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
