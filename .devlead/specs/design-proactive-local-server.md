# Diseño: DevLead proactivo en un servidor local

Estado: **borrador para votar** · Fecha: 2026-11-16 · Rama: `docs/proactive-design`

Este documento convierte el plan "DevLead proactivo" en decisiones concretas. Cada punto de la sección 5 tiene opciones, ventajas y costos, y una recomendación marcada con ★. Nada se implementa hasta que los puntos estén votados.

---

## 1. Qué pidió el usuario (textual)

- **L1** (plan pegado, §1): "Convertir DevLead de un agente **reactivo** (yo lo arranco con `/arranquemos`) a uno **proactivo**: que trabaje solo por horario o por eventos, prepare el trabajo de mi día a día (issues, specs, código, PRs, revisiones), **me avise y espere mi aprobación** antes de cualquier acción irreversible."
- **L1** (plan pegado, §5): "**Nunca sin mi aprobación explícita:** merge, push a `main`/ramas protegidas, despliegues, borrar ramas o archivos, cerrar issues, publicar comentarios en nombre mío, cambiar configuración del repo."
- **L2**: "Por ahora la idea es que hagaoms todo local para el usuario de a pie que pueda usarlo con su subscription por eso claude recomendaba un pluggin"
- **L3**: "No pues digamos te pase el plan para que tenga una idea lo que quiero pero obvio debemos adaprtaarlo, la cosa es claude destop solo esta en windows no y en nuestro caso que usamos omarchy que? esta idea la traje de claude duet que vi que funciona sin que nosotros tengamos el pc activoç"
- **L4**: "No, por eso, digamos, nosotros vamos a simular Claude, pero digamos en nuestra computadora local. Obviamente esta va a estar encendida 24/7 y del lead va a vivir allí en nuestra computadora local como si fuera un servidor. De hecho, lo que estaba diciendo Claude en la otra conversación era que lo iba a correr dentro de un Docker para que estuviera constantemente corriendo."
- **L5**: "Dale vamos con eso pero necesitamos hacer el diseños para votar todos esos puntos"

## 2. Ya decidido (no se vota)

- DevLead corre en la máquina del usuario, encendida 24/7, como si fuera un servidor (L4).
- Corre dentro de Docker (L4, aprobado en L5).
- Usa la suscripción del usuario, sin API key (plan §3.2 y §4).
- Siguen vigentes los invariantes 1 a 7 (`.claude/CLAUDE.md`) y `.claude/GOVERNANCE.md`. Inv 3 no cambia: el envelope lo escribe solo el usuario.
- Opciones descartadas:
  - **Tareas programadas en la nube de Anthropic.** No instalan plugins, el proxy de GitHub bloquea `gh pr` y `gh issue`, y cada corrida empieza de un clon nuevo.
  - **Tareas locales de Claude Desktop.** No hay versión oficial para Arch/Omarchy (solo `.deb` para Ubuntu y Debian, en beta) y solo corren con la app abierta.

## 3. Qué se reutiliza

| Pieza existente | Uso en el servidor |
|---|---|
| `sweep.sh` (resumen y agenda de la mañana, solo bash) | Se usa tal cual. No consume suscripción |
| `sweep-loop.sh` y `discover-fleet.sh` (lanzan `claude -p`) | Se usan tal cual; el programador nuevo los llama |
| `guard.sh`, `post-edit.sh`, `gate-check.sh` | Los mismos hooks, ahora en configuración bloqueada (D9) |
| Puertas `open-pr.sh` y `merge.sh`, más el envelope | Sin cambios. `merge.mode: never` sigue siendo el valor por defecto |
| `notify.sh` (ntfy) | Canal de avisos (D19) |
| `budget.max_issues`, `DEVLEAD_LOOP_MAX`, interruptor `enabled:` | Se mantienen; D17 agrega topes |
| Timers en `.devlead/systemd/` | Se reemplazan por el programador del contenedor (D11). Quedan para quien no use Docker |

## 4. Cómo votar

Responde en el chat con el formato `D1: A, D2: B, …`, o escribe la letra en la línea **Voto** de cada punto. Si aceptas todas las recomendaciones (★), basta con decir "todas las recomendadas". Un punto que quieras discutir se deja en blanco.

---

## 5. Puntos a votar

### A. Comportamiento

#### D1 — Alcance de la v1

El plan tiene cuatro disparadores: la mañana, issues nuevos, revisión de PRs de otros y el cierre del día.

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Mañana, issues y cierre; la revisión de PRs de otros pasa a v2 | Cubre el uso diario; la revisión de otros es opcional en el plan (Fase 4) | La revisión de PRs de otros espera |
| B Los cuatro disparadores en v1 | Plan completo de entrada | Más superficie antes de validar el contenedor |
| C Solo mañana y cierre, sin escribir código | Valida el servidor con riesgo mínimo | No prepara trabajo, que es el objetivo principal |

**Voto:**

#### D2 — Aprobación antes de actuar

Hay una contradicción. El plan pide "aprobar el plan del día", pero el 2026-11-13 decidiste que DevLead publique la agenda y empiece sin esperar. En las tres opciones, lo irreversible de L1 §5 sigue bloqueado: el merge depende de `merge.mode` (por defecto `never`), nada va a `main`, no borra ramas, no cierra issues y no publica comentarios en tu nombre.

| Opción | A favor | En contra |
|---|---|---|
| **A ★** No espera: publica la agenda y empieza; tú reordenas o quitas trabajo (comportamiento actual, `agenda.sh`) | Avanza mientras duermes; ya está construido | Puede gastar una corrida en algo que no querías |
| B Espera tu aprobación del plan del día; sin respuesta, no hace nada | Control total | Si no respondes, el servidor no hace nada; requiere un canal de ida y vuelta |
| C Configurable por repo en el envelope, con A por defecto | Flexible | Agrega un campo al envelope (cambio de formato aditivo) |

**Voto:**

#### D3 — PRs en borrador

Hoy `open-pr.sh` acepta `--draft`, pero ningún comando lo pasa, así que los PRs salen listos para revisión. GitHub no deja mergear un PR en borrador.

| Opción | A favor | En contra |
|---|---|---|
| **A ★** En borrador, salvo que `merge.mode` conceda merge en ese repo | Sin cambio de formato; es coherente con el merge automático a `dev` donde lo concediste | La regla depende de otro campo |
| B Campo nuevo `pr.draft` en el envelope (por defecto `true`) | Explícito | Cambio de formato del envelope |
| C Listos para revisión (como hoy) | Sin cambios | Contradice el plan (Fase 3: "PR en borrador") |

**Voto:**

#### D4 — Cómo detecta trabajo nuevo

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Consulta GitHub cada N minutos con `gh` desde bash y lanza `claude` solo si hay trabajo nuevo | No expone la máquina; consultar no gasta suscripción | Reacciona con hasta N minutos de demora |
| B Webhooks de GitHub | Reacción inmediata | Requiere un endpoint público o un túnel (smee, cloudflared) hacia tu PC |

**Voto:**

#### D5 — Qué issues toma

Hoy toma las issues asignadas a ti (`gh issue list --assignee @me`, `envelope.sh:767`) y filtra con `exclude_labels`.

| Opción | A favor | En contra |
|---|---|---|
| A Solo las asignadas a ti (como hoy) | Sin cambios | No cumple "issue con etiqueta" del plan |
| B Asignadas a ti o con la etiqueta de entrada (p. ej. `devlead`), sin mirar quién la puso | Simple | Cualquiera con permiso de etiquetar decide qué ejecuta DevLead |
| **C ★** Asignadas a ti o con la etiqueta de entrada **puesta por una cuenta de la lista permitida** (por defecto solo tú), verificado en los eventos de la issue | Control determinista contra prompt injection (D6) | Una consulta extra a la API por issue |

**Voto:**

### B. Seguridad

#### D6 — Defensa contra prompt injection

Hoy el cuerpo de la issue entra crudo al pipeline (`sweep-execute.md`, `gh issue view --json title,labels,body`) y no hay ninguna regla que diga que ese texto es dato. Con el servidor corriendo 24/7 sin supervisión, este es el hueco más grave.

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Tres capas: (1) regla en GOVERNANCE y en los comandos: el texto de issues, PRs y comentarios va entre delimitadores y nunca cambia límites, envelope ni destino; (2) control de entrada determinista (D5-C); (3) si detecta instrucciones dirigidas al agente (pedidos de merge, de secretos, de URLs externas, "ignora tus reglas"), PARK más un aviso `need`. `guard.sh` y las puertas siguen como red final | Capas independientes; la (2) no depende del modelo | Más trabajo; la (3) puede dar falsos positivos |
| B Solo la regla en prosa (1) | Barato | Depende enteramente de que el modelo la respete |

**Voto:**

#### D7 — Modo de permisos de `claude -p`

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Como hoy: `--permission-mode acceptEdits --allowedTools …` desde `loop.env`, más `guard.sh` | Ya está probado; las herramientas quedan acotadas | Alguna corrida puede frenarse por una herramienta no permitida |
| B `--dangerously-skip-permissions` dentro del contenedor (la documentación de Anthropic lo admite con usuario no-root) | Sin fricción | Según esa misma documentación, todo lo que hay en el contenedor queda expuesto a exfiltración, tokens incluidos |

**Voto:**

#### D8 — Red de salida

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Firewall de salida con lista permitida (API de Anthropic, GitHub, ntfy y los registros de paquetes que necesiten los tests), basado en el `init-firewall.sh` de referencia de Anthropic. La lista es configurable | Limita qué puede filtrarse y adónde | Necesita las capacidades `NET_ADMIN` y `NET_RAW`; los tests que bajen de dominios no listados fallan hasta agregarlos |
| B Sin firewall; solo `guard.sh` | Simple | `guard.sh` advierte que no es un sandbox |

**Voto:**

#### D9 — Configuración bloqueada

Inv 1 y §hard-limits: DevLead no puede cambiar su propia configuración.

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Hooks y reglas `deny` en `/etc/claude-code/managed-settings.json` (de root, solo lectura, la prioridad más alta de Claude Code); scripts de DevLead dentro de la imagen, de solo lectura; el contenedor corre como usuario no-root | El límite queda en el sistema de archivos, no en la prosa | Cambiar un hook exige reconstruir la imagen |
| B Hooks en `~/.claude/settings.json` del contenedor, como hoy en el host | Igual que hoy | El agente podría editarlos |

**Voto:**

#### D10 — Token de GitHub

| Opción | A favor | En contra |
|---|---|---|
| **A ★** PAT fine-grained, solo para los repos enrolados: Contents RW, Pull requests RW, Issues RW y Metadata R; sin Workflows ni Administration. De respaldo, protección de rama en la rama por defecto | Mínimo privilegio; sin el permiso Workflows, GitHub rechaza cualquier push que toque `.github/workflows` | Hay que mantener la lista de repos del token |
| B PAT clásico o la sesión de `gh` del host | Cero configuración | Acceso a todos tus repos |

**Voto:**

### C. Runtime

#### D11 — Modelo de proceso

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Un contenedor permanente (`restart: unless-stopped`) con supercronic adentro, que reemplaza a los timers systemd | Igual en cualquier sistema con Docker; arranca solo cuando arranca Docker; no recupera corridas perdidas (lo pide el plan, Fase 2) | Un proceso más dentro del contenedor |
| B Los timers systemd del host lanzan un `docker run` por tarea | Reutiliza los timers existentes | Solo funciona en Linux; pierde la portabilidad |
| C Contenedor con un bucle `sleep` casero | Sin dependencias | Reinventa un programador de tareas |

**Voto:**

#### D12 — Autenticación con Claude

| Opción | A favor | En contra |
|---|---|---|
| **A ★** `claude setup-token` genera `CLAUDE_CODE_OAUTH_TOKEN`, que va en un `.env` con permisos 600 y fuera de git. Se guarda la fecha de emisión y `doctor` avisa a los 11 meses | Método documentado para scripts y entornos sin navegador; no toca tu sesión personal | Vence al año; solo sirve para pedidos al modelo, sin conectores de claude.ai |
| B Login interactivo dentro del contenedor, persistido en un volumen (`CLAUDE_CONFIG_DIR`) | Se renueva solo | Hay que entrar al contenedor para iniciar sesión; la credencial queda en un volumen |
| C Montar el `~/.claude` del host | Nada que configurar | Expone tu sesión y tu configuración personal al agente |

**Voto:**

#### D13 — Dónde trabaja

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Clones propios en un volumen, uno por repo enrolado, con `git fetch` antes de cada corrida | Nunca pisa tu trabajo; ves lo que hizo como ramas y PRs | Ocupa disco por cada repo |
| B Montar tus carpetas de trabajo | Ve tu estado actual | Ve tus cambios sin commitear y puede pisarlos |

**Voto:**

#### D14 — Estado compartido con `/devlead` interactivo

Hoy `~/.devlead` guarda inbox, journals, agenda, decisiones, reportes y `run-state`, y `/devlead` los lee. Los archivos TSV no tienen bloqueo (pendiente conocido).

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Montar solo los subdirectorios de estado del `~/.devlead` del host, nunca `gh-token`, `notify.env` ni `loop.env`. El contenedor corre con tu UID y se agrega `flock` a quienes escriben los TSV | Por la mañana `/devlead` ve lo que se hizo de noche | Hay que cerrar la carrera de escritura en los TSV |
| B Estado separado; el contenedor solo avisa por ntfy | Aislamiento total | `/devlead` no ve el trabajo nocturno |
| C Estado en GitHub (una issue de bitácora) | Sirve igual si se muda a un servidor | Más lento; queda visible en el repo |

**Voto:**

#### D15 — Versión de Claude Code

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Versión fija en el Dockerfile más `DISABLE_AUTOUPDATER=1`; se actualiza reconstruyendo la imagen | Corridas reproducibles; una actualización no rompe nada de noche | Hay que actualizar a mano |
| B La última versión, con autoactualización | Siempre al día | Cambios sin control en medio de la noche |

**Voto:**

### D. Operación

#### D16 — Horarios

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Horarios y zona horaria (`TZ`) en un archivo de configuración del servidor. Valores por defecto: mañana a las 06:30 de lunes a viernes; consulta de issues cada 30 min entre 07:00 y 20:00; cierre a las 18:30 de lunes a viernes; loop nocturno a las 22:00; discover los lunes a las 05:00 | Nada fijo en el código (plan §3.3) | Un archivo más que validar |
| B Horarios fijos en la imagen, como hoy en `OnCalendar=` | Simple | Hay que reconstruir la imagen para cambiar una hora |

**Voto:**

#### D17 — Topes

Hoy no hay bloqueo entre corridas, ni tope diario, ni timeout (`TimeoutStartSec=infinity` en loop y fleet).

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Una sola corrida de `claude` a la vez (bloqueo global con `flock`); máximo 8 corridas por día; 60 min por corrida; `budget.max_issues: 3` por corrida (ya existe); pausa global con el archivo `~/.devlead/PAUSE`. Todo configurable | Uso moderado, como piden los términos de la suscripción ("ordinary, individual usage") | Un día con mucho trabajo puede quedar a medias |
| B Solo los topes actuales (iteraciones y estancamiento) | Sin cambios | Sin límite diario ni de tiempo |

**Voto:**

#### D18 — Log de auditoría

Hoy la salida de `claude` va a journald y la copia temporal se borra al terminar.

| Opción | A favor | En contra |
|---|---|---|
| **A ★** Por corrida, una línea JSONL en `~/.devlead/audit/AAAA-MM.jsonl` (id de corrida, disparador, repo, inicio y fin, código de salida, `session_id`, herramientas usadas, archivos cambiados, PRs abiertos, resultado, aviso enviado), más el transcript completo (`--output-format stream-json`) en `audit/runs/<id>.jsonl`, guardado 30 días. Nunca se registran variables de entorno | Responde "qué hizo y por qué" sin reconstruir nada | Ocupa disco; los transcripts pueden contener código del repo |
| B Solo la línea de resumen | Liviano | Sin detalle para investigar un problema |

**Voto:**

#### D19 — Avisos

| Opción | A favor | En contra |
|---|---|---|
| **A ★** ntfy, como ya existe. Plan de la mañana y cierre del día con nivel `agenda`; PR abierto, PARK, fallo y token por vencer con nivel `need`. Con el topic protegido por token, el aviso incluye el link del PR (`DEVLEAD_NOTIFY_DETAIL=1`) | Ya está construido y probado en código | Un solo canal |
| B Agregar Telegram o Slack | Más opciones para otros usuarios | Un segundo backend que mantener |

**Voto:**

#### D20 — Empaquetado

| Opción | A favor | En contra |
|---|---|---|
| **A ★** `docker compose` construido en local desde este repo (`docker compose up -d --build`), con `.env.example`. Publicar la imagen en GHCR después; el plugin queda opcional y solo para el modo interactivo. El producto no lleva "Claude" ni "Anthropic" en el nombre (términos de Anthropic) | Sin infraestructura nueva en v1 | Cada usuario construye la imagen |
| B Publicar la imagen en GHCR desde v1 | Instalación más rápida | Agrega publicación y versionado antes de validar |

**Voto:**

---

## 6. Arquitectura con las recomendaciones

```text
PC del usuario (Omarchy, encendida 24/7)
├── docker compose: servicio devlead (restart: unless-stopped, usuario no-root con tu UID)
│   ├── supercronic → mañana · consulta de issues · cierre · loop · discover      (D11, D16)
│   ├── run.sh → bloqueo, tope diario, timeout, auditoría → claude -p "/<comando>"  (D17, D18)
│   ├── /etc/claude-code/managed-settings.json (root, solo lectura): guard, gates, deny  (D9)
│   ├── firewall de salida con lista permitida                                  (D8)
│   ├── volumen workspace/: clones propios de los repos enrolados               (D13)
│   └── montaje de ~/.devlead/{inbox,journals,agenda,decisions,reports,audit}   (D14)
├── .env (600, fuera de git): CLAUDE_CODE_OAUTH_TOKEN, GH_TOKEN, DEVLEAD_NTFY_*  (D10, D12)
└── el usuario: /devlead interactivo, que lee el mismo estado
```

## 7. Fases después del voto

| Fase | Contenido | Puntos |
|---|---|---|
| F0 | Defensa contra prompt injection y control de entrada por etiqueta. Sirve también para el modo actual, sin Docker | D5, D6 |
| F1 | Imagen y compose: usuario no-root, versión fija, configuración bloqueada, firewall, secretos | D7–D10, D12, D15, D20 |
| F2 | Runner: programador, bloqueo, topes, auditoría, aviso de fallo | D11, D16–D19 |
| F3 | Workspace y estado compartido, con `flock` en los TSV | D13, D14 |
| F4 | Comportamiento: PRs en borrador, cierre del día, alcance | D1–D4 |
| F5 | Tres días seguidos sin intervención (plan, Fase 2) y README de instalación | — |
| v2 | Revisión de PRs de otros; aprobaciones con botones | D1 |

Cada fase se entrega en commits de unidades de trabajo revisables, con sus tests. F0, F1 y F2 tocan seguridad y entorno (riesgo alto, puntos 2 y 5), así que llevan verificación independiente.

## 8. Riesgos

- **Límites de la suscripción.** Los términos asumen un uso individual y normal; D17 mantiene las corridas acotadas.
- **Vencimiento del token.** El token de `setup-token` dura un año; D12 avisa antes.
- **Exfiltración.** Si una corrida queda comprometida, puede filtrar lo que hay en el contenedor. La mitigan D6 a D10, en capas.
- **Máquina encendida.** Si la PC se reinicia, el contenedor vuelve cuando arranca Docker (el servicio está habilitado) y no recupera corridas perdidas.
- **Pregunta abierta, fuera de la votación.** El plan menciona `/docs` alineado con ISO 27001, pero ese directorio no existe en este repo. Si está en otro lado, la auditoría de D18 se alinea con eso; si no, con `GOVERNANCE.md`.

## 9. Fuentes verificadas (2026-11-16)

- Términos de Claude Code: <https://code.claude.com/docs/en/legal-and-compliance>
- Autenticación y `claude setup-token`: <https://code.claude.com/docs/en/authentication>
- Contenedores (firewall, `managed-settings.json`, permisos): <https://code.claude.com/docs/en/devcontainer>
- Tareas en la nube (descartadas): <https://code.claude.com/docs/en/routines> y <https://code.claude.com/docs/en/cloud-environments>
- Tareas locales de Desktop (descartadas): <https://code.claude.com/docs/en/desktop-scheduled-tasks> y <https://code.claude.com/docs/en/desktop>
- Claude Duet (la referencia del plan): <https://www.claude.com/resources/articles/claude-duet>
