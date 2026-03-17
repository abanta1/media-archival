package mkv

import (
	"bufio"
	"bytes"
	"fmt"
	log "media-archival/v7/internal/logger"
	"media-archival/v7/internal/ui"

	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

const IOCTL_STORAGE_EJECT_MEDIA = 0x2D4808
const IOCTL_STORAGE_MEDIA_REMOVAL = 0x002D4804

func InvokeMakeMKVRip(name string, args []string, exePath string) {
	cmd := exec.Command(exePath, args...)
	stdout, _ := cmd.StdoutPipe()
	cmd.Start()

	scanner := bufio.NewScanner(stdout)
	reProg := regexp.MustCompile(`^PRGV:(\d+),(\d+),(\d+)$`)
	reTitle := regexp.MustCompile(`^PRGT:\d+,\d+,"(.*)"$`)

	var currentTitle string

	for scanner.Scan() {
		line := scanner.Text()

		// Update Title Name
		if m := reTitle.FindStringSubmatch(line); m != nil {
			currentTitle = m[1]
		}

		// Update Progress Bar
		if m := reProg.FindStringSubmatch(line); m != nil {
			cur, _ := strconv.Atoi(m[1])
			max, _ := strconv.Atoi(m[3])
			if max > 0 {
				pct := (cur * 100) / max
				ui.DrawProgressBar("Ripping: "+name, currentTitle, pct, 1)
			}
		}
	}

	cmd.Wait()
	log.Log(5, "Rip Complete.")
}

func (s *MKVServer) WatchResize(stop <-chan struct{}) {
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
			ui.SetScrollRegion(5)
			s.DrawStatusLines()
		}
		time.Sleep(500 * time.Millisecond)
	}
}

/*func runMetadataScan(index string, exePath string) DiscInfo {
	// Call makemkvcon to get disc info in robot mode (-r)
	cmd := exec.Command(exePath, "-r", "info", "disc:"+index)
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		log.Log(3, "Failed to start makemkvcon: %v\n", err)
		return DiscInfo{}
	}
	cmd.Start()

	// Pass the streaming output directy to parser
	scanner := bufio.NewScanner(stdout)
	info := ParseMakeMKVOutput(scanner)

	cmd.Process.Kill()
	return info
}*/

// Try to open key files to ensure filesystem is responsive, like in the PowerShell script.
func DiscReady(letter string) bool {
	// 1. Force an OS hardware query to 'wake' drive
	pathStr := filepath.VolumeName(letter) + "\\"
	log.Log(7, "Querying Path: [%s]", pathStr)
	path, _ := windows.UTF16PtrFromString(filepath.VolumeName(letter) + "\\")

	if err := windows.GetVolumeInformation(path, nil, 0, nil, nil, nil, nil, 0); err != nil {
		log.Log(4, "OS cannot talk to hardware %s", err)
		return false // OS cant talk to hardware yet
	} else {
		log.Log(7, "OS can talk to hardware")
	}

	// 2. Verify disc is video disc
	ifoPath := filepath.Join(letter, "VIDEO_TS", "VIDEO_TS.IFO")
	if f, err := os.Open(ifoPath); err == nil {
		f.Close()
		log.Log(7, "DiscReady: Found and opened %s", ifoPath)
		return true
	} else {
		log.Log(4, "DiscReady: DVD Error: %s", err)
	}

	bdmvPath := filepath.Join(letter, "BDMV", "index.bdmv")
	if f, err := os.Open(bdmvPath); err == nil {
		f.Close()
		log.Log(7, "discReady: Found and opened %s", bdmvPath)
		return true
	} else {
		log.Log(4, "mkv.DiscReady BD Error: %s", err)
	}

	// Fallback for discs that might not have those exact files but are ready.
	_, errIFO := os.Stat(filepath.Join(letter, "VIDEO_TS"))
	_, errBDMV := os.Stat(filepath.Join(letter, "BDMV"))
	return errIFO == nil || errBDMV == nil
}

// replaces runMetadataScan
func (s *MKVServer) OpenDisc(driveIndex int) error {
	s.mem = APShmem{}
	s.mem.Args[0] = uint32(driveIndex)
	s.mem.Args[1] = 0
	return s.execCmd(apCallOpenCdDisk, 2, 0)
}

func (s *MKVServer) GetTitleCount() int {
	// AP_vastr or title collection info populated after OpenCdDisk
	// via apBackSetTitleCollInfo callback during execCmd
	return s.TitleCount
}

// replaces runMetadataScan

func openDriveHandle(driveLetter string) (windows.Handle, error) {
	drivePath := `\\.\` + strings.TrimSuffix(driveLetter, "\\")
	path, err := windows.UTF16PtrFromString(drivePath)
	if err != nil {
		return windows.InvalidHandle, err
	}
	handle, err := windows.CreateFile(
		path,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		return windows.InvalidHandle, err
	}
	return handle, nil
}

func EjectDrive(letter string) {
	log.Log(5, "Ejecting drive %s...\n", letter)
	drivePath := fmt.Sprintf(`\\.\%s`, strings.TrimSuffix(letter, "\\"))

	h, err := windows.CreateFile(
		windows.StringToUTF16Ptr(drivePath),
		windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		0,
		0,
	)
	if err != nil {
		log.Log(3, "Failed to open drive: %v\n", err)
		return
	}
	defer windows.CloseHandle(h)

	var bytesReturned uint32
	windows.DeviceIoControl(h, IOCTL_STORAGE_EJECT_MEDIA, nil, 0, nil, 0, &bytesReturned, nil)
	log.Log(5, "Waiting for disc removal...\n")
	for DiscReady(letter) {
		time.Sleep(500 * time.Millisecond)
	}
	log.Log(5, "Disc removed.\n")
}

func GetDriveIndex(targetLetter string, exePath string) (string, error) {
	cmd := exec.Command(exePath, "-r", "info", "disc:9999")
	output, _ := cmd.CombinedOutput()

	scanner := bufio.NewScanner(bytes.NewReader(output))
	re := regexp.MustCompile(`DRV:(\d+),.*,"` + regexp.QuoteMeta(strings.ToUpper(targetLetter)) + `"`)

	for scanner.Scan() {
		match := re.FindStringSubmatch(scanner.Text())
		if len(match) > 1 {
			return match[1], nil
		}
	}
	return "", fmt.Errorf("drive %s not found", targetLetter)
}
