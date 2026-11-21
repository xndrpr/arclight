#!/bin/zsh
# Code and app-size numbers tracked in docs/performance.md. Prints one "name value" pair per line.
#   Scripts/metrics.sh          code metrics, plus the app's size when dist/Arclight.app exists
set -euo pipefail
cd "$(dirname "$0")/.."

src=(${(f)"$(find Sources -name '*.swift')"})
all=$(cat $src | wc -l | tr -d ' ')
comments=$(cat $src | grep -cE '^\s*//' || true)
blank=$(cat $src | grep -cE '^\s*$' || true)
print "source_files ${#src}"
print "source_lines $all"
print "code_lines $((all - comments - blank))"
print "comment_lines $comments"
print "test_lines $(find Tests -name '*.swift' -exec cat {} + | wc -l | tr -d ' ')"
print "observed_document_views $(grep -rhE '@ObservedObject +(var|private var) +doc\b' Sources | wc -l | tr -d ' ')"
print "published_properties $(grep -rhE '@Published' Sources | wc -l | tr -d ' ')"
# Functions, inits and view bodies of 80 lines or more.
long=$(awk '
  function count(s, ch,   n, i) { n = 0; for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++; return n }
  FNR == 1 { depth = 0; open = 0 }
  {
    line = $0
    gsub(/"([^"\\]|\\.)*"/, "\"\"", line)
    sub(/\/\/.*$/, "", line)
    if (match(line, /(func [A-Za-z_][A-Za-z0-9_]*|var [A-Za-z_][A-Za-z0-9_]*: some View|init\()/) && index(line, "{") > 0) {
      open++; start[open] = FNR; at[open] = depth
    }
    depth += count(line, "{") - count(line, "}")
    while (open > 0 && depth <= at[open]) { if (FNR - start[open] + 1 >= 80) n++; open-- }
  }
  END { print n + 0 }' $src)
print "functions_80_lines $long"
if [[ -d dist/Arclight.app ]]; then
  print "app_bytes $(du -sk dist/Arclight.app | cut -f1 | awk '{print $1 * 1024}')"
  print "binary_bytes $(stat -f %z dist/Arclight.app/Contents/MacOS/arclight)"
  print "zip_bytes $(ditto -c -k --keepParent dist/Arclight.app /dev/stdout | wc -c | tr -d ' ')"
fi
