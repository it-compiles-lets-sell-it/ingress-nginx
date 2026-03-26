#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# LTS build script for ingress-nginx
# Usage: ./build-ingress-nginx-lts.sh [OPTIONS]
#
# Options:
#   -t, --tag <tag>         Image tag (default: lts-<git-sha>)
#   -r, --registry <reg>    Registry prefix  (default: "")
#   -i, --image <name>      Image name       (default: ingress-nginx)
#   -b, --branch <branch>   Branch/tag to pin (default: main)
#   --push                  Push image after build
#   --no-cache              Pass --no-cache to docker build
#   -h, --help              Show this help
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMODULE_PATH="ingress-nginx"
UPSTREAM_REPO="https://github.com/kubernetes/ingress-nginx.git"

# Defaults
BRANCH="main"
IMAGE_NAME="ingress-nginx"
REGISTRY=""
TAG=""
BASE_IMAGE=""
PUSH=false
NO_CACHE=""

# ── Argument parsing ─────────────────────────────────────────────────────────
usage() {
  sed -n '/^# Usage/,/^# ---/p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tag)        TAG="$2";        shift 2 ;;
    -r|--registry)   REGISTRY="$2";   shift 2 ;;
    -i|--image)      IMAGE_NAME="$2"; shift 2 ;;
    -b|--branch)     BRANCH="$2";     shift 2 ;;
    --base-image)    BASE_IMAGE="$2"; shift 2 ;;
    --push)          PUSH=true;       shift   ;;
    --no-cache)      NO_CACHE="--no-cache"; shift ;;
    -h|--help)       usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\033[1;32m[BUILD]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
  done
}

# ── Preflight ────────────────────────────────────────────────────────────────
require git docker grep

log "Checking for Docker daemon..."
docker info &>/dev/null || die "Docker daemon is not running or not accessible."

# ── Submodule setup ──────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

if [[ ! -f .gitmodules ]] || ! grep -q "$SUBMODULE_PATH" .gitmodules 2>/dev/null; then
  log "Registering ingress-nginx as a submodule at ./$SUBMODULE_PATH ..."
  git submodule add --force "$UPSTREAM_REPO" "$SUBMODULE_PATH" \
    || warn "Submodule already exists, continuing..."
fi

log "Initialising and fetching submodule..."
git submodule update --init --recursive "$SUBMODULE_PATH"

# Pin to the requested branch / tag
log "Checking out branch/tag: $BRANCH"
(
  cd "$SUBMODULE_PATH"
  git fetch --tags origin
  git checkout "$BRANCH"
  # If it's a branch (not a detached tag), pull latest
  if git symbolic-ref -q HEAD &>/dev/null; then
    git pull --ff-only origin "$BRANCH"
  fi
)

# Capture the exact SHA we're building from
GIT_SHA="$(git -C "$SUBMODULE_PATH" rev-parse --short HEAD)"
log "Pinned to commit: $GIT_SHA"

# ── Resolve Go version ───────────────────────────────────────────────────────
# Read the Go toolchain version the project pins itself to (go.mod / .go-version)
resolve_go_image() {
  local go_ver=""
  local go_mod="$SUBMODULE_PATH/go.mod"
  local go_ver_file="$SUBMODULE_PATH/.go-version"

  if [[ -f "$go_ver_file" ]]; then
    go_ver="$(cat "$go_ver_file" | tr -d '[:space:]')"
  elif [[ -f "$go_mod" ]]; then
    go_ver="$(grep -m1 '^go ' "$go_mod" | awk '{print $2}')"
  fi

  if [[ -n "$go_ver" ]]; then
    echo "golang:${go_ver}-alpine"
  else
    echo "golang:alpine"   # fallback: latest stable
  fi
}

# ── Build Go binaries ─────────────────────────────────────────────────────────
# rootfs/Dockerfile copies pre-built binaries from rootfs/bin/<arch>/.
# We compile them inside a throwaway Go container so the host needs no Go toolchain.
build_go_binaries() {
  local arch="$1"     # e.g. arm64 / amd64
  local go_image
  go_image="$(resolve_go_image)"
  local out_dir="$SCRIPT_DIR/$SUBMODULE_PATH/rootfs/bin/${arch}"
  local src_dir="$SCRIPT_DIR/$SUBMODULE_PATH"

  mkdir -p "$out_dir"

  log "Go builder image : $go_image"
  log "Compiling binaries for arch: $arch → rootfs/bin/${arch}/"

  # Map Docker arch names → GOARCH values
  local goarch="$arch"
  [[ "$arch" == "amd64" ]] && goarch="amd64"
  [[ "$arch" == "arm64" ]] && goarch="arm64"

  # Each entry: "<output-name>  <main-package-path>"
  local -a BINARIES=(
    "nginx-ingress-controller  cmd/nginx"
    "dbg                       cmd/dbg"
    "wait-shutdown             cmd/waitshutdown"
  )

  for entry in "${BINARIES[@]}"; do
    local bin_name pkg_path
    bin_name="$(echo "$entry" | awk '{print $1}')"
    pkg_path="$(echo  "$entry" | awk '{print $2}')"

    log "  Building $bin_name (${pkg_path})..."
    docker run --rm \
      -e CGO_ENABLED=0 \
      -e GOOS=linux \
      -e GOARCH="$goarch" \
      -e GOFLAGS="-buildvcs=false" \
      -v "${src_dir}:/src:ro" \
      -v "${out_dir}:/out" \
      -w /src \
      "$go_image" \
      go build \
        -trimpath \
        -ldflags="-s -w -X k8s.io/ingress-nginx/version.RELEASE=${TAG} -X k8s.io/ingress-nginx/version.COMMIT=${GIT_SHA}" \
        -o "/out/${bin_name}" \
        "./${pkg_path}/..."
  done

  log "Go binaries ready in $out_dir"
}

# ── Detect target arch ────────────────────────────────────────────────────────
# Honour an explicit TARGETARCH env-var; otherwise match the host.
if [[ -z "${TARGETARCH:-}" ]]; then
  HOST_ARCH="$(uname -m)"
  case "$HOST_ARCH" in
    x86_64)  TARGETARCH="amd64" ;;
    aarch64|arm64) TARGETARCH="arm64" ;;
    *) die "Unsupported host architecture: $HOST_ARCH. Set TARGETARCH explicitly." ;;
  esac
fi
log "Target arch      : $TARGETARCH"

# ── Resolve image tag (must happen before Go build for ldflags) ──────────────
[[ -z "$TAG" ]] && TAG="lts-${GIT_SHA}"
log "Image tag        : $TAG"

# ── Resolve BASE_IMAGE build-arg ────────────────────────────────────────────
# rootfs/Dockerfile requires BASE_IMAGE to be passed in; the upstream build
# system derives it from images/nginx/TAG + a fixed registry prefix.
resolve_base_image() {
  local tag_file="$SUBMODULE_PATH/images/nginx/TAG"
  local nginx_registry="registry.k8s.io/ingress-nginx"

  if [[ -f "$tag_file" ]]; then
    local nginx_tag
    nginx_tag="$(cat "$tag_file" | tr -d '[:space:]')"
    echo "${nginx_registry}/nginx:${nginx_tag}"
  else
    echo ""
  fi
}

if [[ -z "$BASE_IMAGE" ]]; then
  BASE_IMAGE="$(resolve_base_image)"
  if [[ -n "$BASE_IMAGE" ]]; then
    log "Auto-detected BASE_IMAGE: $BASE_IMAGE"
  else
    die "Could not auto-detect BASE_IMAGE from images/nginx/TAG.\n       Supply it explicitly with --base-image <image>.\n       Example: --base-image registry.k8s.io/ingress-nginx/nginx:v1.27.1"
  fi
else
  log "Using provided BASE_IMAGE: $BASE_IMAGE"
fi

# Verify the base image is pullable before spending time on the full build
log "Verifying BASE_IMAGE is accessible..."
if ! docker pull "$BASE_IMAGE" &>/dev/null; then
  warn "Could not pull BASE_IMAGE '$BASE_IMAGE' — it may not exist in a public registry."
  warn "You may need to build it first from $SUBMODULE_PATH/images/nginx/ or supply a mirror."
  warn "Continuing anyway; the build will fail if the image is truly absent."
fi

# ── Compile Go binaries ───────────────────────────────────────────────────────
build_go_binaries "$TARGETARCH"

# ── Resolve Dockerfile ───────────────────────────────────────────────────────
# ingress-nginx keeps its controller Dockerfile at:
#   images/nginx/Dockerfile   (older layout)
#   rootfs/Dockerfile          (newer layout)
DOCKERFILE=""
for candidate in \
  "$SUBMODULE_PATH/images/nginx/Dockerfile" \
  "$SUBMODULE_PATH/rootfs/Dockerfile" \
  "$SUBMODULE_PATH/Dockerfile"; do
  if [[ -f "$candidate" ]]; then
    DOCKERFILE="$candidate"
    break
  fi
done

[[ -n "$DOCKERFILE" ]] || die "Could not locate a Dockerfile inside $SUBMODULE_PATH. Inspect the repo layout and set DOCKERFILE manually."

BUILD_CONTEXT="$(dirname "$DOCKERFILE")"
log "Using Dockerfile : $DOCKERFILE"
log "Build context    : $BUILD_CONTEXT"

# ── Full image ref ────────────────────────────────────────────────────────────
FULL_IMAGE="${IMAGE_NAME}:${TAG}"
[[ -n "$REGISTRY" ]] && FULL_IMAGE="${REGISTRY%/}/${FULL_IMAGE}"

log "Image            : $FULL_IMAGE"

# ── Build ────────────────────────────────────────────────────────────────────
log "Starting Docker build..."
docker build \
  ${NO_CACHE} \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg TARGETARCH="$TARGETARCH" \
  --label "org.opencontainers.image.source=${UPSTREAM_REPO}" \
  --label "org.opencontainers.image.revision=${GIT_SHA}" \
  --label "org.opencontainers.image.version=${TAG}" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t "$FULL_IMAGE" \
  -f "$DOCKERFILE" \
  "$BUILD_CONTEXT"

log "Build complete: $FULL_IMAGE"

# ── Optionally push ──────────────────────────────────────────────────────────
if [[ "$PUSH" == true ]]; then
  [[ -z "$REGISTRY" ]] && warn "No --registry specified; pushing to Docker Hub or local daemon."
  log "Pushing $FULL_IMAGE ..."
  docker push "$FULL_IMAGE"
  log "Push complete."
fi

log "Done. ✓"

