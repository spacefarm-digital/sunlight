// Sunlight Live Windows. Adapted from yabai's scripting addition (https://github.com/koekeishiya/yabai,
// via the macOS 27 fork at https://github.com/LCS-Dev-Ergos/yabai, commit 8135286), MIT licensed:
// Copyright (c) 2019 Åsmund Vikane. See LICENSE-yabai.txt.
//
// Shared by the add-on (payload.m) and the helper (../helper.m). The Sunlight protocol's own opcodes
// are in sunbeam.h; the Swift side mirrors all of this in Sources/Canvas/RealWindows/LiveWindowsConnection.swift.

#ifndef SA_COMMON_H
#define SA_COMMON_H

#define SA_SOCKET_PATH_FMT "/tmp/sunlight-live_%s.socket"
#define SA_SOCKET_BUFF_LEN 0x1000

// Bump whenever the add-on changes: the helper reinstalls it (restarting the Dock) only when the
// installed version differs, and reports a Dock still running an older one.

#define OSAX_VERSION "sunlight-57"

// The stock opcodes kept from yabai, with yabai's encoding. Every other stock opcode is ignored.
enum sa_opcode
{
    SA_OPCODE_VERSION      = 0x01,   // no fields; answers OSAX_VERSION and a newline
    SA_OPCODE_WINDOW_MOVE  = 0x06,   // uint32 wid, int32 x, int32 y
    SA_OPCODE_WINDOW_ORDER = 0x10,   // uint32 wid, int32 order (-1, 0, 1), uint32 relative wid
    SA_OPCODE_WINDOW_LEVEL = 0x12,   // uint32 wid, int32 level (Sunlight's own: a window lifted above the canvas at once)
};

#endif
