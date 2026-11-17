# Sowtly

**Sowtly** is a smart assistant you can talk to with your voice or type to, in Arabic or English. Everything runs on your device: the language model, speech-to-text, and text-to-speech. We have no servers, and there are no accounts.

## What It Can Do

- **Live call:** Talk to it and it answers out loud. You can interrupt it at any time.
- **Text chat:** With the reply read aloud if you want.
- **Images and files:** Attach an image, a PDF, or a text file and ask about it. Models marked with the eye icon can see images; the others read the text in the image.
- **On-device memory:** It remembers important things about you from your chats. You can view, edit, and delete them in Settings.

## Internet

The model itself runs on your device. Internet access is controlled by the globe button in the message field:

- **Off:** The app doesn't connect to the internet. If you need to download a model or a voice, it asks you and allows it for that one time only.
- **On:** Text messages search the web (DuckDuckGo or Wikipedia), and the sources appear below the reply.

Exception: Apple Speech may send audio to Apple's servers if your device doesn't support your language on-device and you turned that option on yourself (details in the Privacy Policy).

## Developer

Developer: [za7ef](https://github.com/za7ef)

## Credits and Licenses

Sowtly is built on open-source projects, and each model has its own license that governs its use:

- **MLX, mlx-swift, and mlx-swift-lm** (Apple): Running models on the device. MIT License.
- **Qwen models** (Alibaba): Apache 2.0 License.
- **Gemma models** (Google): Subject to Google's Gemma Terms of Use.
- **Other models in the list:** Each under the license on its Hugging Face page.
- **sherpa-onnx** (k2-fsa): Running speech synthesis and recognition models. Apache 2.0 License.
- **Silero VAD:** Voice activity detection. MIT License.
- **idevice** (Jackson Coxson): Connecting to the device's developer services (phone control and authorizing the UI test session). MIT License.
- **Miro Arabic voice** (OpenVoiceOS, Piper/VITS architecture): CC BY-NC-ND 4.0 License, for non-commercial use with attribution. It isn't shipped inside the app; it downloads from its source on Hugging Face to your device if you request it in Settings.
- **Nabra (Nabra-82M) and Nabra Saudi (Nabra-Saudi-82M)** by oddadmix, built on Kokoro and StyleTTS2: Apache 2.0 License. The Nabra Saudi version used is converted to ONNX and quantized (int8), with no change to the original weights other than quantization.
- **Audar voices — Audar-TTS-V1-Flash** (AudarAI): A Q4_K_M version running with llama.cpp on the GPU while the app is in the foreground, and on the CPU in the background. Licensed under the **AudarAI Open License v1.0**; the full license text ships with the app (AudarAI-Open-License-v1.0.txt) along with the modification notice, and the model itself downloads unmodified from its official page: huggingface.co/audarai/Audar-TTS-V1-Flash. The six voices come from the model's official samples. Sowtly is an independent app, and this does not mean AudarAI endorses or recommends it. There is no voice cloning; any cloning of a person's voice must have their consent and must not impersonate them.
- **LaMa** (Samsung AI / advimman): The "Remove" tool in "Precise". Apache 2.0 License. We use the Core ML conversion from mlboydaisuke/LaMa-CoreML (Apache 2.0, pinned revision 5ed76e3), downloaded with "Precise" and deleted with it, unmodified.
- **NeuCodec** (Neuphonic): Turns Audar codes into audio. Apache 2.0 License. We use only the decoder, converted to float16 and to MLX format, published with the license and notice file.
- **eSpeak NG:** Grapheme-to-phoneme conversion. GPL 3.0 License.
- **NAMAA-Saudi-TTS-V2** (NAMAA Space), built on F5-TTS: CC BY-NC-SA 4.0 License, meaning non-commercial use only, with attribution, and any modification must be shared under the same license. The reference voice is from the Habibi-TTS project.
- **Vocos:** Spectrogram-to-audio conversion. MIT License.
- **swift-transformers and Hugging Face Hub:** Downloading models and reading tokenizers. Apache 2.0 License.
- **ml-stable-diffusion** (Apple): Running Stable Diffusion on the device, a vendored version without the SD3 parts. MIT License.
- **Realistic — CyberRealistic Final** (by Cyberdelia) merged with **LCM-LoRA** for SD 1.5 (Simian Luo et al.), LocalMuseAI's Core ML version: CreativeML OpenRAIL-M License, and LCM-LoRA under OpenRAIL++. Downloads on request.
- **Artistic — DreamShaper 8 LCM** (by Lykon), LocalMuseAI's Core ML version: CreativeML OpenRAIL-M License. Downloads on request.
- **Precise — Bonsai Image Ternary 4B** (PrismML), built on **FLUX.2-klein-4B** (Black Forest Labs) with compressed ternary weights for MLX: Apache 2.0 License. Downloads on request.
- **Qwen3-4B** (Alibaba): The text encoder for "Precise" and "Realistic+", a 4-bit MLX version. Apache 2.0 License.
- **Realistic+ — Z-Image Turbo** (Tongyi-MAI, Alibaba): Apache 2.0 License, the mflux-community 4-bit MLX version. Downloads on request, and uses the same Qwen3-4B text encoder as "Precise".
- **diffusers** (Hugging Face): Reference for the FLUX.2 and Z-Image architecture and generation steps. Apache 2.0 License.
- **turbo-mlx** (rinste): Reference for running Z-Image with MLX Swift. MIT License.
- **flux-2-swift-mlx** (Vincent Gourbin): Reference for writing the FLUX.2 runtime with MLX Swift in Sowtly. MIT License.
- These models are subject to the use restrictions in their licenses (no use for harm, deception, and so on).
- **LCM scheduler:** Written in Sowtly from the equations in the Latent Consistency Models paper (arXiv:2310.04378).

Model and company names belong to their owners and are mentioned here for attribution only.
