# إشعارات الطرف الثالث

## llama.cpp
محرك المعالج يستخدم llama.cpp (ggml-org/llama.cpp) — رخصة MIT. Copyright (c) 2023-2026 The ggml authors.
نموذج المعالج: Gemma 4 E2B بصيغة GGUF (unsloth/gemma-4-E2B-it-GGUF) يُنزَّل داخل التطبيق ويخضع لشروط Gemma.

## Audar-TTS-V1-Flash (AudarAI)

يُنزَّل النموذج عند الطلب من مستودعه الرسمي (النسخة addf2d80538edab4de2103843678825bc11ddce1، الملف Audar-TTS-V1-Flash-Q4_K_M.gguf)، وهو مرخّص بموجب AudarAI Open License v1.0. وتُرفق الرخصة وإشعاراتها كاملةً في صفحة النموذج: https://huggingface.co/audarai/Audar-TTS-V1-Flash
يتضمن التطبيق رموز NeuCodec المرجعية للأصوات التجريبية الستة المأخوذة من عيّنات النموذج الرسمية. ولا يُقصد بذكر AudarAI أي إقرار منها للتطبيق أو تأييد له.

## NeuCodec (Neuphonic)

يُستخدم جزء المفكك من NeuCodec (https://huggingface.co/neuphonic/neucodec) بعد تحويله إلى float16 وإلى تخطيط MLX، وهو مرخّص بموجب رخصة Apache 2.0، ويُنشر الملف المحوَّل مع نص الرخصة وملف إشعار يبيّن التعديلات.

## LaMa (advimman/lama)

تُستخدم أداة LaMa لإزالة العناصر من الصور (Resolution-robust Large Mask Inpainting with Fourier Convolutions، https://github.com/advimman/lama)، وهي مرخّصة بموجب رخصة Apache 2.0. وتُنزَّل نسخة Core ML المحوّلة عند الطلب من المستودع https://huggingface.co/mlboydaisuke/LaMa-CoreML (النسخة 5ed76e3799ab4cad31381750d29880c267477e18، مرخّصة كذلك بموجب Apache 2.0) دون تعديل. ويُرفق نص الرخصة في التطبيق (LaMa-Apache-2.0.txt).
