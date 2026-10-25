"""Tests for rpu_collector.py. Run: python3 -m unittest discover -s collector/tests"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
COLLECTOR = os.path.join(os.path.dirname(HERE), "rpu_collector.py")
FAKE_SMI = os.path.join(HERE, "fake_nvidia_smi.py")
sys.path.insert(0, os.path.dirname(HERE))

import rpu_collector as rc  # noqa: E402

PROC_STAT = """cpu  100 0 50 800 50 0 0 0 0 0
cpu0 50 0 25 400 25 0 0 0 0 0
cpu1 50 0 25 400 25 0 0 0 0 0
intr 12345
"""

MEMINFO = """MemTotal:       24000000 kB
MemFree:         2000000 kB
MemAvailable:   14000000 kB
Buffers:          100000 kB
Cached:          3000000 kB
SwapTotal:       6000000 kB
SwapFree:        5000000 kB
"""


def write(root, rel, text):
    path = os.path.join(root, rel.lstrip("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    return path


def make_root(with_sensors=True):
    root = tempfile.mkdtemp(prefix="rpu-proc-")
    write(root, "/proc/stat", PROC_STAT)
    write(root, "/proc/meminfo", MEMINFO)
    write(root, "/proc/cpuinfo", "processor\t: 0\nmodel name\t: AMD Ryzen 7 9850X3D 8-Core Processor\n"
                                 "cpu MHz\t\t: 4699.779\nprocessor\t: 1\n")
    write(root, "/proc/sys/kernel/osrelease", "6.6.87.2-microsoft-standard-WSL2\n")
    write(root, "/etc/os-release", 'NAME="Ubuntu"\nPRETTY_NAME="Ubuntu 24.04.4 LTS"\n')
    if with_sensors:
        write(root, "/sys/class/hwmon/hwmon0/name", "nvme\n")
        write(root, "/sys/class/hwmon/hwmon0/temp1_input", "38850\n")
        write(root, "/sys/class/hwmon/hwmon1/name", "k10temp\n")
        write(root, "/sys/class/hwmon/hwmon1/temp1_input", "71250\n")
        write(root, "/sys/class/hwmon/hwmon1/temp1_label", "Tctl\n")
        write(root, "/sys/class/hwmon/hwmon1/temp3_input", "65500\n")
        write(root, "/sys/class/hwmon/hwmon1/temp3_label", "Tccd1\n")
        write(root, "/sys/class/hwmon/hwmon2/name", "nct6798\n")
        write(root, "/sys/class/hwmon/hwmon2/fan1_input", "1180\n")
        write(root, "/sys/class/hwmon/hwmon2/fan1_label", "CPU_FAN\n")
        for i in (0, 1):
            write(root, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq" % i, "3600000\n")
    return root


class ParsingTests(unittest.TestCase):
    def test_proc_stat_and_util(self):
        total, cores = rc.parse_proc_stat(PROC_STAT)
        self.assertEqual(total, (150, 1000))  # busy = user+system; idle+iowait = 850
        self.assertEqual(len(cores), 2)
        later = PROC_STAT.replace("cpu  100 0 50 800 50", "cpu  200 0 100 850 50")
        total2, _ = rc.parse_proc_stat(later)
        # busy grew by 150, total by 200 → 75 %
        self.assertAlmostEqual(rc.util_between(total, total2), 75.0)
        self.assertIsNone(rc.util_between(None, total2))
        self.assertIsNone(rc.util_between(total2, total2))

    def test_cpu_list(self):
        self.assertEqual(rc.parse_cpu_list("0-3,8,10-11\n"), [0, 1, 2, 3, 8, 10, 11])
        self.assertEqual(rc.parse_cpu_list(""), [])

    def test_nv_values(self):
        self.assertIsNone(rc.nv_num("[N/A]"))
        self.assertIsNone(rc.nv_num("N/A"))
        self.assertIsNone(rc.nv_num("[Not Supported]"))
        self.assertEqual(rc.nv_num(" 20.69 "), 20.69)
        self.assertEqual(rc.nv_int("5"), 5)
        self.assertEqual(rc.decode_throttle("0x0000000000000004"), ["sw_power_cap"])
        self.assertEqual(rc.decode_throttle("0x0000000000000041"), ["gpu_idle", "hw_thermal"])
        self.assertEqual(rc.decode_throttle("0x0000000000000000"), [])
        self.assertIsNone(rc.decode_throttle("[N/A]"))

    def test_dynamic_row(self):
        fields = [f for f in rc.DYNAMIC_FIELDS if f[0] in ("index", "memory.used", "temperature.memory", "pstate")]
        row = rc.parse_dynamic_row(fields, ["1", "23498", "N/A", "P2"])
        self.assertEqual(row, {"idx": 1, "mem_used": 23498 * rc.MIB, "mem_temp_c": None, "pstate": "P2"})
        self.assertIsNone(rc.parse_dynamic_row(fields, ["1", "2"]))

    def test_meminfo(self):
        root = make_root()
        try:
            mem = rc.read_meminfo(rc.Paths(root))
            self.assertEqual(mem["total"], 24000000 * 1024)
            self.assertEqual(mem["used"], 10000000 * 1024)
            self.assertEqual(mem["swap_used"], 1000000 * 1024)
        finally:
            shutil.rmtree(root)

    def test_sensor_discovery(self):
        root = make_root()
        try:
            paths = rc.Paths(root)
            files = rc.discover_cpu_temp(paths)
            self.assertEqual(len(files), 1)
            self.assertTrue(files[0].endswith("hwmon1/temp1_input"))  # Tctl, not the NVMe sensor
            self.assertEqual(rc.read_temp(files), 71.2)
            fans = rc.discover_fans(paths)
            self.assertEqual(fans[0][0], "CPU_FAN")
        finally:
            shutil.rmtree(root)

    def test_no_sensors_like_wsl(self):
        root = make_root(with_sensors=False)
        try:
            paths = rc.Paths(root)
            self.assertEqual(rc.discover_cpu_temp(paths), [])
            self.assertTrue(rc.is_wsl(paths))
        finally:
            shutil.rmtree(root)


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.root = make_root()
        st = os.stat(FAKE_SMI)
        os.chmod(FAKE_SMI, st.st_mode | stat.S_IXUSR)

    def tearDown(self):
        shutil.rmtree(self.root)

    def run_collector(self, *extra, **env):
        e = dict(os.environ)
        e.update(env)
        cmd = [sys.executable, "-u", COLLECTOR, "--interval", "0.3", "--count", "2",
               "--proc-root", self.root, "--nvidia-smi", FAKE_SMI] + list(extra)
        out = subprocess.check_output(cmd, env=e, timeout=30, universal_newlines=True)
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def test_stream(self):
        msgs = self.run_collector()
        hello = msgs[0]
        self.assertEqual(hello["t"], "hello")
        self.assertEqual(hello["v"], 1)
        self.assertTrue(hello["wsl"])
        self.assertEqual(hello["os_version"], "Ubuntu 24.04.4 LTS")
        self.assertEqual(hello["cpu"]["cores"], 2)
        self.assertEqual(hello["caps"]["gpu"], "nvidia-smi")
        self.assertTrue(hello["caps"]["cpu_temp"])
        self.assertEqual([g["idx"] for g in hello["gpus"]], [0, 1])
        self.assertEqual(hello["gpus"][0]["mem_total"], 24467 * rc.MIB)
        self.assertFalse(hello["gpus"][0]["unified"])

        samples = [m for m in msgs if m["t"] == "s"]
        self.assertEqual(len(samples), 2)
        s = samples[-1]
        self.assertEqual(s["seq"], 2)
        self.assertEqual(s["cpu"]["temp_c"], 71.2)
        self.assertEqual(s["cpu"]["freq_mhz"], 3600)
        self.assertEqual(len(s["gpus"]), 2)
        g1 = s["gpus"][1]
        self.assertEqual(g1["util"], 97)
        self.assertIsNone(g1["power_w"])
        self.assertIsNone(g1["fan_pct"])
        self.assertEqual(g1["throttle"], ["sw_power_cap"])
        self.assertEqual(g1["pcie_gen"], 5)
        self.assertEqual(s["fans"][0]["rpm"], 1180)

    def test_old_driver_field_fallback(self):
        # Driver without the new reason field and without memory temperature.
        msgs = self.run_collector(FAKE_SMI_REJECT="clocks_event_reasons.active,temperature.memory")
        s = [m for m in msgs if m["t"] == "s"][-1]
        self.assertEqual(s["gpus"][1]["throttle"], ["sw_power_cap"])  # via clocks_throttle_reasons
        self.assertNotIn("mem_temp_c", s["gpus"][1])

    def test_unified_memory_gpu_uses_compute_apps(self):
        msgs = self.run_collector(FAKE_SMI_UNIFIED="1")
        hello = msgs[0]
        self.assertEqual(len(hello["gpus"]), 1)
        self.assertTrue(hello["gpus"][0]["unified"])
        self.assertIsNone(hello["gpus"][0]["mem_total"])
        g = [m for m in msgs if m["t"] == "s"][-1]["gpus"][0]
        self.assertEqual(g["mem_used"], (46676 + 1024) * rc.MIB)
        self.assertIsNone(g["mem_total"])
        self.assertEqual(g["util"], 35)

    def test_arm_big_little_clusters(self):
        # cpu0 = Cortex-X925 (0xd85), cpu1 = Cortex-A725 (0xd87)
        write(self.root, "/sys/devices/system/cpu/cpu0/regs/identification/midr_el1", "0x00000000410fd850\n")
        write(self.root, "/sys/devices/system/cpu/cpu1/regs/identification/midr_el1", "0x00000000410fd870\n")
        msgs = self.run_collector("--no-gpu")
        cl = msgs[0]["cpu"]["clusters"]
        self.assertEqual([c["name"] for c in cl], ["Cortex-X925", "Cortex-A725"])
        self.assertEqual([c["cpus"] for c in cl], [[0], [1]])
        self.assertEqual(msgs[0]["cpu"]["model"], "Cortex-X925 + Cortex-A725")
        s = [m for m in msgs if m["t"] == "s"][-1]
        self.assertEqual([c["name"] for c in s["cpu"]["clusters"]], ["Cortex-X925", "Cortex-A725"])

    def test_no_gpu(self):
        msgs = self.run_collector("--no-gpu")
        self.assertIsNone(msgs[0]["caps"]["gpu"])
        self.assertEqual([m for m in msgs if m["t"] == "s"][-1]["gpus"], [])

    def test_stdin_mode_like_ssh(self):
        """The app pipes the script into `python3 -u -`; make sure that works."""
        with open(COLLECTOR) as f:
            script = f.read()
        p = subprocess.run([sys.executable, "-u", "-", "--interval", "0.2", "--count", "1", "--no-gpu",
                            "--proc-root", self.root], input=script, stdout=subprocess.PIPE,
                           universal_newlines=True, timeout=30)
        lines = [json.loads(x) for x in p.stdout.splitlines()]
        self.assertEqual([m["t"] for m in lines], ["hello", "s"])

    def test_exits_when_reader_closes(self):
        p = subprocess.Popen([sys.executable, "-u", COLLECTOR, "--interval", "0.2", "--no-gpu",
                              "--proc-root", self.root], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        p.stdout.readline()
        p.stdout.close()
        self.assertEqual(p.wait(timeout=10), 0)
        self.assertEqual(p.stderr.read(), b"")


if __name__ == "__main__":
    unittest.main()
