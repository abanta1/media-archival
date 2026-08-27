// Copyright (c) 2000-2026 Anthony Banta - MIT License
package log

import (
	"fmt"
	"media-archival/v7/internal/globals"
)

func Log(level int, format string, args ...interface{}) {
	// If logging is disabled [-1] (normal) or message is too quiet, dont print
	if (level >= 0) && (level <= 7) && (level > globals.LogLevel) {
		return
	}

	switch level {
	case 0:
		fmt.Printf("\n[EMERGENCY] "+format+"\n", args...)
	case 1:
		fmt.Printf("\n[ALERT] "+format+"\n", args...)
	case 2:
		fmt.Printf("\n[CRITICAL] "+format+"\n", args...)
	case 3:
		fmt.Printf("\n[ERROR] "+format+"\n", args...)
	case 4:
		fmt.Printf("\n[WARN] "+format+"\n", args...)
	case 5:
		fmt.Printf("\n[NOTICE] "+format+"\n", args...)
	case 6:
		fmt.Printf("\n[INFO] "+format+"\n", args...)
	case 7:
		fmt.Printf("\n[DEBUG] "+format+"\n", args...)
	default:
		fmt.Printf(format+"\n", args...)
	}
}

