package main

import (
	"fmt"
	"os"
)

func ValidatePaths(cfg Config) bool {
	paths := []string{cfg.DestPath, cfg.MakeMKVPath}
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			fmt.Printf("Path Error: %s is invalid or unreachable\n", p)
			return false
		}
	}
	return true
}
