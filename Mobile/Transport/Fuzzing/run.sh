#!/bin/bash
set -euo pipefail

fuzz_root="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$fuzz_root/../../.." && pwd)"
scratch="${SSHENGINE_FUZZ_BUILD:-$repository_root/build/spm-ssh-fuzz}"
corpora="${SSHENGINE_FUZZ_CORPORA:-$repository_root/build/ssh-fuzz-corpora}"
artifacts="${SSHENGINE_FUZZ_ARTIFACTS:-$repository_root/build/ssh-fuzz-artifacts}"
module_cache="$scratch-module-cache"
llvm_root="${FUZZER_LLVM_ROOT:-}"
if [[ -z "$llvm_root" ]] && command -v brew >/dev/null 2>&1; then
  llvm_root="$(brew --prefix llvm@22 2>/dev/null || true)"
fi
llvm_root="${llvm_root:-/opt/homebrew/opt/llvm@22}"
fuzzer_runtime="${FUZZER_RUNTIME:-$(find "$llvm_root/lib/clang" -path '*/lib/darwin/libclang_rt.fuzzer_osx.a' -print | sort -V | tail -1)}"
if [[ ! -f "$fuzzer_runtime" ]]; then
  echo "libFuzzer was not found below $llvm_root; install llvm@22 or set FUZZER_RUNTIME" >&2
  exit 1
fi

mkdir -p "$corpora" "$artifacts" "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
swift run --disable-sandbox --package-path "$fuzz_root" --scratch-path "$scratch-seeds" seed-corpus "$corpora"

swift_flags=(
  -Xswiftc -DSSHENGINE_FUZZING
  -Xswiftc -sanitize=address
  -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table,indirect-calls,trace-cmp
)
products=(fuzz-client-initial fuzz-client-post-kex fuzz-messages fuzz-key-blobs fuzz-signatures fuzz-key-files)
requested="${1:-all}"
if [[ "$requested" == "all" ]]; then
  selected=("${products[@]}")
else
  selected=("$requested")
fi
shift || true

for product in "${selected[@]}"; do
  case " ${products[*]} " in
    *" $product "*) ;;
    *) echo "unknown target: $product" >&2; exit 2 ;;
  esac
done

for product in "${selected[@]}"; do
  FUZZER_LLVM_ROOT="$llvm_root" FUZZER_RUNTIME="$fuzzer_runtime" \
    swift build --disable-sandbox --package-path "$fuzz_root" --scratch-path "$scratch" --configuration release \
    --product "$product" "${swift_flags[@]}"
done
bin="$(FUZZER_LLVM_ROOT="$llvm_root" FUZZER_RUNTIME="$fuzzer_runtime" \
  swift build --disable-sandbox --package-path "$fuzz_root" --scratch-path "$scratch" --configuration release \
  --show-bin-path "${swift_flags[@]}")"

for product in "${selected[@]}"; do
  mkdir -p "$artifacts/$product"
  echo "$product"
  ASAN_OPTIONS="${ASAN_OPTIONS:-abort_on_error=1}" "$bin/$product" "$corpora/$product" \
    -artifact_prefix="$artifacts/$product/" -max_len=262144 -timeout=10 -print_final_stats=1 "$@"
done
