#!/usr/bin/env python3
"""Minimal nvidia-smi stand-in for collector tests.

Mimics the CLI surface rpu_collector.py uses: --help-query-gpu, one-shot
--query-gpu=... --format=csv,noheader,nounits, and the -lms streaming loop.
Values mirror a real 2x RTX PRO 4000 (WSL2) capture. Set FAKE_SMI_REJECT to a
comma-separated list of fields to simulate an older driver rejecting them.
"""
import os
import sys
import time

GPUS = [
    {
        "index": "0", "uuid": "GPU-11111111-2222-3333-4444-000000000000",
        "name": "NVIDIA RTX PRO 4000 Blackwell", "driver_version": "597.16",
        "memory.total": "24467", "memory.used": "23857", "power.limit": "145.00",
        "power.draw": "20.69", "clocks.max.sm": "3090", "pci.bus_id": "00000000:01:00.0",
        "utilization.gpu": "0", "utilization.memory": "0", "temperature.gpu": "61",
        "temperature.memory": "N/A", "clocks.sm": "180", "clocks.mem": "810",
        "fan.speed": "47", "pstate": "P5", "clocks_event_reasons.active": "0x0000000000000001",
        "clocks_throttle_reasons.active": "0x0000000000000001",
        "pcie.link.gen.current": "5", "pcie.link.width.current": "8",
    },
    {
        "index": "1", "uuid": "GPU-11111111-2222-3333-4444-000000000001",
        "name": "NVIDIA RTX PRO 4000 Blackwell", "driver_version": "597.16",
        "memory.total": "24467", "memory.used": "23498", "power.limit": "145.00",
        "power.draw": "[N/A]", "clocks.max.sm": "3090", "pci.bus_id": "00000000:02:00.0",
        "utilization.gpu": "97", "utilization.memory": "41", "temperature.gpu": "72",
        "temperature.memory": "N/A", "clocks.sm": "2805", "clocks.mem": "13801",
        "fan.speed": "[Not Supported]", "pstate": "P2", "clocks_event_reasons.active": "0x0000000000000004",
        "clocks_throttle_reasons.active": "0x0000000000000004",
        "pcie.link.gen.current": "5", "pcie.link.width.current": "8",
    },
]


UNIFIED = {  # GB10-style unified memory GPU (DGX Spark / ASUS GX10)
    "index": "0", "uuid": "GPU-aaaaaaaa-bbbb-cccc-dddd-000000000010", "name": "NVIDIA GB10",
    "driver_version": "580.178.04", "memory.total": "[N/A]", "memory.used": "[N/A]", "power.limit": "[N/A]",
    "power.draw": "12.50", "clocks.max.sm": "3003", "pci.bus_id": "0000000F:01:00.0",
    "utilization.gpu": "35", "utilization.memory": "0", "temperature.gpu": "45", "temperature.memory": "N/A",
    "clocks.sm": "2411", "clocks.mem": "[N/A]", "fan.speed": "[N/A]", "pstate": "P0",
    "clocks_event_reasons.active": "0x0000000000000000", "clocks_throttle_reasons.active": "0x0000000000000000",
    "pcie.link.gen.current": "1", "pcie.link.width.current": "1",
}


def main(argv):
    global GPUS
    if os.environ.get("FAKE_SMI_UNIFIED"):
        GPUS = [UNIFIED]
    if any(a.startswith("--query-compute-apps=") for a in argv):
        if os.environ.get("FAKE_SMI_UNIFIED"):
            print("GPU-aaaaaaaa-bbbb-cccc-dddd-000000000010, 46676")
            print("GPU-aaaaaaaa-bbbb-cccc-dddd-000000000010, 1024")
        return 0
    reject = set(f for f in os.environ.get("FAKE_SMI_REJECT", "").split(",") if f)
    if "--help-query-gpu" in argv:
        for f in sorted(GPUS[0].keys()):
            if f not in reject:
                print('"%s"' % f)
                print("Description of %s." % f)
        return 0
    query = [a for a in argv if a.startswith("--query-gpu=")]
    if not query:
        print("unsupported fake invocation: %r" % argv, file=sys.stderr)
        return 2
    fields = query[0].split("=", 1)[1].split(",")
    for f in fields:
        if f in reject or f not in GPUS[0]:
            print('Field "%s" is not a valid field to query.' % f)
            return 2
    loop_ms = None
    if "-lms" in argv:
        loop_ms = int(argv[argv.index("-lms") + 1])
    while True:
        for g in GPUS:
            print(", ".join(g[f] for f in fields))
        sys.stdout.flush()
        if loop_ms is None:
            return 0
        time.sleep(loop_ms / 1000.0)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
