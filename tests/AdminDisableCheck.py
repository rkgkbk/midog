"""No privilege or host mutations: all command execution is mocked."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "admin_disable", Path(__file__).resolve().parents[1] / "scripts/admin-disable-test.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AdminDisableCheck(unittest.TestCase):
    def test_exact_extension_scope(self):
        rows = module.extension_rows(
            "* * - com.xx.midog.filter (1/3) name [activated enabled]\n"
            "  - com.xx.midog.filter (1/2) name [terminated waiting to uninstall on reboot]\n"
            "* * ABCDE12345 com.xx.midog.BrowserFilter (1/1) name [activated enabled]\n"
            "* * ABCDE12345 com.xx.midog.filter.other (1/1) name [activated enabled]\n"
            "* * ABCDE12345 org.other.filter (1/1) name [activated enabled]\n")
        self.assertEqual([(r[0], r[1]) for r in rows],
                         [("-", "com.xx.midog.filter"), ("-", "com.xx.midog.filter"),
                          ("ABCDE12345", "com.xx.midog.BrowserFilter")])

    def test_default_is_read_only(self):
        with patch.object(module.sys, "argv", ["test"]), \
                patch.object(module.sys, "platform", "darwin"), \
                patch.object(module, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertEqual(module.main(), 0)
            self.assertEqual([call.args[:2] for call in run.call_args_list],
                             [("/bin/launchctl", "print"), ("/bin/launchctl", "print"),
                              ("/usr/bin/systemextensionsctl", "list")])

    def test_permission_failure_is_not_absence(self):
        with patch.object(module, "run", return_value=subprocess.CompletedProcess([], 1, "", "Permission denied")):
            with self.assertRaises(RuntimeError):
                module.loaded(module.SERVICES[0])

    def test_apply_reports_partial_failure(self):
        rows = [("-", "com.xx.midog.filter", "[activated enabled]")]
        with patch.object(module.sys, "argv", ["test", "--apply"]), \
                patch.object(module.sys, "platform", "darwin"), \
                patch.object(module.os, "geteuid", return_value=0), \
                patch.object(module, "status", side_effect=[
                    ({label: True for label in module.SERVICES}, rows),
                    ({label: False for label in module.SERVICES}, rows)]), \
                patch.object(module, "change", side_effect=[True, True, False]) as change:
            self.assertEqual(module.main(), 1)
            self.assertEqual(change.call_args_list[-1].args,
                             ("/usr/bin/systemextensionsctl", "uninstall", "-", "com.xx.midog.filter"))


if __name__ == "__main__":
    unittest.main()
