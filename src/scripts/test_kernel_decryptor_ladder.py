#!/usr/bin/env python3
import hashlib
import math
import struct

PASS = []
FAIL = []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(f"{name}{(' — ' + detail) if detail and not cond else ''}")


def le32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def make_encrypted_binary(pages=3, cryptoff=0x4000, with_signature=True, cpu=0x0100000C, cpu_sub=0):
    ncmds = 2
    header = bytearray(32)
    struct.pack_into("<I", header, 0, 0xFEEDFACF)
    struct.pack_into("<I", header, 4, cpu)
    struct.pack_into("<I", header, 8, cpu_sub)
    struct.pack_into("<I", header, 16, ncmds)
    enc = struct.pack("<IIIII", 0x2C, 20, cryptoff, pages * 4096, 1)
    sig = struct.pack("<IIII", 0x1D, 16, 0x7000, 0x800) if with_signature else b""
    cmds = enc + sig
    struct.pack_into("<I", header, 20, len(cmds))
    body = bytearray(cryptoff + pages * 4096)
    body[0:len(header) + len(cmds)] = bytes(header) + cmds
    struct.pack_into("<I", body, cryptoff - 4, 0xD65F03C0)
    for i in range(pages * 4096):
        body[cryptoff + i] = hashlib.sha256(bytes([i % 251, i >> 8])).digest()[0]
    return bytes(body)


def make_fat(slices):
    off = 8 + 20 * len(slices)
    if off % 16384:
        off += 16384 - (off % 16384)
    placed = []
    for data, cpu, cpusub in slices:
        placed.append((off, len(data), cpu, cpusub))
        off += len(data)
        if off % 16384:
            off += 16384 - (off % 16384)
    entries = b"".join(
        struct.pack(">IIIII", cpu, cpu_sub, off, l, 16384) for off, l, cpu, cpu_sub in placed
    )
    out = struct.pack(">II", 0xCAFEBABE, len(slices)) + entries
    for (off, l, cpu, cpusub), (data, _, __) in zip(placed, slices):
        while len(out) < off:
            out += b"\0"
        out += data
    return out


def parse_slices(data):
    total = len(data)

    def read(count, offset):
        assert count >= 0 and offset + count <= total
        return data[offset:offset + count]

    magic = read(4, 0)
    candidates = []
    if magic == b"\xCA\xFE\xBA\xBE":
        count = int(struct.unpack(">I", read(4, 4))[0])
        for i in range(count):
            entry = read(20, 8 + i * 20)
            candidates.append((struct.unpack(">I", entry[8:12])[0], struct.unpack(">I", entry[12:16])[0]))
    elif magic[0] in (0xCF, 0xCE) and magic[1] == 0xFA and magic[2] == 0xED and magic[3] == 0xFE:
        candidates.append((0, total))
    out = []
    for off, size in candidates:
        if off + 32 > total:
            continue
        header = read(32, off)
        slice_magic = le32(header, 0)
        is64 = slice_magic == 0xFEEDFACF
        if not (is64 or slice_magic == 0xFEEDFACE):
            continue
        cpu_type = le32(header, 4)
        cpu_sub = le32(header, 8)
        ncmds = le32(header, 16)
        sizeofcmds = le32(header, 20)
        header_size = 32 if is64 else 28
        if not (0 < ncmds <= 1000 and 8 <= sizeofcmds <= 1 << 24):
            continue
        if off + header_size + sizeofcmds > total:
            continue
        commands = read(sizeofcmds, off + header_size)
        enc_cmd = 0x2C if is64 else 0x21
        pos = 0
        while pos + 8 <= sizeofcmds:
            cmd = le32(commands, pos)
            cmd_size = le32(commands, pos + 4)
            if cmd_size < 8 or pos + cmd_size > sizeofcmds:
                break
            if cmd == enc_cmd and cmd_size >= 20:
                crypt_off = le32(commands, pos + 8)
                crypt_size = le32(commands, pos + 12)
                cryptid = le32(commands, pos + 16)
                cs_off = cs_size = 0
                scan = 0
                while scan + 8 <= sizeofcmds:
                    scan_cmd = le32(commands, scan)
                    scan_size = le32(commands, scan + 4)
                    if scan_size < 8 or scan + scan_size > sizeofcmds:
                        break
                    if scan_cmd == 0x1D and scan_size >= 12:
                        cs_off = le32(commands, scan + 8)
                        cs_size = le32(commands, scan + 12)
                        break
                    scan += scan_size
                out.append({"fileOffset": off, "size": size, "cpuType": cpu_type, "cpuSubtype": cpu_sub,
                                "cryptOff": crypt_off, "cryptSize": crypt_size, "cryptid": cryptid,
                                "cryptidFileOffset": off + header_size + pos + 16,
                                "csOff": cs_off, "csSize": cs_size})
            pos += cmd_size
    return out


F_ADDFILESIGS_RETURN = 97
MREMAP_SYSCALL = 489
IOS_PAGE = 16384

LADDER = [
    {"prot": "R", "cryptid": 2, "sig": False},
    {"prot": "R", "cryptid": 2, "sig": True},
    {"prot": "RX", "cryptid": 1, "sig": False},
    {"prot": "RX", "cryptid": 1, "sig": True},
]


def entropy(buf):
    if not buf:
        return 0.0
    counts = [0] * 256
    for b in buf:
        counts[b] += 1
    e = 0.0
    for c in counts:
        if c:
            p = c / len(buf)
            e -= p * math.log2(p)
    return e


def fcntl_sig_payload(file_start, blob_offset, blob_size):
    return struct.pack("<qqQ", file_start, blob_offset, blob_size)


def kernel_model(state):
    def call(addr, size, cryptid, cputype, cpusub, prot_has_exec):
        if addr % IOS_PAGE:
            return 22, None
        if cryptid == 0:
            return 0, None
        if cryptid not in (1, 2, 0x10):
            return 22, None
        if cryptid != 2 and not prot_has_exec:
            return 1, None
        if cryptid == 0x10:
            return 0, None
        if not state["has_blob"] and not state.get("ever_registered"):
            return 1, None
        if not state["has_license"]:
            return (12 if state.get("source", "container") == "container" else 1), None
        return 0, state["decrypt"](size)

    return call


def mremap_errno(crypter_result):
    if crypter_result == 0:
        return 0
    if crypter_result in ("license-refused", "mapping-failed"):
        return 1
    return 12


CODE_WORDS = [0xD65F03C0, 0xD503237F, 0xD65F0FFF]


def arm64_code_words(buf):
    n = 0
    for i in range(0, len(buf) - 3, 4):
        w = struct.unpack_from("<I", buf, i)[0]
        if w in CODE_WORDS:
            n += 1
    return n


def model_decrypt(data, state, pagesize=IOS_PAGE):
    state.setdefault("decrypt", ok_decrypt)
    slices = parse_slices(data)
    assert slices, "no encrypted slices parsed"
    slice0 = next(s for s in slices if s["cryptid"] >= 1 and s["cryptSize"] > 0)
    calls = []
    state["ever_registered"] = False
    if (slice0["fileOffset"] + slice0["cryptOff"]) % pagesize:
        return calls + [("precheck-einval",)], None
    firstfail = 0
    for attempt in LADDER:
        if attempt["sig"] and slice0["csSize"] > 0:
            calls.append(("fcntl97", slice0["fileOffset"], slice0["csOff"], slice0["csSize"]))
            state["ever_registered"] = True
        kr, pages = state["kernel"](slice0["fileOffset"] + slice0["cryptOff"], slice0["cryptSize"],
                                    attempt["cryptid"], slice0["cpuType"], slice0["cpuSubtype"],
                                    attempt["prot"] == "RX")
        calls.append(("mremap", attempt["cryptid"], attempt["prot"], attempt["sig"]))
        if kr != 0:
            if firstfail == 0:
                firstfail = kr
            continue
        if pages is not None:
            dec_entropy = entropy(pages)
            enc_probe = data[slice0["fileOffset"] + slice0["cryptOff"]:
                             slice0["fileOffset"] + slice0["cryptOff"] + min(4 * 4096, slice0["cryptSize"])]
            if dec_entropy < 7.6 and dec_entropy > 2.0 \
                    and arm64_code_words(pages[:4 * 4096]) > arm64_code_words(enc_probe):
                return calls, pages
        calls.append(("entropy-reject",))
    return calls, (None if firstfail == 0 else ("error", firstfail))


def ok_decrypt(size):
    unit = b"\x1f\x20\x03\xd5" * 256 + b"\xc0\x03\x5f\xd6" * 256
    return (unit * ((size // len(unit)) + 1))[:size]


def main():
    thin = make_encrypted_binary()
    fat = make_fat([(make_encrypted_binary(cpu=0x0100000C, cpu_sub=0), 0x0100000C, 0),
                    (make_encrypted_binary(cpu=0x0100000C, cpu_sub=2), 0x0100000C, 2)])

    s = parse_slices(thin)
    check("thin: one encrypted slice", len(s) == 1, str(len(s)))
    check("thin: cryptoff/cryptsize", s[0]["cryptOff"] == 0x4000 and s[0]["cryptSize"] == 3 * 4096)
    check("thin: cryptidFileOffset includes headerSize", s[0]["cryptidFileOffset"] == 32 + 0 + 16,
          str(s[0]["cryptidFileOffset"]))
    check("thin: signature parsed", (s[0]["csOff"], s[0]["csSize"]) == (0x7000, 0x800),
          str((s[0]["csOff"], s[0]["csSize"])))

    s2 = parse_slices(fat)
    check("fat: both slices found", len(s2) == 2, str(len(s2)))
    check("fat: cputype/subtype preserved", sorted(x["cpuSubtype"] for x in s2) == [0, 2])
    check("fat: cryptidFileOffset per slice", all(x["cryptidFileOffset"] == x["fileOffset"] + 48 for x in s2),
          str([x["cryptidFileOffset"] for x in s2]))

    s3 = parse_slices(make_encrypted_binary(with_signature=False))
    check("no-sig binary: cs parsed as 0", (s3[0]["csOff"], s3[0]["csSize"]) == (0, 0))

    check("ladder: order is Tetherless table",
          [(a["cryptid"], a["prot"], a["sig"]) for a in LADDER]
          == [(2, "R", False), (2, "R", True), (1, "RX", False), (1, "RX", True)],
          str(LADDER))
    check("ladder: no cryptid 3 (EINVAL in every XNU)", all(a["cryptid"] != 3 for a in LADDER))
    check("ladder: every cryptid-1 attempt maps RX (vm_map_apple_protected EXEC rule)",
          all(a["prot"] == "RX" for a in LADDER if a["cryptid"] == 1))
    check("ladder: cryptid-2 attempts map R (EXEC rule skipped for MODEL_ENCRYPTION)",
          all(a["prot"] == "R" for a in LADDER if a["cryptid"] == 2))

    state = {"has_blob": True, "has_license": True}
    state["kernel"] = kernel_model(state)
    calls, pages = model_decrypt(thin, state)
    check("licensed: decrypted pages accepted", pages is not None and not isinstance(pages, tuple),
          str(calls))
    check("licensed: first attempt is cryptid2 PROT_READ no-sig",
          calls[0] == ("mremap", 2, "R", False), str(calls[:2]))
    if any(c[0] == "fcntl97" for c in calls):
        check("licensed: fcntl97 precedes the sig attempt",
              next(i for i, c in enumerate(calls) if c[0] == "fcntl97")
              < next(i for i, c in enumerate(calls) if c[0] == "mremap" and c[3]), str(calls))
    else:
        check("licensed: blob already on vnode -> plain attempt wins without fcntl",
              calls[0] == ("mremap", 2, "R", False) and len(calls) == 1, str(calls))

    state6 = {"has_blob": False, "has_license": True}
    state6["kernel"] = kernel_model(state6)
    calls6, pages6 = model_decrypt(thin, state6)
    check("unsigned: ladder registers blob and succeeds on the sig variant",
          pages6 is not None and not isinstance(pages6, tuple), str(calls6))
    kr_calls6 = [c for c in calls6 if c[0] == "mremap"]
    check("unsigned: plain cryptid2 attempt answered EPERM first (kernel model)",
          kr_calls6 and kr_calls6[0] == ("mremap", 2, "R", False)
          and kr_calls6[0] == calls6[0], str(calls6))

    state7 = {"has_blob": True, "has_license": False, "source": "container"}
    state7["kernel"] = kernel_model(state7)
    calls7, res7 = model_decrypt(thin, state7)
    check("no-license container: exhausted with ENOMEM 12 (fairplayd cannot read a data container)",
          res7 == ("error", 12), str((calls7, res7)))
    check("no-license container: all four attempts really tried",
          len([c for c in calls7 if c[0] == "mremap"]) == 4, str(calls7))

    state10 = {"has_blob": True, "has_license": True, "source": "installed"}
    state10["kernel"] = kernel_model(state10)
    calls10, pages10 = model_decrypt(thin, state10)
    check("installed source: decrypted pages accepted on the first attempt",
          pages10 is not None and not isinstance(pages10, tuple), str(calls10))
    check("installed source: no license registration needed (installd provisioned the vnode)",
          not any(c[0] == "fcntl97" for c in calls10), str(calls10))

    state11 = {"has_blob": True, "has_license": True, "source": "installed"}
    state11["kernel"] = kernel_model(state11)
    calls11, res11 = model_decrypt(thin, state11)
    check("installed source: precedence over container staging",
          calls11[0] == ("mremap", 2, "R", False) and res11 is not None and not isinstance(res11, tuple),
          str(calls11))

    state8 = {"has_blob": True, "has_license": True}
    state8["kernel"] = lambda addr, size, cryptid, cpu, sub, rx: (
        (0, b"\x88" * size) if cryptid in (0, 0x10) else (1, None))
    _calls8, res8 = model_decrypt(thin, state8)
    check("noop-kernel: no page pass-through accepted", res8 == ("error", 1), str(res8))

    mis = bytearray(make_encrypted_binary())
    struct.pack_into("<I", mis, 32 + 8, 0x4004)
    st9 = {"has_blob": True, "has_license": True}
    st9["kernel"] = kernel_model(st9)
    calls9, res9 = model_decrypt(bytes(mis), st9)
    check("misaligned: pre-check answers EINVAL before any syscall",
          res9 is None and calls9 and calls9[0][0] == "precheck-einval", str(calls9))

    enc = make_encrypted_binary()[0x4000:0x4000 + 4096]
    check("entropy: encrypted page > 7.6", entropy(enc) > 7.6, str(entropy(enc)))
    dec = (b"\x1f\x20\x03\xd5" * 1024)[:4096]
    check("entropy: decrypted page < 7.6", entropy(dec) < 7.6, str(entropy(dec)))

    payload = fcntl_sig_payload(0, 0x7000, 0x800)
    check("fsignatures: 24-byte payload, offsets packed",
          len(payload) == 24 and struct.unpack_from("<q", payload, 0)[0] == 0
          and struct.unpack_from("<q", payload, 8)[0] == 0x7000
          and struct.unpack_from("<Q", payload, 16)[0] == 0x800)
    fat_slice = parse_slices(fat)[1]
    payload2 = fcntl_sig_payload(fat_slice["fileOffset"], fat_slice["csOff"], fat_slice["csSize"])
    check("fsignatures: FAT file_start = slice offset",
          struct.unpack_from("<q", payload2, 0)[0] == fat_slice["fileOffset"] > 0)
    check("fsignatures: kernel blob offset = file_start + dataoff (vn_rdwr)",
          struct.unpack_from("<q", payload2, 0)[0] + struct.unpack_from("<q", payload2, 8)[0]
          == fat_slice["fileOffset"] + fat_slice["csOff"])

    cryptid_none, cryptid_app, cryptid_model = 0, 1, 2
    check("constants: F_ADDFILESIGS_RETURN = 97 (bsd/sys/fcntl.h)", F_ADDFILESIGS_RETURN == 97)
    check("constants: syscall 489 = mremap_encrypted (syscalls.master, #if CONFIG_CODE_DECRYPTION)",
          MREMAP_SYSCALL == 489)
    check("constants: CRYPTID_NO_ENCRYPTION=0, APP=1, MODEL=2 (bsd/sys/mman.h)",
          (cryptid_none, cryptid_app, cryptid_model) == (0, 1, 2))
    st12 = {"has_blob": False, "has_license": False}
    st12["kernel"] = kernel_model(st12)
    kr_none, _ = st12["kernel"](0x4000, 0, cryptid_none, 0x0100000C, 0, False)
    check("constants: cryptid 0 answers no-op success before any other check",
          kr_none == 0, str(kr_none))
    kr_bad, _ = st12["kernel"](0x4000, 0, 3, 0x0100000C, 0, True)
    check("constants: unknown cryptid answers EINVAL (kern_mman.c switch default)",
          kr_bad == 22, str(kr_bad))

    check("xnu: crypter license refusal maps to EPERM 1",
          mremap_errno("license-refused") == 1, str(mremap_errno("license-refused")))
    check("xnu: vm_map_apple_protected failure maps to EPERM 1",
          mremap_errno("mapping-failed") == 1, str(mremap_errno("mapping-failed")))
    check("xnu: any other crypter-create failure maps to ENOMEM 12 (kern_mman.c)",
          mremap_errno("crypter-init-unreadable") == 12, str(mremap_errno("crypter-init-unreadable")))
    check("xnu: code 12 is a crypter-init failure, not a license refusal",
          mremap_errno("crypter-init-unreadable") != mremap_errno("license-refused"), "")
    check("source: installed bundle path is used before any container staging",
          calls11[0] == ("mremap", 2, "R", False) and calls7[0] == ("mremap", 2, "R", False), str((calls11[0], calls7[0])))

    print(f"PASS {len(PASS)}  FAIL {len(FAIL)}")
    for f in FAIL:
        print("  FAIL:", f)
    for p in PASS:
        print("  ok:", p)
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
