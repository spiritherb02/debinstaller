# Maintainer: SpiritHerb <spiritherb@users.noreply.github.com>
pkgname=debinstaller
pkgver=1.0.0
pkgrel=1
pkgdesc="在 Arch Linux 上安装 Debian .deb 包（转成原生 pacman 包再装）"
arch=('any')
url="https://github.com/spiritherb02/debinstaller"
license=('MIT')
depends=('python')
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
  cd "$srcdir/$pkgname-$pkgver"

  install -d "$pkgdir/usr/lib/debinstaller" "$pkgdir/usr/bin"

  cp -r debinstaller "$pkgdir/usr/lib/debinstaller/"
  find "$pkgdir/usr/lib/debinstaller" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

  cat > "$pkgdir/usr/bin/debinstall" <<'ENTRY'
#!/usr/bin/env python3
import sys
sys.path.insert(0, "/usr/lib/debinstaller")
from debinstaller.cli import main
sys.exit(main())
ENTRY
  chmod 755 "$pkgdir/usr/bin/debinstall"
}
