# Third-Party Notices

ZiroEdge includes or depends on the following third-party software:

---

## llama.cpp

- **URL**: <https://github.com/ggml-org/llama.cpp>
- **License**: MIT License
- **Usage**: On-device LLM inference engine. Linked via Swift Package Manager.

```
MIT License

Copyright (c) 2023-2026 The ggml Authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Bundled Fonts

ZiroEdge bundles three typefaces for the `ZiroType` scale. Full license texts
ship beside the font files in `app/ZiroEdge/Resources/Fonts/`.

### Orbitron

- **Files**: `Orbitron-SemiBold.ttf`, `Orbitron-Bold.ttf` — static instances, not the variable file
- **URL**: <https://github.com/google/fonts/tree/main/ofl/orbitron>
- **License**: SIL Open Font License 1.1 (`License-Orbitron-OFL.txt`)
- **Usage**: `ZiroType.display` / `ZiroType.wordmark` — the brand voice only, never body copy

### Satoshi

- **Files**: `Satoshi-Regular.ttf`, `Satoshi-Medium.ttf`, `Satoshi-Bold.ttf`
- **URL**: <https://www.fontshare.com/fonts/satoshi>
- **License**: ITF Free Font License (`License-Satoshi-FFL.txt`)
- **Usage**: every text role — chat, chrome, hero copy

> **Not an Open Font License.** Satoshi is free for commercial use, including
> embedding in a shipped application, but it is closed-source freeware with a
> license that the OFL does not govern. If a non-OFL dependency is
> unacceptable, Inter (OFL-1.1, Google Fonts) substitutes for it directly —
> swap the three files and the `ZiroType.Face` raw values, nothing else.

### Space Mono

- **Files**: `SpaceMono-Regular.ttf`, `SpaceMono-Bold.ttf`
- **URL**: <https://github.com/google/fonts/tree/main/ofl/spacemono>
- **License**: SIL Open Font License 1.1 (`License-SpaceMono-OFL.txt`)
- **Usage**: `ZiroType.technical` / `ZiroType.meta` — model IDs, quantization tiers, token counts, byte sizes, SHA fragments, timestamps

---

## Model Licenses

### Llama 3.2 3B (llama3.2-3b-q4)

- **Base model**: Meta Llama 3.2 3B Instruct
- **License**: Llama 3.2 Community License
- **URL**: <https://www.llama.com/llama3_2/license/>
- **Attribution**: "Built with Meta Llama 3.2"

### Gemma 4 E2B (gemma-4-e2b-q4)

- **Base model**: Google Gemma 4 2B
- **License**: Gemma Terms of Use
- **URL**: <https://ai.google.dev/gemma/terms>
- **Attribution**: Based on Google Gemma 4

### Gemma 4 E4B (gemma-4-e4b-q4)

- **Base model**: Google Gemma 4 4B
- **License**: Gemma Terms of Use
- **URL**: <https://ai.google.dev/gemma/terms>
- **Attribution**: Based on Google Gemma 4

### LFM 2.5 1.2B (lfm2.5-1.2b-q4)

- **Base model**: LiquidAI LFM 2.5 1.2B Instruct
- **License**: LFM Open License v1.0
- **URL**: <https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF>
- **Attribution**: Official LiquidAI GGUF release, device-validated 2026-09-23

### LFM 2.5 2.6B (lfm2.5-2.6b-q4)

- **Base model**: LiquidAI LFM 2.5 2.6B (base, non-instruct)
- **License**: LFM Open License v1.0
- **URL**: <https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF>
- **Attribution**: Official LiquidAI GGUF release, device-validated 2026-09-23

### Qwen 3.5 2B (qwen3.5-2b-q4)

- **Base model**: Qwen 3.5 2B (Alibaba Cloud)
- **License**: Apache 2.0
- **URL**: <https://huggingface.co/unsloth/Qwen3.5-2B-GGUF>
- **Attribution**: Community conversion by unsloth, device-validated 2026-09-23

### Qwen 3.5 0.8B (qwen3.5-0.8b-q4)

- **Base model**: Qwen 3.5 0.8B (Alibaba Cloud)
- **License**: Apache 2.0
- **URL**: <https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF>
- **Attribution**: Community conversion by unsloth, device-validated 2026-09-23

### Bonsai 8B (bonsai-8b-q1)

- **Base model**: PrismML Bonsai 8B (Qwen3-8B dense, end-to-end 1-bit Q1_0)
- **License**: Apache 2.0
- **URL**: <https://huggingface.co/prism-ml/Bonsai-8B-gguf>
- **Attribution**: Official PrismML release, runs on stock llama.cpp b9821, device-validated 2026-09-23

### Bonsai 4B (bonsai-4b-q1)

- **Base model**: PrismML Bonsai 4B (Qwen3-4B dense, end-to-end 1-bit Q1_0)
- **License**: Apache 2.0
- **URL**: <https://huggingface.co/prism-ml/Bonsai-4B-gguf>
- **Attribution**: Official PrismML release, runs on stock llama.cpp b9821, device-validated 2026-09-23

---

## mmproj Files

The multimodal projector (.mmproj.gguf) files for Gemma 4 vision models were sourced from community GGUF conversions. These files are distributed under the same license terms as their base models.

---

*Curated models are hosted on HuggingFace under the `zanish-labs` organization in GGUF format, except the experimental lineup rows above, which pin their upstream sources (official LiquidAI / PrismML repos, unsloth community conversions) at verified revisions. Model files are downloaded on-demand by the user and stored locally on the device.*
