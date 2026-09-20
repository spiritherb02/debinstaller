# Maintainer: SpiritHerb <spiritherb@users.noreply.github.com>
pkgname=debinstaller
pkgver=2.1.0
pkgrel=1
pkgdesc="在 Arch Linux 上安装 Debian .deb 包（转成原生 pacman 包再装），顺带把 .AppImage 收进应用菜单"
arch=('any')
url="https://github.com/spiritherb02/debinstaller"
license=('MIT')
depends=('bash' 'dpkg' 'libarchive' 'fakeroot' 'zstd' 'binutils')
optdepends=(
  'python-gobject: 图形界面（软件包安装程序）'
  'gtk3: 图形界面（软件包安装程序）'
  'p7zip: 只读检查 .AppImage'
  'desktop-file-utils: 注册应用菜单'
  'gtk-update-icon-cache: 刷新图标缓存'
  'xdg-user-dirs: 桌面快捷方式'
  'polkit: 图形界面里输入 sudo 密码'
)
provides=('deb-install')
source=("debinstall-$pkgver.tar.gz::$url/releases/download/v$pkgver/debinstall-$pkgver.tar.gz")
sha256sums=('502637716cdfbafad0c12ed3b3a541566d9d9c525c0842f6dd52f85db71d969f')

package() {
  cd "$srcdir/debinstall-$pkgver"

  # 主程序 + GUI 那套脚本；GUI 里的 @PREFIX_BIN@ 占位符换成真实路径
  for f in debinstall deb-install-ui deb-install-open deb-install-askpass deb-install-raw; do
    if [ "$f" = deb-install-ui ]; then
      sed "s|@PREFIX_BIN@|/usr/bin|g" "bin/$f" > "$pkgdir/usr/bin/$f"
    else
      install -Dm755 "bin/$f" "$pkgdir/usr/bin/$f"
    fi
  done
  ln -sfn debinstall "$pkgdir/usr/bin/deb-install"

  # 桌面入口：Exec 要写绝对路径，装到 /usr 之后 xdg 才找得到
  install -Dm644 share/applications/deb-install.desktop \
    "$pkgdir/usr/share/applications/deb-install.desktop"
  sed -i 's|^Exec=deb-install-ui|Exec=/usr/bin/deb-install-ui|' \
    "$pkgdir/usr/share/applications/deb-install.desktop"

  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 LICENSE    "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 share/doc/SKILL.md "$pkgdir/usr/share/doc/$pkgname/SKILL.md"
}
