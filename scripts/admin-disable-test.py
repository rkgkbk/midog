#!/usr/bin/env python3
"""本机管理员停用实验（只使用 Python 标准库）。

python3 scripts/admin-disable-test.py              # 只读状态
sudo python3 scripts/admin-disable-test.py --apply # 临时停服务，尝试卸载扩展
sudo python3 scripts/admin-disable-test.py --restore-services

先退出 midog，避免应用重新启动服务。停止内核可能导致代理断网；如有必要，
在系统设置中关闭指向它的代理。配置、规则、专注数据均保留，服务重启后可恢复。
扩展恢复需通过原安装应用重新安装并授权，可能需要先重启完成卸载。
"""

import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


SERVICES = ("com.xx.midog.watchdog", "com.xx.midog.mihomo")
EXTENSIONS = {"com.xx.midog.filter", "com.xx.midog.BrowserFilter"}


def run(*args):
    print("$ " + shlex.join(args), flush=True)
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    return result


def loaded(label):
    result = run("/bin/launchctl", "print", "system/" + label)
    if result.returncode == 0:
        return True
    if "Could not find service" in result.stderr:
        return False
    raise RuntimeError(result.stderr.strip() or "无法查询服务状态")


def extension_rows(output):
    rows = []
    for line in output.splitlines():
        fields = line.split()
        for index, field in enumerate(fields):
            if field in EXTENSIONS and index > 0:
                rows.append((fields[index - 1], field, line.strip()))
                break
    return rows


def status():
    states = {}
    for label in SERVICES:
        states[label] = loaded(label)
        print(f"{label}: {'已加载' if states[label] else '未加载'}")
    result = run("/usr/bin/systemextensionsctl", "list")
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "无法查询扩展")
    rows = extension_rows(result.stdout)
    for _, _, line in rows:
        print(line)
    if not rows:
        print("系统扩展列表中未发现指定的 midog 扩展。")
    return states, rows


def change(*args):
    result = run(*args)
    print((result.stdout + result.stderr).strip() or f"退出码: {result.returncode}")
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--apply", action="store_true")
    group.add_argument("--restore-services", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("此脚本只支持 macOS")
    if (args.apply or args.restore_services) and os.geteuid() != 0:
        parser.error("执行变更需要 sudo；默认状态检查不需要管理员权限")
    states, rows = status()
    if not (args.apply or args.restore_services):
        print("只读检查完成。--apply 才执行停用；未测试网络是否可绕过。")
        return 0
    ok = True
    if args.restore_services:
        for label in reversed(SERVICES):
            plist = Path("/Library/LaunchDaemons") / (label + ".plist")
            if not states[label] and plist.is_file():
                ok = change("/bin/launchctl", "bootstrap", "system", str(plist)) and ok
        print("仅恢复保留配置的服务；系统扩展需通过原安装应用重新安装并授权。")
    else:
        for label in SERVICES:
            if states[label]:
                ok = change("/bin/launchctl", "bootout", "system/" + label) and ok
        # Only exact project IDs; never reset all extensions or change SIP.
        targets = sorted({(team, bundle) for team, bundle, _ in rows})
        for team, bundle in targets:
            if not re.fullmatch(r"-|[A-Z0-9]{10}", team):
                raise RuntimeError("无法识别扩展 Team ID，停止操作")
            ok = change("/usr/bin/systemextensionsctl", "uninstall", team, bundle) and ok
        print("若卸载被拒绝，请在系统设置 → 通用 → 登录项与扩展 → 网络扩展中操作。")
        print("若显示等待重启，卸载尚未完成；脚本不会自动重启或关闭 SIP。")
    final_states, final_rows = status()
    if args.apply:
        pending = any(final_states.values()) or bool(final_rows)
        if pending:
            print("仍有服务或扩展记录，不能判定已完全关闭。请检查上述状态。")
            return 1
        print("目标服务未加载且目标扩展无记录；仍需实际访问测试确认网络行为。")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"操作未完成：{error}。已完成的步骤不会自动回滚；可重新运行状态检查。", file=sys.stderr)
        sys.exit(1)
