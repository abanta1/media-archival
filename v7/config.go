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
	MinSeconds  int    `json:"min_seconds"`
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

func SaveConfig(cfgPath string, cfg Config) error {
	file, err := os.Create(cfgPath)
	if err != nil {
		return err
	}
	defer file.Close()
	enc := json.NewEncoder(file)
	enc.SetIndent("", "  ")
	return enc.Encode(cfg)
}
