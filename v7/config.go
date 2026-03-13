package main

import (
	"encoding/json"
	"os"
)

type Config struct {
	DriveLetter string `json:"drive_letter"`
	DestPath    string `json:"base_path"`
	MakeMKVPath string `json:"makemkv_path"`
	APIKey      string `json:"api_key"`
}

func LoadConfig(cfgPath string) (Config, error) {
	file, err := os.Open(cfgPath)
	if err != nil {
		return Config{}, err
	}
	defer file.Close()
	var cfg Config
	json.NewDecoder(file).Decode(&cfg)
	return cfg, err
}
