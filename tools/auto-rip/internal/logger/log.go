package log

import (
	"fmt"
	"media-archival/v7/internal/globals"
)

func DebugLog(format string, args ...interface{}) {
	if globals.DebugMode {
		fmt.Printf("[DEBUG] "+format+"\n", args...)
	}
}
