#!/usr/bin/env bash
# 80-media-stack.sh — hardware video encode/decode for the studio + merch work.
# Rembrandt's VCN 3.1: H.264 encode+decode, HEVC 8-bit encode + 10-bit decode,
# VP9 decode, AV1 DECODE ONLY. AV1 encode needs VCN 4.0 (RDNA3) — not this chip.
# shellcheck source=../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
  poplab_detect
  head1 "80 · media / hardware transcode"
  is_apply && require_root

  head2 "packages"
  # NB: 'libva-drivers-all' is not an Ubuntu package name; the metapackage is
  # 'va-driver-all'. Guides that tell you otherwise silently fail.
  ensure_pkgs mesa-va-drivers va-driver-all vainfo ffmpeg

  head2 "probe"
  local vi
  vi="$(vainfo --display drm --device /dev/dri/renderD128 2>/dev/null || true)"
  if [[ -z "$vi" ]]; then
    warn "vainfo returned nothing; retrying with LIBVA_DRIVER_NAME=radeonsi"
    vi="$(LIBVA_DRIVER_NAME=radeonsi vainfo 2>/dev/null || true)"
    [[ -n "$vi" ]] && write_file /etc/profile.d/poplab-vaapi.sh 0644 <<'VA'
# poplab — VAAPI autodetect misfires on some Mesa/driver combinations.
export LIBVA_DRIVER_NAME=radeonsi
VA
  fi
  if [[ -n "$vi" ]]; then
    printf '%s\n' "$vi" | grep -E 'VAProfile' | sed 's/^/    /' | head -30
    grep -q 'VAProfileH264High.*EncSlice' <<<"$vi" && ok "H.264 hardware encode available" || warn "no H.264 encode entrypoint"
    grep -q 'VAProfileHEVCMain.*EncSlice' <<<"$vi" && ok "HEVC 8-bit hardware encode available" || warn "no HEVC encode entrypoint"
  else
    warn "VAAPI still not responding — check that your user is in the 'render' group"
  fi

  head2 "helper"
  write_file /usr/local/bin/poplab-encode 0755 <<'ENC'
#!/usr/bin/env bash
# poplab-encode — full-hardware transcode on Rembrandt (VCN 3.1).
#   poplab-encode in.mov out.mp4            # H.264, CQP 23
#   poplab-encode -c hevc in.mov out.mp4    # HEVC 8-bit
# AV1 encode is NOT available on this GPU (decode only). For AV1 delivery,
# encode with libsvtav1 on the CPU — it is fast enough on 8 Zen3+ cores.
set -euo pipefail
codec=h264
while getopts "c:q:" o; do case "$o" in c) codec="$OPTARG";; q) qp="$OPTARG";; *) exit 64;; esac; done
shift $((OPTIND-1))
qp="${qp:-23}"
in="${1:?input}"; out="${2:?output}"
case "$codec" in
  h264) enc=h264_vaapi ;;
  hevc|h265) enc=hevc_vaapi ;;
  av1) echo "AV1 encode is unsupported on VCN 3.1; using libsvtav1 on CPU" >&2
       exec ffmpeg -i "$in" -c:v libsvtav1 -preset 6 -crf 32 -c:a copy "$out" ;;
  *) echo "unknown codec: $codec" >&2; exit 64 ;;
esac
exec ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -hwaccel_output_format vaapi -i "$in" \
  -c:v "$enc" -rc_mode CQP -qp "$qp" -c:a copy "$out"
ENC
  return 0
}
main "$@"
