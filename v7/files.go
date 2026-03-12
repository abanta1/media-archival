package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

func MoveAndRename(fullPath, desiredName, encodingName, encodingDir string, baseOutputDir string) error {
	// Find all mkv files in the temp rip dir
	files, err := os.ReadDir(fullPath)
	if err != nil {
		return err
	}

	reRip := regexp.MustCompile(`(?i)(.*)(_t\d{2})\.mkv$`)
	debugLog("MoveAndRename: reRip='%s'", reRip)

	for _, file := range files {
		if file.IsDir() || !reRip.MatchString(file.Name()) {
			continue
		}

		debugLog("MoveAndRename: fullPath='%s' desiredName='%s' encodingName='%s' encodingDir='%s' baseOutputDir='%s'", fullPath, encodingName, encodingDir, baseOutputDir)

		matches := reRip.FindStringSubmatch(file.Name())
		ripExt := matches[2] // e.g., "_t00"
		newName := encodingName + ripExt + ".mkv"

		destDir := filepath.Join(baseOutputDir, encodingDir)
		srcFile := filepath.Join(fullPath, file.Name())
		tempNewPath := filepath.Join(fullPath, newName)
		destFile := filepath.Join(destDir, newName)

		debugLog("MoveAndRename: matches='%s' ripExt='%s' newName='%s' destDir='%s' srcFile='%s' tempNewPath='%s' destFile='%s'",
			matches, ripExt, newName, destDir, srcFile, tempNewPath, destFile)

		// 1. Ensure Destination Dir exists
		os.MkdirAll(destDir, 0755)

		// 2. Local Rename first (inside temp folder)
		if err := os.Rename(srcFile, tempNewPath); err != nil {
			return fmt.Errorf("failed local rename: %v", err)
		}

		// 3. Retry loop for move
		success := false
		for i := 1; i <= 10; i++ {
			err := os.Rename(tempNewPath, destFile)
			if err == nil {
				success = true
				break
			}
			fmt.Printf("\rMove attempt %d/10 failed, retrying in 200ms...", i)
			time.Sleep(200 * time.Millisecond)
		}

		if !success {
			return fmt.Errorf("failed to move %s after 10 attempts", newName)
		}

		// 4. Clean up _t00 suffix if main title
		if strings.HasSuffix(newName, "_t00.mkv") {
			finalName := strings.Replace(destFile, "_t00.mkv", ".mkv", 1)
			os.Rename(destFile, finalName)
		}

		fmt.Printf("\nSuccessfully moved: %s\n", newName)
	}
	return nil
}

func ValidatePaths(cfg Config) bool {
	paths := []string{cfg.RipPath, cfg.DestPath, cfg.MakeMKVPath}
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			fmt.Printf("Path Error: %s is invalid or unreachable\n", p)
			return false
		}
	}
	return true
}
