# NPU model runner

This folder contains helper scripts to run NPU-optimized models (RyzenAI/ONNX GenAI).

run_model.sh
- Usage: `./run_model.sh <model-file-or-dir> [port]`
- Behavior:
  - If given a directory, the script searches for `genai_config.json` (preferred) or `.onnx` files (depth 3).
  - Autodetects `ryzenai` models (via `genai_config.json`) and ONNX files.
  - Chooses an available port starting at `8080` (or the provided port) and logs the chosen port.
  - If `ryzenai-server` is present in `$PATH` or the workspace, attempts to start it with `-m <model-dir> --port <port>`.
  - Writes runtime logs to `<model-dir>/run_model_<port>.log` and writes the chosen port to `<model-dir>/.run_model_port`.

Notes & troubleshooting
- The repository `.gitignore` contains a `run_*.sh` pattern which may exclude `npu/run_model.sh` from Git. To track the script use either:
  - `git add -f npu/run_model.sh` or
  - whitelist the file by adding `!/npu/run_model.sh` to `.gitignore`.

- `lemonade` in this repo is the clipboard tool; the server binary (`lemond`/`ryzenai-server`) may be missing and must be installed separately.

Examples

```bash
# Start a model folder, auto-choose a port
./run_model.sh /path/to/models/Qwen2.5-Coder-..._npu_16K/

# Start and request a specific port (will choose next free if occupied)
./run_model.sh /path/to/models/ModelX/ 8090
```
