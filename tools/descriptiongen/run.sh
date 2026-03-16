#!/bin/bash
set -euxo pipefail

# --- CONFIGURATION ---
VENV_DIR=".venv"
PYTHON_BIN="python3.11"        # brew install python@3.11 if missing
MODEL_LIMIT_MB="${VLM_GPU_LIMIT_MB:-18000}"  # Override: export VLM_GPU_LIMIT_MB=20000

# --- PYTHON CHECK ---
if ! command -v "$PYTHON_BIN" &> /dev/null; then
    echo "❌ $PYTHON_BIN not found. Install it with: brew install python@3.11"
    exit 1
fi
echo "✅ $PYTHON_BIN found"

# --- VENV SETUP ---
if [ -d "$VENV_DIR" ]; then
    source "$VENV_DIR/bin/activate"
else
    echo "📦 Creating fresh virtual environment (Python $PYTHON_VERSION)..."
    $PYTHON_BIN -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
fi

# Only install packages once (delete .packages_installed to force reinstall)
if [ ! -f "$VENV_DIR/.packages_installed" ]; then
    echo "📦 Installing packages (first run only)..."
    pip install -U mlx-vlm opencv-python huggingface_hub \
        mlx mlx-lm Pillow numpy torch torchvision pyyaml
    touch "$VENV_DIR/.packages_installed"
else
    echo "✅ Packages already installed. Skipping."
fi

# --- GPU ALLOCATION (requires sudo) ---
echo "🔑 Allocating ${MODEL_LIMIT_MB}MB for GPU..."
sudo sysctl iogpu.wired_limit_mb=$MODEL_LIMIT_MB

# --- RUN ---
python3 process_vlog.py "$@"

# --- TEARDOWN ---
echo "🧹 Releasing GPU (restoring dynamic management)..."
sudo sysctl iogpu.wired_limit_mb=0 > /dev/null 2>&1 || true

deactivate
echo "✅ venv deactivated."