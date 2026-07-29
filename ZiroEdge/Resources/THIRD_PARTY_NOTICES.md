# Third-Party Notices

ZiroEdge includes or depends on the following third-party software:

---

## llama.cpp

- **URL**: https://github.com/ggml-org/llama.cpp
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

## Model Licenses

### Llama 3.2 3B (llama3.2-3b-q4)

- **Base model**: Meta Llama 3.2 3B Instruct
- **License**: Llama 3.2 Community License
- **URL**: https://www.llama.com/llama3_2/license/
- **Attribution**: "Built with Meta Llama 3.2"

### Gemma 4 E2B (gemma-4-e2b-q4)

- **Base model**: Google Gemma 4 2B
- **License**: Gemma Terms of Use
- **URL**: https://ai.google.dev/gemma/terms
- **Attribution**: Based on Google Gemma 4

### Gemma 4 E4B (gemma-4-e4b-q4)

- **Base model**: Google Gemma 4 4B
- **License**: Gemma Terms of Use
- **URL**: https://ai.google.dev/gemma/terms
- **Attribution**: Based on Google Gemma 4

---

## mmproj Files

The multimodal projector (.mmproj.gguf) files for Gemma 4 vision models were sourced from community GGUF conversions. These files are distributed under the same license terms as their base models.

---

*All models are hosted on HuggingFace under the `zanish-labs` organization in GGUF format. Model files are downloaded on-demand by the user and stored locally on the device.*
