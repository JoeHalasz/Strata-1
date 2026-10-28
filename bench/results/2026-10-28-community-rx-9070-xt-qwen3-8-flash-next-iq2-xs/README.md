# Community benchmark on AMD Radeon RX 9070 XT

Measured on 2026-10-28 with `tools/strata_bench.py` (suite 1, 3 runs per test, medians with ranges). Speeds are the engine's own timings; first-token times are measured by the client over HTTP. Speed only: no correctness check was run.

## Hardware and software

- GPU and VRAM: AMD Radeon RX 9070 XT, 16 GiB VRAM
- CPU: AMD Ryzen 9 9950X3D 16-Core Processor (16 cores, 32 threads); installed RAM: 95.6 GiB; storage: not measured
- OS: Windows 10 (10.0.19045); GPU driver: 32.0.32015.2008; CUDA: not read
- Strata: project 0.1.44.1, commit d1ba1378; engine 0.1.44.1
- Background workloads and power limits: not recorded

## Model and configuration

- Model and quantization: qwen3.8-flash-next-iq2_xs
- Context: 131072 tokens; parallel slots: 1
- Settings: the install's own configuration, unchanged (hip backend); thinking off for the suite; temperature 0

```text
strata.exe --pack iq2_xs --native Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf --ple-gguf Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf --expert-profile expert-profile.bin --expert-cache auto --prefill auto --spec 4 --spec-min-p 0.5 --mtp rt --max-context 131072 --kv int8 --kv-resident 32768
```

Environment of the config: `STRATA_HIPBLASLT_TUNING=gfx1201-hipblaslt-100500.txt`

## Method

Run by `python tools/strata_bench.py` against the HTTP API of a Strata server (started by the benchmark from the install configuration); model loading is not timed. One warm-up chat and a 1K prompt are discarded first. Every prompt starts with a unique tag, so the conversation cache cannot help the fresh-prompt tests.

- short chat: the three questions of `tools/ab_engine.py`, up to 100 new tokens, 3 runs
- 4K / 16K prompts: generated word lists sized by a calibration request, 24 new tokens, 3 fresh prompts each
- agent session: system prompt and four tools, then 5 turns that each add about 1500 words of a project file and continue from the model's own earlier answers (the way agent clients resend a conversation), 64 new tokens per turn, 3 sessions; the cache numbers come from the answer's usage (`cached_tokens`) and timings (`prompt_n`)
- concurrency (when run): N requests sent at the same moment, total tokens over the wall time of the burst, latency over all requests

## Results

| Configuration | Actual prompt tokens | Reused tokens | Generated tokens | Runs | Prompt tok/s median and range | Decode tok/s median and range | TTFT seconds median and range |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| short chat | 46 (43-51) | 0 | 100 (100-100) | 9 | not measured | 87.9 (83.7-112.9) | 0.30 (0.26-0.38) |
| 4K prompt, fresh | 4019 (4019-4019) | 0 (0-0) | 24 cap | 3 | 678.3 (677.1-678.9) | not measured | 5.96 (5.94-5.97) |
| 16K prompt, fresh | 16058 (16058-16058) | 0 (0-0) | 24 cap | 3 | 799.5 (799.0-800.2) | not measured | 20.12 (20.11-20.14) |
| agent session, follow-up turns | 14590 (14568-14627) at the last turn | see below | up to 64 | 3 | see below | 94.0 (82.4-109.4) | 5.77 (4.86-6.15) |

Ranges are the lowest and highest of the runs; `Runs` counts requests that returned a token.

### Agent session (conversation cache)

Cache hit over the follow-up turns: 68.8 % (68.4-68.9); earlier-turn tokens read again per session: 2 (0-144) (earlier turns that the cache did not hold; the 13729 (13726-13729) new tokens of the files are read once); first turn (nothing cached) first token: 4.17 s (4.09-4.30).

| Turn (run 1) | Prompt tokens | Reused | Read | Prompt tok/s | First token (s) | Decode tok/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 609 | 0 | 609 | 142.1 | 4.304 | 78.7 |
| 1 | 3766 | 646 | 3120 | 544.6 | 5.768 | 83.9 |
| 2 | 5299 | 3830 | 1469 | 305.3 | 4.856 | 90.2 |
| 3 | 8743 | 5363 | 3380 | 584.6 | 5.806 | 85.6 |
| 4 | 11665 | 8805 | 2860 | 510.2 | 5.655 | 102.8 |
| 5 | 14627 | 11730 | 2897 | 505.4 | 5.761 | 109.4 |

Per-request data: `results.json`. Engine log lines from the start: `engine-log-excerpt.txt` (when this run started the server).

## Correctness and limitations

Not measured: this is a speed suite. The conversation uses the model's own replies, so token counts differ a little between runs. Machine details come from the server, `nvidia-smi`/`rocm-smi` and the OS; background load and power limits are not recorded. Total time of the suite: 208 s.
