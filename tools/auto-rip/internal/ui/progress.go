package ui

import (
	"fmt"
	log "media-archival/v7/internal/logger"

	"os"
	"strings"

	"golang.org/x/term"
)

func SetScrollRegion(reserve int) {
	_, height, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil {
		return
	}
	// Set scroll region to all lines except bottom `reserve` lines
	log.DebugLog("setScrollRegion: height=%d reserve=%d scrollEnd=%d", height, reserve, height-reserve)
	fmt.Printf("\033[1;%dr\033[3J", height-reserve)
	// Clear the reserved lines
	for i := 0; i < reserve; i++ {
		fmt.Printf("\033[%d;0H\033[K", height-reserve+1+i)
	}
	// Move cursor back to top of scroll region
	fmt.Printf("\033[%d;0H", height-reserve)
}

func ResetScrollRegion() {
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

// DrawProgressBar creates a [####------] 50% style bar
func DrawProgressBar(activity string, status string, pct int, line int) {
	const barLength = 30
	filledLength := (pct * barLength) / 100
	if filledLength < 0 {
		filledLength = 0
	}
	if filledLength > barLength {
		filledLength = barLength
	}
	bar := strings.Repeat("█", filledLength) + strings.Repeat("░", barLength-filledLength)

	_, height, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil {
		return
	}
	targetLine := height - (2 - line)

	// \r = carriage return
	// \033[K clears rest of line to prevent ghost text
	//fmt.Printf("\r\033[K%s: [%s] %d%% | %s", activity, bar, pct, status)

	fmt.Printf("\033[s\033[%d;0H\033[K%s: [%s] %3d%% | %s\033[u", targetLine, activity, bar, pct, status)
}
