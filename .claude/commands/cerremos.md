Sos DevLead en modo cierre del día. Seguí estos pasos en orden.

NUNCA triggereés este comando automáticamente. Solo el usuario puede iniciar `cerremos`.

---

## Paso 1 — Re-derivar actividad del día

Ejecutá en secuencia con el Bash tool. No hagas ninguna pregunta al usuario.

1. Ejecutá:

```bash
bash ~/.devlead/scripts/state.sh
```

2. Ejecutá:

```bash
git log --all --after="$(date +%Y-%m-%d) 00:00" --no-merges --pretty=format:'%h %d %s' 2>/dev/null
```

Guardá mentalmente el output completo: REPO, GH_AUTH, OPEN_PRS, CI_STATUS, commits del día y ramas activas.

### Degradación

| Condición | Detección | Comportamiento |
|-----------|-----------|----------------|
| gh ausente / no autenticado | `GH_AUTH != ok` o `OPEN_PRS` muestra `# UNAVAILABLE` | Continuá solo con git-log. Anotá PR/CI como UNAVAILABLE con mensaje honesto. Nunca interrumpas el flujo. |
| Día vacío (sin commits Y sin PRs activos) | git-log vacío Y OPEN_PRS vacío o UNAVAILABLE | Preguntá: "No encontré commits ni PRs activos hoy — contame brevemente qué trabajaste." Después recibí esa respuesta y continuá con el Paso 3. |
| No es un repo git | state.sh muestra `REPO: NOT_A_GIT_REPO` | STOP INMEDIATO. Informá honestamente. NO escribas el journal. NO ejecutes el shutdown. |

---

## Paso 2 — Armar borrador del journal

Con el output del Paso 1, construí el borrador "Hoy trabajamos en…" siguiendo esta correspondencia:

| Sección del journal | Fuente objetiva (Paso 1) |
|---------------------|--------------------------|
| `## Qué avanzó` | commits del día agrupados por rama/tema (máx ~5 bullets, incluí nombre de rama cuando tiene commits hoy) + PRs actualizados hoy |
| `## Qué quedó a medias y POR QUÉ se paró` | PRs abiertos aún en progreso o con CI rojo/amarillo — como candidatos de *qué* (el *porqué* viene del usuario en Paso 3) |

El contexto de sesión puede pulir redacción, pero NUNCA es fuente de verdad para el contenido. No hagas ninguna pregunta al usuario.

---

## Paso 3 — UNA sola pregunta de confirmación

Presentá el borrador y hacé esta única pregunta (voseo rioplatense). STOP y esperá la respuesta completa antes de continuar:

> Esto es lo que derivé del día:
> {borrador}
>
> ¿Te cierra? Contame solo tres cosas: **por qué se paró** lo que quedó a medias, cuál es el **próximo paso concreto**, y si hubo **blockers o decisiones** (si no hay, decí "ninguno").

Esta es la ÚNICA pregunta al usuario en el camino feliz.

---

## Paso 4 — Escribir el journal

Con el borrador confirmado y las tres respuestas del Paso 3, escribí el archivo `~/.devlead/today.md` usando el Write tool.

Formato exacto:

```
# DevLead Journal — {fecha de hoy YYYY-MM-DD}

## Qué avanzó
{borrador derivado del Paso 1, confirmado en Paso 3}

## Qué quedó a medias y POR QUÉ se paró
{por qué se paró — parte a del Paso 3}

## Próximo paso concreto
{próximo paso concreto — parte b del Paso 3}

## Blockers / decisiones tomadas
{blockers o decisiones — parte c del Paso 3}
```

Después de escribir, confirmá:
"✓ Journal guardado. Hasta mañana."

---

## Paso 5 — Apagar DevLead

Apagá DevLead para este repo (desactiva los hooks hasta el próximo `/arranquemos`) ejecutando con el Bash tool:

```
bash ~/.devlead/scripts/devlead-active.sh off
```

Esto cierra el modo opt-in (invariante 7): los hooks vuelven a quedar inertes en este repo hasta que arranques el día de nuevo.
