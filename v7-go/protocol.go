package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// ============================================================
// Constants from aproxy.h / apdefs.h
// ============================================================

const AP_ABI_VER = "A0001"

// AP_CMD - command codes
const (
	apNop               uint32 = 0
	apReturn            uint32 = 1
	apClientDone        uint32 = 2
	apCallSignalExit    uint32 = 3
	apCallOnIdle        uint32 = 4
	apCallCancelAllJobs uint32 = 5

	apCallSetOutputFolder            uint32 = 16
	apCallUpdateAvailableDrives      uint32 = 17
	apCallOpenFile                   uint32 = 18
	apCallOpenCdDisk                 uint32 = 19
	apCallOpenTitleCollection        uint32 = 20
	apCallCloseDisk                  uint32 = 21
	apCallEjectDisk                  uint32 = 22
	apCallSaveAllSelectedTitlesToMkv uint32 = 23
	apCallGetUiItemState             uint32 = 24
	apCallSetUiItemState             uint32 = 25
	apCallGetUiItemInfo              uint32 = 26
	apCallGetSettingInt              uint32 = 27
	apCallGetSettingString           uint32 = 28
	apCallSetSettingInt              uint32 = 29
	apCallSetSettingString           uint32 = 30
	apCallSaveSettings               uint32 = 31
	apCallAppGetString               uint32 = 85
	apCallBackupDisc                 uint32 = 86
	apCallGetInterfaceLanguageData   uint32 = 87
	apCallSetUiItemInfo              uint32 = 88
	apCallSetProfile                 uint32 = 89

	apBackEnterJobMode      uint32 = 192
	apBackLeaveJobMode      uint32 = 193
	apBackUpdateDrive       uint32 = 194
	apBackUpdateCurrentBar  uint32 = 195
	apBackUpdateTotalBar    uint32 = 196
	apBackUpdateLayout      uint32 = 197
	apBackSetTotalName      uint32 = 198
	apBackUpdateCurrentInfo uint32 = 199
	apBackReportUiMessage   uint32 = 200
	apBackExit              uint32 = 201
	apBackSetTitleCollInfo  uint32 = 202
	apBackSetTitleInfo      uint32 = 203
	apBackSetTrackInfo      uint32 = 204
	apBackSetChapterInfo    uint32 = 205
	apBackReportUiDialog    uint32 = 206

	apBackFatalCommError uint32 = 224
	apBackOutOfMem       uint32 = 225
	apUnknown            uint32 = 239
)

// AP_SHMEM flags
const (
	AP_SHMEM_FLAG_START uint32 = 0x01000000
	AP_SHMEM_FLAG_EXIT  uint32 = 0x02000000
	AP_SHMEM_FLAG_NOMEM uint32 = 0x04000000
)

// AP_UpdateDrives flags
const (
	AP_UpdateDrivesFlagNoScan        uint32 = 1
	AP_UpdateDrivesFlagNoSingleDrive uint32 = 2
)

// AP_DriveState values
const (
	AP_DriveStateEmptyClosed uint32 = 0
	AP_DriveStateEmptyOpen   uint32 = 1
	AP_DriveStateInserted    uint32 = 2
	AP_DriveStateLoading     uint32 = 3
	AP_DriveStateNoDrive     uint32 = 256
	AP_DriveStateUnmounting  uint32 = 257
)

// AP_DskFsFlags
const (
	AP_DskFsFlagDvdFilesPresent    uint32 = 1
	AP_DskFsFlagHdvdFilesPresent   uint32 = 2
	AP_DskFsFlagBlurayFilesPresent uint32 = 4
	AP_DskFsFlagAacsFilesPresent   uint32 = 8
	AP_DskFsFlagBdsvmFilesPresent  uint32 = 16
)

const (
	AP_MaxCdromDevices   = 16
	AP_Progress_MaxValue = 65536
	apStrBufSize         = 65008
	apArgsCount          = 32
)

// CmdPack packs command, arg count, and data size into a single uint32
func CmdPack(cmd uint32, argCount uint32, dataSize uint32) uint32 {
	return (cmd << 24) | (argCount << 16) | (dataSize & 0xffff)
}

// CmdUnpack extracts cmd, argCount, dataSize
func CmdUnpack(packed uint32) (cmd uint32, argCount uint32, dataSize uint32) {
	cmd = packed >> 24
	argCount = (packed >> 16) & 0xff
	dataSize = packed & 0xffff
	return
}

// ============================================================
// APShmem - in-memory representation (not wire format)
// ============================================================

type APShmem struct {
	Cmd    uint32
	Flags  uint32
	Args   [apArgsCount]uint32
	StrBuf [apStrBufSize]byte
}

// ============================================================
// Wire format send/recv (from clt_pipe.cpp)
//
// SendCmd:
//   Short form (0 args, 0 data, cmd < 0x10000000):
//     1 byte: (cmd>>24) | 0xf0
//   Long form:
//     (1 + argCount)*4 + dataSize bytes
//     [cmd uint32 LE][args... uint32 LE][strbuf data]
//
// RecvCmd:
//   Read bytes until have >= 4
//   If first byte >= 0xf0: short form, cmd = (byte-0xf0)<<24
//   Else: parse full header, read remaining args+data
// ============================================================

func sendCmd(w io.Writer, mem *APShmem) error {
	cmd := mem.Cmd
	argCount := (cmd >> 16) & 0xff
	dataSize := cmd & 0xffff

	// Short form
	if argCount == 0 && dataSize == 0 && cmd < 0x10000000 {
		_, err := w.Write([]byte{byte((cmd >> 24) | 0xf0)})
		return err
	}

	// Long form
	allSize := (1+int(argCount))*4 + int(dataSize)
	buf := make([]byte, allSize)
	binary.LittleEndian.PutUint32(buf[0:], cmd)
	for i := uint32(0); i < argCount; i++ {
		binary.LittleEndian.PutUint32(buf[4+i*4:], mem.Args[i])
	}
	if dataSize > 0 {
		copy(buf[4+argCount*4:], mem.StrBuf[:dataSize])
	}
	_, err := w.Write(buf)
	return err
}

func recvCmd(r io.Reader, mem *APShmem) error {
	bufSize := (1+apArgsCount)*4 + apStrBufSize
	buf := make([]byte, bufSize)
	have := 0

	// Read until we have at least 4 bytes
	for have < 4 {
		n, err := r.Read(buf[have:])
		if err != nil {
			return err
		}
		have += n

		// Short form: first byte >= 0xf0
		if have == 1 && buf[0] >= 0xf0 {
			cmd := uint32(buf[0]-0xf0) << 24
			binary.LittleEndian.PutUint32(buf[0:], cmd)
			have = 4
		}
	}

	cmd := binary.LittleEndian.Uint32(buf[0:])
	argCount := (cmd >> 16) & 0xff
	dataSize := cmd & 0xffff
	allSize := (1+int(argCount))*4 + int(dataSize)

	// Read remaining bytes
	for have < allSize {
		n, err := r.Read(buf[have:])
		if err != nil {
			return err
		}
		have += n
	}

	mem.Cmd = cmd
	for i := uint32(0); i < argCount; i++ {
		mem.Args[i] = binary.LittleEndian.Uint32(buf[4+i*4:])
	}
	if dataSize > 0 {
		offset := int(4 + argCount*4)
		copy(mem.StrBuf[:], buf[offset:offset+int(dataSize)])
	}
	return nil
}

// ============================================================
// MKVServer - persistent makemkvcon guiserver process
// ============================================================

type MKVServer struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
	mem    APShmem
	Drives [AP_MaxCdromDevices]DriveInfo
}

// NewMKVServer launches makemkvcon in guiserver mode and performs the handshake
func NewMKVServer(makemkvPath string) (*MKVServer, error) {
	s := &MKVServer{}
	s.cmd = exec.Command(makemkvPath, "guiserver", AP_ABI_VER+"+std")

	var err error
	s.stdin, err = s.cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("stdin pipe: %w", err)
	}
	s.stdout, err = s.cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	if err := s.cmd.Start(); err != nil {
		return nil, fmt.Errorf("start makemkvcon: %w", err)
	}
	if err := s.handshake(); err != nil {
		s.cmd.Process.Kill()
		return nil, fmt.Errorf("handshake: %w", err)
	}
	debugLog("MKVServer: guiserver started, handshake complete")

	// Required init sequence before UpdateDrives will fire apBackUpdateDrive callbacks.
	// Mirrors AppGetInterfaceLanguageData() in lstring.cpp called by main.cpp after Init().
	//
	// Step 1: apCallAppGetString(85) — Id=23 (AP_vastr_InterfaceLanguage), Index1=7000 (AP_APP_LOC_MAX), Index2=0
	s.mem = APShmem{}
	s.mem.Args[0] = 23   // AP_vastr_InterfaceLanguage
	s.mem.Args[1] = 7000 // AP_APP_LOC_MAX
	s.mem.Args[2] = 0
	if err := s.execCmd(apCallAppGetString, 3, 0); err != nil {
		s.cmd.Process.Kill()
		return nil, fmt.Errorf("AppGetString init: %w", err)
	}

	// Step 2: apCallGetInterfaceLanguageData(87) — arg[0]=7000 (AP_APP_LOC_MAX)
	// Return value ignored (no language pack = fine, server still initializes drive state)
	s.mem = APShmem{}
	s.mem.Args[0] = 7000 // AP_APP_LOC_MAX
	if err := s.execCmd(apCallGetInterfaceLanguageData, 1, 0); err != nil {
		s.cmd.Process.Kill()
		return nil, fmt.Errorf("GetInterfaceLanguageData init: %w", err)
	}

	return s, nil
}

// handshake implements client.cpp + clt_std.cpp protocol:
//  1. Read stdout until '$'  -- version string "A0001:-"
//  2. Validate prefix == AP_ABI_VER
//  3. Read stdout until byte 0xaa
//  4. Write byte 0xbb
func (s *MKVServer) handshake() error {
	var response strings.Builder
	buf := make([]byte, 1)

	// Step 1: read until '$'
	for {
		if _, err := io.ReadFull(s.stdout, buf); err != nil {
			return fmt.Errorf("read version: %w", err)
		}
		if buf[0] == '$' {
			break
		}
		response.WriteByte(buf[0])
	}

	resp := response.String()
	debugLog("MKVServer version string: %q", resp)

	// Step 2: validate
	if !strings.HasPrefix(resp, AP_ABI_VER+":") {
		return fmt.Errorf("version mismatch: %q", resp)
	}

	// Step 3: read until 0xaa
	for {
		if _, err := io.ReadFull(s.stdout, buf); err != nil {
			return fmt.Errorf("read 0xaa: %w", err)
		}
		if buf[0] == 0xaa {
			break
		}
	}

	// Step 4: send 0xbb
	if _, err := s.stdin.Write([]byte{0xbb}); err != nil {
		return fmt.Errorf("write 0xbb: %w", err)
	}

	debugLog("MKVServer handshake complete")
	return nil
}

// transact sends the current mem and receives the response
func (s *MKVServer) transact() error {
	if err := sendCmd(s.stdin, &s.mem); err != nil {
		return fmt.Errorf("send: %w", err)
	}
	if err := recvCmd(s.stdout, &s.mem); err != nil {
		return fmt.Errorf("recv: %w", err)
	}
	return nil
}

// execCmd sends a command and processes callbacks until apReturn
func (s *MKVServer) execCmd(cmd uint32, argCount uint32, dataSize uint32) error {
	s.mem.Cmd = CmdPack(cmd, argCount, dataSize)

	for {
		if err := s.transact(); err != nil {
			return err
		}

		recvCmdVal, _, _ := CmdUnpack(s.mem.Cmd)
		debugLog("execCmd recv: cmd=0x%x (%d)", recvCmdVal, recvCmdVal)
		if recvCmdVal == apReturn {
			return nil
		}

		// Handle callback then reply with apClientDone
		replyArgs, replyData := s.handleCallback(recvCmdVal)
		s.mem.Cmd = CmdPack(apClientDone, replyArgs, replyData)
	}
}

// handleCallback processes async callbacks.
// Returns (argCount, dataSize) for the apClientDone reply.
func (s *MKVServer) handleCallback(cmd uint32) (uint32, uint32) {
	switch cmd {
	case apBackReportUiMessage:
		msg := nullTermString(s.mem.StrBuf[:])
		debugLog("MKV msg: %s", msg)
		s.mem.Args[0] = 0
		return 1, 0

	case apBackReportUiDialog:
		s.mem.StrBuf[0] = 0
		s.mem.Args[0] = 0xffffffff // -1 = no handler
		return 1, 1

	case apBackUpdateDrive:
		debugLog("apBackUpdateDrive raw: args=%v", s.mem.Args[:5])
		idx := int(s.mem.Args[0])
		state := s.mem.Args[2]
		fsFlags := s.mem.Args[3]

		// Parse strings from strbuf
		p := s.mem.StrBuf[:]
		var drvName, dskName, devName string
		if s.mem.Args[1]&1 != 0 {
			drvName = nullTermString(p)
			p = p[len(drvName)+1:]
		}
		if s.mem.Args[1]&2 != 0 {
			dskName = nullTermString(p)
			p = p[len(dskName)+1:]
		}
		if s.mem.Args[1]&4 != 0 {
			devName = nullTermString(p)
		}

		if idx < AP_MaxCdromDevices {
			s.Drives[idx] = DriveInfo{
				Index:   idx,
				State:   state,
				FsFlags: fsFlags,
				Label:   dskName,
				Device:  devName,
			}
			debugLog("MKV drive update: index=%d state=%d label=%q device=%q", idx, state, dskName, devName)
		}
		return 0, 0

	case apBackUpdateCurrentBar:
		pct := s.mem.Args[0] * 100 / AP_Progress_MaxValue
		debugLog("MKV progress current: %d%%", pct)
		return 0, 0

	case apBackUpdateTotalBar:
		pct := s.mem.Args[0] * 100 / AP_Progress_MaxValue
		debugLog("MKV progress total: %d%%", pct)
		return 0, 0

	case apBackSetTotalName:
		return 0, 0

	case apBackUpdateLayout:
		return 0, 0

	case apBackUpdateCurrentInfo:
		debugLog("MKV info[%d]: %s", s.mem.Args[0], nullTermString(s.mem.StrBuf[:]))
		return 0, 0

	case apBackEnterJobMode:
		debugLog("MKV enter job mode")
		return 0, 0

	case apBackLeaveJobMode:
		debugLog("MKV leave job mode")
		return 0, 0

	case apBackExit:
		debugLog("MKV exit signal received")
		return 0, 0

	case apBackSetTitleCollInfo, apBackSetTitleInfo,
		apBackSetTrackInfo, apBackSetChapterInfo:
		return 0, 0

	default:
		debugLog("MKV unknown callback cmd=0x%x", cmd)
		s.mem.Args[0] = 0
		return 1, 0
	}
}

// ============================================================
// High-level commands
// ============================================================

// OnIdle sends a no-op heartbeat
func (s *MKVServer) OnIdle() error {
	s.mem = APShmem{}
	return s.execCmd(apCallOnIdle, 0, 0)
}

// UpdateDrives enumerates drives without scanning disc content
// AP_UpdateDrivesFlagNoScan avoids seeking drives that are ripping
func (s *MKVServer) UpdateDrives() error {
	s.mem = APShmem{}
	s.mem.Args[0] = 0 //AP_UpdateDrivesFlagNoScan | AP_UpdateDrivesFlagNoSingleDrive
	return s.execCmd(apCallUpdateAvailableDrives, 1, 0)
}

// SetOutputFolder sets the rip destination folder
func (s *MKVServer) SetOutputFolder(path string) error {
	s.mem = APShmem{}
	b := append([]byte(path), 0)
	copy(s.mem.StrBuf[:], b)
	return s.execCmd(apCallSetOutputFolder, 0, uint32(len(b)))
}

// OpenCdDisk opens a disc by drive index
func (s *MKVServer) OpenCdDisk(driveIndex uint32) error {
	s.mem = APShmem{}
	s.mem.Args[0] = driveIndex
	s.mem.Args[1] = 0
	return s.execCmd(apCallOpenCdDisk, 2, 0)
}

// SaveAllTitles rips all selected titles to MKV
func (s *MKVServer) SaveAllTitles() error {
	s.mem = APShmem{}
	return s.execCmd(apCallSaveAllSelectedTitlesToMkv, 0, 0)
}

// CloseDisk closes the current disc
func (s *MKVServer) CloseDisk() error {
	s.mem = APShmem{}
	s.mem.Args[0] = AP_MaxCdromDevices
	return s.execCmd(apCallCloseDisk, 1, 0)
}

// EjectDisk ejects a drive by index
func (s *MKVServer) EjectDisk(driveIndex uint32) error {
	s.mem = APShmem{}
	s.mem.Args[0] = driveIndex
	return s.execCmd(apCallEjectDisk, 1, 0)
}

// SignalExit tells makemkvcon to shut down cleanly
func (s *MKVServer) SignalExit() {
	s.mem = APShmem{}
	s.mem.Cmd = CmdPack(apCallSignalExit, 0, 0)
	_ = sendCmd(s.stdin, &s.mem)
}

// Close shuts down the server process
func (s *MKVServer) Close() {
	s.SignalExit()
	if s.stdin != nil {
		s.stdin.Close()
	}
	if s.stdout != nil {
		s.stdout.Close()
	}
	if s.cmd != nil && s.cmd.Process != nil {
		s.cmd.Process.Kill()
	}
}

// ============================================================
// Helpers
// ============================================================

func nullTermString(b []byte) string {
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}
