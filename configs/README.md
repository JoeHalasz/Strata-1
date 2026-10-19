# configs

One folder per model. Everything here except a `base.json` is written by
`launcher\make_configs.py` - edit a `base.json` and re-run it, never a generated file.

```
configs\
  models.json                       the menu run-strata.bat reads        (generated)
  <model>\
    base.json                       this model's settings               (you edit this one)
    <model>--local.json             127.0.0.1, no web search            (generated)
    <model>--online.json            0.0.0.0 + SearXNG web search        (generated)
    <model>--local-vision.json      as local, plus the image encoder    (generated)
    <model>--online-vision.json     as online, plus the image encoder   (generated)
  _archive\                         configs for models that are not installed here
```

## Starting

`run-strata.bat` in the project root asks three questions - model, online, vision - and starts
the server in that window. It remembers the last answer to each, so Enter three times repeats the
last start. `run-strata.bat -List` shows the models; `-Model iq3_s -Online -Vision` skips the
questions; `-DryRun` prints the command instead of running it.

## The four variants

Only three keys differ between them, which is the whole difference between "local" and "online":

| | `host` | `mcp_servers.searxng` | `--vision` in `args` + `vision` section |
|---|---|---|---|
| local | absent (the server's own default, 127.0.0.1) | removed | absent |
| online | `0.0.0.0` | added | absent |
| *-vision | as above | as above | added |

`host` is read by `serve\server.py` (`a.host = a.host or cfg.get("host") or "127.0.0.1"`).
With no `host` the server answers `127.0.0.1` only; `0.0.0.0` also answers the rest of your
network, and the server then warns that no API key is set.

The `-vision` variants are only written when both `mmproj-*.gguf` next to the model's GGUF and
`engine\strata-vision.exe` exist. Right now that is `iq3_s` alone; the other two models get two
variants each, and the launcher does not offer vision for them.

## Changing something

Edit `configs\<model>\base.json`, then:

    .venv\Scripts\python.exe launcher\make_configs.py

It rewrites every variant of every model and `models.json`, and removes a variant that no longer
applies (a model whose mmproj went away, say). `launcher\start.ps1` runs it by itself whenever a
`base.json` is newer than `models.json`, so saving the edit is usually enough.

Anything you put in a `base.json` is copied to all four variants, so that is where engine args,
`sampling`, `env`, `lib_dirs` and your own MCP servers belong. Put `api_key` in a `base.json` to
require it on every variant of that model.

## Adding a model

Make `configs\<name>\` and put a `base.json` in it - copy one and change `--pack`, `--native`,
`--ple-gguf`, `tokenizer`, `model_name` and `--max-context`. `--native` is what the generator
looks beside to find the mmproj. Re-run `make_configs.py` and it appears in the menu.

`setup.py` writes its own `strata-<model>.json` in the project root. To bring one of those in,
save it as `configs\<name>\base.json` and re-run the generator; the root copy is then redundant.

## Logs

Every variant logs to `logs\strata-<model>.log`, so one model's runs land in one file whatever
you picked. `logs\scratch\` holds old one-off logs from building and debugging.
