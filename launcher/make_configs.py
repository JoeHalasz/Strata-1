#!/usr/bin/env python3
"""Write one Strata engine config per option combination, so starting never edits anything.

    reads    configs/<model>/base.json                 the model's settings - edit THIS, never a variant
    writes   configs/<model>/<model>--<variant>.json   local | online | local-vision | online-vision
             configs/models.json                       the menu run-strata.bat shows

    local    127.0.0.1 only (this PC); the browser opens when the model is ready
    online   0.0.0.0 (other devices on your network) + the SearXNG web-search MCP server
    vision   --vision in the engine args + a "vision" section; needs an image encoder - mmproj-*.gguf
          next to the model, or the "mmproj" key in its base.json naming one (one encoder serves
          every quant of the same base model)

    Re-run it after editing a base.json, adding a configs/<model>/ folder, or downloading an mmproj:

        .venv\\Scripts\\python.exe launcher\\make_configs.py
"""
import json
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIGS = ROOT / "configs"
LOGS = ROOT / "logs"
VISION_EXE = ROOT / "engine" / "strata-vision.exe"

# (variant name, online, vision) in the order the files are written
COMBOS = [("local", False, False), ("local-vision", False, True),
          ("online", True, False), ("online-vision", True, True)]

SEARXNG = {"command": "npx", "args": ["-y", "mcp-searxng"], "env": {"SEARXNG_URL": "http://127.0.0.1:8888"}}
MCP = {"timeout_s": 60, "max_result_chars": 20000, "max_rounds": 8}


def arg_value(args, flag):
    """The value that follows a flag in the engine args ("--native" -> the GGUF path); None if absent."""
    return args[args.index(flag) + 1] if flag in args else None


def write(path, obj):
    path.write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")


def mmproj_for(native, override=None):
    """The model's image encoder.

    A base.json "mmproj" wins, because the encoder belongs to the BASE model and not to a quant:
    every quant of Qwen3.8-Flash-Next can share one file.  Checked in the GGUF headers of the three
    quants installed here - the projector writes clip.vision.projection_dim 2560, which is exactly
    the qwen4exp.embedding_length of all three, and all three carry the same image_token_id
    (248056), the same tokenizer pre-tokenizer (qwen35) and vision_start / vision_end / image_pad
    in the chat template.  Their headers differ only in quantization provenance.

    Without an override, mmproj-*.gguf next to the model's own GGUF is used - where setup puts it.
    """
    if override:
        p = Path(override)
        p = p if p.is_absolute() else ROOT / p
        return str(p) if p.exists() else None
    if not native or not Path(native).exists():
        return None
    found = sorted(Path(native).parent.glob("mmproj*.gguf"))
    return str(found[0]) if found else None


def build(base, online, vision, mmproj, vision_exe):
    """One config dict from the model's base.json; every write replaces a key, so base is never touched."""
    cfg = dict(base)
    if online:
        cfg["host"] = "0.0.0.0"
        servers = dict(cfg.get("mcp_servers") or {})
        servers.setdefault("searxng", dict(SEARXNG))
        cfg["mcp_servers"] = servers
        cfg.setdefault("mcp", dict(MCP))
    else:
        cfg.pop("host", None)                             # the server's own default is 127.0.0.1
        servers = dict(cfg.get("mcp_servers") or {})
        servers.pop("searxng", None)                      # web search is the online half of this switch
        if servers:
            cfg["mcp_servers"] = servers
        else:
            cfg.pop("mcp_servers", None)                  # any MCP server you added yourself is kept
    args = list(cfg.get("args") or [])
    if vision:
        if "--vision" not in args:
            args.append("--vision")                       # the engine refuses pictures without it
        cfg["args"] = args
        v = dict(cfg.get("vision") or {})
        v.update({"exe": str(vision_exe), "mmproj": mmproj, "model": arg_value(args, "--native")})
        # engine\strata-vision.exe here is the CPU build (build-vision-cpu.ps1, CUDA off - the exe holds
        # no CUDA code at all).  True would add --gpu to the encoder and make the server hold 700 MiB of
        # VRAM the encoder never touches.  Set it true in a base.json only beside a CUDA-built encoder.
        v.setdefault("gpu", False)
        v.setdefault("max_tokens", 300)
        v.setdefault("threads", 16)
        cfg["vision"] = v
    else:
        cfg["args"] = [a for a in args if a != "--vision"]   # without an encoder the engine would refuse to start
        cfg.pop("vision", None)
    return cfg


def main():
    if not CONFIGS.is_dir():
        print(f"no configs folder: {CONFIGS}", file=sys.stderr)
        return 1
    LOGS.mkdir(parents=True, exist_ok=True)

    models, skipped, no_encoder = [], [], []
    for folder in sorted(p for p in CONFIGS.iterdir() if p.is_dir() and not p.name.startswith("_")):
        key, base_path = folder.name, folder / "base.json"
        if not base_path.exists():
            skipped.append(key)
            continue
        base = json.loads(base_path.read_text(encoding="utf-8-sig"))     # utf-8-sig: Notepad adds a BOM
        base["log"] = str(LOGS / f"strata-{key}.log")                     # logs go to logs/, not the root

        mmproj = mmproj_for(arg_value(base.get("args") or [], "--native"), base.get("mmproj"))
        base.pop("mmproj", None)                              # a note to this script, not a server setting
        can_vision = bool(mmproj and VISION_EXE.exists())
        if not can_vision:
            no_encoder.append(key)                            # could take pictures if an encoder were around

        wanted = {f"{key}--{name}.json" for name, _, vis in COMBOS if not vis or can_vision}
        for stale in folder.glob(f"{key}--*.json"):                       # a variant that no longer applies
            if stale.name not in wanted:
                stale.unlink()

        variants = []
        for name, online, vision in COMBOS:
            if vision and not can_vision:
                continue
            write(folder / f"{key}--{name}.json", build(base, online, vision, mmproj, VISION_EXE))
            variants.append(name)

        models.append({"key": key,
                       "label": (base.get("model_name") or key).replace("qwen3.8-flash-next-", ""),
                       "context": int(arg_value(base.get("args") or [], "--max-context") or 0),
                       "backend": base.get("backend") or "",
                       "vision": can_vision,
                       "variants": variants})
        print(f"  wrote {key:<20} {len(variants)} config(s)   vision: {'yes' if can_vision else 'no'}")

    if not models:
        print(f"no model found: put a base.json in configs\\<model>\\ first ({CONFIGS})", file=sys.stderr)
        return 1

    write(CONFIGS / "models.json", {"generated": datetime.now().strftime("%Y-%m-%d %H:%M"),
                                    "note": "Written by launcher/make_configs.py. Edit a model's base.json "
                                            "and re-run it.",
                                    "models": models})
    for key in skipped:
        print(f"  skipped {key} (no base.json)", file=sys.stderr)
    if no_encoder and VISION_EXE.exists():
        print(f"\nno image encoder for: {', '.join(no_encoder)} - pictures are off for them.  An mmproj-*.gguf "
              f"next to the model, or an \"mmproj\" path in its base.json pointing at one, turns them on.",
              file=sys.stderr)
    print(f"\n{len(models)} model(s) in configs\\models.json.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

