#!/usr/bin/env python3
"""Builds synthetic Apple Screen Time sources for tests (no real user data).

Usage: make_fixtures.py OUT_DIR

Creates:
  OUT_DIR/biome/streams/restricted/App.InFocus/remote/<IPHONE>/<segment>   SEGB v2 file
  OUT_DIR/biome/sync/sync.db                                              DevicePeer table
  OUT_DIR/biome-v1/streams/restricted/App.InFocus/remote/<IPHONE>/1       SEGB v1-looking file
  OUT_DIR/biome-empty/                                                    no remote devices
  OUT_DIR/knowledgeC.db                                                   ZOBJECT/ZSOURCE/ZSYNCPEER
All timestamps are on 2026-01-15 (UTC); run the archiver with TZ=UTC.
"""
import os
import sqlite3
import struct
import sys
import zlib
from datetime import datetime, timezone

APPLE_EPOCH = 978307200
IPHONE = "11111111-2222-3333-4444-555555555555"
OLD_IPHONE = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"


def apple_ts(hh, mm, ss=0):
    return datetime(2026, 1, 15, hh, mm, ss, tzinfo=timezone.utc).timestamp() - APPLE_EPOCH


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def event(kind, starting, ts, bundle):
    b = bundle.encode()
    return (varint(2 << 3) + varint(kind) + varint(3 << 3) + varint(starting)
            + varint((4 << 3) | 1) + struct.pack("<d", ts)
            + varint((6 << 3) | 2) + varint(len(b)) + b)


def segb_v2(records, size=4096):
    """records: list of (state, payload, corrupt_crc)."""
    body = bytearray()
    entries = []
    for state, payload, corrupt in records:
        while len(body) % 4:
            body.append(0)
        crc = zlib.crc32(payload) ^ (0xFFFF if corrupt else 0)
        if state == 3:
            payload = bytes(len(payload))  # deleted records are zeroed
        body += struct.pack("<II", crc, 10) + payload
        entries.append(struct.pack("<IId", len(body), state, 0.0))
    header = b"SEGB" + struct.pack("<Id", len(records), apple_ts(0, 0)) + bytes(16)
    trailer = b"".join(reversed(entries))
    data = header + bytes(body)
    return data + bytes(size - len(data) - len(trailer)) + trailer


def main(out):
    seg_dir = os.path.join(out, "biome/streams/restricted/App.InFocus/remote", IPHONE)
    os.makedirs(seg_dir, exist_ok=True)
    os.makedirs(os.path.join(seg_dir, "tombstone"), exist_ok=True)
    records = [
        (1, event(1, 1, apple_ts(10, 0), "com.example.alpha"), False),
        (1, event(1, 0, apple_ts(10, 30), "com.example.alpha"), False),
        (1, event(3, 1, apple_ts(10, 30), "com.apple.control-center"), False),   # overlay: ignored
        (1, event(3, 0, apple_ts(10, 31), "com.apple.control-center"), False),
        (1, event(1, 1, apple_ts(10, 50), "com.example.beta"), False),           # crosses the hour
        (1, event(1, 0, apple_ts(11, 10), "com.example.beta"), False),
        (3, event(1, 1, apple_ts(12, 0), "com.example.deleted"), False),         # deleted: ignored
        (3, event(1, 0, apple_ts(12, 5), "com.example.deleted"), False),
        (1, event(1, 1, apple_ts(13, 0), "com.example.corrupt"), True),          # bad CRC: ignored
        (1, event(1, 0, apple_ts(13, 5), "com.example.corrupt"), False),
        (1, event(1, 1, apple_ts(14, 0), "com.example.open"), False),            # no end yet: ignored
    ]
    with open(os.path.join(seg_dir, "811000000000000"), "wb") as f:
        f.write(segb_v2(records))

    os.makedirs(os.path.join(out, "biome/sync"), exist_ok=True)
    db = sqlite3.connect(os.path.join(out, "biome/sync/sync.db"))
    db.execute("CREATE TABLE DevicePeer (device_identifier STRING NOT NULL, me BOOLEAN, name STRING, model STRING,"
               " platform INTEGER, last_sync_date INTEGER, protocol_version INTEGER NOT NULL, ids_device_identifier STRING)")
    db.execute("INSERT INTO DevicePeer VALUES ('ME', 1, '', '24G419', 3, NULL, 5, NULL)")
    db.execute("INSERT INTO DevicePeer VALUES (?, 0, '', '23A341', 2, 0, 5, NULL)", (IPHONE,))
    db.commit()
    db.close()

    v1_dir = os.path.join(out, "biome-v1/streams/restricted/App.InFocus/remote", IPHONE)
    os.makedirs(v1_dir, exist_ok=True)
    with open(os.path.join(v1_dir, "1"), "wb") as f:
        f.write(bytes(52) + b"SEGB" + bytes(200))

    os.makedirs(os.path.join(out, "biome-empty"), exist_ok=True)

    db = sqlite3.connect(os.path.join(out, "knowledgeC.db"))
    db.executescript("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE ZSOURCE (Z_PK INTEGER PRIMARY KEY, ZDEVICEID VARCHAR, ZBUNDLEID VARCHAR);
        CREATE TABLE ZSYNCPEER (Z_PK INTEGER PRIMARY KEY, ZDEVICEID VARCHAR, ZMODEL VARCHAR);
        CREATE TABLE ZOBJECT (Z_PK INTEGER PRIMARY KEY, ZSOURCE INTEGER, ZSTREAMNAME VARCHAR,
                              ZVALUESTRING VARCHAR, ZSTARTDATE TIMESTAMP, ZENDDATE TIMESTAMP);
    """)
    db.execute("INSERT INTO ZSOURCE VALUES (1, ?, NULL)", (OLD_IPHONE,))
    db.execute("INSERT INTO ZSYNCPEER VALUES (1, ?, 'iPhone14,5')", (OLD_IPHONE,))
    rows = [
        (None, "/app/usage", "com.example.macapp", apple_ts(9, 0), apple_ts(9, 45)),
        (None, "/app/usage", "com.example.macapp", apple_ts(15, 0), apple_ts(15, 15)),
        (None, "/app/usage", "com.example.zero", apple_ts(16, 0), apple_ts(16, 0)),      # zero length: ignored
        (None, "/app/webUsage", "example.com", apple_ts(9, 0), apple_ts(9, 10)),         # other stream: ignored
        (1, "/app/usage", "com.example.oldphone", apple_ts(8, 0), apple_ts(8, 20)),      # synced (legacy) device
    ]
    db.executemany("INSERT INTO ZOBJECT (ZSOURCE, ZSTREAMNAME, ZVALUESTRING, ZSTARTDATE, ZENDDATE) VALUES (?,?,?,?,?)", rows)
    db.commit()
    db.close()


if __name__ == "__main__":
    main(sys.argv[1])
