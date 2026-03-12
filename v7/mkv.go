package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/windows"
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
				DrawProgressBar("Ripping: "+name, currentTitle, pct)
			}
		}
	}

	cmd.Wait()
	fmt.Println("\nRip Complete.")
}

/*func runMetadataScan(index string, exePath string) DiscInfo {
	// Call makemkvcon to get disc info in robot mode (-r)
	cmd := exec.Command(exePath, "-r", "info", "disc:"+index)
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		fmt.Printf("Failed to start makemkvcon: %v\n", err)
		return DiscInfo{}
	}
	cmd.Start()

	// Pass the streaming output directy to parser
	scanner := bufio.NewScanner(stdout)
	info := ParseMakeMKVOutput(scanner)

	cmd.Process.Kill()
	return info
}*/

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

func ejectDrive(letter string) {
	fmt.Printf("Ejecting drive %s...\n", letter)
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
		fmt.Printf("Failed to open drive: %v\n", err)
		return
	}
	defer windows.CloseHandle(h)

	var bytesReturned uint32
	windows.DeviceIoControl(h, IOCTL_STORAGE_EJECT_MEDIA, nil, 0, nil, 0, &bytesReturned, nil)
	fmt.Printf("Waiting for disc removal...\n")
	for discReady(letter) {
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Printf("Disc removed.\n")
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
