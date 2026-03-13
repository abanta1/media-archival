package main

import (
	"fmt"
	"os"
	"strings"

	"golang.org/x/term"
)

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
