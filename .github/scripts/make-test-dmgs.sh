#!/bin/bash
# Generates .dmg test fixtures for damage. macOS only (needs hdiutil, ditto).
# Written for the stock /bin/bash 3.2 on macOS.
#
# Usage: make-test-dmgs.sh OUTPUT_DIR
#
# Output:
#   <master>-<FORMAT>.<ext>               the images
#   <image>.imageinfo.plist               `hdiutil imageinfo -plist` for each image
#   <master>.manifest.tsv                 expected file tree inside each master
#   segmented/                            a UDZO image split into .dmgpart segments
#   INDEX.tsv                             one row per image, with status and verify result
#   EXPECTED.tsv                          per master: sha256 and byte size of the decoded raw disk
#   FAILED.txt                            required steps that failed (empty means success)
set -euo pipefail

OUT="${1:?usage: make-test-dmgs.sh OUTPUT_DIR}"
IMAGE_SIZE="${IMAGE_SIZE:-64m}"
RANDOM_MB="${RANDOM_MB:-12}"
SEGMENT_SIZE="${SEGMENT_SIZE:-5m}"

# Every format `hdiutil convert` can write, minus the encrypted variants.
ALL_FORMATS="UDRO UDCO UDZO UDBZ ULFO ULMO UDRW UDTO UDSP UDSB"

# slug|filesystem (hdiutil -fs)|layout (hdiutil -layout)|formats to convert to
# The two masters marked ALL get the full format set. The rest vary the
# filesystem or partition layout and are only written as UDZO.
MASTERS="hfsj-gpt|Journaled HFS+|GPTSPUD|ALL
hfsj-apm|Journaled HFS+|SPUD|UDZO
hfsj-mbr|Journaled HFS+|MBRSPUD|UDZO
hfsj-none|Journaled HFS+|NONE|UDZO
hfs-gpt|HFS+|GPTSPUD|UDZO
hfsx-gpt|Case-sensitive Journaled HFS+|GPTSPUD|UDZO
apfs-gpt|APFS|GPTSPUD|ALL
apfs-apm|APFS|SPUD|UDZO
apfs-mbr|APFS|MBRSPUD|UDZO
apfs-none|APFS|NONE|UDZO
apfscs-gpt|Case-sensitive APFS|GPTSPUD|UDZO"

# Failures of these are recorded as "skipped" instead of failing the run.
# UDCO (ADC) and APFS on an Apple Partition Map may be refused by newer macOS.
OPTIONAL=" UDCO apfs-apm "

WORK="$(mktemp -d)"
SRC="$WORK/src"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
INDEX="$OUT/INDEX.tsv"
EXPECTED="$OUT/EXPECTED.tsv"
FAILED="$OUT/FAILED.txt"
printf 'image\tmaster\tfilesystem\tlayout\tformat\tstatus\tverify\n' > "$INDEX"
printf 'master\traw_sha256\traw_bytes\n' > "$EXPECTED"
: > "$FAILED"

cleanup() {
  for m in "$WORK"/mnt-*; do
    [ -d "$m" ] && hdiutil detach "$m" -force -quiet >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

log() { printf '==> %s\n' "$*"; }

is_optional() {
  case "$OPTIONAL" in *" $1 "*) return 0 ;; esac
  return 1
}

# fail KEY MESSAGE: record a failure unless KEY is optional.
fail() {
  if is_optional "$1"; then
    printf 'skipped (optional): %s\n' "$2"
    return 1
  fi
  printf 'FAILED: %s\n' "$2" | tee -a "$FAILED"
  return 1
}

detach() {
  local i
  for i in 1 2 3 4 5; do
    hdiutil detach "$1" -quiet && return 0
    sleep 2
  done
  hdiutil detach "$1" -force -quiet
}

ext_for() {
  case "$1" in
    UDTO) echo cdr ;;
    UDSP) echo sparseimage ;;
    UDSB) echo sparsebundle ;;
    *)    echo dmg ;;
  esac
}

# Source tree copied into every image. Each entry targets a reader feature.
make_source_tree() {
  log "building source tree"
  mkdir -p "$SRC/dir/nested/deeper" "$SRC/empty-dir" "$SRC/text" "$SRC/many"

  printf 'hello from damage\n' > "$SRC/hello.txt"
  : > "$SRC/empty.txt"
  printf 'three levels down\n' > "$SRC/dir/nested/deeper/file.txt"

  # Extended attribute and classic resource fork.
  xattr -w com.example.damage "xattr value" "$SRC/hello.txt"
  printf 'resource fork data\n' > "$SRC/hello.txt/..namedfork/rsrc"

  # Small file: decmpfs data stored inline in the xattr when compressed.
  printf 'short compressible text, short compressible text\n' > "$SRC/text/small.txt"
  # Large compressible file: many UDIF chunks, and decmpfs data in the
  # resource fork when compressed.
  yes 'a line of compressible text for chunk and decmpfs tests' | head -n 20000 > "$SRC/text/compressible.txt"

  # Incompressible data: forces raw chunks inside compressed formats and
  # spans several segments in the segmented image.
  head -c $((RANDOM_MB * 1024 * 1024)) /dev/urandom > "$SRC/random.bin"
  # All zeros: should come out as zero-fill chunks.
  dd if=/dev/zero of="$SRC/zeros.bin" bs=1m count=8 2>/dev/null

  # Non-ASCII name (NFC on input; HFS+ stores it decomposed).
  printf 'unicode name\n' > "$SRC/dir/"$'caf\xc3\xa9'".txt"

  # Symlinks, absolute-looking target and relative target.
  ln -s hello.txt "$SRC/link-to-hello"
  ln -s ../../hello.txt "$SRC/dir/nested/relative-link"
  ln -s /nonexistent/target "$SRC/dangling-link"

  # Enough directory entries to need index nodes in the catalog/fs B-tree.
  local i name
  i=1
  while [ "$i" -le 2000 ]; do
    printf -v name 'file-%05d.txt' "$i"
    printf '%d\n' "$i" > "$SRC/many/$name"
    i=$((i + 1))
  done

  chmod 600 "$SRC/empty.txt"
  chmod 755 "$SRC/dir/nested"
}

# Copy the source tree into a mounted volume, then add what ditto can't
# carry over from the host.
populate() {
  local mnt="$1"
  ditto "$SRC" "$mnt" || return 1
  # HFS transparent compression (decmpfs). Works on HFS+ and APFS.
  ditto --hfsCompression "$SRC/text" "$mnt/hfs-compressed" || return 1
  # Hard links created on the target volume itself.
  printf 'linked content\n' > "$mnt/linked.txt" || return 1
  ln "$mnt/linked.txt" "$mnt/dir/hardlink-1" || return 1
  ln "$mnt/linked.txt" "$mnt/dir/nested/hardlink-2" || return 1
  touch "$mnt/.metadata_never_index" || return 1
}

# Tab-separated listing of everything under ROOT, used as the test oracle.
write_manifest() {
  local root="$1" out="$2"
  printf '# type\tpath\tmode\tsize\tnlink\tflags\trsrc_size\tsha256\txattrs\n' > "$out"
  ( cd "$root" || exit 1
    find . \( -name .fseventsd -o -name .Spotlight-V100 -o -name .Trashes -o -name .TemporaryItems \) -prune -o -print \
      | LC_ALL=C sort \
      | while IFS= read -r p; do
          if [ -L "$p" ]; then
            printf 'link\t%s\t%s\n' "$p" "$(readlink "$p")"
          elif [ -d "$p" ]; then
            printf 'dir\t%s\t%s\n' "$p" "$(stat -f '%Lp' "$p")"
          else
            rsrc=$(stat -f '%z' "$p/..namedfork/rsrc" 2>/dev/null || echo 0)
            printf 'file\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
              "$p" \
              "$(stat -f '%Lp' "$p")" \
              "$(stat -f '%z' "$p")" \
              "$(stat -f '%l' "$p")" \
              "$(stat -f '%Sf' "$p")" \
              "$rsrc" \
              "$(shasum -a 256 "$p" | cut -d' ' -f1)" \
              "$(xattr "$p" 2>/dev/null | LC_ALL=C sort | paste -sd, -)"
          fi
        done ) >> "$out"
}

# build_master SLUG FS LAYOUT -> writes $WORK/SLUG.dmg (UDRW)
build_master() {
  local slug="$1" fs="$2" layout="$3"
  local master="$WORK/$slug.dmg" mnt="$WORK/mnt-$slug"
  mkdir -p "$mnt"
  hdiutil create -size "$IMAGE_SIZE" -fs "$fs" -layout "$layout" \
    -volname "damage-$slug" -format UDRW -o "$master" -quiet || return 1
  hdiutil attach "$master" -nobrowse -noverify -noautoopen -mountpoint "$mnt" -quiet || return 1
  populate "$mnt" || { detach "$mnt"; return 1; }
  write_manifest "$mnt" "$OUT/$slug.manifest.tsv" || { detach "$mnt"; return 1; }
  detach "$mnt" || return 1

  # Byte-exact reference for the decoded disk.
  local raw="$WORK/$slug-raw.cdr"
  hdiutil convert "$master" -format UDTO -o "$raw" -quiet || return 1
  printf '%s\t%s\t%s\n' "$slug" \
    "$(shasum -a 256 "$raw" | cut -d' ' -f1)" \
    "$(stat -f '%z' "$raw")" >> "$EXPECTED"
  rm -f "$raw"
}

# convert_one SLUG FS LAYOUT FORMAT
convert_one() {
  local slug="$1" fs="$2" layout="$3" fmt="$4"
  local name dest status="ok" verify="n/a"
  name="$slug-$fmt.$(ext_for "$fmt")"
  dest="$OUT/$name"

  if hdiutil convert "$WORK/$slug.dmg" -format "$fmt" -o "$dest" -quiet; then
    hdiutil imageinfo -plist "$dest" > "$dest.imageinfo.plist" 2>/dev/null || true
    case "$fmt" in
      UDTO|UDSP|UDSB) ;;  # not UDIF, nothing to checksum
      *)
        if hdiutil verify "$dest" -quiet >/dev/null 2>&1; then verify="ok"; else verify="failed"; fi
        ;;
    esac
  else
    if is_optional "$fmt"; then status="skipped"; else status="failed"; fi
    fail "$fmt" "convert $slug to $fmt" || true
    rm -rf "$dest"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$slug" "$fs" "$layout" "$fmt" "$status" "$verify" >> "$INDEX"
}

make_source_tree

while IFS='|' read -r -u 3 slug fs layout formats; do
  [ -n "$slug" ] || continue
  log "master $slug ($fs, $layout)"
  if ! build_master "$slug" "$fs" "$layout"; then
    fail "$slug" "create master $slug ($fs, $layout)" || true
    printf '%s\t%s\t%s\t%s\t-\t%s\t-\n' "-" "$slug" "$fs" "$layout" \
      "$(is_optional "$slug" && echo skipped || echo failed)" >> "$INDEX"
    continue
  fi
  [ "$formats" = "ALL" ] && formats="$ALL_FORMATS"
  for fmt in $formats; do
    log "  $slug -> $fmt"
    convert_one "$slug" "$fs" "$layout" "$fmt"
  done
  rm -f "$WORK/$slug.dmg"
done 3<<EOF
$MASTERS
EOF

# What `hdiutil create -srcfolder` produces with default settings; this is
# how most downloadable app DMGs are made.
log "srcfolder default image"
if hdiutil create -srcfolder "$SRC" -volname damage-srcfolder -o "$OUT/srcfolder-default.dmg" -quiet; then
  hdiutil imageinfo -plist "$OUT/srcfolder-default.dmg" > "$OUT/srcfolder-default.dmg.imageinfo.plist" 2>/dev/null || true
  mnt="$WORK/mnt-srcfolder"
  mkdir -p "$mnt"
  if hdiutil attach "$OUT/srcfolder-default.dmg" -readonly -nobrowse -noautoopen -mountpoint "$mnt" -quiet; then
    write_manifest "$mnt" "$OUT/srcfolder-default.manifest.tsv"
    detach "$mnt"
  fi
  printf 'srcfolder-default.dmg\tsrcfolder-default\tdefault\tdefault\tdefault\tok\t-\n' >> "$INDEX"
else
  fail srcfolder "create srcfolder-default.dmg" || true
fi

# Segmented image (.dmg plus .dmgpart files).
if [ -f "$OUT/hfsj-gpt-UDZO.dmg" ]; then
  log "segmented image"
  mkdir -p "$OUT/segmented"
  if hdiutil segment -segmentSize "$SEGMENT_SIZE" -o "$OUT/segmented/hfsj-gpt-UDZO-seg" "$OUT/hfsj-gpt-UDZO.dmg" -quiet; then
    printf 'segmented/hfsj-gpt-UDZO-seg.dmg\thfsj-gpt\tJournaled HFS+\tGPTSPUD\tUDZO segmented\tok\t-\n' >> "$INDEX"
  else
    fail segment "segment hfsj-gpt-UDZO.dmg" || true
  fi
fi

{
  printf '\nmacOS: %s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
  printf 'hdiutil: %s\n' "$(hdiutil -version 2>/dev/null | head -n1 || echo unknown)"
} >> "$OUT/INDEX.tsv.meta"

log "done"
column -t -s $'\t' "$INDEX"
if [ -s "$FAILED" ]; then
  printf '\nRequired steps failed:\n'
  cat "$FAILED"
  exit 1
fi
