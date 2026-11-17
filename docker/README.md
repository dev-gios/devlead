# Servidor local de DevLead (Docker)

DevLead puede vivir en tu propia máquina como un servidor: un contenedor encendido todo el día que trabaja con tu suscripción de Claude, sin API key y sin nube. De noche avanza las issues, de día detecta trabajo nuevo, y a la mañana `/devlead` en tu terminal ve lo que hizo.

El diseño votado está en `.devlead/specs/design-proactive-local-server.md`. Cada variable se explica con detalle en `docker/devlead.env.example`.

## Qué hace y cuándo

| Trabajo | Horario por defecto | Qué hace | ¿Abre sesión de Claude? |
|---|---|---|---|
| `morning` | 06:30 lun–vie | Resumen y agenda del día (nivel `agenda`) | No |
| `poll` | cada 30 min, 07:00–19:30 | Busca issues elegibles nuevas con `gh`; solo si hay alguna, lanza una corrida para ellas | Solo si hay trabajo nuevo |
| `endofday` | 18:30 lun–vie | Resumen del día: corridas, PRs abiertos, trabajo parado (PARK), fallos | No |
| `loop` | 22:00 | Avanza el plan de `DEVLEAD_LOOP_PLAN` en `DEVLEAD_LOOP_REPO` | Sí |
| `fleet` | 22:30 | Una pasada por cada repo enrolado con el envelope activo | Sí |
| `discover` | lunes 05:00 | Exploración semanal de los repos que activaron discovery | Sí |

Lo que el servidor nunca hace solo:
- mergear fuera de lo que concede `merge.mode`, y siempre a través de `merge.sh`;
- pushear a la rama por defecto;
- borrar ramas;
- cerrar o comentar issues;
- revisar o comentar PRs;
- sacar un PR del estado borrador.

Los PRs que abre son borradores salvo que el envelope del repo conceda el merge.

## Requisitos

- Una máquina Linux encendida 24/7 con Docker y Docker Compose v2. En macOS los archivos de estado se escriben sin `flock`.
- Una suscripción de Claude y Claude Code instalado en una máquina con navegador, solo para generar el token.
- Una cuenta de GitHub con acceso a los repos que vas a enrolar.
- Este repositorio clonado en la máquina. La imagen se construye desde él.

## Instalación

### 1. Token de Claude

En una máquina con navegador:

```bash
claude setup-token
```

Aprueba el acceso y guarda el token que imprime. Anota la fecha de hoy. El token dura un año y `doctor` avisa desde el mes 11.

**Varias suscripciones.** Si tienes más de una cuenta de Claude (por ejemplo la del equipo de tu empresa y la tuya personal), el servidor puede usarlas todas como un *pool* de cuentas. Corre `claude setup-token` una vez por cuenta, con la sesión iniciada en esa cuenta, y guarda cada token con su fecha. En el paso 5 cada cuenta lleva un número, que es su prioridad, y un nombre corto:

```bash
DEVLEAD_CLAUDE_ACCOUNT_1=team                  # la cuenta Team: la que se usa primero
DEVLEAD_CLAUDE_ACCOUNT_1_TOKEN=sk-ant-oat01-...
DEVLEAD_CLAUDE_ACCOUNT_1_ISSUED=2026-11-17
DEVLEAD_CLAUDE_ACCOUNT_2=ultra                 # la cuenta personal: el respaldo
DEVLEAD_CLAUDE_ACCOUNT_2_TOKEN=sk-ant-oat01-...
DEVLEAD_CLAUDE_ACCOUNT_2_ISSUED=2026-11-17
```

El orden es tuyo: el número 1 es la cuenta que se usa primero. Cada sesión usa la cuenta de mayor prioridad y recibe solo el token de esa cuenta. El registro de sesiones y la auditoría nombran la cuenta, nunca el token. Con un pool, deja vacíos `CLAUDE_CODE_OAUTH_TOKEN` y `DEVLEAD_CLAUDE_TOKEN_ISSUED`: las dos formas no se mezclan, y si una cuenta está incompleta o mal escrita el contenedor no arranca y el log nombra la variable.

### 2. Token de GitHub

Crea un token *fine-grained* en GitHub → Settings → Developer settings → Fine-grained tokens:

- **Repository access:** *Only select repositories*, exactamente los repos que vas a enrolar.
- **Permisos:** Contents *Read and write*, Pull requests *Read and write*, Issues *Read and write*, Metadata *Read-only*.
- **Nada más:** sin Workflows ni Administration.

### 3. Ajustes en cada repo enrolado (GitHub)

- **Protección de la rama por defecto:** activa la protección de rama, o un ruleset, sobre la rama por defecto. Es la red de respaldo; DevLead no la configura.
- **Borrado automático de ramas:** activa *Settings → General → Automatically delete head branches*. El servidor no borra ramas, así que sin esto las ramas mergeadas quedan en GitHub y las tareas apiladas sobre ellas terminan en PARK.
- **Envelope:** commitea `.devlead/envelope.yml` en la rama por defecto. El servidor lee el envelope, `CLAUDE.md` y `.claude/` desde origin. Sin envelope en esa rama, el repo cuenta como no enrolado.

### 4. Estado compartido con tu `/devlead`

El contenedor monta solo estas carpetas de tu `~/.devlead`. Nunca monta `gh-token`, `notify.env` ni `loop.env`. Créalas una vez:

```bash
mkdir -p ~/.devlead/{agenda,audit,decisions,journals,learn,outcomes,reports,run-state}
touch ~/.devlead/inbox.tsv ~/.devlead/inbox.read.tsv
```

### 5. Archivo de entorno

Desde la raíz de este repo:

```bash
cp docker/devlead.env.example .env
chmod 600 .env
```

`.env` guarda secretos: tiene que quedar en modo 600 y fuera de git (`.gitignore` ya lo ignora). Completa como mínimo:

| Variable | Valor |
|---|---|
| `DEVLEAD_UID`, `DEVLEAD_GID` | La salida de `id -u` y `id -g` |
| `DEVLEAD_STATE_DIR` | La ruta absoluta de tu `~/.devlead` |
| `DEVLEAD_WORKSPACE` | La carpeta absoluta que contiene los repos a enrolar |
| `DEVLEAD_REPOS` | `<ruta local>=<owner>/<repo>`, separados por comas |
| `DEVLEAD_GIT_NAME`, `DEVLEAD_GIT_EMAIL` | El autor de los commits del servidor |
| `CLAUDE_CODE_OAUTH_TOKEN`, `DEVLEAD_CLAUDE_TOKEN_ISSUED` | El token del paso 1 y su fecha (`AAAA-MM-DD`); o, con varias cuentas, `DEVLEAD_CLAUDE_ACCOUNT_<N>`, `_TOKEN` e `_ISSUED` por cuenta |
| `GH_TOKEN` | El token del paso 2 |
| `TZ` | Tu zona horaria, por ejemplo `America/Bogota` |

Las rutas de `DEVLEAD_REPOS` son las de tus repos en esta máquina. El servidor mantiene su propio clon de cada uno en la misma ruta dentro del contenedor, así que tus copias de trabajo nunca se tocan.

Opcionales:
- **Notificaciones:** `DEVLEAD_NTFY_URL` y `DEVLEAD_NTFY_TOKEN`. Con `DEVLEAD_NOTIFY_DETAIL=1`, el push lleva enlaces y números de issue.
- **Loop nocturno:** `DEVLEAD_LOOP_REPO` y `DEVLEAD_LOOP_PLAN`.
- **Paquetes para los tests:** `DEVLEAD_EGRESS_ALLOW`, con los registros de paquetes que necesiten los tests de tus repos.

### 6. Apaga los timers del host

Si usabas los timers de systemd de `.devlead/systemd/`, apágalos; si no, ellos y el servidor escribirían el mismo reporte del día:

```bash
systemctl --user disable --now devlead-sweep.timer devlead-loop.timer devlead-fleet.timer devlead-discover.timer
```

### 7. Construye y arranca

```bash
DEVLEAD_SOURCE_REV="$(git rev-parse HEAD)" docker compose up -d --build
```

`DEVLEAD_SOURCE_REV` le permite a `doctor` verificar la imagen. Sin él, las corridas de Claude no arrancan.

Si un valor del `.env` es inválido, el contenedor no arranca y el log nombra la variable. El valor nunca aparece en el log.

### 8. Verifica

```bash
docker compose ps                     # el servicio "devlead" en estado running
docker compose logs --tail 50 devlead  # avisos de arranque, por ejemplo un loop sin plan
docker compose exec -u devlead devlead bash /home/devlead/.devlead/scripts/doctor.sh
docker compose exec -u devlead devlead /opt/devlead/docker/run-job.sh morning
```

`doctor` debe terminar sin errores. La corrida manual de `morning` deja una línea en `~/.devlead/audit/` y publica la agenda.

Los comandos que actúan como el agente llevan `-u devlead`. `docker compose exec` sin `-u` corre como root, y las corridas se niegan a correr como root.

## Uso diario

- **Lo que hizo de noche:** abre tu terminal y corre `/devlead`. Lee el mismo estado que escribió el servidor.
- **Pausar todo:** ningún trabajo ni sesión arranca mientras exista el archivo. Solo root puede crearlo o borrarlo.
  ```bash
  docker compose exec -u root devlead touch /home/devlead/.devlead/PAUSE
  docker compose exec -u root devlead rm /home/devlead/.devlead/PAUSE
  ```
- **Auditoría:** cada corrida agrega una línea a `~/.devlead/audit/AAAA-MM.jsonl` y a `docker compose logs`. Las transcripciones completas quedan 30 días en `audit/runs/`.
- **Topes:**
  - una sesión de Claude a la vez;
  - 8 por día (`DEVLEAD_MAX_SESSIONS_PER_DAY`);
  - 60 min por sesión (`DEVLEAD_SESSION_TIMEOUT`);
  - 4 h por trabajo (`DEVLEAD_JOB_TIMEOUT`).

  El conteo diario sobrevive a recrear el contenedor.
- **Avisos:**
  - **nivel `agenda`:** la agenda de la mañana y el resumen del día;
  - **nivel `need`:** PR abierto, trabajo parado (PARK), corrida fallida o excedida, sesión rechazada por un tope, auditoría alterada, token por vencer y una issue con instrucciones dirigidas al agente (`untrusted-content`), que queda fuera del plan.
- **Cambiar el plan del loop:** edita el archivo y reinicia el contenedor con `docker compose restart devlead`.

## Mantenimiento

- **Actualizar DevLead:** `git pull` en este repo y luego el mismo comando del paso 7. La versión de Claude Code está fijada en la imagen y solo cambia al reconstruir.
- **Renovar el token de Claude** antes del año: `claude setup-token`, actualiza `CLAUDE_CODE_OAUTH_TOKEN` y `DEVLEAD_CLAUDE_TOKEN_ISSUED` en `.env`, y corre `docker compose up -d`. Con un pool, renueva la cuenta que nombra el aviso: su `DEVLEAD_CLAUDE_ACCOUNT_<N>_TOKEN` y su `DEVLEAD_CLAUDE_ACCOUNT_<N>_ISSUED`.
- **Detener:** `docker compose down`. Los clones y el conteo diario quedan en sus volúmenes. `docker compose down -v` también borra los volúmenes.

## Límites conocidos

- El horario no recupera las corridas que se perdieron mientras la máquina estaba apagada.
- El límite `irreversible` de `guard.sh` compara texto. No es un sandbox, y el token de GitHub sigue pudiendo cerrar issues. La protección de rama del paso 3 es la red de respaldo.
- Cada consulta de issues sincroniza todos los repos enrolados. Si uno falla, el aviso `job-failed` se repite en cada consulta hasta que se arregle.
- Las corridas guiadas no pueden escribir el reporte `~/.devlead/reports/*-execute.md`, así que el aviso de PARK puede apuntar a un reporte que no existe. Los motivos quedan en la transcripción de la corrida.

## Prueba de tres días

El criterio de cierre (T7) es que el servidor corra tres días seguidos sin intervención. Cada mañana revisa:

1. `docker compose ps`: el contenedor siguió encendido.
2. `docker compose logs --since 24h devlead | grep devlead-audit`: hubo corridas, y el campo `outcome` de cada línea de auditoría muestra su resultado.
3. En `/devlead`: la agenda, los PRs en borrador y las decisiones de la noche están ahí.
4. Que no haya llegado ningún aviso `need` inesperado, como `job-failed`, `audit-tampered` o `job-refused`.
5. En GitHub: ningún merge fuera de lo que concede el envelope, ninguna issue cerrada, ningún comentario a tu nombre.
