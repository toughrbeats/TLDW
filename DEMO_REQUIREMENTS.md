# Demo bring-up checklist (what to add)

This repo currently has orchestration scripts, but most model checkpoints are **not** checked in.
Use this checklist to make the end-to-end demo run.

Quick start: run `bash scripts/get_demo_files.sh` to auto-download the known OpenVoice/SadTalker demo assets.

## 1) OpenVoice checkpoints/files to add

Expected by `pipeline_openvoice/src/openvoice.py` and runner scripts:

- `pipeline_openvoice/checkpoints/checkpoints_v2/base_speakers/ses/en-default.pth`
- `pipeline_openvoice/checkpoints/checkpoints_v2/converter/config.json` (already present)
- `pipeline_openvoice/checkpoints/checkpoints_v2/converter/checkpoint.pth`

Also ensure MeloTTS model assets are downloadable in the OpenVoice env (the code uses `MeloTTS.melo.api.TTS(...)`, which pulls model/config via its download helpers).

## 2) SadTalker checkpoints/files to add

For `pipeline_sadtalker/SadTalker/inference.py`, place models under:

- `pipeline_sadtalker/SadTalker/checkpoints/`

Required set (legacy `.pth` path, per SadTalker code/docs):

- `wav2lip.pth`
- `auido2pose_00140-model.pth`
- `auido2exp_00300-model.pth`
- `facevid2vid_00189-model.pth.tar`
- `epoch_20.pth`
- `mapping_00229-model.pth.tar`
- `mapping_00109-model.pth.tar`
- `shape_predictor_68_face_landmarks.dat`
- `BFM/` (BFM fitting assets)
- `hub/` (face-alignment assets)

Alternative packaged option (safetensors):

- `SadTalker_V0.0.2_256.safetensors` **or** `SadTalker_V0.0.2_512.safetensors`
- Plus mapping files (`mapping_00229-model.pth.tar` and/or `mapping_00109-model.pth.tar`) depending on preprocess mode.

If using enhancer flags (`--enhancer gfpgan` / background enhancer), add:

- `pipeline_sadtalker/SadTalker/gfpgan/weights/*`

## 3) Runtime input files you must provide per demo run

In your chosen `WORKDIR` (default `./work/<timestamp>`):

- `script.txt` (or pass `--text`/`--script` to generate/copy it)
- `beats.json` (generated automatically if bypassing ScriptGen)
- `hooks.json` (needed only for `--ab-hooks` mode)
- `voice.wav` (auto-generated unless you run captions preview in reuse mode)

User-supplied media:

- `--avatar <image>` (required)
- `--ref-wav <reference.wav>` for OpenVoice cloning if not using default speaker mode

Font asset expected by defaults:

- `runnervidpipeline/fonts/TikTokSans_24pt_Expanded-Black.ttf` (already present)

## 4) External project paths the runner expects (hardcoded currently)

`runnervidpipeline/runpipeline.sh` uses absolute macOS paths. For this repo clone to work as a demo, either edit these paths or mirror those folders:

- `/Users/raj/PycharmProjects/pipeline_openvoice`
- `/Users/raj/PycharmProjects/Captions_pipeline`
- `/Users/raj/PycharmProjects/pipeline_sadtalker`
- `/Users/raj/PycharmProjects/ScriptGen_Pipeline`
- `/Users/raj/PycharmProjects/PatternInterrupts_Pipeline`
- `/Users/raj/PycharmProjects/VidFinder_Pipeline` (if YouTube seeding is used)
- `/Users/raj/PycharmProjects/pipelinewhisperx` (if YouTube seeding is used)

## 5) Environment/API prerequisites

- `OPENROUTER_API_KEY` in env (required by `ScriptGen_Pipeline/ScriptGen.py` unless bypassing ScriptGen)
- Python venvs with expected executables:
  - `pipeline_openvoice/.venv/bin/python`
  - `pipeline_sadtalker/.venv/bin/python`
  - `Captions_pipeline/.venv/bin/python`
  - `PatternInterrupts_Pipeline/.venv/bin/python`

## 6) Minimal “demo-ready” checkpoint summary

If you only want a minimal non-YouTube local demo:

1. Add OpenVoice:
   - `checkpoints_v2/base_speakers/ses/en-default.pth`
   - `checkpoints_v2/converter/checkpoint.pth`
2. Add SadTalker checkpoints folder contents listed above.
3. Ensure `script.txt`, avatar image, and ref wav exist.
4. Set or bypass ScriptGen (`OPENROUTER_API_KEY` or `--bypass-scriptgen`).
