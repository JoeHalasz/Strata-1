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
questions; `-DryRun` prints the command instead of running it; `-LogOutputFile logs\run.log`
copies the full server output (stdout+stderr) to a file while still showing it in the window.

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

The `-vision` variants are written when both an image encoder (`engine\strata-vision.exe`) and an
`mmproj-*.gguf` are there. All three models installed here have both, so all three offer four
variants.

The encoder belongs to the base model and not to a quant, so one 866 MB file serves all three -
the two Unsloth folders point at the one in `models\IQ3_S\` with `"mmproj"` in their `base.json`.
The GGUF headers say why that is sound: the projector writes `clip.vision.projection_dim` 2560,
which is the `qwen4exp.embedding_length` of every quant here, and all three carry the same
`image_token_id` (248056), the same `tokenizer.ggml.pre` (`qwen35`), and `vision_start`,
`vision_end` and `image_pad` in the chat template. Their headers differ only in who quantized them
and what they calibrated on. Checked by running the encoder against each model: all three print
`READY 2560` and encode a 448x192 picture to 84 tokens in 0.4 s.

`engine\strata-vision.exe` here is the **CPU** build (`build-vision-cpu.ps1` - the AMD/HIP engine
zip ships without an encoder, `engine\BUILD.json` says `"vision": "none"`, and the exe contains no
CUDA code). So the `vision` section carries `"gpu": false`; with `true` the server would also hold
700 MiB of VRAM the encoder never touches. Set it `true` in a `base.json` only beside a
CUDA-built encoder.

## Changing something

Edit `configs\<model>\base.json`, then:

    .venv\Scripts\python.exe launcher\make_configs.py

It rewrites every variant of every model and `models.json`, and removes a variant that no longer
applies (a model whose mmproj went away, say). `launcher\start.ps1` runs it by itself whenever a
`base.json` is newer than `models.json`, so saving the edit is usually enough.

Anything you put in a `base.json` is copied to all four variants, so that is where engine args,
`sampling`, `env`, `lib_dirs` and your own MCP servers belong. Put `api_key` in a `base.json` to
require it on every variant of that model. The one exception is `mmproj`: it tells the generator
where the image encoder is, and it is written into the variants as `vision.mmproj` rather than
left at the top level.

## Adding a model

Make `configs\<name>\` and put a `base.json` in it - copy one and change `--pack`, `--native`,
`--ple-gguf`, `tokenizer`, `model_name` and `--max-context`. The generator looks beside `--native`
for an `mmproj-*.gguf`; if the encoder lives elsewhere, add `"mmproj": "<path>"` - another model's
copy is fine when both are quants of the same base model. Re-run `make_configs.py` and the model
appears in the menu, with or without the two vision variants depending on what it found.

`setup.py` writes its own `strata-<model>.json` in the project root. To bring one of those in,
save it as `configs\<name>\base.json` and re-run the generator; the root copy is then redundant.

## Logs

Every variant logs to `logs\strata-<model>.log`, so one model's runs land in one file whatever
you picked. `logs\scratch\` holds old one-off logs from building and debugging.
