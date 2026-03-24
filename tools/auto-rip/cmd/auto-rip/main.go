package main

import (
	"bufio"
	"bytes"
	"context"
	_ "embed"
	"flag"
	"fmt"
	"image"
	"math"
	"media-archival/v7/internal/config"
	"media-archival/v7/internal/globals"
	log "media-archival/v7/internal/logger"
	"media-archival/v7/internal/mkv"
	"media-archival/v7/internal/models"
	"media-archival/v7/internal/processor"
	tmdb "media-archival/v7/internal/tmdb"
	"media-archival/v7/internal/ui"
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

	"github.com/blacktop/go-termimg"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

//go:embed makemkv.png
var embeddedLogo []byte

// Global Config (PS1 param block)
var (
	TmdbKey = os.Getenv("TMDB_API")
	//debugMode       bool
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
	flag.IntVar(&globals.LogLevel, "log-level", -1, "")
	flag.IntVar(&globals.LogLevel, "V", -1, "")
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

	minLength := flag.String("min-length", "", "")
	flag.StringVar(minLength, "L", "", "")

	flag.Usage = func() {
		exeName := filepath.Base(os.Args[0])

		log.Log(-1, "Automated MakeMKV utility.\n")
		log.Log(-1, "  Usage of %s:", exeName)

		log.Log(-1, "  -H, --help\n\tPrints this help message\n")
		log.Log(-1, "  -V, --debug [int]\n\tEnable  logging at syslog level [int]\n\n")
		log.Log(-1, "  -C, --config [string]\n\tPath to new/existing config file (default \"config.json\")\n\t"+
			"  config file used for static/normal defaults. Flags override config.\n\t  disc drive, API key, destination dir\n\n")
		log.Log(-1, "  -T, --drive <driveletter:> - i.e. --drive D:\n\tSpecifies the disc drive to use\n\n")
		log.Log(-1, "  -S, --setup\n\tEnters config setup mode\n\n")
		log.Log(-1, "  -K, --apikey <key> - i.e. --apikey 123ABC\n\tSpecifies the TMDB API key to use for title matching\n\n")
		log.Log(-1, "  -D, --dest <dir> - i.e. --dest C:\\Path\\to\\Final\\\n\tSpecifies the path to use as the base directory for final location\n\n")
		log.Log(-1, "  -M, --makemkv <dir> - i.e. --dest C:\\Path\\to\\makemkvcon.exe\\\n\tSpecifies the path to use for MakeMKV binary\n\n")
		log.Log(-1, "  -L, --min-length [900] - i.e. --min-length 300\n\tSpecifies a minimum title length in seconds (e.g. 300 = 5m). Absent this, will rip all titles\n\n")
		//flag.PrintDefaults() // Prints alphabetically
	}
	flag.Parse()

	// 1. Handle Graceful Exit (Ctrl+C)
	setupCloseHandler()

	if globals.LogLevel >= 0 {
		globals.DebugMode = true
	} else {
		ui.SetScrollRegion(5)
	}

	var cfg config.Config

	defaultMKVPaths := []string{
		`C:\Program Files (x86)\MakeMKV\makemkvcon64.exe`,
		`C:\Program Files\MakeMKV\makemkvcon64.exe`,
		`C:\Program Files (x86)\MakeMKV\makemkvcon.exe`,
		`C:\Program Files\MakeMKV\makemkvcon.exe`,
	}
	cfg.MakeMKVPath = ""

	// Height=256, Width=256
	img, _, _ := image.Decode(bytes.NewReader(embeddedLogo))
	//dst := image.NewRGBA(image.Rect(0, 0, 128, 128))
	//draw.ApproxBiLinear.Scale(dst, dst.Bounds(), img, img.Bounds(), draw.Over, nil)

	termimg.Print(img)
	fmt.Printf("\n")
	fmt.Printf("\n")

	var configFound bool

	if configSetup || *configPath != "" {
		// Load config based on flag
		if _, err := os.Stat(*configPath); err == nil {

			log.Log(-1, "Loading config from %s...", *configPath)
			cfg, _ = config.LoadConfig(*configPath)
			configFound = true
		} else {

			log.Log(-1, "Config file not found")
			configFound = false
		}
	}

	for _, p := range defaultMKVPaths {
		if _, err := os.Stat(p); err == nil {
			cfg.MakeMKVPath = p
			log.Log(-1, "MakeMKV found at: %s", p)
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
	if *minLength != "" {
		fmt.Sscanf(*minLength, "%d", &cfg.MinSeconds)
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
			log.Log(-1, "Missing required arguments:")
			for _, arg := range missingArgs {
				log.Log(-1, "  %s\n", arg)
			}
		}

		log.Log(-1, "Would you like to create a config file [Y]/n: ")

		keyCh, oldState := inputLoop()

		var key byte
		select {
		case key = <-keyCh:
		case <-time.After(30 * time.Second):
			log.Log(-1, "Timeout reached. Defaulting to 'n'.")
			key = 'n'
			if oldState != nil {
				term.Restore(int(os.Stdin.Fd()), oldState)
			}
			select {
			case <-keyCh:
			default:
			}
		}
		key = byte(unicode.ToLower(rune(key)))

		switch key {
		case '\n', 'y':
			configSetup = true
		case 'n':
			log.Log(-1, "See help `rip-auto -H` for usage information.")
			os.Exit(0)
		default:
			log.Log(-1, "Invalid key. Expected Y or N.")
			os.Exit(1)
		}

	} else if configSetup || (*configPath != "" && configFound == false) {
		log.Log(-1, "No config file found. Let's create one.")
		log.Log(-1, "Entering config setup mode...")
		reader := bufio.NewReader(os.Stdin)

		log.Log(-1, "Drive letter (e.g. D:): ")
		cfg.DriveLetter, _ = reader.ReadString('\n')
		cfg.DriveLetter = strings.TrimSpace(cfg.DriveLetter)

		log.Log(-1, "TMDB API key: ")
		cfg.APIKey, _ = reader.ReadString('\n')
		cfg.APIKey = strings.TrimSpace(cfg.APIKey)

		log.Log(-1, "Destination Directory (e.g. E:\\Movies): ")
		cfg.DestPath, _ = reader.ReadString('\n')
		cfg.DestPath = strings.TrimSpace(cfg.DestPath)

		for _, p := range defaultMKVPaths {
			if _, err := os.Stat(p); err == nil {
				cfg.MakeMKVPath = p
				log.Log(-1, "MakeMKV found at: %s", p)
				break
			}
		}
		if cfg.MakeMKVPath == "" {
			log.Log(-1, "MakeMKV executable path (e.g. C:\\Program Files (x86)\\MakeMKV\\makemkvcon.exe): ")
			cfg.MakeMKVPath, _ = reader.ReadString('\n')
			cfg.MakeMKVPath = strings.TrimSpace(cfg.MakeMKVPath)
		}

		log.Log(-1, "Minimum title length in seconds (e.g. 900) for 15m: ")
		minStr, _ := reader.ReadString('\n')
		minStr = strings.TrimSpace(minStr)
		fmt.Sscanf(minStr, "%d", &cfg.MinSeconds)

		if err := config.SaveConfig(*configPath, cfg); err != nil {
			log.Log(4, "Failed to save config: %v\n", err)
		} else {
			log.Log(5, "Config saved to %s\n", *configPath)
		}
	} else {
		log.Log(-1, "Proceeding with CLI flags...")
	}

	if !config.ValidatePaths(cfg) {
	}

	log.Log(-1, "Starting MakeMKV Go-Auto...")

	if globals.LogLevel >= 0 {
		log.Log(0, "Log Level: %d\n", globals.LogLevel)
	}
	dots := []string{".   ", "..  ", "... ", "...."}
	for i := 0; !mkv.DiscReady(filepath.VolumeName(cfg.DriveLetter) + "\\"); i++ {
		fmt.Printf("\033[K\rWaiting for OS to present disc%s\033[K", dots[i%4])
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Println()

	server, err := mkv.NewMKVServer(cfg.MakeMKVPath)
	if err != nil {
		log.Log(0, "Failed to start MKV server: %v", err)
		os.Exit(1)
	}
	server.TargetDrive = cfg.DriveLetter
	defer server.Close()

	server.CurrentStage = "Starting MakeMKV"
	server.DrawStatusLines()

	if cfg.MinSeconds > 0 {
		if err := server.SetMinTitleLength(cfg.MinSeconds); err != nil {
			log.Log(4, "Failed to set minimum title length: %v", err)
		} else {
			log.Log(6, "Minimum title length: %ds (%dm)", cfg.MinSeconds, cfg.MinSeconds/60)
		}
	}

	server.CurrentStage = "MakeMKV Go-Auto is Running"
	server.DrawStatusLines()

	if globals.LogLevel < 0 {
		stopResize := make(chan struct{})
		go server.WatchResize(stopResize)
		defer close(stopResize)

		server.CurrentStage = "Scanning Drives..."
		server.DrawStatusLines()
	}

	// Trigger the initial drive enumeration.
	server.OnIdle()
	server.ScanDrives()

	// 2. Main Exec Loop
	for {
		// Invalidate stale drive entry before scanning
		for i := range server.Drives {
			if strings.Contains(strings.ToUpper(server.Drives[i].Device), strings.ToUpper(cfg.DriveLetter)) {
				server.Drives[i].State = mkv.AP_DriveStateNoDrive
				break
			}
		}

		if globals.LogLevel < 0 {
			server.CurrentStage = ""
			server.CurrentSource = ""
			server.CurrentFile = ""
			server.CurrentSize = ""
			server.CurrentRate = ""
			server.CurrentOutput = ""
			server.CurrentOutSize = ""
			server.CurrentBar = 0
			server.TotalBar = 0
			server.DrawStatusLines()

			_, height, _ := term.GetSize(int(os.Stdout.Fd()))
			fmt.Printf("\033[%d;0H", height-5)
		}

		if server.IsDead {
			log.Log(-1, "MakeMKV server connection lost. Attempting to restart...")
			server.Close() // Clean up old process
			server, err := mkv.NewMKVServer(cfg.MakeMKVPath)
			if err != nil {
				log.Log(3, "Failed to start MKV server: %v\n", err)
				os.Exit(1) // Or maybe sleep and retry
			}
			server.TargetDrive = cfg.DriveLetter
			if cfg.MinSeconds > 0 {
				if err := server.SetMinTitleLength(cfg.MinSeconds); err != nil {
					log.Log(3, "Warning: failed to set minimum title length: %v\n", err)
				} else {
					log.Log(7, "Minimum title length: %ds (%dm)\n", cfg.MinSeconds, cfg.MinSeconds/60)
				}
			}
			server.ScanDrives()

			log.Log(-1, "MakeMKV server restarted successfully.")
		}

		if globals.LogLevel < 0 {
			server.CurrentStage = "Waiting for disc..."
			server.DrawStatusLines()
		}
		dots := []string{".   ", "..  ", "... ", "...."}
		var cRLF string
		if globals.LogLevel < 0 {
			cRLF = "\r"
		} else {
			cRLF = "\n"
		}
		fmt.Println()

		for i := 0; !mkv.DiscReady(filepath.VolumeName(cfg.DriveLetter) + "\\"); i++ {
			fmt.Printf("\033[K%sWaiting for disc%s\033[K", cRLF, dots[i%4])
			time.Sleep(500 * time.Millisecond)
			server.OnIdle()
		}
		server.ScanDrives()
		time.Sleep(500 * time.Millisecond)
		fmt.Println()

		// Wait for disc
		server.CurrentStage = "Waiting for disc..."
		server.DrawStatusLines()

		// Reset from prior rip
		server.DiscReady = false
		server.IsRipping = false
		server.UpdateDrives()

		// 3. Poll for the server's response.
		driveTimeout := time.Now().Add(15 * time.Second)
		driveIndex := -1

		for driveIndex == -1 && time.Now().Before(driveTimeout) {
			server.OnIdle()
			time.Sleep(500 * time.Millisecond)

			for _, d := range server.Drives {
				if strings.Contains(strings.ToUpper(d.Device), strings.ToUpper(cfg.DriveLetter)) &&
					d.State != mkv.AP_DriveStateNoDrive { // Find the first valid entry for our drive
					driveIndex = d.Index
					break
				}
			}
		}

		if driveIndex == -1 {
			server.OnIdle()
			server.UpdateDrives()
			continue
		}

		// At this point, the GUI would show a dialog. Since this is an automation tool,
		// we already know which drive we want. We now tell the server to open that specific drive by its index.
		// This is the action that will cause the single, selected drive to spin up.
		log.Log(6, "Opening disc by index: %d", driveIndex)
		log.Log(6, "Pre-scan: CollectionHandle=%d TitleCount=%d", server.CollectionHandle, server.TitleCount)
		if err := server.OpenCdDisk(uint32(driveIndex)); err != nil {
			log.Log(3, "Failed to open disc by index: %v\n", err)
			continue
		}

		// The server will now perform a targeted scan on the selected drive.
		// We wait for the apBackLeaveJobMode callback, which sets DiscReady to true.

		log.Log(6, "Drive Index: %d\n", driveIndex)
		log.Log(6, "Opening disc: driveIndex=%d, drive device=%q label=%q state=%d", driveIndex, server.Drives[driveIndex].Device, server.Drives[driveIndex].Label, server.Drives[driveIndex].State)
		//log.Log(-1, "Waiting for disc scan...")
		server.CurrentStage = "Waiting for disc scan"

		deadline := time.Now().Add(240 * time.Second)
		for !server.DiscReady && time.Now().Before(deadline) {
			time.Sleep(300 * time.Millisecond)
			server.OnIdle()
		}
		if !server.DiscReady {
			log.Log(1, "Disc scan timed out")
			continue
		}

		info, err := server.ScanDisc()
		if err != nil {
			log.Log(1, "Failed to scan disc: %v\n", err)
			log.Log(1, "Drive Index %d", driveIndex)
			log.Log(1, "Drive state %d", server.Drives[driveIndex].State)
			log.Log(1, "server.DiscReady: %b", server.DiscReady)
			continue
		}

		if info.Title != "" {
			// Allow user to edit disc title before TMDB search
			cleanTitle := CleanTitle(info.Title)

			log.Log(-1, "Title detected: %s\n", cleanTitle)
			log.Log(-1, "Press Enter to edit, any other key to continue (30s)...")

			// Keepalive during user input
			start, stopKeepalive := context.WithCancel(context.Background())
			serverKeepalive(start, server)

			keyCh, oldState := inputLoop()

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
				if oldState != nil {
					term.Restore(int(os.Stdin.Fd()), oldState)
				}
				log.Log(-1, "\nContinuing...")
			}
			stopKeepalive()
			select {
			case <-keyCh:
			default:
			}

			log.Log(-1, "Processing cuts...")
			processor.ProcessCuts(&info, cfg.MinSeconds)

			log.Log(-1, "Identifying video via TMDB...")
			RunParallelLookups(&info, TmdbKey, userTitle)

			// Find theatrical runtime (shortest match)
			theatricalMinutes := math.MaxInt32
			for _, m := range info.Matches {
				for _, cut := range info.DistinctCuts {
					if cut.Index == m.Index && cut.Minutes < theatricalMinutes {
						theatricalMinutes = cut.Minutes
					}
				}
			}
			// Flag extended cuts
			for i, m := range info.Matches {
				for _, cut := range info.DistinctCuts {
					if cut.Index == m.Index && cut.Minutes > theatricalMinutes {
						info.Matches[i].IsExtended = cut.Minutes > theatricalMinutes+20
					}
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
			log.Log(7, "Video Encoding Title: %s", encodingTitle)
			log.Log(7, "Video Encoding Title Name: %s", encodingTitleName)
			log.Log(7, "Video Encoding Dir: %s", encodingDir)
			log.Log(7, "Video Temp path: %s", fullTempPath)
			if err := os.MkdirAll(fullTempPath, 0755); err != nil {
				log.Log(1, "Failed to create temp directory %q: %v\n", fullTempPath, err)
				continue
			}

			if err := server.SetOutputFolder(fullTempPath); err != nil {
				log.Log(1, "Error: SetOutputFolder() failed: %v\n", err)
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

				log.Log(7, "Cut #%d: encodingTitle='%s' yearPart='%s' imdbID='%s'", cut.Index, encodingTitle, yearPart, imdbID)
				log.Log(7, "Cut #%d: encodingDir: %s", cut.Index, encodingDir)
				log.Log(7, "Cut #%d: origName: %s", cut.Index, cut.FileName)
				log.Log(7, "Cut #%d: newFileName: %s", cut.Index, encodingTrackFileName)
				log.Log(7, "Cut #%d: definition: %s", cut.Index, vidDef)
				log.Log(7, "Cut #%d: resolution: %s", cut.Index, cut.Resolution)
				log.Log(7, "Cut #%d: width: %d", cut.Index, cut.Width)
				log.Log(7, "Cut #%d: height: %d", cut.Index, cut.Height)
				log.Log(7, "Cut #%d: fileSize: %s", cut.Index, cut.FileSize)
				log.Log(7, "Cut #%d: fullTempPath: %s", cut.Index, fullTempPath)
				log.Log(7, "Cut #%d: DestPath: %s", cut.Index, cfg.DestPath)

				expectedFile := filepath.Join(fullTempPath, encodingTrackFileName)

				for {
					if _, err := os.Stat(expectedFile); err != nil {
						break //  file doesnt exist, proceed
					}
					log.Log(-1, "File already exists: %s\n", encodingTrackFileName)
					log.Log(-1, "[R]ename  [O]verwrite  [S]kip  (30s to skip)...")

					// Keepalive during user input
					start, stopKeepalive := context.WithCancel(context.Background())
					serverKeepalive(start, server)

					keyCh, oldState := inputLoop()

					var action byte
					select {
					case action = <-keyCh:
					case <-time.After(30 * time.Second):
						if oldState != nil {
							term.Restore(int(os.Stdin.Fd()), oldState)
						}
						action = 's'
					}
					fmt.Println()

					select {
					case <-keyCh:
					default:
					}

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
							log.Log(3, "Failed to remove existing file: %v\n", err)

						} // loop back to re-check/prompt
					default: // 's', 'S', timeout
						log.Log(-1, "Skipping: %s\n", encodingTrackFileName)
						goto nextDisc
					}

					if _, err := os.Stat(expectedFile); err != nil {
						break // resolved
					}
					stopKeepalive()
				}

				titleHandle := server.Titles[cut.Index].Handle
				if titleHandle == 0 {
					log.Log(3, "Error: title %d has no handle, skipping\n", cut.Index)
					continue
				}

				// Deselect all titles, then select only this cut
				for i, t := range server.Titles {
					if t.Handle != 0 {
						if err := server.SetTitleSelected(i, false); err != nil {
							log.Log(3, "SetTitleSelected(false) failed for handle %d: %v", i, err)
						}
					}
				}
				if err := server.SetTitleSelected(cut.Index, true); err != nil {
					log.Log(3, "SetTitleSelected(true) failed: %v\n", err)
					continue
				}

				if err := server.SetDefaultOutputFileName(encodingTrackName); err != nil {
					log.Log(4, "SetDefaultOutputFileName failed: %v", err)
				} else {
					log.Log(7, "SetDefaultOutputFileName success")
				}

				// Verify the name was actually accepted
				outputFileNameKey := mkv.GetOutputFileNameKey()
				if actual, err := server.GetUiItemInfo(titleHandle, outputFileNameKey); err == nil {
					if actual != encodingTrackFileName {
						log.Log(4, "MakeMKV rejected filename %q, will rip as %q", encodingTrackFileName, actual)
					}
					log.Log(6, "MakeMKV accepted filename %q", actual)
				} else {
					log.Log(4, "Unable to set MakeMKV filename %q, because: %q", encodingTrackFileName, err)
				}

				log.Log(-1, "Ripping track %d: %s\n", cut.Index, encodingTrackName)

				server.DiscReady = false
				ripErr := server.SaveAllTitles()

				// SaveAllTitles is async — poll OnIdle until LeaveJobMode sets DiscReady
				for !server.DiscReady {
					time.Sleep(500 * time.Millisecond)
					server.OnIdle()
				}

				// --- Rip validation (makemkvcon exits 0 even on read errors) ---
				ripFailed := false

				// 1. Protocol-level error (pipe died, IPC fault, etc.)
				if ripErr != nil {
					log.Log(3, "Rip IPC error for title %d: %v\n", cut.Index, ripErr)
					ripFailed = true
				}

				// 2. AP_UIMSG_BOXERROR messages received during the rip — genuine errors
				//    the GUI would have shown as a Critical dialog (read failures, etc.).
				//    Warning only: makemkvcon often recovers, so the size check is the gate.
				if hadErr, msgs := server.RipHadErrors(); hadErr {
					log.Log(4, "WARNING: Rip reported %d error(s) for title %d (validating output size):\n", len(msgs), cut.Index)
					for _, m := range msgs {
						fmt.Fprintf(os.Stderr, "  • %s\n", m)
					}
				}

				// 3. Filesystem sanity check — stat the filename makemkvcon actually
				//    wrote (re-read from the server post-rip) rather than our predicted
				//    name, so we never accidentally stat a stale leftover file.
				if !ripFailed {
					actualFileName, _ := server.GetUiItemInfo(titleHandle, outputFileNameKey)
					actualFile := filepath.Join(fullTempPath, actualFileName)
					fi, statErr := os.Stat(actualFile)
					if statErr != nil {
						log.Log(3, "Rip output missing for title %d: %v\n", cut.Index, statErr)
						ripFailed = true
					} else {
						actual := fi.Size()
						expected := cut.FileSizeBytes
						if expected > 0 {
							lo := int64(float64(expected) * 0.85)
							hi := int64(float64(expected) * 1.15)
							if actual < lo || actual > hi {
								log.Log(3,
									"Rip output size out of range for title %d: got %d bytes, expected %d ±15%% (%d–%d)\n",
									cut.Index, actual, expected, lo, hi)
								ripFailed = true
							}
						} else if actual < 10*1024*1024 {
							log.Log(3,
								"Rip output suspiciously small for title %d: %d bytes (%s)\n",
								cut.Index, actual, actualFile)
							ripFailed = true
						}
					}
				}

				if ripFailed {
					log.Log(3, "Rip FAILED for title %d: %s — skipping move\n", cut.Index, encodingTrackName)
					continue
				}

				log.Log(-1, "Rip successful for title %d, %s\n", cut.Index, encodingTrackName)
			}

		nextDisc:

			_, height, _ := term.GetSize(int(os.Stdout.Fd()))
			fmt.Printf("\033[%d;0H", height-5)

			server.CloseDisk()
			server.OnIdle()
			mkv.EjectDrive(cfg.DriveLetter)
			for mkv.DiscReady(cfg.DriveLetter) {
				time.Sleep(500 * time.Millisecond)
				server.OnIdle()
			}

			fmt.Println()
		}
	}
}

func serverKeepalive(ctx context.Context, server *mkv.MKVServer) {
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				server.OnIdle()
			case <-ctx.Done():
				return
			}
		}
	}()
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
		ui.ResetScrollRegion()
		log.Log(-1, "- Ctrl+C pressed. Cleaning up processes and exiting")
		os.Exit(0)
	}()
}

func userConfirmed() bool {
	reader := bufio.NewReader(os.Stdin)
	text, _ := reader.ReadString('\n')
	return strings.ToLower(strings.TrimSpace(text)) == "y"
}

func inputLoop() (chan byte, *term.State) {
	keyCh := make(chan byte, 1)
	oldState, err := term.MakeRaw(int(os.Stdin.Fd()))
	go func() {
		if err != nil {
			keyCh <- 0
			return
		}
		defer term.Restore(int(os.Stdin.Fd()), oldState)
		var buf [1]byte
		os.Stdin.Read(buf[:])
		if buf[0] == 3 {
			if oldState != nil {
				term.Restore(int(os.Stdin.Fd()), oldState)
			}
			ui.ResetScrollRegion()
			log.Log(-1, "- Ctrl+C pressed. Cleaning up processes and exiting")
			os.Exit(0)
		}
		keyCh <- buf[0]
	}()
	return keyCh, oldState
}

func RunParallelLookups(info *models.DiscInfo, apiKey string, userTitle string) {
	var wg sync.WaitGroup
	// Mutex to safely write to the slice from multiple goroutines
	var mu sync.Mutex

	for _, cut := range info.DistinctCuts {
		wg.Add(1)
		go func(c models.TitleMetadata) {
			defer wg.Done()

			match, method := tmdb.SearchMovieMatch(userTitle, c.Minutes, apiKey)

			mu.Lock()
			if match != nil {
				year := ""
				if len(match.ReleaseDate) >= 4 {
					year = match.ReleaseDate[:4]
				}
				info.Matches = append(info.Matches, models.MatchResult{
					Index:       c.Index,
					Title:       match.Title,
					Year:        year,
					ImdbID:      match.ImdbID,
					Method:      method,
					NeedsReview: method != "Runtime Match",
				})
				log.Log(-1, "  Cut #%d: Found %s via %s\n", c.Index, match.Title, method)
			} else {
				log.Log(-1, "  Cut #%d: No match found (%s)\n", c.Index, method)
			}
			// Store results in logic
			mu.Unlock()
		}(cut)
	}
	wg.Wait()
}
