#!/usr/bin/env bash
# Build a synthetic .deb and exercise debinstaller end to end.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
prefix="${PREFIX:-/usr/local}"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$prefix/bin/debinstall"
    rm -rf "$prefix/lib/debinstaller"
    echo "debinstaller removed from $prefix"
    exit 0
fi

install -d "$prefix/lib/debinstaller" "$prefix/bin"
rm -rf "$prefix/lib/debinstaller/debinstaller"
cp -r "$here/debinstaller" "$prefix/lib/debinstaller/"
find "$prefix/lib/debinstaller" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

cat > "$prefix/bin/debinstall" <<EOF
#!/usr/bin/env python3
import sys
sys.path.insert(0, "$prefix/lib/debinstaller")
from debinstaller.cli import main
sys.exit(main())
EOF
chmod 0755 "$prefix/bin/debinstall"

"$prefix/bin/debinstall" --version
echo "installed: $prefix/bin/debinstall"
