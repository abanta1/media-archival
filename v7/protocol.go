package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"
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

// Attribute IDs from apdefs.h
const (
	ap_iaType = 1
	ap_iaName = 2
	//ap_iaLangCode       = 3
	//ap_iaLangName       = 4
	//ap_iaCodecId        = 5
	//ap_iaCodecShort     = 6
	ap_iaChapterCount = 8
	ap_iaDuration     = 9
	ap_iaDiskSize     = 10
	//ap_iaDiskSizeBytes  = 11
	ap_iaStreamTypeExtension = 12
	//ap_iaSourceFileName = 16
	ap_iaVideoSize      = 19
	ap_iaOutputFileName = 27
	ap_iaVolumeName     = 32
)

// Settings from apdefs.h
const (
	apset_io_SingleDrive                   = 23
	apset_app_DefaultOutputFileName uint32 = 40 // from ApSettingId enum (0-indexed: apset_Unknown=0...apset_app_DefaultOutputFileName=39)
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
	AP_TTREE_VIDEO      = 6201
	AP_TTREE_AUDIO      = 6202
	AP_TTREE_SUBPICTURE = 6203
)

const (
	apArgsCount           = 32
	AP_MaxCdromDevices    = 16
	AP_stageOpeningDisc   = 3100
	AP_stageProcTitleSets = 3102
	AP_stageProcTitles    = 3103
	AP_stageDecrypting    = 3104
	AP_stageScanContents  = 3120
	AP_stageSavingMKV     = 5017
	AP_stageScanDevices   = 5018
	AP_stageRipping       = 5024
	AP_stageAnalyzing     = 5057
	apStrBufSize          = 65008
	AP_Progress_MaxValue  = 65536
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

	// Log raw first 16 bytes
	end := have
	if end > 16 {
		end = 16
	}
	//debugLog("recvCmd raw[0:%d]: % x", end, buf[:end])

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
	cmd              *exec.Cmd
	stdin            io.WriteCloser
	stdout           io.ReadCloser
	stderr           io.ReadCloser
	mem              APShmem
	isDead           bool
	Drives           [AP_MaxCdromDevices]DriveInfo
	TitleCount       int
	Titles           []TitleInfo
	CollectionHandle uint64
	DiscReady        bool
	currentStatus    string
	totalStatus      string
	currentFile      string
	currentSpeed     string
	currentBytes     string
	currentSource    string
	currentSize      string
	currentRate      string
	currentProgress  string
	currentVobu      string
	currentOutput    string
	currentOutSize   string
	currentBar       int
	totalBar         int
	isRipping        bool
	currentStage     string
}

// NewMKVServer launches makemkvcon in guiserver mode and performs the handshake
func NewMKVServer(makemkvPath string) (*MKVServer, error) {
	s := &MKVServer{isDead: false}
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
	s.stderr, err = s.cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("stderr pipe: %w", err)
	}
	if err := s.cmd.Start(); err != nil {
		return nil, fmt.Errorf("start makemkvcon: %w", err)
	}

	// Goroutine to log stderr for debugging
	go func() {
		scanner := bufio.NewScanner(s.stderr)
		for scanner.Scan() {
			debugLog("makemkvcon stderr: %s", scanner.Text())
		}
	}()

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

	// Perform an initial drive update to populate the drive list without a hardware scan.
	if err := s.UpdateDrives(); err != nil {
		s.cmd.Process.Kill()
		return nil, fmt.Errorf("initial UpdateDrives: %w", err)
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
	if s.isDead {
		return fmt.Errorf("server process is dead")
	}
	if err := sendCmd(s.stdin, &s.mem); err != nil {
		if strings.Contains(err.Error(), "pipe is being closed") {
			debugLog("transact: detected dead pipe on send")
			s.isDead = true
		}
		return fmt.Errorf("send: %w", err)
	}
	if err := recvCmd(s.stdout, &s.mem); err != nil {
		if err == io.EOF || strings.Contains(err.Error(), "pipe is being closed") {
			debugLog("transact: detected dead pipe on recv")
			s.isDead = true
		}
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
		//debugLog("execCmd recv: cmd=0x%x (%d)", recvCmdVal, recvCmdVal)
		if recvCmdVal == apReturn {
			return nil
		}

		// Handle callback then reply with apClientDone
		if recvCmdVal != apBackUpdateCurrentBar && recvCmdVal != apBackUpdateTotalBar {
			//debugLog("execCmd callback: cmd=%d (0x%x)", recvCmdVal, recvCmdVal)
		}
		replyArgs, replyData := s.handleCallback(recvCmdVal)
		s.mem.Cmd = CmdPack(apClientDone, replyArgs, replyData)
	}
}

// handleCallback processes async callbacks.
// Returns (argCount, dataSize) for the apClientDone reply.
func (s *MKVServer) handleCallback(cmd uint32) (uint32, uint32) {
	switch cmd {
	case apBackReportUiMessage:
		//msg := nullTermString(s.mem.StrBuf[:])
		//debugLog("MKV msg: flags=%d code=%d msg=%q", s.mem.Args[0], s.mem.Args[1], msg)
		s.mem.Args[0] = 0
		return 1, 0

	case apBackReportUiDialog:
		// Log dialog details so we can see what MakeMKV is asking
		dialogType := s.mem.Args[0]
		dialogID := s.mem.Args[1]
		dialogMsg := nullTermString(s.mem.StrBuf[:])
		debugLog("MKV dialog: type=%d id=%d msg=%q", dialogType, dialogID, dialogMsg)
		// Repsond with button 0 (default/OK) rather than -1 (no handler),
		// which may cause MakeMKV to cancel the job during a rip
		s.mem.StrBuf[0] = 0
		s.mem.Args[0] = 0
		//s.mem.Args[0] = 0xffffffff // -1 = no handler
		return 1, 1

	case apBackUpdateDrive:
		//debugLog("apBackUpdateDrive raw: args=%v", s.mem.Args[:5])
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
		//debugLog("apBackUpdateDrive callback: index=%d state=%d label=%q device=%q drvName=%q", idx, state, dskName, devName, drvName)
		if idx < AP_MaxCdromDevices {
			s.Drives[idx] = DriveInfo{
				Index:   idx,
				State:   state,
				FsFlags: fsFlags,
				Label:   dskName,
				Device:  devName,
			}
			//debugLog("MKV drive update: index=%d state=%d label=%q device=%q", idx, state, dskName, devName)
		}
		return 0, 0

	case apBackUpdateCurrentBar:
		s.currentBar = int(s.mem.Args[0] * 100 / AP_Progress_MaxValue)
		s.drawStatusLines()
		//debugLog("MKV progress current: %d%%", pct)
		return 0, 0

	case apBackUpdateTotalBar:
		s.totalBar = int(s.mem.Args[0] * 100 / AP_Progress_MaxValue)
		s.drawStatusLines()
		//debugLog("MKV progress total: %d%%", pct)
		return 0, 0

	case apBackUpdateLayout:
		switch s.mem.Args[0] {
		case AP_stageScanDevices:
			s.currentStage = "Scanning Devices"
		case AP_stageProcTitleSets:
			s.currentStage = "Processing Title Sets"
		case AP_stageProcTitles:
			s.currentStage = "Processing Titles"
		case AP_stageScanContents:
			s.currentStage = "Scanning Contents"
		case AP_stageDecrypting:
			s.currentStage = "Decrypting"
		case AP_stageAnalyzing:
			s.currentStage = "Analyzing Segments"
			s.isRipping = true
		case AP_stageSavingMKV:
			s.currentStage = "Saving MKV"
			s.isRipping = true
		default:
			debugLog("apBackSetCurrentName unknown code/args[0]=%d", s.mem.Args[0])
		}
		s.drawStatusLines()
		return 0, 0

	case apBackSetTotalName:
		switch s.mem.Args[0] {
		case AP_stageScanDevices:
			s.currentStage = "Scanning Devices"
			s.isRipping = false
		case AP_stageOpeningDisc:
			s.currentStage = "Opening disc"
			s.isRipping = false
		case AP_stageRipping:
			s.currentStage = "Ripping"
			s.isRipping = true
		default:
			debugLog("apBackSetTotalName unknown code/args[0]=%d", s.mem.Args[0])
		}
		s.drawStatusLines()
		return 0, 0

	case apBackUpdateCurrentInfo:
		s.currentStatus = nullTermString(s.mem.StrBuf[:])
		val := nullTermString(s.mem.StrBuf[:])

		switch s.mem.Args[0] {
		case 0:
			s.currentSource = val
		case 1:
			s.currentFile = val
		case 2:
			if s.isRipping {
				s.currentSize = val
			} else {
				s.currentProgress = val
			}
		case 3:
			if s.isRipping {
				s.currentRate = val
			} else {
				s.currentVobu = val
			}
		case 4:
			s.currentOutput = val
		case 5:
			s.currentOutSize = val
		}
		s.drawStatusLines()

		//debugLog("apBackUpdateCurrentInfo index=%d val=%q", s.mem.Args[0], nullTermString(s.mem.StrBuf[:]))
		//debugLog("MKV info[%d]: %s", s.mem.Args[0], nullTermString(s.mem.StrBuf[:]))
		return 0, 0

	case apBackEnterJobMode:
		s.DiscReady = false
		s.isRipping = false
		debugLog("MKV enter job mode")
		return 0, 0

	case apBackLeaveJobMode:
		s.DiscReady = true
		debugLog("MKV leave job mode")
		return 0, 0

	case apBackExit:
		debugLog("MKV exit signal received")
		return 0, 0

	case apBackSetTitleCollInfo:
		s.CollectionHandle = uint64(s.mem.Args[0]) | uint64(s.mem.Args[1])<<32
		count := int(s.mem.Args[2])
		s.TitleCount = count
		s.Titles = make([]TitleInfo, count)
		return 0, 0

	case apBackSetTitleInfo:
		id := int(s.mem.Args[0])
		handle := uint64(s.mem.Args[1]) | uint64(s.mem.Args[2])<<32
		trackCount := s.mem.Args[3]
		chapterCount := s.mem.Args[4]
		if id < len(s.Titles) {
			s.Titles[id].Handle = handle
			s.Titles[id].TrackCount = trackCount
			s.Titles[id].ChapterCount = chapterCount
		}
		return 0, 0

	case apBackSetTrackInfo:
		debugLog("apBackSetTrackInfo raw: args=%v", s.mem.Args[:6])
		id := int(s.mem.Args[0])
		handle := uint64(s.mem.Args[2]) | uint64(s.mem.Args[3])<<32
		if id < len(s.Titles) {
			s.Titles[id].Tracks = append(s.Titles[id].Tracks, TrackInfo{Handle: handle})
		}
		return 0, 0

	case apBackSetChapterInfo:
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

func (s *MKVServer) SetSingleDrive(device string) error {
	s.mem = APShmem{}
	b := append([]byte(device), 0)
	copy(s.mem.StrBuf[:], b)
	s.mem.Args[0] = apset_io_SingleDrive
	debugLog("SetSingleDrive: sending command apCallSetSettingString with setting ID %d and value %q", apset_io_SingleDrive, device)
	return s.execCmd(apCallSetSettingString, 1, uint32(len(b)))
}

// SetSingleDriveMode enables or disables the single drive mode boolean setting.
func (s *MKVServer) SetSingleDriveMode(enable bool) error {
	s.mem = APShmem{}
	s.mem.Args[0] = apset_io_SingleDrive
	s.mem.Args[1] = boolToUint32(enable)
	return s.execCmd(apCallSetSettingInt, 2, 0)
}

// ScanDrives enumerates drives without scanning disc content
func (s *MKVServer) ScanDrives() error {
	s.mem = APShmem{}
	s.mem.Args[0] = 0 // full scan - only call this once when disc detected
	debugLog("ScanDrives: sending command apCallUpdateAvailableDrives with Args[0]=%d", s.mem.Args[0])
	return s.execCmd(apCallUpdateAvailableDrives, 1, 0)
}

// UpdateDrives enumerates drives without scanning disc content
// AP_UpdateDrivesFlagNoScan avoids seeking drives that are ripping
func (s *MKVServer) UpdateDrives() error {
	s.mem = APShmem{}
	s.mem.Args[0] = 1 // AP_UpdateDrivesFlagNoScan - refresh state without hardware probe
	return s.execCmd(apCallUpdateAvailableDrives, 1, 0)
}

// ScanConfiguredDrives probes hardware respecting current settings (like apset_io_SingleDrive).
func (s *MKVServer) ScanConfiguredDrives() error {
	s.mem = APShmem{}
	debugLog("ScanConfiguredDrives: sending command apCallUpdateAvailableDrives with 0 arguments")
	return s.execCmd(apCallUpdateAvailableDrives, 0, 0)
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

// SetTitleSelected enables or disables a title for ripping
// Args: CollectionHandle (low/high), title index, Qt::CheckState (0=unchecked, 2=checked).
func (s *MKVServer) SetTitleSelected(titleIndex int, selected bool) error {
	s.mem = APShmem{}
	s.mem.Args[0] = uint32(s.CollectionHandle)
	s.mem.Args[1] = uint32(s.CollectionHandle >> 32)
	s.mem.Args[2] = uint32(titleIndex)
	if selected {
		s.mem.Args[3] = 2 // Qt::Checked
	} else {
		s.mem.Args[3] = 0 // Qt::Unchecked
	}
	return s.execCmd(apCallSetUiItemState, 4, 0)
}

// SaveAllTitles rips all selected titles to MKV
func (s *MKVServer) SaveAllTitles() error {
	s.mem = APShmem{}
	s.isRipping = true
	return s.execCmd(apCallSaveAllSelectedTitlesToMkv, 0, 0)
}

func (s *MKVServer) drawStatusLines() {
	_, height, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil {
		return
	}

	const barLength = 20
	fillBar := func(pct int) string {
		f := (pct * barLength) / 100
		if f < 0 {
			f = 0
		}
		if f > barLength {
			f = barLength
		}
		return strings.Repeat("█", f) + strings.Repeat("░", barLength-f)
	}
	var line0 string
	var line1 string
	var msgFilePath string
	var msgFileSize string
	if filepath.Base(s.currentOutput) != "." {
		msgFilePath = fmt.Sprintf("||| %s", filepath.Base(s.currentOutput))
	}
	if s.currentOutSize != "" {
		msgFileSize = fmt.Sprintf("Out: %s", s.currentOutSize)
	}

	if s.isRipping {
		var curSize string
		if s.currentSize != "" && s.currentOutSize != "." {
			curSize = "||| Size:"
		}
		line0 = fmt.Sprintf("Status: %s %s", s.currentStage, msgFilePath)
		line1 = fmt.Sprintf("%-40s", fmt.Sprintf("Source: %s %s %s", s.currentSource, curSize, s.currentSize))
	} else {
		var msgVOBU string
		var msgCELL string
		if s.currentVobu != "" {
			msgVOBU = "||| VOBU:"
		}
		if s.currentProgress != "" {
			msgCELL = "||| CELL:"

		}
		line0 = fmt.Sprintf("Status: %s %s %s %s %s %s", s.currentStage, msgFilePath, msgCELL, s.currentProgress, msgVOBU, s.currentVobu)
		line1 = fmt.Sprintf("%-40s", fmt.Sprintf("Source: %s", s.currentSource))
	}

	line2 := fmt.Sprintf("[%s] %3d%%  %s", fillBar(s.currentBar), s.currentBar, msgFileSize)
	line3 := fmt.Sprintf("[%s] %3d%%  %s", fillBar(s.totalBar), s.totalBar, s.currentRate)
	fmt.Printf("\033[s\033[%d;0H\033[K\033[%d;0H\033[K%s\033[%d;0H\033[K%s\033[%d;0H\033[K%s\033[%d;0H\033[K%s\033[u",
		height-4, // blank separator
		height-3, line0,
		height-2, line1,
		height-1, line2,
		height, line3)
}

func (s *MKVServer) watchResize(stop <-chan struct{}) {
	var lastW, lastH int
	for {
		select {
		case <-stop:
			return
		default:
		}
		w, h, err := term.GetSize(int(os.Stdout.Fd()))
		if err != nil {
			time.Sleep(500 * time.Millisecond)
			continue
		}
		if w != lastW || h != lastH {
			lastW, lastH = w, h
			//Clear entire screen and re-establish scroll region
			fmt.Printf("\033[2J")
			setScrollRegion(5)
			s.drawStatusLines()
		}
		time.Sleep(500 * time.Millisecond)
	}
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
	if s.stderr != nil {
		s.stderr.Close()
	}
	if s.cmd != nil && s.cmd.Process != nil {
		s.cmd.Process.Kill()
	}
}

func (s *MKVServer) GetUiItemInfo(handle uint64, attrID uint32) (string, error) {
	s.mem = APShmem{}
	s.mem.Args[0] = uint32(handle)
	s.mem.Args[1] = uint32(handle >> 32)
	s.mem.Args[2] = attrID
	if err := s.execCmd(apCallGetUiItemInfo, 3, 0); err != nil {
		return "", err
	}
	//debugLog("GetUiItemInfo handle=%d attr=%d args[0]=%d args[1]=%d args[2]=%d", handle, attrID, s.mem.Args[0], s.mem.Args[1], s.mem.Args[2])
	if s.mem.Args[1] == 0 {
		return "", nil
	}
	// UTF-8 string in strbuf
	//debugLog("GetUiItemInfo attr=%d raw strbuf: % x", attrID, s.mem.StrBuf[:32])
	return nullTermString(s.mem.StrBuf[:]), nil
}

// Set the global output filename template before ripping
func (s *MKVServer) SetDefaultOutputFileName(name string) error {
	s.mem = APShmem{}
	b := append([]byte(name), 0)
	copy(s.mem.StrBuf[:], b)
	s.mem.Args[0] = apset_app_DefaultOutputFileName
	return s.execCmd(apCallSetSettingString, 1, uint32(len(b)))
}

// ============================================================
// Helpers
// ============================================================

func boolToUint32(b bool) uint32 {
	if b {
		return 1
	}
	return 0
}

func nullTermString(b []byte) string {
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

func (s *MKVServer) ScanDisc() (DiscInfo, error) {
	var info DiscInfo

	// Get disc title from title collection handle
	volName, err := s.GetUiItemInfo(s.CollectionHandle, ap_iaVolumeName)
	if err == nil && volName != "" {
		info.Title = volName
	}

	for i, t := range s.Titles {
		if t.Handle == 0 {
			continue
		}
		//name, _ := s.GetUiItemInfo(t.Handle, ap_iaName)
		duration, _ := s.GetUiItemInfo(t.Handle, ap_iaDuration)
		//fileName, _ := s.GetUiItemInfo(t.Handle, ap_iaOutputFileName)
		fileSize, _ := s.GetUiItemInfo(t.Handle, ap_iaDiskSize)
		minutes := parseDurationToMinutes(duration)
		var (
			vidWidth  int
			vidHeight int
			vidRes    string
		)

		//debugLog("Title[%d]: name=%q duration=%q size=%q", i, name, duration, fileSize)
		//debugLog("Title[%d] track count=%d", i, len(s.Titles[i].Tracks))
		for _, track := range s.Titles[i].Tracks {
			if track.Handle == 0 {
				continue
			}

			//streamType, _ := s.GetUiItemInfo(track.Handle, ap_iaStreamTypeExtension)
			//debugLog("Title[%d] track handle=%d streamTypeExt=%q", i, track.Handle, streamType)

			//trackType, _ := s.GetUiItemInfo(track.Handle, ap_iaType)
			//debugLog("Title[%d] trackType=%s handle=%d ap_iaType raw=%q", i, trackType, track.Handle, trackType)

			typeCode, _ := s.GetUiItemCode(track.Handle, ap_iaType)
			//debugLog("Title[%d] track handle=%d typeCode=%d", i, track.Handle, typeCode)

			if typeCode == AP_TTREE_VIDEO {
				vidRes, _ = s.GetUiItemInfo(track.Handle, ap_iaVideoSize)
				//debugLog("Title[%d] vidRes=%q", i, vidRes)
				if parts := strings.SplitN(vidRes, "x", 2); len(parts) == 2 {
					vidWidth, _ = strconv.Atoi(strings.TrimSpace(parts[0]))
					vidHeight, _ = strconv.Atoi(strings.TrimSpace(parts[1]))
					//debugLog("Title[%d] vidRes=%d", i, vidWidth)
					//debugLog("Title[%d] vidRes=%d", i, vidHeight)
				}
				break
			}
		}

		info.Features = append(info.Features, TitleMetadata{
			Index:   i,
			Minutes: minutes,
			//FileName: fileName,
			FileSize:   fileSize,
			Resolution: vidRes,
			Width:      vidWidth,
			Height:     vidHeight,
		})
	}
	return info, nil
}

func (s *MKVServer) GetUiItemCode(handle uint64, attrID uint32) (uint32, error) {
	s.mem = APShmem{}
	s.mem.Args[0] = uint32(handle)
	s.mem.Args[1] = uint32(handle >> 32)
	s.mem.Args[2] = attrID
	if err := s.execCmd(apCallGetUiItemInfo, 3, 0); err != nil {
		return 0, err
	}
	return s.mem.Args[0], nil
}

func parseDurationToMinutes(duration string) int {
	// duration comes back as "h:mm:ss"" or total seconds string

	var secs int
	fmt.Sscanf(duration, "%d", &secs)
	return secs / 60
}
