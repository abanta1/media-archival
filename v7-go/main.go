package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

// Global Config (PS1 param block)
var (
	TmdbKey   = os.Getenv("TMDB_API")
	debugMode bool
)

func enableANSI() {
	stdout := windows.Handle(os.Stdout.Fd())
	var mode uint32
	windows.GetConsoleMode(stdout, &mode)
	windows.SetConsoleMode(stdout, mode|0x0004) // ENABLE_VIRTUAL_TERMINAL_PROCESSING
}

func main() {
	enableANSI()

	configPath := flag.String("config", "config.json", "")
	flag.StringVar(configPath, "C", "config.json", "")
	flag.BoolVar(&debugMode, "debug", false, "")
	flag.BoolVar(&debugMode, "V", false, "")
	driveLetter := flag.String("drive", "D:", "")
	flag.StringVar(driveLetter, "T", "D:", "")
	apiKey := flag.String("apikey", "", "")
	flag.StringVar(apiKey, "K", "", "")
	destDir := flag.String("dest", "", "")
	flag.StringVar(destDir, "D", "", "")
	ripDir := flag.String("rip", "", "")
	flag.StringVar(ripDir, "R", "", "")

	makemkvPath := flag.String("makemkv", "", "")
	flag.StringVar(makemkvPath, "M", "", "")

	flag.Usage = func() {
		exeName := filepath.Base(os.Args[0])

		fmt.Fprintf(os.Stderr, "Automated MakeMKV utility.\n\n")
		fmt.Fprintf(os.Stderr, "  Usage of %s:\n", exeName)

		fmt.Fprintf(os.Stderr, "  -H, --help\n\tPrints this help message\n")
		fmt.Fprintf(os.Stderr, "  -V, --debug\n\tEnable verbose logging\n\n")
		fmt.Fprintf(os.Stderr, "  -C, --config [string]\n\tPath to config file (default \"config.json\")\n\t"+
			"  config file used for static/normal defaults. Flags override config.\n\t  disc drive, API key, destination dir\n\n")
		fmt.Fprintf(os.Stderr, "  -T, --drive <driveletter:> - i.e. --drive D:\n\tSpecifies the disc drive to use\n\n")
		fmt.Fprintf(os.Stderr, "  -K, --apikey <key> - i.e. --apikey 123ABC\n\tSpecifies the TMDB API key to use for title matching\n\n")
		fmt.Fprintf(os.Stderr, "  -D, --dest <dir> - i.e. --dest C:\\Path\\to\\Final\\\n\tSpecifies the path to use as the base directory for final location\n\n")
		fmt.Fprintf(os.Stderr, "  -R, --rip <dir> - i.e. --dest C:\\Path\\to\\Rip\\\n\tSpecifies the path to use as the base directory for rips\n\n")
		//flag.PrintDefaults() // Prints alphabetically
	}
	flag.Parse()

	// Load config based on flag
	var cfg Config
	if _, err := os.Stat(*configPath); err == nil {
		cfg, _ = LoadConfig(*configPath)
	}

	if *apiKey != "" {
		cfg.APIKey = *apiKey
		TmdbKey = *apiKey
	} else if cfg.APIKey != "" {
		TmdbKey = cfg.APIKey
	}
	if *ripDir != "" {
		cfg.RipPath = *ripDir
	}
	if *destDir != "" {
		cfg.DestPath = *destDir
	}
	if *driveLetter != "" {
		cfg.DriveLetter = *driveLetter
	}
	if *makemkvPath != "" {
		cfg.MakeMKVPath = *makemkvPath
	}

	if cfg.APIKey == "" || cfg.DestPath == "" || cfg.DriveLetter == "" || cfg.MakeMKVPath == "" || cfg.RipPath == "" {
		fmt.Fprintln(os.Stderr, "Error: API Key, Destination Dir and Drive letter are required (via flag or config).")
		flag.Usage()
		os.Exit(0)
	}

	if !ValidatePaths(cfg) {
	}

	// 1. Handle Graceful Exit (Ctrl+C)
	setupCloseHandler()

	fmt.Println("Starting MakeMKV Go-Auto...")
	handle, err := openDriveHandle(cfg.DriveLetter)
	if err != nil {
		debugLog("Failed to open drive handle: %v", err)
	} else {
		lockDrive(handle)
		defer func() {
			unlockDrive(handle)
			windows.CloseHandle(handle)
		}()
	}

	// 2. Main Exec Loop
	for {
		// Wait for disc
		dots := []string{".   ", "..  ", "... ", "...."}
		for i := 0; !discReady(cfg.DriveLetter); i++ {
			fmt.Printf("\rWaiting for disc%s", dots[i%4])
			time.Sleep(500 * time.Millisecond)
		}

		fmt.Println("\nDisc detected! Starting workflow...")
		lockDrive(handle)

		driveIndex, _ := GetDriveIndex(cfg.DriveLetter, cfg.MakeMKVPath)
		fmt.Println("Drive Index: " + driveIndex)

		fmt.Println("Scanning Disc Info...")
		info := runMetadataScan(driveIndex, cfg.MakeMKVPath)

		if info.Title != "" {
			// Allow user to edit disc title before TMDB search
			fmt.Printf("Title detected: %s\n", info.Title)
			fmt.Println("Press Enter to edit, any other key to continue (30s)...")

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
				keyCh <- buf[0]
			}()

			select {
			case key := <-keyCh:
				fmt.Println()
				if key == 13 {
					fmt.Print("Enter new title: ")
					var newTitle string
					fmt.Scanln(&newTitle)
					if strings.TrimSpace(newTitle) != "" {
						info.Title = strings.TrimSpace(newTitle)
					}
				}
			case <-time.After(30 * time.Second):
				fmt.Println("\nContinuing...")
			}

			fmt.Println("Processing cuts...")
			ProcessCuts(&info)

			fmt.Println("Identifying video via TMDB...")
			RunParallelLookups(&info, TmdbKey)

			for _, cut := range info.DistinctCuts {
				var match *MatchResult
				for i := range info.Matches {
					if info.Matches[i].Index == cut.Index {
						match = &info.Matches[i]
						break
					}
				}
				imdbID := "unknown"
				encodingTitle := info.Title
				year := ""
				if match != nil {
					imdbID = match.ImdbID
					encodingTitle = match.Title
					year = match.Year
				}
				yearPart := ""
				if year != "" {
					yearPart = fmt.Sprintf(" (%s)", year)
				}
				encodingDir := fmt.Sprintf("%s%s {imdb-%s}", encodingTitle, yearPart, imdbID)
				encNewName := fmt.Sprintf("%s%s", encodingTitle, yearPart)
				fullTempPath := filepath.Join(cfg.RipPath, encodingDir)
				os.MkdirAll(fullTempPath, 0755)
				args := []string{
					"-r",
					"--progress=-stdout",
					"mkv",
					"--noscan",
					"--minlength=900",
					"disc:" + driveIndex,
					fmt.Sprintf("%d", cut.Index),
					fullTempPath,
				}

				debugLog("Cut #%d: encodingTitle='%s' year='%s' imdbID='%s'", cut.Index, encodingTitle, year, imdbID)
				debugLog("encodingDir: %s", encodingDir)
				debugLog("encNewName: %s", encNewName)
				debugLog("origName: %s", cut.FileName)
				debugLog("fileSize: %s", cut.FileSize)
				debugLog("fullTempPath: %s", fullTempPath)
				debugLog("DestPath: %s", cfg.DestPath)
				debugLog("Rip args: %v", args)

				expectedFile := filepath.Join(fullTempPath, cut.FileName)
				if _, err := os.Stat(expectedFile); err == nil {
					fmt.Printf("File already exists, skipping: %s\n", expectedFile)
					continue
				}

				InvokeMakeMKVRip(encNewName, args, cfg.MakeMKVPath)
				MoveAndRename(fullTempPath, encNewName, encodingDir, cfg.DestPath)
			}

			unlockDrive(handle)
			ejectDrive(cfg.DriveLetter)
		}
	}
}

func setupCloseHandler() {
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		fmt.Println("\n- Ctrl+C pressed. Cleaning up processes and exiting")
		// Logic to kill orphaned Java/MakeMKV goes here
		os.Exit(0)
	}()
}

func debugLog(format string, args ...interface{}) {
	if debugMode {
		fmt.Printf("[DEBUG] "+format+"\n", args...)
	}
}

func discReady(letter string) bool {
	// Checks for common optical disc structures
	_, errIFO := os.Stat(letter + "\\VIDEO_TS")
	_, errBDMV := os.Stat(letter + "\\BDMV")
	return errIFO == nil || errBDMV == nil
}

func userConfirmed() bool {
	reader := bufio.NewReader(os.Stdin)
	text, _ := reader.ReadString('\n')
	return strings.ToLower(strings.TrimSpace(text)) == "y"
}

func RunParallelLookups(info *DiscInfo, apiKey string) {
	var wg sync.WaitGroup
	// Mutex to safely write to the slice from multiple goroutines
	var mu sync.Mutex

	for _, cut := range info.DistinctCuts {
		wg.Add(1)
		go func(c TitleMetadata) {
			defer wg.Done()

			match, method := SearchMovieMatch(info.Title, c.Minutes, apiKey)

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
