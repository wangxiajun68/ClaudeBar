# Provider brand assets

Bundled offline. PNGs from LobeHub Icons, pinned to `@lobehub/icons-static-png@1.97.1`; see `LICENSE-LobeHub.txt` (MIT). Brand marks identify their respective services and remain the property of their owners. No generated or letter-substitute logos.

LiteLLM uses its official documentation favicon, https://docs.litellm.ai/img/favicon.ico (retrieved 2026-09-24).

`-color` variants keep the brand's own multicolor artwork (Kimi's is white-on-brand-color);
`kimi` uses the monochrome mark, which is the only variant that stays legible on the editor's
near-white icon well in light mode. Check every new asset's ink luminance against
`Theme.bgSecondary` before adding it — a white mark on a light well reads as a blank tile.
Swapped `-color` for the monochrome mark on 2026-09-24 for five brands whose color artwork
failed that check on its own themed well — Kimi (pure white, 1.06:1 light), NVIDIA (2.35:1),
OpenRouter (acid yellow, 1.13:1 light), 硅基流动 (2.52:1 dark), 火山方舟 (2.77:1 light).
`Tests/provider-icon-regressions.py` now enforces the 3:1 floor on every bundled mark.

| Local asset | Source |
| --- | --- |
| anthropic-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/anthropic.png |
| anthropic-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/anthropic.png |
| deepseek-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/deepseek-color.png |
| deepseek-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/deepseek-color.png |
| gemini-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/gemini-color.png |
| gemini-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/gemini-color.png |
| kimi-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/kimi.png |
| kimi-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/kimi.png |
| minimax-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/minimax-color.png |
| minimax-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/minimax-color.png |
| nvidia-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/nvidia.png |
| nvidia-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/nvidia.png |
| openai-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/openai.png |
| openai-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/openai.png |
| lmstudio-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/lmstudio.png |
| lmstudio-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/lmstudio.png |
| ollama-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/ollama.png |
| ollama-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/ollama.png |
| openrouter-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/openrouter.png |
| openrouter-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/openrouter.png |
| qwen-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/qwen-color.png |
| qwen-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/qwen-color.png |
| siliconcloud-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/siliconcloud.png |
| siliconcloud-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/siliconcloud-color.png |
| stepfun-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/stepfun-color.png |
| stepfun-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/stepfun-color.png |
| volcengine-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/volcengine.png |
| volcengine-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/volcengine.png |
| xai-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/xai.png |
| xai-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/xai.png |
| zai-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/zai.png |
| zai-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/zai.png |
| zhipu-dark.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/dark/zhipu-color.png |
| zhipu-light.png | https://unpkg.com/@lobehub/icons-static-png@1.97.1/light/zhipu-color.png |
