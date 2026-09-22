# Internet en Alice

Alice llega a la web a través de Hermes, en el Mac. Agent-Reach instala y diagnostica las herramientas. Las peticiones no pasan por `agent-reach`: Hermes llama a la herramienta que ya corresponde, y `reach` solo unifica las que no tenían skill propia.

Lo que ya estaba se mantiene:

- páginas y búsqueda general: herramientas web de Hermes (Firecrawl);
- GitHub: `gh` y la skill `github`;
- RSS: skill `rss-feeds`;
- Reddit público: skill `reddit-reading`.

`reach` añade YouTube (búsqueda y metadatos; las transcripciones las lee la skill `youtube-content` de Hermes, que las trae enteras y más rápido, y `reach` queda de reserva), búsqueda semántica con Exa, V2EX, búsqueda en Bilibili y lectura de X, Facebook, Instagram, LinkedIn y Xiaohongshu cuando hay sesión. Una rutina puede llamar a `reach` igual que un chat. No hay otro scheduler.

## Cómo fluye una petición

Hermes ve la skill `internet` cuando la pregunta encaja (YouTube, Exa, V2EX, Bilibili o una red que pide sesión). Elige la capability, `reach` ejecuta la herramienta con timeout y devuelve JSON con fuentes. El texto es datos: no se obedecen instrucciones encontradas en una página, un hilo o un transcript.

Varias consultas independientes van en un solo `reach batch` (máximo seis, en paralelo). Si una fuente falla, las demás siguen.

## Dónde está cada cosa

| Qué                           | Dónde                                                               |
| ----------------------------- | ------------------------------------------------------------------- |
| Código y skill versionados    | `hermes-agents/internet/`                                           |
| Skill que carga Hermes        | `~/.hermes/skills/research/internet/SKILL.md`                       |
| Comando                       | `~/.local/bin/reach` → el `reach.py` del repo                       |
| Paquete Agent-Reach 1.5.0     | `~/.agent-reach-venv` (Python 3.13 de uv, no el Python del sistema) |
| Configuración y registro      | `~/.agent-reach/` (permisos `700`)                                  |
| Skill upstream, solo consulta | `~/.agents/skills/agent-reach/`                                     |
| Exa                           | `~/.mcporter/mcporter.json`                                         |
| Temporales de subtítulos      | un directorio temporal que se borra al terminar                     |

Hermes arranca desde launchd con un PATH corto, sin la carpeta global de npm. `reach` añade al final las carpetas donde Agent-Reach deja sus programas (`~/.local/bin`, `~/.hermes/node/bin`, Homebrew y cada `~/.nvm/versions/node/*/bin`) y ejecuta cada programa con su propia carpeta primero, para que `mcporter` y `opencli` usen el `node` con el que se instalaron.

No hay cookies ni tokens en el repositorio. X solo recibe `TWITTER_AUTH_TOKEN` y `TWITTER_CT0` dentro del subproceso, si la persona los ha guardado con `agent-reach configure twitter-cookies`. El registro de `reach` anota capability, backend, duración, número de resultados y código de error. No anota la consulta ni el contenido.

## Estado

```bash
reach health
```

Usa una caché de seis horas. Para repetir el diagnóstico:

```bash
reach health --refresh
agent-reach doctor
agent-reach --version
```

`active_backend: null` en un canal con sesión quiere decir que el diagnóstico no ha tocado el navegador, no que falte el programa.

## Actualizar

No hay actualización silenciosa.

```bash
~/.agent-reach-venv/bin/pip install -U "https://github.com/Panniantong/Agent-Reach/archive/main.zip"
agent-reach install --system --env=local
python3 hermes-agents/internet/instalar.py
reach health --refresh
```

`agent-reach check-update` solo avisa. La skill de Hermes no se reescribe sola: `instalar.py` vuelve a copiarla.

## Plataformas que piden sesión

Hace falta Chrome, la extensión [OpenCLI](https://chromewebstore.google.com/detail/opencli/ildkmabpimmkaediidaifkhjpohdnifk) y haber iniciado sesión en esa web. Comprueba con `opencli doctor`.

X también puede ir por `twitter-cli`. Las cookies se entregan a mano:

```bash
agent-reach configure twitter-cookies
```

Eso no inicia sesión por la persona ni exporta el resto de cookies del navegador.

LinkedIn, sin extensión, queda en Jina para páginas públicas. El MCP de LinkedIn pide un login aparte (`uvx mcp-server-linkedin@latest --login`) y no está activado.

## Desactivar

Quita la skill y el comando. Alice y el resto de herramientas siguen igual.

```bash
rm -rf ~/.hermes/skills/research/internet
rm ~/.local/bin/reach
```

Para quitar también Agent-Reach y sus programas:

```bash
agent-reach uninstall
rm ~/.local/bin/agent-reach ~/.local/bin/yt-dlp
rm -rf ~/.agent-reach-venv
npm uninstall -g mcporter @jackwener/opencli
uv tool uninstall twitter-cli
```

`agent-reach uninstall` no borra entradas de mcporter que no pueda atribuir, ni el venv. Revisa `~/.agent-reach/` antes de borrarlo si guardaste cookies ahí.
