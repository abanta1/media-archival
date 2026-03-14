package main

import (
	"bufio"
	"flag"
	"fmt"
	"math"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

// Global Config (PS1 param block)
var (
	TmdbKey         = os.Getenv("TMDB_API")
	debugMode       bool
	setupMode       bool
	configSetup     bool
	kernel32        = syscall.NewLazyDLL("kernel32.dll")
	setTitle        = kernel32.NewProc("SetConsoleTitleW")
	procSetTitle    = kernel32.NewProc("SetConsoleTitleW")
	procGetConsMode = kernel32.NewProc("GetConsoleMode")
	procSetConsMode = kernel32.NewProc("SetConsoleMode")
)

func enableANSI() {
	stdout := os.Stdout.Fd()
	var mode uint32
	procGetConsMode.Call(stdout, uintptr(unsafe.Pointer(&mode)))
	procSetConsMode.Call(stdout, uintptr(mode|0x0004))
}

func setConsoleTitle(title string) {
	ptr, _ := windows.UTF16PtrFromString(title)
	procSetTitle.Call(uintptr(unsafe.Pointer(ptr)))
}

func main() {
	enableANSI()
	setConsoleTitle("MakeMKV Go-Auto")

	configPath := flag.String("config", "", "")
	flag.StringVar(configPath, "C", "", "")
	flag.BoolVar(&debugMode, "debug", false, "")
	flag.BoolVar(&debugMode, "V", false, "")
	driveLetter := flag.String("drive", "", "")
	flag.StringVar(driveLetter, "T", "", "")
	apiKey := flag.String("apikey", "", "")
	flag.StringVar(apiKey, "K", "", "")
	destDir := flag.String("dest", "", "")
	flag.StringVar(destDir, "D", "", "")
	flag.BoolVar(&configSetup, "setup", false, "")
	flag.BoolVar(&configSetup, "S", false, "")

	makemkvPath := flag.String("makemkv", "", "")
	flag.StringVar(makemkvPath, "M", "", "")

	flag.Usage = func() {
		exeName := filepath.Base(os.Args[0])

		fmt.Fprintf(os.Stderr, "Automated MakeMKV utility.\n\n")
		fmt.Fprintf(os.Stderr, "  Usage of %s:\n", exeName)

		fmt.Fprintf(os.Stderr, "  -H, --help\n\tPrints this help message\n")
		fmt.Fprintf(os.Stderr, "  -V, --debug\n\tEnable verbose logging\n\n")
		fmt.Fprintf(os.Stderr, "  -C, --config [string]\n\tPath to new/existing config file (default \"config.json\")\n\t"+
			"  config file used for static/normal defaults. Flags override config.\n\t  disc drive, API key, destination dir\n\n")
		fmt.Fprintf(os.Stderr, "  -T, --drive <driveletter:> - i.e. --drive D:\n\tSpecifies the disc drive to use\n\n")
		fmt.Fprintf(os.Stderr, "  -S, --setup\n\tEnters config setup mode\n\n")
		fmt.Fprintf(os.Stderr, "  -K, --apikey <key> - i.e. --apikey 123ABC\n\tSpecifies the TMDB API key to use for title matching\n\n")
		fmt.Fprintf(os.Stderr, "  -D, --dest <dir> - i.e. --dest C:\\Path\\to\\Final\\\n\tSpecifies the path to use as the base directory for final location\n\n")
		fmt.Fprintf(os.Stderr, "  -M, --makemkv <dir> - i.e. --dest C:\\Path\\to\\makemkvcon.exe\\\n\tSpecifies the path to use for MakeMKV binary\n\n")
		//flag.PrintDefaults() // Prints alphabetically
	}
	flag.Parse()

	var cfg Config

	defaultMKVPaths := []string{
		`C:\Program Files (x86)\MakeMKV\makemkvcon64.exe`,
		`C:\Program Files\MakeMKV\makemkvcon64.exe`,
		`C:\Program Files (x86)\MakeMKV\makemkvcon.exe`,
		`C:\Program Files\MakeMKV\makemkvcon.exe`,
	}
	cfg.MakeMKVPath = ""

	var configFound bool

	if configSetup || *configPath != "" {
		// Load config based on flag
		if _, err := os.Stat(*configPath); err == nil {
			debugLog("Config file found: %s", *configPath)
			fmt.Printf("Loading config from %s...\n", *configPath)
			cfg, _ = LoadConfig(*configPath)
			configFound = true
		} else {
			debugLog("Config file not found: %s", *configPath)
			fmt.Printf("Config file not found\n")
			configFound = false
		}
	}

	for _, p := range defaultMKVPaths {
		if _, err := os.Stat(p); err == nil {
			cfg.MakeMKVPath = p
			fmt.Printf("MakeMKV found at: %s\n", p)
			break
		}
	}

	if *apiKey != "" {
		cfg.APIKey = *apiKey
		TmdbKey = *apiKey
	} else if cfg.APIKey != "" {
		TmdbKey = cfg.APIKey
	}
	if *destDir != "" {
		cfg.DestPath = *destDir
	}
	if *driveLetter != "" {
		cfg.DriveLetter = *driveLetter
	}
	if cfg.MakeMKVPath == "" {
		if *makemkvPath != "" {
			cfg.MakeMKVPath = *makemkvPath
		}
	}

	if !configSetup && *configPath == "" && (cfg.APIKey == "" || cfg.DestPath == "" || cfg.DriveLetter == "" || cfg.MakeMKVPath == "") {
		var missingArgs []string
		if cfg.APIKey == "" {
			missingArgs = append(missingArgs, "API Key")
		}
		if cfg.DestPath == "" {
			missingArgs = append(missingArgs, "Destination Path")
		}
		if cfg.DriveLetter == "" {
			missingArgs = append(missingArgs, "Drive Letter")
		}
		if cfg.MakeMKVPath == "" {
			missingArgs = append(missingArgs, "MakeMKV Path")
		}
		if len(missingArgs) > 0 {
			fmt.Println("Missing required arguments:")
			for _, arg := range missingArgs {
				fmt.Printf("  %s\n", arg)
			}
		}

		fmt.Print("Would you like to create a config file [Y]/n: ")
		keyCh := make(chan byte, 1)
		go func() {
			oldState, err := term.MakeRaw(int(os.Stdin.Fd()))
			if err != nil {
				keyCh <- 0
				return
			}
			defer term.Restore(int(os.Stdin.Fd()), oldState)
			var buf [1]byte
			os.Stdin.Read(buf[:])
			if buf[0] == 3 {
				term.Restore(int(os.Stdin.Fd()), oldState)
				fmt.Println("\n- Ctrl+C pressed. Cleaning up processes and exiting")
				os.Exit(0)
			}
			keyCh <- buf[0]
		}()

		key := <-keyCh
		key = byte(unicode.ToLower(rune(key)))

		switch key {
		case '\n', 'y':
			configSetup = true
		case 'n':
			fmt.Println("\nSee help `rip-auto -H` for usage information.")
			os.Exit(0)
		default:
			fmt.Println("\nInvalid key. Expected Y or N.")
			os.Exit(1)
		}
	} else if configSetup || (*configPath != "" && configFound == false) {
		fmt.Println("No config file found. Let's create one.")
		fmt.Println("Entering config setup mode...")
		reader := bufio.NewReader(os.Stdin)

		fmt.Print("Drive letter (e.g. D:): ")
		cfg.DriveLetter, _ = reader.ReadString('\n')
		cfg.DriveLetter = strings.TrimSpace(cfg.DriveLetter)

		fmt.Print("TMDB API key: ")
		cfg.APIKey, _ = reader.ReadString('\n')
		cfg.APIKey = strings.TrimSpace(cfg.APIKey)

		fmt.Print("Destination Directory (e.g. E:\\Movies): ")
		cfg.DestPath, _ = reader.ReadString('\n')
		cfg.DestPath = strings.TrimSpace(cfg.DestPath)

		for _, p := range defaultMKVPaths {
			if _, err := os.Stat(p); err == nil {
				cfg.MakeMKVPath = p
				fmt.Printf("MakeMKV found at: %s\n", p)
				break
			}
		}
		if cfg.MakeMKVPath == "" {
			fmt.Print("MakeMKV executable path (e.g. C:\\Program Files (x86)\\MakeMKV\\makemkvcon.exe): ")
			cfg.MakeMKVPath, _ = reader.ReadString('\n')
			cfg.MakeMKVPath = strings.TrimSpace(cfg.MakeMKVPath)
		}

		fmt.Print("Minimum title length in seconds (e.g. 900) for 15m: ")
		minStr, _ := reader.ReadString('\n')
		minStr = strings.TrimSpace(minStr)
		fmt.Sscanf(minStr, "%d", &cfg.MinSeconds)

		if err := SaveConfig(*configPath, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to save config: %v\n", err)
		} else {
			fmt.Printf("Config saved to %s\n", *configPath)
		}
	} else {
		fmt.Println("Proceeding with CLI flags...")
	}

	if !ValidatePaths(cfg) {
	}

	server, err := NewMKVServer(cfg.MakeMKVPath)
	server.TargetDrive = cfg.DriveLetter

	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start MKV server: %v\n", err)
		os.Exit(1)
	}
	defer server.Close()

	setScrollRegion(5)
	stopResize := make(chan struct{})
	go server.watchResize(stopResize)
	defer close(stopResize)

	// 1. Handle Graceful Exit (Ctrl+C)
	setupCloseHandler()

	fmt.Printf("Starting MakeMKV Go-Auto...\n")
	fmt.Printf("MakeMKV Go-Auto is Running\n")

	// 2. Main Exec Loop
	for {
		_, height, _ := term.GetSize(int(os.Stdout.Fd()))
		fmt.Printf("\033[%d;0H", height-5)

		if server.isDead {
			fmt.Println("MakeMKV server connection lost. Attempting to restart...")
			server.Close() // Clean up old process
			var err error
			server, err = NewMKVServer(cfg.MakeMKVPath)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Failed to restart MKV server: %v\n", err)
				os.Exit(1) // Or maybe sleep and retry
			}
			fmt.Println("MakeMKV server restarted successfully.")
		}

		// Wait for disc
		server.currentStage = "Waiting for disc..."
		server.drawStatusLines()

		// Reset from prior rip
		server.DiscReady = false
		server.isRipping = false

		// Trigger the initial drive enumeration.
		server.currentStage = "Scanning Drives..."
		server.drawStatusLines()
		server.OnIdle()
		server.ScanDrives()

		// 3. Poll for the server's response.
		driveTimeout := time.Now().Add(15 * time.Second)
		driveIndex := -1

		for driveIndex == -1 && time.Now().Before(driveTimeout) {
			server.OnIdle()
			time.Sleep(500 * time.Millisecond)

			for _, d := range server.Drives {
				if strings.Contains(strings.ToUpper(d.Device), strings.ToUpper(cfg.DriveLetter)) &&
					d.State != AP_DriveStateNoDrive { // Find the first valid entry for our drive
					driveIndex = d.Index
					break
				}
			}
		}

		if driveIndex == -1 {
			server.OnIdle()
			server.ScanDrives()
			continue
		}

		// At this point, the GUI would show a dialog. Since this is an automation tool,
		// we already know which drive we want. We now tell the server to open that specific drive by its index.
		// This is the action that will cause the single, selected drive to spin up.
		debugLog("Opening disc by index: %d", driveIndex)
		debugLog("Pre-scan: CollectionHandle=%d TitleCount=%d", server.CollectionHandle, server.TitleCount)
		if err := server.OpenCdDisk(uint32(driveIndex)); err != nil {
			fmt.Printf("Failed to open disc by index: %v\n", err)
			continue
		}

		// The server will now perform a targeted scan on the selected drive.
		// We wait for the apBackLeaveJobMode callback, which sets DiscReady to true.

		//fmt.Printf("Drive Index: %d\n", driveIndex)
		debugLog("Drive Index: %d\n", driveIndex)
		//fmt.Println("Scanning Disc Info...")

		debugLog("Opening disc: driveIndex=%d, drive device=%q label=%q state=%d", driveIndex, server.Drives[driveIndex].Device, server.Drives[driveIndex].Label, server.Drives[driveIndex].State)

		fmt.Println("Waiting for disc scan...")
		deadline := time.Now().Add(240 * time.Second)
		for !server.DiscReady && time.Now().Before(deadline) {
			time.Sleep(300 * time.Millisecond)
			server.OnIdle()
		}
		if !server.DiscReady {
			fmt.Println("Disc scan timed out")
			continue
		}

		info, err := server.ScanDisc()
		if err != nil {
			fmt.Printf("Failed to scan disc: %v\n", err)
			debugLog("Drive Index %d", driveIndex)
			debugLog("Drive state %d", server.Drives[driveIndex].State)
			debugLog("server.DiscReady: %b", server.DiscReady)
			continue
		}

		if info.Title != "" {
			// Allow user to edit disc title before TMDB search
			cleanTitle := CleanTitle(info.Title)

			fmt.Printf("Title detected: %s\n", cleanTitle)
			fmt.Println("Press Enter to edit, any other key to continue (30s)...")

			// Keepalive during user input
			keepalive := make(chan struct{})
			go func() {
				ticker := time.NewTicker(60 * time.Second)
				defer ticker.Stop()
				for {
					select {
					case <-ticker.C:
						server.OnIdle()
					case <-keepalive:
						return
					}
				}
			}()

			keyCh := make(chan byte, 1)
			go func() {
				oldState, err := term.MakeRaw(int(os.Stdin.Fd()))
				if err != nil {
					keyCh <- 0
					return
				}
				defer term.Restore(int(os.Stdin.Fd()), oldState)
				var buf [1]byte
				os.Stdin.Read(buf[:])
				if buf[0] == 3 {
					term.Restore(int(os.Stdin.Fd()), oldState)
					resetScrollRegion()
					fmt.Println("\n- Ctrl+C pressed. Cleaning up processes and exiting")
					os.Exit(0)
				}
				keyCh <- buf[0]
			}()

			userTitle := cleanTitle
			select {
			case key := <-keyCh:
				fmt.Println()
				if key == 13 {
					fmt.Print("Enter new title: ")
					reader := bufio.NewReader(os.Stdin)
					newTitle, _ := reader.ReadString('\n')
					newTitle = strings.TrimSpace(newTitle)
					if newTitle != "" {
						userTitle = newTitle
					}
				}
			case <-time.After(30 * time.Second):
				fmt.Println("\nContinuing...")
			}
			close(keepalive)

			fmt.Println("Processing cuts...")
			ProcessCuts(&info)

			fmt.Println("Identifying video via TMDB...")
			RunParallelLookups(&info, TmdbKey, userTitle)

			// Find theatrical runtime (shortest match)
			theatricalMinutes := math.MaxInt32
			for _, m := range info.Matches {
				cut := info.DistinctCuts[m.Index]
				if cut.Minutes < theatricalMinutes {
					theatricalMinutes = cut.Minutes
				}
			}
			// Flag extended cuts
			for i, m := range info.Matches {
				cut := info.DistinctCuts[m.Index]
				if cut.Minutes > theatricalMinutes {
					info.Matches[i].IsExtended = cut.Minutes > theatricalMinutes+20
				}
			}

			// Resolve disc-level identity once - all cuts share same folder
			imdbID := "unknown"
			encodingTitle := CleanTitle(userTitle)
			year := ""
			if len(info.Matches) > 0 {
				m := info.Matches[0]
				if m.ImdbID != "" {
					imdbID = m.ImdbID // {imdb-tt123456}
				}
				encodingTitle = CleanTitle(m.Title) // The Nut Job 2
				year = m.Year                       // (2022)
			}
			yearPart := ""
			if year != "" {
				yearPart = fmt.Sprintf("(%s)", year) // (2022)
			}
			encodingDir := fmt.Sprintf("%s %s {imdb-%s}", encodingTitle, yearPart, imdbID) // The Nut Job 2 (2022) {imdb-tt123456}
			encodingTitleName := fmt.Sprintf("%s %s", encodingTitle, yearPart)             // The Nut Job 2 (2022)
			fullTempPath := filepath.Join(cfg.DestPath, encodingDir)                       // G:\makemkvcon\The Nut Job 2 (2022) {imdb-tt123456}
			debugLog("Video Encoding Title: %s", encodingTitle)
			debugLog("Video Encoding Title Name: %s", encodingTitleName)
			debugLog("Video Encoding Dir: %s", encodingDir)
			debugLog("Video Temp path: %s", fullTempPath)
			if err := os.MkdirAll(fullTempPath, 0755); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to create temp directory %q: %v\n", fullTempPath, err)
				continue
			}

			for _, cut := range info.DistinctCuts {
				var vidDef string
				switch {
				case cut.Height <= 576:
					vidDef = "SD"
				case cut.Height == 720:
					vidDef = "HD"
				case cut.Height == 1080:
					vidDef = "1080p"
				case cut.Height == 2160:
					vidDef = "4K"
				default:
					vidDef = ""
				}

				var extendedSuffix string
				for _, m := range info.Matches {
					if m.Index == cut.Index {
						if m.IsExtended {
							extendedSuffix = " - {edition-Extended}"
						}
						break
					}
				}

				encodingTrackName := fmt.Sprintf("%s %s%s - %s", encodingTitle, yearPart, extendedSuffix, vidDef)         // The Nut Job 2 (2022) - {edition-Extended} - SD
				encodingTrackFileName := fmt.Sprintf("%s %s%s - %s.mkv", encodingTitle, yearPart, extendedSuffix, vidDef) // The Nut Job 2 (2022) - {edition-Extended} - SD.mkv

				debugLog("Cut #%d: encodingTitle='%s' yearPart='%s' imdbID='%s'", cut.Index, encodingTitle, yearPart, imdbID)
				debugLog("Cut #%d: encodingDir: %s", cut.Index, encodingDir)
				debugLog("Cut #%d: origName: %s", cut.Index, cut.FileName)
				debugLog("Cut #%d: newFileName: %s", cut.Index, encodingTrackFileName)
				debugLog("Cut #%d: definition: %s", cut.Index, vidDef)
				debugLog("Cut #%d: resolution: %s", cut.Index, cut.Resolution)
				debugLog("Cut #%d: width: %d", cut.Index, cut.Width)
				debugLog("Cut #%d: height: %d", cut.Index, cut.Height)
				debugLog("Cut #%d: fileSize: %s", cut.Index, cut.FileSize)
				debugLog("Cut #%d: fullTempPath: %s", cut.Index, fullTempPath)
				debugLog("Cut #%d: DestPath: %s", cut.Index, cfg.DestPath)

				expectedFile := filepath.Join(fullTempPath, encodingTrackFileName)

				for {
					if _, err := os.Stat(expectedFile); err != nil {
						break //  file doesnt exist, proceed
					}
					fmt.Printf("File already exists: %s\n", encodingTrackFileName)
					fmt.Println("[R]ename  [O]verwrite  [S]kip  (30s to skip)...")
					// Keepalive during user input
					keepalive := make(chan struct{})
					go func() {
						ticker := time.NewTicker(60 * time.Second)
						defer ticker.Stop()
						for {
							select {
							case <-ticker.C:
								server.OnIdle()
							case <-keepalive:
								return
							}
						}
					}()
					keyCh := make(chan byte, 1)
					go func() {
						oldState, err := term.MakeRaw(int(os.Stdin.Fd()))
						if err != nil {
							keyCh <- 's'
							return
						}
						defer term.Restore(int(os.Stdin.Fd()), oldState)
						var buf [1]byte
						os.Stdin.Read(buf[:])
						if buf[0] == 3 {
							term.Restore(int(os.Stdin.Fd()), oldState)
							resetScrollRegion()
							fmt.Println("\n- Ctrl+C pressed. Cleaning up processes and exiting")
							os.Exit(0)
						}
						keyCh <- buf[0]
					}()

					var action byte
					select {
					case action = <-keyCh:
					case <-time.After(30 * time.Second):
						action = 's'
					}
					fmt.Println()

					switch action {
					case 'r', 'R':
						fmt.Print("Enter new filename (without extension): ")
						reader := bufio.NewReader(os.Stdin)
						newName, _ := reader.ReadString('\n')
						newName = strings.TrimSpace(newName)
						if newName != "" {
							encodingTrackFileName = newName + ".mkv"
							encodingTrackName = newName
							expectedFile = filepath.Join(fullTempPath, encodingTrackFileName)
						}
						// loop back to re-check
					case 'o', 'O':
						if err := os.Remove(expectedFile); err != nil {
							fmt.Fprintf(os.Stderr, "Failed to remove existing file: %v\n", err)

						} // loop back to re-check/prompt
					default: // 's', 'S', timeout
						fmt.Printf("Skipping: %s\n", encodingTrackFileName)
						goto nextCut
					}

					if _, err := os.Stat(expectedFile); err != nil {
						break // resolved
					}

					close(keepalive)

				}

				titleHandle := server.Titles[cut.Index].Handle
				if titleHandle == 0 {
					fmt.Fprintf(os.Stderr, "Error: title %d has no handle, skipping\n", cut.Index)
					continue
				}

				// Deselect all titles, then select only this cut
				for i, t := range server.Titles {
					if t.Handle != 0 {
						if err := server.SetTitleSelected(i, false); err != nil {
							debugLog("SetTitleSelected(false) failed for handle %d: %v", i, err)
						}
					}
				}

				if err := server.SetTitleSelected(cut.Index, true); err != nil {
					fmt.Fprintf(os.Stderr, "Error: SetTitleSelected(true) failed: %v\n", err)
					continue
				}

				if err := server.SetDefaultOutputFileName(encodingTrackName); err != nil {
					debugLog("SetDefaultOutputFileName failed: %v", err)
				} else {
					debugLog("SetDefaultOutputFileName success")
				}

				// Verify the name was actually accepted
				if actual, err := server.GetUiItemInfo(titleHandle, ap_iaOutputFileName); err == nil {
					if actual != encodingTrackFileName {
						fmt.Fprintf(os.Stderr, "Warning: MakeMKV rejected filename %q, will rip as %q\n", encodingTrackFileName, actual)
					}
					//debugLog(">>> Info: Server filename %q\n", actual)
				}

				if err := server.SetOutputFolder(fullTempPath); err != nil {
					fmt.Fprintf(os.Stderr, "Error: SetOutputFolder() failed: %v\n", err)
					continue
				}

				fmt.Printf("Ripping track %d: %s\n", cut.Index, encodingTrackName)

				server.DiscReady = false
				ripErr := server.SaveAllTitles()

				// SaveAllTitles is async — poll OnIdle until LeaveJobMode sets DiscReady
				for !server.DiscReady {
					time.Sleep(500 * time.Millisecond)
					server.OnIdle()
				}

				if ripErr != nil {
					fmt.Fprintf(os.Stderr, "Rip failed for title %d: %v\n", cut.Index, ripErr)
					continue
				}
			}
		nextCut:
			server.currentStage = ""
			server.currentSource = ""
			server.currentFile = ""
			server.currentSize = ""
			server.currentRate = ""
			server.currentOutput = ""
			server.currentOutSize = ""
			server.currentBar = 0
			server.totalBar = 0
			server.drawStatusLines()
			_, height, _ := term.GetSize(int(os.Stdout.Fd()))
			fmt.Printf("\033[%d;0H", height-5)

			ejectDrive(cfg.DriveLetter)
			for discReady(cfg.DriveLetter) {
				time.Sleep(500 * time.Millisecond)
				server.OnIdle()
			}

			// Invalidate stale drive entry before scanning
			for i := range server.Drives {
				if strings.Contains(strings.ToUpper(server.Drives[i].Device), strings.ToUpper(cfg.DriveLetter)) {
					server.Drives[i].State = AP_DriveStateNoDrive
					break
				}
			}
			fmt.Println()
		}
	}
}

func CleanTitle(s string) string {
	// Strip disc volumename noise
	noisePattern := regexp.MustCompile(`(?i)[-_ ]?(BLU[- ]?RAY|DVD|DISC\s?\d+|SPECIAL_FEATURES|#.*).*$`)
	s = noisePattern.ReplaceAllString(s, "")
	// Collapse spaces
	spacePattern := regexp.MustCompile(`\s+`)
	s = spacePattern.ReplaceAllString(s, " ")
	s = strings.TrimSpace(s)
	// Strips illegal NTFS filename characters
	var b strings.Builder
	for _, r := range s {
		switch r {
		case ':':
			b.WriteRune('-')
		case '_':
			b.WriteRune(' ')
		case '\\', '/', '*', '?', '"', '<', '>', '|':
			// drop
		default:
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}

func setupCloseHandler() {
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		resetScrollRegion()
		fmt.Println("\n- Ctrl+C pressed. Cleaning up processes and exiting")
		os.Exit(0)
	}()
}

func debugLog(format string, args ...interface{}) {
	if debugMode {
		fmt.Printf("[DEBUG] "+format+"\n", args...)
	}
}

func discReady(letter string) bool {
	// Try to open key files to ensure filesystem is responsive, like in the PowerShell script.
	ifoPath := filepath.Join(letter, "VIDEO_TS", "VIDEO_TS.IFO")
	if f, err := os.Open(ifoPath); err == nil {
		f.Close()
		debugLog("\ndiscReady: Found and opened %s", ifoPath)
		return true
	}

	bdmvPath := filepath.Join(letter, "BDMV", "index.bdmv")
	if f, err := os.Open(bdmvPath); err == nil {
		f.Close()
		debugLog("discReady: Found and opened %s", bdmvPath)
		return true
	}

	// Fallback for discs that might not have those exact files but are ready.
	_, errIFO := os.Stat(filepath.Join(letter, "VIDEO_TS"))
	_, errBDMV := os.Stat(filepath.Join(letter, "BDMV"))
	return errIFO == nil || errBDMV == nil
}

func userConfirmed() bool {
	reader := bufio.NewReader(os.Stdin)
	text, _ := reader.ReadString('\n')
	return strings.ToLower(strings.TrimSpace(text)) == "y"
}

func RunParallelLookups(info *DiscInfo, apiKey string, userTitle string) {
	var wg sync.WaitGroup
	// Mutex to safely write to the slice from multiple goroutines
	var mu sync.Mutex

	for _, cut := range info.DistinctCuts {
		wg.Add(1)
		go func(c TitleMetadata) {
			defer wg.Done()

			match, method := SearchMovieMatch(userTitle, c.Minutes, apiKey)

			mu.Lock()
			if match != nil {
				year := ""
				if len(match.ReleaseDate) >= 4 {
					year = match.ReleaseDate[:4]
				}
				info.Matches = append(info.Matches, MatchResult{
					Index:       c.Index,
					Title:       match.Title,
					Year:        year,
					ImdbID:      match.ImdbID,
					Method:      method,
					NeedsReview: method != "Runtime Match",
				})
				fmt.Printf("  Cut #%d: Found %s via %s\n", c.Index, match.Title, method)
			} else {
				fmt.Printf("  Cut #%d: No match found (%s)\n", c.Index, method)
			}
			// Store results in logic
			mu.Unlock()
		}(cut)
	}
	wg.Wait()
}

func setScrollRegion(reserve int) {
	_, height, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil {
		return
	}
	// Set scroll region to all lines except bottom `reserve` lines
	debugLog("setScrollRegion: height=%d reserve=%d scrollEnd=%d", height, reserve, height-reserve)
	fmt.Printf("\033[1;%dr\033[3J", height-reserve)
	// Clear the reserved lines
	for i := 0; i < reserve; i++ {
		fmt.Printf("\033[%d;0H\033[K", height-reserve+1+i)
	}
	// Move cursor back to top of scroll region
	fmt.Printf("\033[%d;0H", height-reserve)
}

func resetScrollRegion() {
	_, height, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil {
		return
	}
	// Clear the scroll region
	for i := 0; i < 5; i++ {
		fmt.Printf("\033[%d;0H\033[K", height-4+i)
	}
	// Reset scroll region to full term
	fmt.Printf("\033[1;%dr", height)
	// Move cursor to bottomm
	fmt.Printf("\033[%d;0H", height-5)
}
