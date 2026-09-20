#!/usr/bin/env python3
"""
把 GUI 的 AppImage 只读扫描单独跑一遍，结果以 KEY='value' 形式写到文件里给
run-checks.sh 断言用。

为什么不开窗口：_appimage_probe 只需要 _emit / _cmd 和几个静态解析函数，
用 Fake 顶掉控件依赖，就能在没有显示环境的情况下验证解析逻辑。
GUI 是 import 进来的，不会创建窗口（GTK 只有在实例化窗口时才连显示服务器）。

用法：probe-appimage.py <deb-install-ui> <包路径> <输出文件>
"""
import subprocess
import sys
from importlib.machinery import SourceFileLoader


def main():
    if len(sys.argv) != 4:
        print("用法: probe-appimage.py <GUI> <包> <输出>", file=sys.stderr)
        return 2
    ui, sample, out = sys.argv[1:4]

    dui = SourceFileLoader("dui", ui).load_module()
    C = dui.DebInstallerUI

    class Fake:
        def _emit(self, text, tag=None):
            pass

        def _cmd(self, args, timeout=180):
            try:
                r = subprocess.run(args, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True,
                                   errors="replace", timeout=timeout)
                return r.returncode, r.stdout
            except Exception:                                  # noqa: BLE001
                return 1, ""

        _parse_desktop = staticmethod(C._parse_desktop)
        _locale_key = staticmethod(C._locale_key)
        _pick_icon = staticmethod(C._pick_icon)
        _version_from_filename = staticmethod(C._version_from_filename)
        _appimage_probe = C._appimage_probe

    info = {}
    rc = Fake()._appimage_probe(sample, info)

    rows = [("ai_rc", str(rc)),
            ("ai_name", info.get("name", "")),
            ("ai_arch", info.get("arch", "") or ""),
            ("ai_slug", info.get("slug", "")),
            ("ai_icon", info.get("icon", "") or ""),
            ("ai_desktop", info.get("desktop_in_pkg", "") or "")]
    with open(out, "w", encoding="utf-8") as fh:
        for k, v in rows:
            v = str(v).replace("\n", " ").replace("'", "'\\''")
            fh.write("%s='%s'\n" % (k, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
