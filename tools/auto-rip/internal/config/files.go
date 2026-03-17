package config

import (
	log "media-archival/v7/internal/logger"
	"os"
)

func ValidatePaths(cfg Config) bool {
	paths := []string{cfg.DestPath, cfg.DestPath, cfg.MakeMKVPath}
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			log.Log(3, "Path Error: %s is invalid or unreachable\n", p)
			return false
		}
	}
	return true
}
