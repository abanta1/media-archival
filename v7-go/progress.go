package main

import (
	"fmt"
	"strings"
)

// DrawProgressBar creates a [####------] 50% style bar
func DrawProgressBar(activity string, status string, pct int) {
	const barLength = 30
	filledLength := (pct * barLength) / 100
	if filledLength < 0 {
		filledLength = 0
	}
	if filledLength > barLength {
		filledLength = barLength
	}

	bar := strings.Repeat("█", filledLength) + strings.Repeat("░", barLength-filledLength)

	// \r = carriage return
	// \033[K clears rest of line to prevent ghost text
	fmt.Printf("\r\033[K%s: [%s] %d%% | %s", activity, bar, pct, status)
}
